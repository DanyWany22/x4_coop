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
  /x4coop status            print mode, link, proxy state and where your partner is
  /x4coop join              warp your ship beside your partner (pilot seat, undocked)
  /x4coop say <text>        send a chat line to your partner
  /x4coop guestship         (host, shared world) park a spare ship next to you for the joiner, then save
  /x4coop takeship          (joiner) move into the guest ship from the host's save
  /x4coop ghost | net | off switch mode (remembered in the savegame)
  /x4coop backend lua|md|auto
  /x4coop probe             re-run the rotation-convention probe
  /x4coop pipe <name>       use another pipe name (a second game on the same PC; not saved)
  /x4coop set <key> <value> tweak a numeric setting, e.g. /x4coop set interp_delay 0.15

Wire format (one message per pipe write, '|' separated, also used by the Python tools):
  S|seq|t|sector_macro|ship_macro|x|y|z|yaw|pitch|roll|vx|vy|vz|name[|idcode]   snapshot (sender clock t in s)
  P|t / Q|t                                                            ping / pong (RTT)
  M|name|text                                                          chat line
  R|role, L|world|role|ship, K|ship, D|ship|hull, F|ship                shared world (see that section)
  B|t|sector|radius|complete|code,macro,owner,hull,x,y,z,yaw,pitch,roll,vx,vy,vz;...   host's nearby ships
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
	const char* GetObjectIDCode(UniverseID objectid);
	UIPosRot GetObjectPositionInSector(UniverseID objectid);
	const char* GetPlayerName(void);
	UniverseID GetPlayerID(void);
	UniverseID GetPlayerOccupiedShipID(void);
	bool IsComponentOperational(UniverseID componentid);
	bool IsGamePaused(void);
	void SetObjectSectorPos(UniverseID objectid, UniverseID sectorid, UIPosRot offset);
	const char* CanTeleportPlayerTo(UniverseID controllableid, bool allowcontrolling, bool force);
	bool TeleportPlayerTo(UniverseID controllableid, bool allowcontrolling, bool instant, bool force);
]]

local config = {
	mode = "ghost",           -- "ghost" (offline test), "net" (needs the bridge), "off"; chat choice overrides per save
	backend = "auto",         -- "lua", "md" or "auto"
	send_rate = 30,           -- snapshots per second (limited by frame rate)
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
	engine_fx = 1,            -- 1: also give the proxy matching physics velocity (experiment: engine effects,
	engine_fx_rate = 4,       --    covers frames without a Lua update); commands per second
	fire_fx = 1,              -- 1: proxies get a pilot and fire at what their player is hitting (ghost: what you hit)
	npc_sync = 1,             -- 1: in a linked shared world, the host's nearby ships drive the joiner's copies
	npc_radius = 6000,        -- m, "nearby"
	npc_rate = 10,            -- host: NPC pose updates per second
	npc_mirror = 1,           -- joiner: create stand-ins for ships only the host has
	npc_remove = 1,           -- joiner: remove ships near the host that the host doesn't have
	npc_hull = 1,             -- joiner: take the host's (lower) hull values
	ghost_latency = 0.12,     -- s, simulated one-way latency in ghost mode
	ghost_jitter = 0.03,      -- s, extra random delay per snapshot
	ghost_loss = 0.0,         -- 0..1, fraction of snapshots dropped
	ghost_right = 60,         -- m, ghost offset in your ship's frame: ahead and to the right, so it is
	ghost_up = 0,             --    in view from the cockpit (raise these for L/XL ships)
	ghost_forward = 120,
	pipe = "x4_coop",
}

local SETTINGS_KEY = { mode = "$x4coop_mode", backend = "$x4coop_backend" }
local PIPES_MODULE = "extensions.sn_mod_support_apis.ui.named_pipes.Interface"

local S = {}  -- all runtime state, rebuilt by reset()
local kept_role = nil  -- "host"/"join" from the bridge; it only says so when the pipe connects

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
-- Measured in-game (v9.00, 2026-10-08): pitch and roll turn the opposite way to right-handed maths.
local DEFAULT_CONV = { order = "YXZ", sy = 1, sp = -1, sr = -1 }

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
		health = { frames = 0, gap_max = 0, corr_sum = 0, corr_n = 0, corr_max = 0 },
		link = { role = kept_role, world = nil, state = nil, linked = false, last_sent = -1e9, last_hit = {} },
		npc = { sent_radius = nil, members = {}, ents = {}, prev = {}, last_send = -1e9, received = 0, driven = 0,
			found = {}, mirrors = {}, mirror_of = {}, pending = {}, unmatched = {}, removed = {}, removed_count = 0,
			dead = {}, my_hits = {}, last_sweep = -1e9 },
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
		local code = C.GetObjectIDCode(ship)
		L.idcode = code ~= nil and ffi.string(code) or ""
	end
	if sector ~= L.sector then
		L.sector, L.prev = sector, nil
		L.sector_macro = GetComponentData(to64(sector), "macro")
	end
	if not L.sector_macro or not L.ship_macro or now - L.last_send < 1 / config.send_rate - 0.004 then
		return nil
	end
	local p = C.GetObjectPositionInSector(ship)
	L.seq = L.seq + 1
	local s = {
		seq = L.seq, t = now, sector_macro = L.sector_macro, ship_macro = L.ship_macro, name = L.name, idcode = L.idcode,
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

-- Text that is safe to put in a message field and to show: no separators or control characters.
local function clean_text(text, max_len)
	text = tostring(text or ""):gsub("[|%c]", " "):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
	return text:sub(1, max_len)
end

local function encode_snapshot(s)
	return string.format("S|%d|%.4f|%s|%s|%.2f|%.2f|%.2f|%.5f|%.5f|%.5f|%.2f|%.2f|%.2f|%s|%s",
		s.seq, s.t, s.sector_macro, s.ship_macro, s.x, s.y, s.z, s.yaw, s.pitch, s.roll, s.vx, s.vy, s.vz,
		clean_text(s.name, 32), s.idcode or "")
end

local function split(msg)
	local f = {}
	for part in (msg .. "|"):gmatch("([^|]*)|") do
		f[#f + 1] = part
	end
	return f
end

-- Snapshots come from another machine: accept only sane values, since they end up in md lookups and ship placement.
local SNAPSHOT_LIMITS = { x = 1e7, y = 1e7, z = 1e7, yaw = 10, pitch = 10, roll = 10, vx = 1e5, vy = 1e5, vz = 1e5 }

local function decode_snapshot(f)
	if #f < 15 then return nil end
	local s = { seq = tonumber(f[2]), t = tonumber(f[3]), sector_macro = f[4], ship_macro = f[5] }
	for _, macro in ipairs({ s.sector_macro, s.ship_macro }) do
		if #macro > 80 or not macro:match("^[%w_]+$") then return nil end
	end
	if not s.t or s.t ~= s.t or math.abs(s.t) > 1e9 then return nil end
	local keys = { "x", "y", "z", "yaw", "pitch", "roll", "vx", "vy", "vz" }
	for i, k in ipairs(keys) do
		local v = tonumber(f[5 + i])
		if not v or v ~= v or math.abs(v) > SNAPSHOT_LIMITS[k] then return nil end
		s[k] = v
	end
	s.name = clean_text(f[15], 32)
	if s.name == "" then s.name = "Partner" end
	if f[16] and #f[16] <= 16 and f[16]:match("^[%w%-]+$") then
		s.idcode = f[16]  -- their ship's ID code: in a shared world that ship exists here too
	end
	return s
end

-------------------------------------------------------------------------------
-- Remote snapshots: buffering and sampling

local function on_snapshot(s, now, R)
	R = R or S.rem
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
	R.count = (R.count or 0) + 1
end

local function latency_estimate()
	if config.mode == "ghost" then
		return config.ghost_latency + config.ghost_jitter * 0.5
	end
	return S.net.rtt and S.net.rtt * 0.5 or 0
end

-- Pose of an entity (default: the partner) at sender time tr: Hermite interpolation between
-- snapshots, linear dead reckoning past the newest one.
local function sample_remote(tr, R)
	local snaps = (R or S.rem).snaps
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

local function remote_target(now, R)
	R = R or S.rem
	if not R.lag then return nil end
	local tr
	if config.predict == 1 then
		tr = now - R.lag + latency_estimate()
	else
		tr = now - R.lag - config.interp_delay
	end
	return sample_remote(tr, R)
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
local on_world_message  -- shared-world messages (R, L, K, D), defined after proxy management
local send_link

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
		send_link(now)
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
		N.status = "bridge not running (start bridge/x4_coop_bridge.py)"
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
		if tonumber(f[2]) then
			net_send("Q|" .. f[2])
		end
	elseif kind == "Q" then
		local t = tonumber(f[2])
		if t and now - t >= 0 and now - t < 10 then
			local rtt = now - t
			N.rtt = N.rtt and (N.rtt * 0.8 + rtt * 0.2) or rtt
		end
	elseif kind == "M" then
		local text = clean_text(f[3], 200)
		if text ~= "" then
			notify("%s: %s", clean_text(f[2], 32), text)
		end
	elseif kind == "N" or kind == "W" then
		notify("%s", clean_text(f[2], 200))
	elseif kind == "R" or kind == "L" or kind == "K" or kind == "D" or kind == "F" or kind == "B" then
		if config.mode == "net" then on_world_message(kind, f, now) end
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

-- The pose to show this frame: move the shown pose D with the target's velocity, then blend away the
-- remaining error (snap when far off). Returns the new pose and the error that was blended (nil on a snap).
local function follow(D, target, dt)
	if not D or math.sqrt((D.x - target.x) ^ 2 + (D.y - target.y) ^ 2 + (D.z - target.z) ^ 2) > config.snap_distance then
		return { x = target.x, y = target.y, z = target.z, q = target.q }, nil
	end
	local k = 1 - math.exp(-dt / config.smoothing)
	local miss = math.sqrt((D.x + target.vx * dt - target.x) ^ 2 + (D.y + target.vy * dt - target.y) ^ 2 + (D.z + target.vz * dt - target.z) ^ 2)
	D.x = D.x + target.vx * dt
	D.y = D.y + target.vy * dt
	D.z = D.z + target.vz * dt
	D.x = D.x + (target.x - D.x) * k
	D.y = D.y + (target.y - D.y) * k
	D.z = D.z + (target.z - D.z) * k
	D.q = slerp(D.q, target.q, k)
	return D, miss
end

local function drive_lua(now, dt, target)
	local P = S.proxy
	local D, miss = follow(P.shown, target, dt)
	if miss then
		local H = S.health
		H.corr_sum, H.corr_n, H.corr_max = H.corr_sum + miss, H.corr_n + 1, math.max(H.corr_max, miss)
	end
	P.shown = D
	if config.engine_fx == 1 and now - (P.last_fx or 0) >= 1 / config.engine_fx_rate then
		P.last_fx = now
		request("velocity", { target.vx, target.vy, target.vz })
	end
	if P.last_cmd then
		local cur = C.GetObjectPositionInSector(P.id)
		local dev = math.sqrt((cur.x - P.last_cmd[1]) ^ 2 + (cur.y - P.last_cmd[2]) ^ 2 + (cur.z - P.last_cmd[3]) ^ 2)
		P.max_dev = math.max(P.max_dev or 0, dev)
	end
	C.SetObjectSectorPos(P.id, P.sector, make_posrot(D.x, D.y, D.z, D.q))
	P.last_cmd = { D.x, D.y, D.z }
end

-- "in <sector>, 1.2 km away" for the partner's proxy, or nil while there is none.
local function partner_whereabouts()
	local P = S.proxy
	if P.state ~= "live" or P.sector == 0 then return nil end
	local text = "in " .. tostring(GetComponentData(to64(P.sector), "name") or P.sector_macro)
	local ship = C.GetPlayerOccupiedShipID()
	if ship ~= 0 and C.GetContextByClass(ship, "sector", false) == P.sector then
		local a, b = C.GetObjectPositionInSector(ship), C.GetObjectPositionInSector(P.id)
		local d = math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2)
		text = text .. (d < 1000 and string.format(", %.0f m away", d) or string.format(", %.1f km away", d / 1000))
	end
	return text
end

-- Every 15 s while the proxy is live, one log line with what is needed to debug "I can't see it".
local function health_report(now, backend)
	local P, R = S.proxy, S.rem
	if now < (P.report_at or 0) then return end
	local span = now - (P.report_from or now)
	local H = S.health
	if span > 0 then
		log("health: proxy %s via %s backend, partner %s | %.1f snapshots/s | %.0f updates/s, longest gap %.0f ms"
			.. " | corrections avg %.2f m, max %.2f m | engine moved it up to %s from where it was put (engine_fx %d)",
			P.state, backend, partner_whereabouts() or "?", ((R.count or 0) - (P.report_count or 0)) / span,
			H.frames / span, H.gap_max * 1000, H.corr_n > 0 and H.corr_sum / H.corr_n or 0, H.corr_max,
			P.max_dev and string.format("%.1f m", P.max_dev) or "n/a", config.engine_fx)
		if (S.npc.sent_radius or 0) > 0 then
			local n = 0
			for _ in pairs(S.npc.members) do n = n + 1 end
			local mirrors = 0
			for _ in pairs(S.npc.mirrors) do mirrors = mirrors + 1 end
			log("health: npc bubble as %s: %d ships nearby, %d driven, %d stand-ins, %d removed, %.0f poses/s received",
				S.link.role or "?", n, S.npc.driven, mirrors, S.npc.removed_count, S.npc.received / span)
		end
		S.npc.received = 0
	end
	P.report_at, P.report_from, P.report_count, P.max_dev = now + 15, now, R.count or 0, nil
	S.health = { frames = 0, gap_max = 0, corr_sum = 0, corr_n = 0, corr_max = 0 }
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

-- ID code of the ship we are flying, or nil.
local function own_idcode()
	local ship = C.GetPlayerOccupiedShipID()
	local code = ship ~= 0 and C.GetObjectIDCode(ship) or nil
	return code ~= nil and ffi.string(code) or nil
end

-- In a shared world the partner's own ship exists here (same ID code) and should be their proxy.
local function adopt_wanted(snapshot)
	return config.mode == "net" and S.link.linked and snapshot.idcode ~= nil
end

local function proxy_is_adopted()
	local P = S.proxy
	if P.state ~= "live" or P.id == 0 then return false end
	local code = C.GetObjectIDCode(P.id)
	local newest = S.rem.snaps[#S.rem.snaps]
	return code ~= nil and newest ~= nil and ffi.string(code) == newest.idcode
end

-- The backend in use: the forced one, or what the self-test picked.
local function effective_backend()
	return config.backend ~= "auto" and config.backend or S.backend
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
			P.sector_macro, P.ship_macro, P.idcode = newest.sector_macro, newest.ship_macro, newest.idcode
			P.adopt_requested = adopt_wanted(newest)
			P.blocked_by_me = P.adopt_requested and own_idcode() == newest.idcode
			request("spawn", { newest.sector_macro, newest.ship_macro, newest.x, newest.y, newest.z,
				newest.yaw, newest.pitch, newest.roll, newest.name or "Partner",
				newest.idcode or "", P.adopt_requested and 1 or 0, config.fire_fx == 1 and 1 or 0 })
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
	if newest.ship_macro ~= P.ship_macro or (newest.idcode and P.idcode and newest.idcode ~= P.idcode) then
		despawn_proxy(now)  -- they changed ships; respawn next frame with the new one
		return
	end
	-- Retry adoption only when something changed: the worlds got linked after the proxy spawned, or
	-- adoption was blocked because we were sitting in their ship and have since left it.
	if adopt_wanted(newest) and not proxy_is_adopted()
		and (not P.adopt_requested or (P.blocked_by_me and own_idcode() ~= newest.idcode)) then
		log("retrying proxy as %s (their own ship)", newest.idcode)
		despawn_proxy(now)
		return
	end
	if newest.sector_macro ~= P.sector_macro then
		P.sector_macro, P.shown = newest.sector_macro, nil
		request("warp", { newest.sector_macro, newest.x, newest.y, newest.z, newest.yaw, newest.pitch, newest.roll })
		set_proxy_state("warping", now)
		return
	end
	if C.IsGamePaused() then return end

	-- The self-test also finds out whether SetObjectSectorPos wants degrees, so it runs even when a
	-- backend is forced.
	if not S.backend then
		backend_selftest(now)
		return
	end
	local backend = effective_backend()
	local target = remote_target(now)
	if not target then return end
	if backend == "lua" then
		drive_lua(now, dt, target)
	else
		drive_md(now, target)
	end
	health_report(now, backend)
end

-------------------------------------------------------------------------------
-- NPC bubble (shared world). Both games list the ships near their player (md BubbleScan, every second).
-- The host sends their poses at npc_rate; the joiner moves its own copies of the same ships (same ID
-- code) with the partner's smoothing and prediction, so a fight looks the same on both sides.
-- The host's world is the truth near the players (the joiner's world is a copy of the host's save):
--   * a ship the joiner can't find gets a stand-in ("mirror") - md first looks for the real copy;
--   * ships only the joiner has, well inside the host's coverage, are removed (never player-owned);
--   * hull follows the host, except that the joiner's own fresh hits are not undone.
-- Ships that were just killed are "dead" for a while, so they don't come back as stand-ins.

local NPC_MAX = 40           -- ships per bubble (md lists at most this many)
local NPC_DEAD_HOLD = 30     -- s a killed ship stays dead here, whatever the host still says
local NPC_LOST_GRACE = 3     -- s to wait for the host's verdict when our copy dies on its own

local function npc_enabled()
	return config.mode == "net" and S.link.linked and config.npc_sync == 1 and effective_backend() == "lua"
end

local function lua_id(id)
	return ConvertStringToLuaID(tostring(id))
end

-- md finished a scan: player.entity.$x4coop_bubble lists the nearby ships, nearest first;
-- $x4coop_bubble_complete says whether that is all of them.
local function on_bubble()
	local N = S.npc
	local list = S.player and GetNPCBlackboard(S.player, "$x4coop_bubble")
	if type(list) ~= "table" then return end
	local members = {}
	for _, ship in ipairs(list) do
		local id = to64(ship)
		local code = C.GetObjectIDCode(id)
		if code ~= nil and C.IsComponentOperational(id) then
			members[ffi.string(code)] = { id = id, macro = GetComponentData(id, "macro"), owner = GetComponentData(id, "owner"),
				hull = GetComponentData(id, "hullpercent"), playerowned = GetComponentData(id, "isplayerowned") }
		end
	end
	N.members = members
	local complete = GetNPCBlackboard(S.player, "$x4coop_bubble_complete")
	N.scan_complete = complete == 1 or complete == true
	-- Our real copy came into range of a ship we had a stand-in for: the stand-in goes.
	for code, mirror in pairs(N.mirrors) do
		if members[code] then
			request("obj_remove", { lua_id(mirror.id) })
			N.mirrors[code] = nil
		end
	end
end

-- md answered stand-in requests: player.entity.$x4coop_mirrors = list of [host idcode, ship, created].
-- created = 0 means md found our own copy of that ship (outside our scan), 1 that it made a stand-in.
local function on_npc_mirror()
	local N = S.npc
	local list = S.player and GetNPCBlackboard(S.player, "$x4coop_mirrors")
	if S.player then SetNPCBlackboard(S.player, "$x4coop_mirrors", nil) end
	if type(list) ~= "table" then return end
	for _, v in ipairs(list) do
		if type(v) == "table" and type(v[1]) == "string" and v[2] then
			local id = to64(v[2])
			N.pending[v[1]] = nil
			if v[3] == 1 or v[3] == true then
				N.mirrors[v[1]] = { id = id }
				local local_code = C.GetObjectIDCode(id)
				if local_code ~= nil then N.mirror_of[ffi.string(local_code)] = v[1] end
			else
				N.found[v[1]] = { id = id }
			end
		end
	end
end

-- The joiner's ship for a host ID code: our copy (in our scan, or found further away), or our stand-in.
local function npc_local(code)
	local N = S.npc
	local m = N.members[code] or N.found[code] or N.mirrors[code]
	return m and C.IsComponentOperational(m.id) and m.id or nil
end

local function npc_count(t)
	local n = 0
	for _ in pairs(t) do n = n + 1 end
	return n
end

local function npc_send(now)
	local N = S.npc
	if now - N.last_send < 1 / config.npc_rate or not S.loc.sector_macro then return end
	N.last_send = now
	local entries, prev = {}, N.prev
	for code, m in pairs(N.members) do
		if C.IsComponentOperational(m.id) and C.GetContextByClass(m.id, "sector", false) == S.loc.sector then
			local p = C.GetObjectPositionInSector(m.id)
			local q = prev[code]
			local vx, vy, vz = 0, 0, 0
			if q and now - q.t > 0.001 and now - q.t < 1 then
				vx, vy, vz = (p.x - q.x) / (now - q.t), (p.y - q.y) / (now - q.t), (p.z - q.z) / (now - q.t)
			end
			prev[code] = { t = now, x = p.x, y = p.y, z = p.z }
			entries[#entries + 1] = string.format("%s,%s,%s,%.1f,%.2f,%.2f,%.2f,%.5f,%.5f,%.5f,%.2f,%.2f,%.2f",
				code, m.macro, tostring(m.owner or "ownerless"), tonumber(m.hull) or 100, p.x, p.y, p.z, p.yaw, p.pitch, p.roll, vx, vy, vz)
		end
	end
	-- "complete" tells the joiner it may remove ships we don't list; md says whether the list was cut off.
	net_send(string.format("B|%.4f|%s|%d|%d|%s", now, S.loc.sector_macro, config.npc_radius, N.scan_complete and 1 or 0,
		table.concat(entries, ";")))
end

-- Joiner: one B message from the host.
local function npc_receive(f, now)
	local N = S.npc
	local t, radius = tonumber(f[2]), tonumber(f[4])
	if not t or f[3] ~= S.loc.sector_macro or not radius or radius ~= radius then return end  -- only the sector we are in
	N.host_radius, N.host_complete, N.last_b = math.max(0, math.min(radius, config.npc_radius)), f[5] == "1", now
	local taken = 0
	for entry in (f[6] or ""):gmatch("[^;]+") do
		if taken >= NPC_MAX then break end
		local v = {}
		for field in entry:gmatch("[^,]+") do v[#v + 1] = field end
		local code, macro, owner, hull = v[1], v[2], v[3], tonumber(v[4])
		if #v == 13 and #code <= 16 and code:match("^[%w%-]+$") and #macro <= 80 and macro:match("^[%w_]+$")
			and #owner <= 40 and owner:match("^[%w_]+$") and hull and hull >= 0 and hull <= 100
			and not (N.dead[code] and now - N.dead[code] < NPC_DEAD_HOLD) then
			local s = { t = t, sector_macro = f[3], ship_macro = macro }
			local okay = true
			for i, k in ipairs({ "x", "y", "z", "yaw", "pitch", "roll", "vx", "vy", "vz" }) do
				local num = tonumber(v[4 + i])
				if not num or num ~= num or math.abs(num) > SNAPSHOT_LIMITS[k] then okay = false break end
				s[k] = num
			end
			if okay then
				taken = taken + 1
				local E = N.ents[code] or { snaps = {}, first = now }
				N.ents[code] = E
				on_snapshot(s, now, E)
				E.seen, E.macro, E.owner, E.hull = now, macro, owner, hull
				N.received = N.received + 1
			end
		end
	end
end

local function npc_reset_tables(N)
	N.ents, N.members, N.found, N.mirrors, N.mirror_of = {}, {}, {}, {}, {}
	N.pending, N.unmatched, N.dead, N.my_hits = {}, {}, {}, {}
end

local function npc_tick(now, dt)
	local N = S.npc
	local radius = npc_enabled() and config.npc_radius or 0
	if radius ~= N.sent_radius then
		N.sent_radius = radius
		request("bubble", { radius })
		if radius == 0 then
			request("npc_clear", {})
			npc_reset_tables(N)
		end
	end
	if radius == 0 or C.IsGamePaused() then return end
	if S.link.role == "host" then
		npc_send(now)
		return
	end
	-- Joiner: drive our ships for the host's. Ones the host stopped mentioning go back to their own AI;
	-- stand-ins for them are removed.
	local driven, requested = 0, 0
	local stand_ins = npc_count(N.mirrors) + npc_count(N.pending)
	for code, E in pairs(N.ents) do
		local id = npc_local(code)
		if now - (E.seen or 0) > 2 or (N.dead[code] and now - N.dead[code] < NPC_DEAD_HOLD) then
			N.ents[code] = nil
			local mirror = N.mirrors[code]
			if mirror then
				if C.IsComponentOperational(mirror.id) then request("obj_remove", { lua_id(mirror.id) }) end
				N.mirrors[code] = nil
			end
			N.found[code] = nil
		elseif id then
			E.had, E.lost = true, nil
			local target = remote_target(now, E)
			if target then
				E.shown = follow(E.shown, target, dt)
				local sector = C.GetContextByClass(id, "sector", false)
				C.SetObjectSectorPos(id, sector, make_posrot(E.shown.x, E.shown.y, E.shown.z, E.shown.q))
				driven = driven + 1
			end
			-- The host referees damage: follow its hull, but don't undo our own hits from the last 3 s.
			if config.npc_hull == 1 and E.hull and now - (E.hull_at or 0) >= 1 then
				E.hull_at = now
				local mine = tonumber(GetComponentData(id, "hullpercent"))
				local my_hit = now - (N.my_hits[code] or -1e9) < 3
				if mine and (E.hull < mine - 1 or (E.hull > mine + 1 and not my_hit)) then
					request("obj_hull", { lua_id(id), E.hull })
				end
			end
		else
			-- Nothing of ours to drive. If our copy just died, give the host time to report the kill first.
			if E.had then E.lost = E.lost or now end
			local settled = not E.had or now - E.lost >= NPC_LOST_GRACE
			if config.npc_mirror == 1 and settled and now - E.first > 1 and now - (N.pending[code] or -1e9) > 5
				and requested < 2 and stand_ins < NPC_MAX then
				local newest = E.snaps[#E.snaps]
				if newest then
					requested, stand_ins = requested + 1, stand_ins + 1
					N.pending[code] = now
					request("npc_mirror", { code, E.macro, E.owner, newest.sector_macro,
						newest.x, newest.y, newest.z, newest.yaw, newest.pitch, newest.roll })
				end
			end
		end
	end
	N.driven = driven

	-- Remove ships the host doesn't have, but only where the host's list is complete and covers them.
	if config.npc_remove == 1 and now - N.last_sweep >= 1 then
		N.last_sweep = now
		local P = S.proxy
		local host_pos = (P.state == "live" and P.sector == S.loc.sector and N.host_complete and now - (N.last_b or -1e9) < 1)
			and C.GetObjectPositionInSector(P.id) or nil
		for code, m in pairs(N.members) do
			if N.ents[code] or N.removed[code] or not host_pos or m.playerowned then
				N.unmatched[code] = nil
			else
				local p = C.GetObjectPositionInSector(m.id)
				local d = math.sqrt((p.x - host_pos.x) ^ 2 + (p.y - host_pos.y) ^ 2 + (p.z - host_pos.z) ^ 2)
				if d > 0.8 * N.host_radius then
					N.unmatched[code] = nil
				else
					N.unmatched[code] = N.unmatched[code] or now
					if now - N.unmatched[code] >= 3 then
						N.removed[code] = true
						N.removed_count = N.removed_count + 1
						request("obj_remove", { lua_id(m.id) })
					end
				end
			end
		end
	end
end

-------------------------------------------------------------------------------
-- Shared world. Both players load the same save (the host's), so every ship exists on both sides
-- with the same ID code. The host's save carries a world id; once both games report the same id,
-- with one host and one joiner, the local player's kills and hits are mirrored onto the same ships
-- in the partner's world (md: OnPlayerKill/OnPlayerHit report, OnWorldKill/OnWorldHull apply).

local WORLD_KEY = "$x4coop_world"
local IDCODE_PATTERN = "^[%w%-]+$"

-- The world id lives on the player's blackboard, so it is saved with the game and travels with the save.
local function world_id()
	local K = S.link
	if not K.world and S.player then
		local id = GetNPCBlackboard(S.player, WORLD_KEY)
		if type(id) == "string" and id:match("^%w+$") then
			K.world = id
		elseif K.role == "host" then
			K.world = string.format("%06x%06x", math.floor(getElapsedTime() * 1e6) % 16777216, math.random(0, 16777215))
			SetNPCBlackboard(S.player, WORLD_KEY, K.world)
			notify("new co-op world %s: save now and give that save to your partner", K.world)
		end
	end
	return K.world
end

local function update_link(now)
	local K = S.link
	local state
	if not K.role then
		state = "waiting for the bridge to say host or join"
	elseif not world_id() then
		state = "no world id: load the host's latest save"
	elseif not K.heard_at or now - K.heard_at > 6 then
		state = "waiting for partner"
	elseif K.partner_world ~= K.world then
		state = "different worlds: the joiner must load the host's save made after co-op started"
	elseif K.partner_role == K.role then
		state = "both sides are " .. K.role .. "s: one bridge needs --host, the other --join"
	else
		state = "linked"
	end
	K.linked = state == "linked"
	if state ~= K.state then
		K.state = state
		if state ~= "waiting for partner" or K.linked_before then notify("world: %s", state) end
		K.linked_before = K.linked_before or K.linked
	end
	local mine = own_idcode()
	local clash = K.linked and mine ~= nil and mine == K.partner_ship
	if clash and not K.clash then
		notify("you are both flying %s; the joiner should switch ships%s", mine,
			K.role == "join" and " (/x4coop takeship, if the host made a guest ship)" or "")
	end
	K.clash = clash
end

send_link = function(now)
	local K = S.link
	update_link(now)
	if K.role then
		net_send(string.format("L|%s|%s|%s", world_id() or "-", K.role, own_idcode() or "-"))
	end
end

local function valid_world_ref(idcode, ship_macro, sector_macro)
	return type(idcode) == "string" and #idcode <= 16 and idcode:match(IDCODE_PATTERN)
		and type(ship_macro) == "string" and #ship_macro <= 80 and ship_macro:match("^[%w_]+$")
		and type(sector_macro) == "string" and #sector_macro <= 80 and sector_macro:match("^[%w_]+$")
end

on_world_message = function(kind, f, now)
	local K = S.link
	if kind == "R" then
		if (f[2] == "host" or f[2] == "join") and K.role ~= f[2] then
			K.role, kept_role = f[2], f[2]
			update_link(now)
		end
	elseif kind == "L" then
		if (f[3] == "host" or f[3] == "join") and type(f[2]) == "string" and f[2]:match("^[%w%-]+$") then
			K.partner_world, K.partner_role, K.heard_at = f[2], f[3], now
			K.partner_ship = (f[4] or ""):match(IDCODE_PATTERN) and f[4] or nil
			update_link(now)
		end
	elseif kind == "B" then
		if K.linked and K.role == "join" and npc_enabled() then npc_receive(f, now) end
	elseif K.linked and valid_world_ref(f[2], f[3], f[4]) then
		local mirror = S.npc.mirrors[f[2]]  -- a ship we only have as a stand-in: address it directly
		if kind == "K" then S.npc.dead[f[2]] = now end
		if mirror then
			if kind == "F" then
				request("obj_fire", { lua_id(mirror.id) })
			elseif kind == "K" then
				request("obj_kill", { lua_id(mirror.id) })
			elseif tonumber(f[5]) and tonumber(f[5]) >= 0 and tonumber(f[5]) <= 100
				and tonumber(f[5]) < (tonumber(GetComponentData(mirror.id, "hullpercent")) or 0) then
				request("obj_hull", { lua_id(mirror.id), tonumber(f[5]) })  -- lowest hull wins
			end
		elseif kind == "F" then
			request("fire", { f[2], f[3], f[4] })
		elseif kind == "K" then
			request("world_kill", { f[2], f[3], f[4] })
		else
			local hull = tonumber(f[5])
			if hull and hull >= 0 and hull <= 100 then
				request("world_hull", { f[2], f[3], f[4], hull })
			end
		end
	end
end

-- md reports the local player's kills ("K|idcode|macro|sector") and hits ("D|...|hull").
local function on_world_event(_, param)
	local K = S.link
	local f = split(tostring(param or ""))
	if not valid_world_ref(f[2], f[3], f[4]) then return end
	f[2] = S.npc.mirror_of[f[2]] or f[2]  -- a stand-in we made: use the host's code for it
	local now = getElapsedTime()
	if f[1] == "D" and config.fire_fx == 1 and now - (K.last_fire or -1e9) >= 0.5 then
		-- You are hitting f[2]: your proxy on the other side (or your ghost here) fires at it too.
		K.last_fire = now
		if config.mode == "ghost" then
			request("fire", { f[2], f[3], f[4] })
		elseif config.mode == "net" and K.linked then
			net_send(table.concat({ "F", f[2], f[3], f[4] }, "|"))
		end
	end
	if config.mode ~= "net" or not K.linked then return end
	if f[1] == "K" then
		S.npc.dead[f[2]] = now  -- don't bring it back as a stand-in while the host catches up
		net_send(table.concat({ "K", f[2], f[3], f[4] }, "|"))
	elseif f[1] == "D" then
		local hull = tonumber(tostring(f[5]):match("^%-?[%d%.]+"))
		S.npc.my_hits[f[2]] = now  -- the host's hull mustn't undo this hit before it has counted it
		if hull and now - (K.last_hit[f[2]] or -1e9) >= 0.3 then  -- hits can arrive every frame
			K.last_hit[f[2]] = now
			net_send(string.format("D|%s|%s|%s|%.2f", f[2], f[3], f[4], hull))
		end
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
	S.npc.sent_radius = nil
	if first then
		log("md ready; mode=%s backend=%s", config.mode, config.backend)
	end
end

local function on_proxy_spawned(_, ship)
	local P = S.proxy
	P.id = to64(ship)
	P.sector = C.GetContextByClass(P.id, "sector", false)
	P.shown, P.test, P.last_cmd, P.report_at = nil, nil, nil, nil
	set_proxy_state("live", getElapsedTime())
	log("proxy live")
	notify("%s is %s", S.rem.name or "partner", partner_whereabouts() or "here")
end

local function on_warped(_, ship)
	local P = S.proxy
	P.sector, P.shown, P.last_cmd = C.GetContextByClass(P.id, "sector", false), nil, nil
	set_proxy_state("live", getElapsedTime())
	notify("%s moved %s", S.rem.name or "partner", partner_whereabouts() or "")
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
	-- Only new attitudes tell conventions apart; sitting still would just repeat one sample.
	local q_new = quat_from_euler(p[1], p[2], p[3])
	for _, old in ipairs(P.samples) do
		if quat_angle(quat_from_euler(old[1], old[2], old[3]), q_new) < 0.15 then return end
	end
	P.samples[#P.samples + 1] = p
	local conv, err, runner_up = calibrate(P.samples)
	if err > 0.05 then
		P.done = true
		log("probe: no convention fits (best %s, error %.3f); keeping %s. raw: %s",
			conv_name(conv), err, conv_name(S.conv), table.concat(p, ", "))
	elseif err < 0.001 and runner_up > math.max(0.004, 10 * err) then
		-- md's vectors are exact, so an exact fit with a clearly worse runner-up decides it, even when
		-- the runner-up is close (e.g. a roll-sign difference while the player hardly rolls).
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
		S.npc.ents = {}
		log("probe: engine rotation convention is %s (error %.4f, next best %.3f, %d samples)",
			conv_name(conv), err, runner_up, #P.samples)
	elseif #P.samples >= 40 then
		P.done = true
		log("probe: still ambiguous after %d different attitudes (best %s); keeping %s. raw: %s",
			#P.samples, conv_name(conv), conv_name(S.conv), table.concat(p, ", "))
	elseif #P.samples % 5 == 0 then
		log("probe: %d attitudes so far, best %s (error %.3f, next best %.3f); keep pitching and rolling",
			#P.samples, conv_name(conv), err, runner_up)
	end
end

-------------------------------------------------------------------------------
-- Chat commands

local function status_text()
	local P, R, N = S.proxy, S.rem, S.net
	local age = R.last_recv > 0 and string.format("%.1fs ago", getElapsedTime() - R.last_recv) or "never"
	local link = config.mode == "net" and (N.status .. (N.rtt and string.format(", rtt %.0f ms", N.rtt * 1000) or "")
		.. " | " .. (S.link.role or "?") .. ", world " .. (S.link.state or "unknown")) or "-"
	return string.format("mode %s | backend %s (%s) | proxy %s%s | partner %s %s, last snapshot %s | link %s | rotation %s %s",
		config.mode, config.backend, S.backend or "untested", P.state, proxy_is_adopted() and " (their own ship)" or "",
		R.name or "-", partner_whereabouts() or "", age, link,
		conv_name(S.conv), S.probe.measured and "measured" or "assumed")
end

local USAGE = "usage: /x4coop status | join | say <text> | guestship | takeship | ghost | net | off | backend lua|md|auto | probe | pipe <name> | set <key> <number>"

local function guest_ship()
	local ship = S.player and GetNPCBlackboard(S.player, "$x4coop_guestship")
	if not ship then return nil end
	local id = to64(ship)
	return C.IsComponentOperational(id) and id or nil
end

local function take_guest_ship()
	local id = guest_ship()
	if not id then
		notify("no guest ship in this save: the host types /x4coop guestship, saves, and sends you that save")
		return
	end
	if id == C.GetPlayerOccupiedShipID() then
		notify("you are already in the guest ship")
		return
	end
	local verdict = ffi.string(C.CanTeleportPlayerTo(id, true, true))
	if verdict ~= "granted" then
		notify("the game won't move you to the guest ship: %s", verdict)
		return
	end
	C.TeleportPlayerTo(id, true, true, true)
	notify("moved to the guest ship %s; take the pilot seat", ffi.string(C.GetObjectIDCode(id)))
end

local function say(text)
	text = clean_text(text, 200)
	if text == "" then
		notify("usage: /x4coop say <text>")
	elseif config.mode == "ghost" then
		notify("Ghost: %s", text)  -- the ghost repeats you, so this tests the display path
	elseif config.mode == "net" and S.net.connected then
		net_send("M|" .. clean_text(S.loc.name, 32) .. "|" .. text)
		notify("you: %s", text)
	else
		notify("not connected to the bridge; message not sent")
	end
end

local function command(param)
	local args = {}
	for word in tostring(param or ""):gmatch("%S+") do args[#args + 1] = word end
	local cmd = args[1] or "status"
	if cmd == "ghost" or cmd == "net" or cmd == "off" then
		if config.mode == "net" and cmd ~= "net" then
			-- Stop listening, so nothing from the partner reaches this world outside net mode.
			local N = S.net
			if N.api and N.reading and N.api.Close_Pipe then pcall(N.api.Close_Pipe, config.pipe) end
			N.reading, N.connected, N.status = false, false, "idle"
			S.link.linked, S.link.state, S.link.heard_at = false, nil, nil
		end
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
	elseif cmd == "join" then
		request("join", {})
	elseif cmd == "guestship" then
		request("guestship", {})
	elseif cmd == "takeship" then
		take_guest_ship()
	elseif cmd == "pipe" then
		-- A second game on the same PC needs its own pipe (and its own bridge with --pipe). Not saved:
		-- both games may load the same save.
		local name = args[2]
		if name and #name <= 40 and name:match("^[%w_]+$") then
			local N = S.net
			if N.api and N.reading and N.api.Close_Pipe then pcall(N.api.Close_Pipe, config.pipe) end
			config.pipe = name
			N.reading, N.connected, N.retry_at, N.status = false, false, 0, "connecting to bridge"
			notify("pipe %s: start this game's bridge with --pipe %s", name, name)
		else
			notify("pipe is %s; /x4coop pipe <name> gives a second game on this PC its own bridge", config.pipe)
		end
	elseif cmd == "say" then
		say(tostring(param):match("^%s*say%s+(.*)$"))
	else
		notify("%s", USAGE)
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
	-- A new game swaps the player character during setup, so follow the id and only touch the
	-- player's blackboard once md reports the game is up.
	local player64 = to64(player)
	if S.player and S.player ~= player64 then
		reset()
	end
	if not S.player then
		S.player = player64
		local name = C.GetPlayerName()
		S.loc.name = name ~= nil and ffi.string(name) or "Pilot"
	end
	if S.md_ready and not S.settings_loaded then
		S.settings_loaded = true
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
	npc_tick(now, dt)
end

local function on_update()
	local now = getElapsedTime()
	local dt = S.last_frame and math.min(now - S.last_frame, 0.25) or 0
	S.last_frame = now
	local H = S.health
	H.frames, H.gap_max = H.frames + 1, math.max(H.gap_max, dt)
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
	RegisterEvent("x4coop.world", on_world_event)
	RegisterEvent("x4coop.bubble", on_bubble)
	RegisterEvent("x4coop.npc_mirror", on_npc_mirror)

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
