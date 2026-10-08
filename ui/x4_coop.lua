--[[
X4 Co-op (prototype) - Lua side. Loaded through ui.xml.

Each player runs their own single-player universe. The other player is shown as a
"proxy" ship whose pose is copied from their snapshots, so two players can fly side
by side in the same sector. Nothing else (NPCs, combat, economy) is shared yet.

Per frame this file:
  1. samples the local player's ship pose (sector space) and, at send_rate, emits a snapshot;
  2. delivers the partner's snapshots, either from the offline "ghost" loopback (your own
     ship, delayed and offset) or from the named pipe to the Python network bridge;
  3. keeps a short snapshot buffer and interpolates / dead-reckons the partner's pose;
  4. moves the proxy: SetObjectSectorPos every frame ("lua" backend), or warp/velocity
     commands to md/x4_coop.xml ("md" backend). "auto" self-tests "lua" and falls back.

Chat window commands (type them in the chat window, they never leave your PC):
  /x4coop status            print mode, link and proxy state
  /x4coop ghost | net | off switch mode (remembered in the savegame)
  /x4coop backend lua|md|auto
  /x4coop probe             re-run the rotation-convention probe
  /x4coop set <key> <value> tweak a numeric setting, e.g. /x4coop set interp_delay 0.15

Wire format (one message per pipe write, '|' separated, also used by the Python tools):
  S|seq|t|sector_macro|ship_macro|x|y|z|yaw|pitch|roll|vx|vy|vz|name   snapshot (sender clock t in s)
  P|t / Q|t                                                            ping / pong (RTT)
  W|text, N|text                                                       bridge welcome / notice
]]

local ffi = require("ffi")
local C = ffi.C
ffi.cdef[[
	typedef uint64_t UniverseID;
	typedef struct {
		float x;
		float y;
		float z;
		float yaw;
		float pitch;
		float roll;
	} UIPosRot;
	UniverseID GetContextByClass(UniverseID componentid, const char* classname, bool includeself);
	UIPosRot GetObjectPositionInSector(UniverseID objectid);
	const char* GetPlayerName(void);
	UniverseID GetPlayerID(void);
	UniverseID GetPlayerOccupiedShipID(void);
	bool IsComponentOperational(UniverseID componentid);
	bool IsGamePaused(void);
	void SetObjectSectorPos(UniverseID objectid, UniverseID sectorid, UIPosRot offset);
]]

local config = {
	mode = "ghost",           -- "ghost" (offline test), "net" (needs the bridge), "off"; chat choice overrides per save
	backend = "auto",         -- "lua", "md" or "auto"
	send_rate = 20,           -- snapshots per second
	predict = 1,              -- 1: dead-reckon the partner to the estimated present; 0: show them interp_delay in the past
	interp_delay = 0.10,      -- s, jitter buffer used when predict is 0
	max_extrapolation = 0.5,  -- s, never dead-reckon further than this
	smoothing = 0.08,         -- s, time constant for blending corrections into the shown pose
	snap_distance = 1000,     -- m, teleport instead of blending beyond this error
	stale_timeout = 10,       -- s without snapshots before the proxy is removed
	md_rate = 10,             -- md backend: commands per second
	md_snap_distance = 50,    -- m, md backend warps when further off than this
	md_snap_angle = 0.15,     -- rad, md backend warps when rotated further off than this
	md_gain = 2.0,            -- 1/s, md backend: velocity correction per metre of error
	ghost_latency = 0.12,     -- s, simulated one-way latency in ghost mode
	ghost_jitter = 0.03,      -- s, extra random delay per snapshot
	ghost_loss = 0.0,         -- 0..1, fraction of snapshots dropped
	ghost_right = 100,        -- m, ghost offset in your ship's frame (raise it for L/XL ships)
	ghost_up = 0,
	ghost_forward = 0,
	pipe = "x4_coop",
}

local SETTINGS_KEY = { mode = "$x4coop_mode", backend = "$x4coop_backend" }
local PIPES_MODULE = "extensions.sn_mod_support_apis.ui.named_pipes.Interface"

local S = {}  -- all runtime state, rebuilt by reset()

local function log(fmt, ...)
	DebugError("[x4coop] " .. string.format(fmt, ...))
end

local function notify(fmt, ...)
	local text = string.format(fmt, ...)
	log("%s", text)
	AddUITriggeredEvent("x4coop", "notify", text)
end

local function to64(id)
	return ConvertStringTo64Bit(tostring(id))
end

-------------------------------------------------------------------------------
-- Rotation maths.
-- Snapshots carry the engine's own yaw/pitch/roll. A "convention" says how the engine turns
-- those into axes: the order in which the yaw (Y), pitch (X) and roll (Z) rotations apply, and
-- a sign per angle. Every conversion goes through it, so interpolated poses go back to the
-- engine in its own terms. The probe measures it (calibrate below); until then YXZ+++ is assumed.

local AXIS = { X = 1, Y = 2, Z = 3 }
local EVEN_ORDER = { XYZ = true, YZX = true, ZXY = true }
local ORDERS = { "YXZ", "YZX", "XYZ", "XZY", "ZXY", "ZYX" }
local DEFAULT_CONV = { order = "YXZ", sy = 1, sp = 1, sr = 1 }

local function conv_name(c)
	return c.order .. (c.sy > 0 and "+" or "-") .. (c.sp > 0 and "+" or "-") .. (c.sr > 0 and "+" or "-")
end

local function mat_mul(a, b)
	local r = {}
	for i = 1, 3 do
		r[i] = {}
		for j = 1, 3 do
			r[i][j] = a[i][1] * b[1][j] + a[i][2] * b[2][j] + a[i][3] * b[3][j]
		end
	end
	return r
end

local function axis_rot(axis, a)
	local c, s = math.cos(a), math.sin(a)
	if axis == "X" then return { { 1, 0, 0 }, { 0, c, -s }, { 0, s, c } } end
	if axis == "Y" then return { { c, 0, s }, { 0, 1, 0 }, { -s, 0, c } } end
	return { { c, -s, 0 }, { s, c, 0 }, { 0, 0, 1 } }
end

-- Rotation matrix whose columns are the right, up and forward vectors in sector space.
local function mat_from_euler(conv, yaw, pitch, roll)
	local ang = { Y = yaw * conv.sy, X = pitch * conv.sp, Z = roll * conv.sr }
	local a, b, c = conv.order:sub(1, 1), conv.order:sub(2, 2), conv.order:sub(3, 3)
	return mat_mul(mat_mul(axis_rot(a, ang[a]), axis_rot(b, ang[b])), axis_rot(c, ang[c]))
end

local function euler_from_mat(conv, m)
	local o = conv.order
	local i, j, k = AXIS[o:sub(1, 1)], AXIS[o:sub(2, 2)], AXIS[o:sub(3, 3)]
	local e = EVEN_ORDER[o] and 1 or -1
	local s = e * m[i][k]
	local c = math.sqrt(m[i][i] * m[i][i] + m[i][j] * m[i][j])
	local t1, t2, t3
	if c < 1e-7 then
		-- Gimbal lock: the first and last axes line up, so put the whole turn in the first angle.
		local sign = s > 0 and 1 or -1
		t1, t2, t3 = math.atan2(sign * m[j][i], m[j][j]), sign * math.pi / 2, 0
	else
		t1, t2, t3 = math.atan2(-e * m[j][k], m[k][k]), math.atan2(s, c), math.atan2(-e * m[i][j], m[i][i])
	end
	local ang = { [o:sub(1, 1)] = t1, [o:sub(2, 2)] = t2, [o:sub(3, 3)] = t3 }
	return ang.Y * conv.sy, ang.X * conv.sp, ang.Z * conv.sr
end

local function quat_from_mat(m)
	local tr = m[1][1] + m[2][2] + m[3][3]
	if tr > 0 then
		local s = math.sqrt(tr + 1) * 2
		return { 0.25 * s, (m[3][2] - m[2][3]) / s, (m[1][3] - m[3][1]) / s, (m[2][1] - m[1][2]) / s }
	elseif m[1][1] > m[2][2] and m[1][1] > m[3][3] then
		local s = math.sqrt(1 + m[1][1] - m[2][2] - m[3][3]) * 2
		return { (m[3][2] - m[2][3]) / s, 0.25 * s, (m[1][2] + m[2][1]) / s, (m[1][3] + m[3][1]) / s }
	elseif m[2][2] > m[3][3] then
		local s = math.sqrt(1 + m[2][2] - m[1][1] - m[3][3]) * 2
		return { (m[1][3] - m[3][1]) / s, (m[1][2] + m[2][1]) / s, 0.25 * s, (m[2][3] + m[3][2]) / s }
	end
	local s = math.sqrt(1 + m[3][3] - m[1][1] - m[2][2]) * 2
	return { (m[2][1] - m[1][2]) / s, (m[1][3] + m[3][1]) / s, (m[2][3] + m[3][2]) / s, 0.25 * s }
end

local function mat_from_quat(q)
	local w, x, y, z = q[1], q[2], q[3], q[4]
	return {
		{ 1 - 2 * (y * y + z * z), 2 * (x * y - w * z), 2 * (x * z + w * y) },
		{ 2 * (x * y + w * z), 1 - 2 * (x * x + z * z), 2 * (y * z - w * x) },
		{ 2 * (x * z - w * y), 2 * (y * z + w * x), 1 - 2 * (x * x + y * y) },
	}
end

local function quat_from_euler(yaw, pitch, roll)
	return quat_from_mat(mat_from_euler(S.conv, yaw, pitch, roll))
end

local function euler_from_quat(q)
	return euler_from_mat(S.conv, mat_from_quat(q))
end

local function quat_dot(a, b)
	return a[1] * b[1] + a[2] * b[2] + a[3] * b[3] + a[4] * b[4]
end

local function quat_mul(a, b)
	return {
		a[1] * b[1] - a[2] * b[2] - a[3] * b[3] - a[4] * b[4],
		a[1] * b[2] + a[2] * b[1] + a[3] * b[4] - a[4] * b[3],
		a[1] * b[3] - a[2] * b[4] + a[3] * b[1] + a[4] * b[2],
		a[1] * b[4] + a[2] * b[3] - a[3] * b[2] + a[4] * b[1],
	}
end

local function quat_angle(a, b)
	local d = math.min(1, math.abs(quat_dot(a, b)))
	return 2 * math.acos(d)
end

local function slerp(a, b, t)
	local d = quat_dot(a, b)
	local s = 1
	if d < 0 then d, s = -d, -1 end
	local wa, wb
	if d > 0.9995 then
		wa, wb = 1 - t, t
	else
		local th = math.acos(d)
		local sn = math.sin(th)
		wa, wb = math.sin((1 - t) * th) / sn, math.sin(t * th) / sn
	end
	wb = wb * s
	local q = { wa * a[1] + wb * b[1], wa * a[2] + wb * b[2], wa * a[3] + wb * b[3], wa * a[4] + wb * b[4] }
	local n = math.sqrt(quat_dot(q, q))
	return { q[1] / n, q[2] / n, q[3] / n, q[4] / n }
end

-- Angular velocity (sector axes, rad/s) that turns a into b in dt seconds.
local function angular_velocity(a, b, dt)
	local d = quat_mul(b, { a[1], -a[2], -a[3], -a[4] })
	if d[1] < 0 then d = { -d[1], -d[2], -d[3], -d[4] } end
	local sn = math.sqrt(d[2] * d[2] + d[3] * d[3] + d[4] * d[4])
	if sn < 1e-9 or dt <= 0 then return { 0, 0, 0 } end
	local k = 2 * math.atan2(sn, d[1]) / (sn * dt)
	return { d[2] * k, d[3] * k, d[4] * k }
end

-- q turned by angular velocity w (sector axes) for dt seconds.
local function quat_advance(q, w, dt)
	local wn = math.sqrt(w[1] * w[1] + w[2] * w[2] + w[3] * w[3])
	if wn < 1e-9 or dt <= 0 then return q end
	local half = wn * dt * 0.5
	local s = math.sin(half) / wn
	return quat_mul({ math.cos(half), w[1] * s, w[2] * s, w[3] * s }, q)
end

-- Right, up and forward unit vectors in sector space.
local function basis(conv, yaw, pitch, roll)
	local m = mat_from_euler(conv, yaw, pitch, roll)
	return { m[1][1], m[2][1], m[3][1] }, { m[1][2], m[2][2], m[3][2] }, { m[1][3], m[2][3], m[3][3] }
end

-- Fit the convention to probe samples { yaw, pitch, roll, fx, fy, fz, rx, ry, rz, ux, uy, uz }.
-- Returns the best convention, its RMS axis error, and the runner-up's error. One sample taken
-- in level flight fits many conventions, so callers keep sampling until the runner-up is far off.
local function calibrate(samples)
	local results = {}
	for _, order in ipairs(ORDERS) do
		for sy = -1, 1, 2 do
			for sp = -1, 1, 2 do
				for sr = -1, 1, 2 do
					local conv = { order = order, sy = sy, sp = sp, sr = sr }
					local e = 0
					for _, p in ipairs(samples) do
						local r, u, f = basis(conv, p[1], p[2], p[3])
						for n = 1, 3 do
							e = e + (f[n] - p[3 + n]) ^ 2 + (r[n] - p[6 + n]) ^ 2 + (u[n] - p[9 + n]) ^ 2
						end
					end
					results[#results + 1] = { conv = conv, err = math.sqrt(e / #samples) }
				end
			end
		end
	end
	table.sort(results, function(a, b) return a.err < b.err end)
	return results[1].conv, results[1].err, results[2].err
end

-------------------------------------------------------------------------------
-- State

local function reset()
	S = {
		player = nil,           -- 64-bit player id, owner of the blackboard settings
		md_ready = false,
		handshake_at = -1e9,
		last_frame = nil,
		last_error_at = -1e9,
		conv = DEFAULT_CONV,
		probe = { samples = {}, next_at = 0, done = false, measured = false },
		loc = { ship = 0, sector = 0, sector_macro = nil, ship_macro = nil, prev = nil, last_send = -1e9, seq = 0, name = "Pilot" },
		rem = { snaps = {}, last_recv = -1e9, lag = nil, name = nil },
		proxy = { id = 0, sector = 0, sector_macro = nil, ship_macro = nil, state = "none", since = -1e9, shown = nil, last_md = -1e9, test = nil },
		backend = nil,          -- resolved backend: "lua" or "md" (nil while auto is undecided)
		lua_degrees = false,    -- set if SetObjectSectorPos turns out to take degrees
		ghost = { queue = {} },
		net = { api = nil, status = "idle", reading = false, connected = false, retry_at = 0, last_ping = -1e9, rtt = nil },
	}
end
reset()

local function load_settings()
	for key, bbkey in pairs(SETTINGS_KEY) do
		local v = GetNPCBlackboard(S.player, bbkey)
		if type(v) == "string" and v ~= "" then
			config[key] = v
		end
	end
end

local function save_setting(key)
	if S.player then
		SetNPCBlackboard(S.player, SETTINGS_KEY[key], config[key])
	end
end

-------------------------------------------------------------------------------
-- Local player sampling

local function local_tick(now)
	local L = S.loc
	local ship = C.GetPlayerOccupiedShipID()
	if ship == 0 then
		L.ship, L.prev = 0, nil
		return nil
	end
	local sector = C.GetContextByClass(ship, "sector", false)
	if sector == 0 then
		return nil  -- e.g. inside a superhighway
	end
	if ship ~= L.ship then
		L.ship, L.prev = ship, nil
		L.ship_macro = GetComponentData(to64(ship), "macro")
	end
	if sector ~= L.sector then
		L.sector, L.prev = sector, nil
		L.sector_macro = GetComponentData(to64(sector), "macro")
	end
	if not L.sector_macro or not L.ship_macro or now - L.last_send < 1 / config.send_rate then
		return nil
	end
	local p = C.GetObjectPositionInSector(ship)
	L.seq = L.seq + 1
	local s = {
		seq = L.seq, t = now, sector_macro = L.sector_macro, ship_macro = L.ship_macro, name = L.name,
		x = p.x, y = p.y, z = p.z, yaw = p.yaw, pitch = p.pitch, roll = p.roll, vx = 0, vy = 0, vz = 0,
	}
	local prev = L.prev
	if prev and now - prev.t > 0.001 and now - prev.t < 1 then
		local dt = now - prev.t
		s.vx, s.vy, s.vz = (s.x - prev.x) / dt, (s.y - prev.y) / dt, (s.z - prev.z) / dt
	end
	L.prev, L.last_send = s, now
	return s
end

-------------------------------------------------------------------------------
-- Wire format

local function encode_snapshot(s)
	return string.format("S|%d|%.4f|%s|%s|%.2f|%.2f|%.2f|%.5f|%.5f|%.5f|%.2f|%.2f|%.2f|%s",
		s.seq, s.t, s.sector_macro, s.ship_macro, s.x, s.y, s.z, s.yaw, s.pitch, s.roll, s.vx, s.vy, s.vz,
		(tostring(s.name):gsub("|", "/")))
end

local function split(msg)
	local f = {}
	for part in (msg .. "|"):gmatch("([^|]*)|") do
		f[#f + 1] = part
	end
	return f
end

local function decode_snapshot(f)
	if #f < 15 then return nil end
	local s = { seq = tonumber(f[2]), t = tonumber(f[3]), sector_macro = f[4], ship_macro = f[5], name = f[15] }
	local keys = { "x", "y", "z", "yaw", "pitch", "roll", "vx", "vy", "vz" }
	for i, k in ipairs(keys) do
		s[k] = tonumber(f[5 + i])
		if not s[k] then return nil end
	end
	if not s.t or s.sector_macro == "" then return nil end
	return s
end

-------------------------------------------------------------------------------
-- Remote snapshots: buffering and sampling

local function on_snapshot(s, now)
	local R = S.rem
	local snaps = R.snaps
	local last = snaps[#snaps]
	if last and s.t < last.t - 5 then
		snaps, last, R.lag = {}, nil, nil  -- their clock restarted (game restarted)
		R.snaps = snaps
	end
	if last and s.t <= last.t then
		return  -- duplicate or out of order
	end
	if last and s.sector_macro ~= last.sector_macro then
		snaps, last = {}, nil  -- they changed sector; old poses are in other coordinates
		R.snaps = snaps
	end
	s.q = quat_from_euler(s.yaw, s.pitch, s.roll)
	s.w = (last and s.t - last.t < 1) and angular_velocity(last.q, s.q, s.t - last.t) or { 0, 0, 0 }
	snaps[#snaps + 1] = s
	if #snaps > 32 then
		table.remove(snaps, 1)
	end
	-- lag = our clock minus theirs at arrival (clock offset + one-way latency). Follow drops
	-- immediately and rises slowly, so it tracks the least-delayed packets.
	local lag = now - s.t
	if (not R.lag) or lag < R.lag then
		R.lag = lag
	else
		R.lag = R.lag + (lag - R.lag) * 0.01
	end
	R.last_recv, R.name = now, s.name
end

local function latency_estimate()
	if config.mode == "ghost" then
		return config.ghost_latency + config.ghost_jitter * 0.5
	end
	return S.net.rtt and S.net.rtt * 0.5 or 0
end

-- Pose of the partner at sender time tr: Hermite interpolation between snapshots, linear
-- dead reckoning past the newest one.
local function sample_remote(tr)
	local snaps = S.rem.snaps
	local n = #snaps
	if n == 0 then return nil end
	local newest = snaps[n]
	if tr >= newest.t or n == 1 then
		local dt = math.max(0, math.min(tr - newest.t, config.max_extrapolation))
		return {
			x = newest.x + newest.vx * dt, y = newest.y + newest.vy * dt, z = newest.z + newest.vz * dt,
			vx = newest.vx, vy = newest.vy, vz = newest.vz, q = quat_advance(newest.q, newest.w, dt),
		}
	end
	if tr <= snaps[1].t then
		local s = snaps[1]
		return { x = s.x, y = s.y, z = s.z, vx = s.vx, vy = s.vy, vz = s.vz, q = s.q }
	end
	for i = n - 1, 1, -1 do
		local a, b = snaps[i], snaps[i + 1]
		if tr >= a.t then
			local h = b.t - a.t
			local u = (tr - a.t) / h
			local u2, u3 = u * u, u * u * u
			local h00, h10, h01, h11 = 2 * u3 - 3 * u2 + 1, u3 - 2 * u2 + u, -2 * u3 + 3 * u2, u3 - u2
			local function herm(p0, v0, p1, v1)
				return h00 * p0 + h10 * h * v0 + h01 * p1 + h11 * h * v1
			end
			return {
				x = herm(a.x, a.vx, b.x, b.vx), y = herm(a.y, a.vy, b.y, b.vy), z = herm(a.z, a.vz, b.z, b.vz),
				vx = a.vx + (b.vx - a.vx) * u, vy = a.vy + (b.vy - a.vy) * u, vz = a.vz + (b.vz - a.vz) * u,
				q = slerp(a.q, b.q, u),
			}
		end
	end
end

local function remote_target(now)
	local R = S.rem
	if not R.lag then return nil end
	local tr
	if config.predict == 1 then
		tr = now - R.lag + latency_estimate()
	else
		tr = now - R.lag - config.interp_delay
	end
	return sample_remote(tr)
end

-------------------------------------------------------------------------------
-- Ghost loopback: your own snapshots, delayed, jittered and offset, fed back as the partner.

local function ghost_send(s, now)
	if math.random() < config.ghost_loss then return end
	local r, u, f = basis(S.conv, s.yaw, s.pitch, s.roll)
	local g = {}
	for k, v in pairs(s) do g[k] = v end
	local o = { config.ghost_right, config.ghost_up, config.ghost_forward }
	g.x = s.x + r[1] * o[1] + u[1] * o[2] + f[1] * o[3]
	g.y = s.y + r[2] * o[1] + u[2] * o[2] + f[2] * o[3]
	g.z = s.z + r[3] * o[1] + u[3] * o[2] + f[3] * o[3]
	g.name = "Ghost"
	-- The offset point swings as you turn, so its velocity is not yours; difference it like a real sender.
	local prev = S.ghost.prev
	if prev and prev.sector_macro == g.sector_macro and g.t - prev.t > 0.001 and g.t - prev.t < 1 then
		local dt = g.t - prev.t
		g.vx, g.vy, g.vz = (g.x - prev.x) / dt, (g.y - prev.y) / dt, (g.z - prev.z) / dt
	end
	S.ghost.prev = g
	local q = S.ghost.queue
	q[#q + 1] = { at = now + config.ghost_latency + math.random() * config.ghost_jitter, s = g }
end

local function ghost_deliver(now)
	local q = S.ghost.queue
	local keep = {}
	for _, item in ipairs(q) do
		if item.at <= now then
			on_snapshot(item.s, now)
		else
			keep[#keep + 1] = item
		end
	end
	S.ghost.queue = keep
end

-------------------------------------------------------------------------------
-- Network: named pipe to the Python bridge (needs SirNukes' Mod Support APIs)

local on_pipe_message

local function net_send(msg)
	local N = S.net
	if N.connected then
		N.api.Schedule_Write(config.pipe, nil, msg)
	end
end

local function net_tick(now)
	local N = S.net
	if not N.api then
		if now < N.retry_at then return end
		N.retry_at = now + 5
		local ok, api = pcall(require, PIPES_MODULE)
		if not ok or type(api) ~= "table" or not api.Schedule_Read then
			N.status = "Mod Support APIs not installed"
			return
		end
		if api.winpipe_loaded == false then
			N.status = "pipe DLL blocked: turn off Protected UI Mode"
			return
		end
		N.api, N.retry_at = api, 0
	end
	if not N.reading and now >= N.retry_at then
		N.reading, N.status = true, "connecting to bridge"
		N.api.Schedule_Read(config.pipe, on_pipe_message, true)
	end
	if N.connected and now - N.last_ping > 2 then
		N.last_ping = now
		net_send(string.format("P|%.4f", now))
	end
end

on_pipe_message = function(msg)
	local N = S.net
	local now = getElapsedTime()
	if msg == "ERROR" or msg == "CANCELLED" or msg == "TIMEOUT" then
		if N.connected then
			notify("bridge disconnected")
		end
		N.reading, N.connected, N.retry_at = false, false, now + 3
		N.status = "bridge not running (start X4_Python_Pipe_Server)"
		return
	end
	if not N.connected then
		N.connected, N.status = true, "bridge connected"
		notify("bridge connected")
	end
	local f = split(msg)
	local kind = f[1]
	if kind == "S" then
		local s = decode_snapshot(f)
		if s and config.mode == "net" then
			on_snapshot(s, now)
		end
	elseif kind == "P" then
		net_send("Q|" .. tostring(f[2]))
	elseif kind == "Q" then
		local t = tonumber(f[2])
		if t then
			local rtt = now - t
			N.rtt = N.rtt and (N.rtt * 0.8 + rtt * 0.2) or rtt
		end
	elseif kind == "N" or kind == "W" then
		notify("%s", tostring(f[2]))
	end
end

-------------------------------------------------------------------------------
-- Proxy management

local function request(command, args)
	AddUITriggeredEvent("x4coop", command, args)
end

local function set_proxy_state(state, now)
	S.proxy.state, S.proxy.since = state, now
end

local function despawn_proxy(now)
	local P = S.proxy
	if P.state ~= "none" then
		request("despawn", {})
	end
	P.id, P.sector, P.shown, P.test = 0, 0, nil, nil
	set_proxy_state("none", now)
end

local function make_posrot(x, y, z, q)
	local yaw, pitch, roll = euler_from_quat(q)
	if S.lua_degrees then
		yaw, pitch, roll = math.deg(yaw), math.deg(pitch), math.deg(roll)
	end
	local pr = ffi.new("UIPosRot")
	pr.x, pr.y, pr.z, pr.yaw, pr.pitch, pr.roll = x, y, z, yaw, pitch, roll
	return pr
end

-- "auto" backend: move the proxy 30 m up with a known rotation, read it back next frames.
local function backend_selftest(now)
	local P = S.proxy
	local t = P.test
	if not t then
		local p = C.GetObjectPositionInSector(P.id)
		t = { at = now, frames = 0, x = p.x, y = p.y + 30, z = p.z }
		P.test = t
		local pr = ffi.new("UIPosRot")
		pr.x, pr.y, pr.z, pr.yaw, pr.pitch, pr.roll = t.x, t.y, t.z, 0.5, 0, 0
		C.SetObjectSectorPos(P.id, P.sector, pr)
		return
	end
	t.frames = t.frames + 1
	local p = C.GetObjectPositionInSector(P.id)
	local dist = math.sqrt((p.x - t.x) ^ 2 + (p.y - t.y) ^ 2 + (p.z - t.z) ^ 2)
	if dist < 2 then
		S.backend = "lua"
		if math.abs(p.yaw - math.rad(0.5)) < 0.002 then
			S.lua_degrees = true
		end
		log("backend self-test passed: SetObjectSectorPos works (readback yaw %.4f -> angles in %s)", p.yaw, S.lua_degrees and "degrees" or "radians")
	elseif t.frames >= 10 then
		S.backend = "md"
		notify("SetObjectSectorPos had no effect (off by %.0f m); using md backend", dist)
	end
end

local function drive_lua(now, dt, target)
	local P = S.proxy
	local D = P.shown
	if not D or math.sqrt((D.x - target.x) ^ 2 + (D.y - target.y) ^ 2 + (D.z - target.z) ^ 2) > config.snap_distance then
		D = { x = target.x, y = target.y, z = target.z, q = target.q }
	else
		-- Move with the target's velocity, then blend away the remaining error.
		local k = 1 - math.exp(-dt / config.smoothing)
		D.x = D.x + target.vx * dt
		D.y = D.y + target.vy * dt
		D.z = D.z + target.vz * dt
		D.x = D.x + (target.x - D.x) * k
		D.y = D.y + (target.y - D.y) * k
		D.z = D.z + (target.z - D.z) * k
		D.q = slerp(D.q, target.q, k)
	end
	P.shown = D
	C.SetObjectSectorPos(P.id, P.sector, make_posrot(D.x, D.y, D.z, D.q))
end

local function drive_md(now, target)
	local P = S.proxy
	if now - P.last_md < 1 / config.md_rate then return end
	P.last_md = now
	local cur = C.GetObjectPositionInSector(P.id)
	local ex, ey, ez = target.x - cur.x, target.y - cur.y, target.z - cur.z
	local dist = math.sqrt(ex * ex + ey * ey + ez * ez)
	local ang = quat_angle(quat_from_euler(cur.yaw, cur.pitch, cur.roll), target.q)
	local snap = dist > config.md_snap_distance or ang > config.md_snap_angle
	local g = snap and 0 or config.md_gain
	local yaw, pitch, roll = euler_from_quat(target.q)
	request("move", { target.x, target.y, target.z, yaw, pitch, roll,
		target.vx + ex * g, target.vy + ey * g, target.vz + ez * g, snap and 1 or 0 })
end

local function proxy_tick(now, dt)
	local P, R = S.proxy, S.rem
	local newest = R.snaps[#R.snaps]
	local fresh = newest and (now - R.last_recv) < config.stale_timeout
	if config.mode == "off" or not fresh then
		if P.state ~= "none" then
			despawn_proxy(now)
		end
		if not fresh and newest then
			R.snaps, R.lag = {}, nil
		end
		return
	end

	if P.state == "none" or P.state == "failed" then
		local wait = P.state == "failed" and 10 or 0
		if now - P.since >= wait then
			P.sector_macro, P.ship_macro = newest.sector_macro, newest.ship_macro
			request("spawn", { newest.sector_macro, newest.ship_macro, newest.x, newest.y, newest.z,
				newest.yaw, newest.pitch, newest.roll, newest.name or "Partner" })
			set_proxy_state("spawning", now)
		end
		return
	end
	if P.state == "spawning" or P.state == "warping" then
		if now - P.since > 5 then
			log("no answer from md for %s; retrying", P.state)
			set_proxy_state("none", now)
		end
		return
	end

	-- live
	if not C.IsComponentOperational(P.id) then
		log("proxy vanished; respawning")
		P.id = 0
		set_proxy_state("none", now)
		return
	end
	if newest.ship_macro ~= P.ship_macro then
		despawn_proxy(now)  -- they changed ships; respawn next frame with the new hull
		return
	end
	if newest.sector_macro ~= P.sector_macro then
		P.sector_macro, P.shown = newest.sector_macro, nil
		request("warp", { newest.sector_macro, newest.x, newest.y, newest.z, newest.yaw, newest.pitch, newest.roll })
		set_proxy_state("warping", now)
		return
	end
	if C.IsGamePaused() then return end

	local backend = config.backend ~= "auto" and config.backend or S.backend
	if not backend then
		backend_selftest(now)
		return
	end
	local target = remote_target(now)
	if not target then return end
	if backend == "lua" then
		drive_lua(now, dt, target)
	else
		drive_md(now, target)
	end
end

-------------------------------------------------------------------------------
-- Events from md

local function on_md_ready()
	local first = not S.md_ready
	S.md_ready = true
	-- md just destroyed any proxy it had
	S.proxy.id, S.proxy.shown, S.proxy.test = 0, nil, nil
	set_proxy_state("none", getElapsedTime())
	if first then
		log("md ready; mode=%s backend=%s", config.mode, config.backend)
	end
end

local function on_proxy_spawned(_, ship)
	local P = S.proxy
	P.id = to64(ship)
	P.sector = C.GetContextByClass(P.id, "sector", false)
	P.shown, P.test = nil, nil
	set_proxy_state("live", getElapsedTime())
	log("proxy live")
end

local function on_warped(_, ship)
	local P = S.proxy
	P.sector, P.shown = C.GetContextByClass(P.id, "sector", false), nil
	set_proxy_state("live", getElapsedTime())
end

local function on_spawn_failed(_, reason)
	notify("could not place partner: %s", tostring(reason))
	set_proxy_state("failed", getElapsedTime())
end

local function wrap_angle(a)
	return (a + math.pi) % (2 * math.pi) - math.pi
end

local function on_probe_result()
	local P = S.probe
	local p = S.player and GetNPCBlackboard(S.player, "$x4coop_probe")
	local ship = C.GetPlayerOccupiedShipID()
	if P.done or type(p) ~= "table" or #p < 12 or ship == 0 then return end
	-- The convention is fitted to md's angles, so they must be the numbers Lua reads too.
	local q = C.GetObjectPositionInSector(ship)
	if math.abs(wrap_angle(q.yaw - p[1])) + math.abs(wrap_angle(q.pitch - p[2])) + math.abs(wrap_angle(q.roll - p[3])) > 0.1 then
		P.skipped = (P.skipped or 0) + 1
		log("probe: md angles %.4f %.4f %.4f differ from lua angles %.4f %.4f %.4f; sample skipped",
			p[1], p[2], p[3], q.yaw, q.pitch, q.roll)
		P.done = P.skipped >= 10
		return
	end
	P.samples[#P.samples + 1] = p
	local conv, err, runner_up = calibrate(P.samples)
	if err > 0.05 then
		P.done = true
		log("probe: no convention fits (best %s, error %.3f); keeping %s. raw: %s",
			conv_name(conv), err, conv_name(S.conv), table.concat(p, ", "))
	elseif runner_up > 0.2 then
		P.done, P.measured, S.conv = true, true, conv
		-- Buffered rotations were derived with the old convention.
		local prev
		for _, s in ipairs(S.rem.snaps) do
			s.q = quat_from_euler(s.yaw, s.pitch, s.roll)
			s.w = prev and angular_velocity(prev.q, s.q, s.t - prev.t) or { 0, 0, 0 }
			prev = s
		end
		S.proxy.shown = nil
		S.ghost.queue, S.ghost.prev = {}, nil  -- in-flight ghost offsets used the old axes
		log("probe: engine rotation convention is %s (error %.4f, next best %.3f, %d samples)",
			conv_name(conv), err, runner_up, #P.samples)
	elseif #P.samples >= 40 then
		P.done = true
		log("probe: still ambiguous after %d samples (best %s); keeping %s. Pitch and roll a little, then /x4coop probe",
			#P.samples, conv_name(conv), conv_name(S.conv))
	end
end

-------------------------------------------------------------------------------
-- Chat commands

local function status_text()
	local P, R, N = S.proxy, S.rem, S.net
	local age = R.last_recv > 0 and string.format("%.1fs ago", getElapsedTime() - R.last_recv) or "never"
	local link = config.mode == "net" and (N.status .. (N.rtt and string.format(", rtt %.0f ms", N.rtt * 1000) or "")) or "-"
	return string.format("mode %s | backend %s (%s) | proxy %s | partner %s, last snapshot %s | link %s | rotation %s %s | you: %s",
		config.mode, config.backend, S.backend or "untested", P.state, R.name or "-", age, link, conv_name(S.conv),
		S.probe.measured and "measured" or "assumed", S.loc.sector_macro or "not in a ship")
end

local function command(param)
	local args = {}
	for word in tostring(param or ""):gmatch("%S+") do args[#args + 1] = word end
	local cmd = args[1] or "status"
	if cmd == "ghost" or cmd == "net" or cmd == "off" then
		config.mode = cmd
		save_setting("mode")
		S.rem.snaps, S.rem.lag, S.ghost.queue = {}, nil, {}
		notify("mode %s", cmd)
	elseif cmd == "backend" and (args[2] == "lua" or args[2] == "md" or args[2] == "auto") then
		config.backend = args[2]
		save_setting("backend")
		S.proxy.shown, S.proxy.test = nil, nil
		if args[2] == "auto" then S.backend = nil end
		notify("backend %s", args[2])
	elseif cmd == "probe" then
		S.probe = { samples = {}, next_at = 0, done = false, measured = false }
		notify("probe restarted; fly with some pitch and roll")
	elseif cmd == "set" and args[2] and tonumber(args[3]) and type(config[args[2]]) == "number" then
		config[args[2]] = tonumber(args[3])
		notify("%s = %s", args[2], args[3])
	elseif cmd == "status" then
		notify("%s", status_text())
	else
		notify("usage: /x4coop status | ghost | net | off | backend lua|md|auto | probe | set <key> <number>")
	end
end

-------------------------------------------------------------------------------
-- Frame loop

local function tick(now, dt)
	local player = C.GetPlayerID()
	if player == 0 then
		if S.player then reset() end
		return
	end
	if not S.player then
		S.player = to64(player)
		local name = C.GetPlayerName()
		S.loc.name = name ~= nil and ffi.string(name) or "Pilot"
		load_settings()
	end
	if not S.md_ready then
		if now - S.handshake_at > 2 then
			S.handshake_at = now
			request("lua_ready", {})
		end
		return
	end
	local P = S.probe
	if not P.done and now >= P.next_at and C.GetPlayerOccupiedShipID() ~= 0 then
		P.next_at = now + 2
		request("probe", {})
	end

	local s = local_tick(now)
	if config.mode == "ghost" then
		if s then ghost_send(s, now) end
		ghost_deliver(now)
	elseif config.mode == "net" then
		net_tick(now)
		if s then net_send(encode_snapshot(s)) end
	end
	proxy_tick(now, dt)
end

local function on_update()
	local now = getElapsedTime()
	local dt = S.last_frame and math.min(now - S.last_frame, 0.25) or 0
	S.last_frame = now
	local ok, err = pcall(tick, now, dt)
	if not ok and now - S.last_error_at > 5 then
		S.last_error_at = now
		DebugError("[x4coop] error: " .. tostring(err))
	end
end

local function init()
	RegisterEvent("x4coop.md_ready", on_md_ready)
	RegisterEvent("x4coop.proxy_spawned", on_proxy_spawned)
	RegisterEvent("x4coop.proxy_despawned", function() end)
	RegisterEvent("x4coop.warped", on_warped)
	RegisterEvent("x4coop.spawn_failed", on_spawn_failed)
	RegisterEvent("x4coop.probe_result", on_probe_result)

	-- Chat window "/x4coop ..." commands; everything else goes to the original handler.
	local ego_ExecuteDebugCommand = ExecuteDebugCommand
	ExecuteDebugCommand = function(cmd, param, ...)
		if cmd == "x4coop" then
			local ok, err = pcall(command, param)
			if not ok then DebugError("[x4coop] command error: " .. tostring(err)) end
			return
		end
		if ego_ExecuteDebugCommand then
			return ego_ExecuteDebugCommand(cmd, param, ...)
		end
	end

	SetScript("onUpdate", on_update)
end

-- Exposed for debugging and offline tests.
X4Coop = {
	config = config,
	state = function() return S end,
	reset = reset,
	command = command,
	math = {
		mat_from_euler = mat_from_euler, euler_from_mat = euler_from_mat, quat_from_mat = quat_from_mat, mat_from_quat = mat_from_quat,
		quat_from_euler = quat_from_euler, euler_from_quat = euler_from_quat, slerp = slerp, quat_angle = quat_angle,
		angular_velocity = angular_velocity, quat_advance = quat_advance, basis = basis, calibrate = calibrate, conv_name = conv_name,
	},
	wire = { encode_snapshot = encode_snapshot, decode_snapshot = decode_snapshot, split = split },
	on_snapshot = on_snapshot,
	sample_remote = sample_remote,
}

init()
