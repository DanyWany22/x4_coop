--[[
Offline X4 stand-in for ui/x4_coop.lua, run inside the game's LuaJIT by run_tests.py / run_lua.py.
Globals from the runner: MOD (mod lua path), OUT (report path), SCENARIO (name, or "list").

The "engine" here has its own rotation convention (TRUE_CONV), a player ship that flies a
manoeuvring path, an md model (spawn/despawn/warp/move/probe/notify with one frame of event
latency) and optional fake named-pipe API. Errors are measured against ground truth.
]]
local report = {}
local function say(fmt, ...) report[#report + 1] = string.format(fmt, ...) end
local function finish(ok)
	local f = io.open(OUT, "w")
	f:write(table.concat(report, "\n"), "\n", ok and "RESULT: PASS\n" or "RESULT: FAIL\n")
	f:close()
end

local SC = {
	ghost        = { true_conv = { order = "ZXY", sy = -1, sp = 1, sr = -1 }, mode = "ghost", setpos = "radians", duration = 40, fire_test = true },
	ghost_default= { true_conv = { order = "YXZ", sy = 1, sp = 1, sr = 1 }, mode = "ghost", setpos = "radians", duration = 30 },
	degrees      = { true_conv = { order = "YXZ", sy = 1, sp = -1, sr = 1 }, mode = "ghost", setpos = "degrees", duration = 30 },
	setpos_ignored = { true_conv = { order = "YXZ", sy = 1, sp = -1, sr = 1 }, mode = "ghost", setpos = "ignore", duration = 30, max_pos_err = 60, max_rot_err = 0.25 },
	md_backend   = { true_conv = { order = "YXZ", sy = 1, sp = -1, sr = 1 }, mode = "ghost", setpos = "radians", backend = "md", duration = 30, max_pos_err = 60, max_rot_err = 0.25 },
	net          = { true_conv = { order = "XYZ", sy = 1, sp = -1, sr = -1 }, mode = "net", setpos = "radians", duration = 30, pipes = true },
	world        = { true_conv = { order = "YXZ", sy = 1, sp = -1, sr = -1 }, mode = "net", setpos = "degrees", duration = 30, pipes = true,
	                 role = "join", own_world = "abc123", partner_world = "abc123", world_test = "linked", partner_ship = "HOS-001" },
	world_mismatch = { true_conv = { order = "YXZ", sy = 1, sp = -1, sr = -1 }, mode = "net", setpos = "degrees", duration = 30, pipes = true,
	                 role = "join", own_world = "abc123", partner_world = "zzz999", world_test = "mismatch" },
	world_host   = { true_conv = { order = "YXZ", sy = 1, sp = -1, sr = -1 }, mode = "net", setpos = "degrees", duration = 30, pipes = true,
	                 role = "host", world_test = "host" },
	npc_host     = { true_conv = { order = "YXZ", sy = 1, sp = -1, sr = -1 }, mode = "net", setpos = "degrees", duration = 30, pipes = true,
	                 role = "host", own_world = "abc123", partner_world = "abc123", npc_test = "host" },
	npc_join     = { true_conv = { order = "YXZ", sy = 1, sp = -1, sr = -1 }, mode = "net", setpos = "degrees", duration = 30, pipes = true,
	                 role = "join", own_world = "abc123", partner_world = "abc123", npc_test = "join" },
	econ_host    = { true_conv = { order = "YXZ", sy = 1, sp = -1, sr = -1 }, mode = "net", setpos = "degrees", duration = 30, pipes = true,
	                 role = "host", own_world = "abc123", partner_world = "abc123", econ_test = "host" },
	econ_join    = { true_conv = { order = "YXZ", sy = 1, sp = -1, sr = -1 }, mode = "net", setpos = "degrees", duration = 30, pipes = true,
	                 role = "join", own_world = "abc123", partner_world = "abc123", econ_test = "join" },
	relations_join = { true_conv = { order = "YXZ", sy = 1, sp = -1, sr = -1 }, mode = "net", setpos = "degrees", duration = 30, pipes = true,
	                 role = "join", own_world = "abc123", partner_world = "abc123", rel_test = "join" },
	relations_host = { true_conv = { order = "YXZ", sy = 1, sp = -1, sr = -1 }, mode = "net", setpos = "degrees", duration = 30, pipes = true,
	                 role = "host", own_world = "abc123", partner_world = "abc123", rel_test = "host" },
	unlocks      = { true_conv = { order = "YXZ", sy = 1, sp = -1, sr = -1 }, mode = "net", setpos = "degrees", duration = 30, pipes = true,
	                 role = "join", own_world = "abc123", partner_world = "abc123", unlock_test = true },
	credits      = { true_conv = { order = "YXZ", sy = 1, sp = -1, sr = -1 }, mode = "net", setpos = "degrees", duration = 30, pipes = true,
	                 role = "join", own_world = "abc123", partner_world = "abc123", credits_test = true },
	npc_apart_join = { true_conv = { order = "YXZ", sy = 1, sp = -1, sr = -1 }, mode = "net", setpos = "degrees", duration = 30, pipes = true,
	                 role = "join", own_world = "abc123", partner_world = "abc123", npc_test = "apart_join", partner_sector = 501 },
	npc_apart    = { true_conv = { order = "YXZ", sy = 1, sp = -1, sr = -1 }, mode = "net", setpos = "degrees", duration = 30, pipes = true,
	                 role = "host", own_world = "abc123", partner_world = "abc123", npc_test = "apart", partner_sector = 501 },
	world_oldmod = { true_conv = { order = "YXZ", sy = 1, sp = -1, sr = -1 }, mode = "net", setpos = "degrees", duration = 30, pipes = true,
	                 role = "join", own_world = "abc123", partner_world = "abc123", world_test = "mismatch", partner_protocol = "",
	                 want_check = "different mod versions" },
	net_missing  = { true_conv = { order = "YXZ", sy = 1, sp = 1, sr = 1 }, mode = "net", setpos = "radians", duration = 8, pipes = false, expect_no_proxy = true },
	sector_jump  = { true_conv = { order = "YXZ", sy = 1, sp = -1, sr = 1 }, mode = "ghost", setpos = "radians", duration = 30, jump_at = 18 },
	net_restart  = { true_conv = { order = "YXZ", sy = 1, sp = -1, sr = 1 }, mode = "net", setpos = "radians", duration = 30, pipes = true, partner_restart_at = 16 },
	forced_lua   = { true_conv = { order = "YXZ", sy = 1, sp = -1, sr = -1 }, mode = "ghost", setpos = "degrees", duration = 30,
	                 forced_backend = "lua" },
	low_roll     = { true_conv = { order = "YXZ", sy = 1, sp = -1, sr = 1 }, mode = "ghost", setpos = "degrees", duration = 30, roll_amp = 0.03 },
	steep        = { true_conv = { order = "YXZ", sy = 1, sp = -1, sr = 1 }, mode = "ghost", setpos = "radians", duration = 30, steep = true },
}
if SCENARIO == "list" then
	local names = {}
	for name in pairs(SC) do names[#names + 1] = name end
	table.sort(names)
	local f = io.open(OUT, "w")
	f:write(table.concat(names, "\n"), "\n")
	f:close()
	return
end
local sc = SC[SCENARIO]
assert(sc, "unknown scenario " .. tostring(SCENARIO))
say("scenario %s: engine convention %s%s%s%s, SetObjectSectorPos %s", SCENARIO, sc.true_conv.order,
	sc.true_conv.sy > 0 and "+" or "-", sc.true_conv.sp > 0 and "+" or "-", sc.true_conv.sr > 0 and "+" or "-", sc.setpos)

---------------------------------------------------------------------------
-- Engine geometry (independent of the mod's implementation)
local function rot(axis, a)
	local c, s = math.cos(a), math.sin(a)
	if axis == "X" then return { { 1, 0, 0 }, { 0, c, -s }, { 0, s, c } } end
	if axis == "Y" then return { { c, 0, s }, { 0, 1, 0 }, { -s, 0, c } } end
	return { { c, -s, 0 }, { s, c, 0 }, { 0, 0, 1 } }
end
local function mul(a, b)
	local r = {}
	for i = 1, 3 do r[i] = {} for j = 1, 3 do r[i][j] = a[i][1] * b[1][j] + a[i][2] * b[2][j] + a[i][3] * b[3][j] end end
	return r
end
local function engine_mat(yaw, pitch, roll)
	local c = sc.true_conv
	local ang = { Y = yaw * c.sy, X = pitch * c.sp, Z = roll * c.sr }
	local o = c.order
	return mul(mul(rot(o:sub(1, 1), ang[o:sub(1, 1)]), rot(o:sub(2, 2), ang[o:sub(2, 2)])), rot(o:sub(3, 3), ang[o:sub(3, 3)]))
end
local function col(m, i) return { m[1][i], m[2][i], m[3][i] } end
local function mat_angle(a, b)  -- angle of a^T b
	local tr = 0
	for i = 1, 3 do for k = 1, 3 do tr = tr + a[k][i] * b[k][i] end end
	return math.acos(math.max(-1, math.min(1, (tr - 1) / 2)))
end

---------------------------------------------------------------------------
-- World
local clock, frame_dt = 0, 1 / 60
local SECTORS = { [500] = "cluster_01_sector001_macro", [501] = "cluster_01_sector002_macro" }
local SHIP_MACRO = "ship_arg_s_fighter_01_a_macro"
local objects = {}
local PLAYER = 100
local PARKED = 300
local NPC_COUNT = 4
local function npc_truth(i, t, h)
	local ang = 0.3 * t + i * 1.57
	return h.x + 300 * math.cos(ang), h.y + 50 * i, h.z + 300 * math.sin(ang)
end

objects[PLAYER] = { sector = 500, x = 1000, y = 0, z = -2000, yaw = 0, pitch = 0, roll = 0, macro = SHIP_MACRO, hull = 63, shield = 40 }
local player_ship_lost = false
if sc.npc_test then
	for i = 1, NPC_COUNT do
		local x, y, z = npc_truth(i, 0, objects[PLAYER])
		objects[400 + i] = { sector = 500, x = x + (sc.npc_test == "join" and 500 or 0), y = y, z = z, yaw = i * 0.5, pitch = 0, roll = 0,
			macro = SHIP_MACRO, idcode = "NPC-" .. i }
	end
end
if sc.npc_test == "apart" or sc.npc_test == "apart_join" then
	local pl = objects[PLAYER]
	for i = 1, NPC_COUNT do
		local x, y, z = npc_truth(20 + i, 0, { x = pl.x + 150, y = pl.y, z = pl.z })
		objects[420 + i] = { sector = 501, x = x + 500, y = y, z = z, yaw = 0, pitch = 0, roll = 0, macro = SHIP_MACRO,
			idcode = "NPC-" .. (20 + i) }
	end
	objects[427] = { sector = 501, x = pl.x + 400, y = pl.y, z = pl.z, yaw = 0, pitch = 0, roll = 0, macro = SHIP_MACRO, idcode = "NPC-27" }
	objects[428] = { sector = 501, x = pl.x - 100, y = pl.y, z = pl.z, yaw = 0, pitch = 0, roll = 0, macro = SHIP_MACRO, idcode = "OWN-28",
		playerowned = true }
end
local HOST_STOCK = {  -- the host's stations; STN-9 doesn't exist in the joiner's world
	["STN-1"] = { energycells = 5200, foodrations = 340 }, ["STN-2"] = { hullparts = 800 },
	["STN-3"] = { energycells = 100, water = 2500, ice = 0 }, ["STN-4"] = {}, ["STN-5"] = { claytronics = 75 },
	["STN-9"] = { energycells = 1 },
}
if sc.econ_test then
	local mine = sc.econ_test == "host" and HOST_STOCK or {  -- the joiner's world drifted
		["STN-1"] = { energycells = 4900, foodrations = 340 }, ["STN-2"] = { hullparts = 800, silicon = 120 },
		["STN-3"] = { energycells = 100, water = 2600 }, ["STN-4"] = { energycells = 50 }, ["STN-5"] = { claytronics = 75 },
	}
	for i = 1, 5 do
		local cargo = {}
		for ware, amount in pairs(mine["STN-" .. i]) do cargo[ware] = amount end
		objects[700 + i] = { sector = 500, x = 50000 * i, y = 0, z = 0, yaw = 0, pitch = 0, roll = 0, macro = "station_gen_factory_base_01_macro",
			idcode = "STN-" .. i, station = true, cargo = cargo }
	end
end
if sc.npc_test == "join" then
	local pl = objects[PLAYER]
	objects[407] = { sector = 500, x = pl.x + 200, y = pl.y, z = pl.z, yaw = 0, pitch = 0, roll = 0, macro = SHIP_MACRO, idcode = "NPC-7" }
	objects[408] = { sector = 500, x = pl.x - 200, y = pl.y, z = pl.z, yaw = 0, pitch = 0, roll = 0, macro = SHIP_MACRO, idcode = "OWN-8",
		playerowned = true }
	-- our own copy of the host's NPC-10, far outside our 6 km scan
	objects[410] = { sector = 500, x = pl.x + 50000, y = pl.y, z = pl.z, yaw = 0, pitch = 0, roll = 0, macro = SHIP_MACRO, idcode = "NPC-10" }
end
if sc.partner_ship then
	objects[PARKED] = { sector = 500, x = 5000, y = 0, z = 5000, yaw = 0, pitch = 0, roll = 0, macro = SHIP_MACRO,
		idcode = sc.partner_ship, pilot = true }
end
local next_id, spawns, warps, moves, md_events, lua_errors = 200, 0, 0, 0, {}, 0
local teleports, game_saves, game_loads = {}, {}, {}
local last_status = nil
local spawn_sectors, world_requests, adoptions = {}, {}, 0
local bubble_radius = 0
setpos_count = {}
stock_actions, log_lines, trades_seen, host_named = {}, {}, {}, {}
local mirror_of_code, obj_actions, found_own = {}, {}, {}
local proxy_id = nil
local history = {}   -- player pose history for ground truth

local function ramp(t, a, b) return math.max(0, math.min(1, (t - a) / (b - a))) end
local function player_angles(t)
	local k = ramp(t, 4, 7)  -- level flight first, so a single probe is ambiguous
	local pitch_amp = sc.steep and 1.45 or 0.6
	return 0.2 * t + 0.8 * math.sin(0.15 * t), k * pitch_amp * math.sin(0.23 * t), k * (sc.roll_amp or 1.2) * math.sin(0.31 * t)
end

local function step_player(dt)
	local o = objects[PLAYER]
	o.yaw, o.pitch, o.roll = player_angles(clock)
	local f = col(engine_mat(o.yaw, o.pitch, o.roll), 3)
	local speed = 220 + 80 * math.sin(0.1 * clock)
	o.x, o.y, o.z = o.x + f[1] * speed * dt, o.y + f[2] * speed * dt, o.z + f[3] * speed * dt
	if sc.jump_at and clock >= sc.jump_at and o.sector == 500 then
		o.sector, o.x, o.y, o.z = 501, -5000, 100, 3000
		say("t=%.1f player jumped to %s", clock, SECTORS[501])
	end
	history[#history + 1] = { t = clock, sector = o.sector, x = o.x, y = o.y, z = o.z, m = engine_mat(o.yaw, o.pitch, o.roll) }
end

local function player_at(t)
	for i = #history, 1, -1 do
		if history[i].t <= t then return history[i] end
	end
	return history[1]
end

---------------------------------------------------------------------------
-- Game API stubs
local handlers, on_update, blackboard, queued, notifications = {}, nil, {}, {}, {}
local md_loaded_at = 0.5

C = {
	GetPlayerID = function() return 1 end,
	GetPlayerName = function() return "Tester" end,
	GetPlayerOccupiedShipID = function() return player_ship_lost and 0 or PLAYER end,
	GetContextByClass = function(id, cls) local o = objects[id]; return o and o.sector or 0 end,
	GetObjectIDCode = function(id)
		local o = objects[id]
		return (o and o.idcode) or (id == PLAYER and "PLY-100") or ("SIM-" .. tostring(id))
	end,
	GetObjectPositionInSector = function(id)
		local o = objects[id]
		assert(o, "GetObjectPositionInSector on missing object " .. tostring(id))
		return { x = o.x, y = o.y, z = o.z, yaw = o.yaw, pitch = o.pitch, roll = o.roll }
	end,
	SetObjectSectorPos = function(id, sector, pr)
		local o = objects[id]
		assert(o, "SetObjectSectorPos on missing object " .. tostring(id))
		setpos_count[id] = (setpos_count[id] or 0) + 1
		if sc.setpos == "ignore" then return end
		local k = sc.setpos == "degrees" and math.pi / 180 or 1
		o.x, o.y, o.z, o.yaw, o.pitch, o.roll = pr.x, pr.y, pr.z, pr.yaw * k, pr.pitch * k, pr.roll * k
	end,
	IsGamePaused = function() return false end,
	CanTeleportPlayerTo = function(id) return objects[id] and "granted" or "no such ship" end,
	GetSaveFolderPath = function() return "C:/fake/Egosoft/X4/1/save" end,
	IsSaveListLoadingComplete = function() return true end,
	GetNumAllFactions = function() return 4 end,
	GetAllFactions = function(buf, n)
		for i, id in ipairs({ "argon", "teladi", "player", "xenon" }) do buf[i - 1] = id end
		return 4
	end,
	IsSaveValid = function(name) return name == "quicksave" end,
	ReloadSaveList = function() end,
	TeleportPlayerTo = function(id) teleports[#teleports + 1] = id; return true end,
	IsComponentOperational = function(id) return objects[id] ~= nil and not (id == PLAYER and player_ship_lost) end,
}
package.loaded.ffi = {
	cdef = function() end,
	C = C,
	new = function() return { x = 0, y = 0, z = 0, yaw = 0, pitch = 0, roll = 0 } end,
	string = function(s) return s end,
}
function getElapsedTime() return clock end
function DebugError(s)
	log_lines[#log_lines + 1] = s
	if s:find("[x4coop] error", 1, true) or s:find("[x4coop] command error", 1, true) then lua_errors = lua_errors + 1 end
	say("  log %6.2f %s", clock, s)
end
function RegisterEvent(name, fn) handlers[name] = fn end
function SetScript(kind, fn) if kind == "onUpdate" then on_update = fn end end
function ConvertStringTo64Bit(s) return tonumber((tostring(s):gsub("ULL$", ""))) end
function ConvertStringToLuaID(s) return tonumber((tostring(s):gsub("ULL$", ""))) end
function GetComponentData(id, key)
	if key == "macro" then return SECTORS[id] or (objects[id] and objects[id].macro) end
	if key == "name" and SECTORS[id] then return "Sector " .. id end
	local o = objects[id]
	if key == "owner" then return o and o.owner or "pirate" end
	if key == "hullpercent" then return o and o.hull or 100 end
	if key == "shieldpercent" then return o and o.shield or 100 end
	if key == "isplayerowned" then return o and o.playerowned or false end
	if key == "cargo" then
		local copy = {}
		for ware, amount in pairs(o and o.cargo or {}) do copy[ware] = amount end
		return copy
	end
end
function GetNPCBlackboard(_, key) return blackboard[key] end
player_money, money_requests, empire_requests, partner_gives_acked = 100000, {}, {}, {}
HOST_RELATIONS = { argon = 0.3, teladi = -0.2, xenon = -1 }
our_relations = sc.rel_test == "join" and { argon = 0.1, teladi = -0.2, xenon = -1 } or { argon = 0.3, teladi = -0.2, xenon = -1 }
rel_actions, rel_reads, rel_changes_seen, rel_named = {}, 0, {}, {}
unlock_requests, unlock_switch, unlock_sends = {}, {}, {}
function GetPlayerMoney() return player_money end
function SetNPCBlackboard(_, key, v) blackboard[key] = v end
function ExecuteDebugCommand(cmd, param) say("  ego command /%s %s", cmd, tostring(param)) end
function SaveGame(name, desc) game_saves[#game_saves + 1] = name end
function LoadGame(name) game_loads[#game_loads + 1] = name end

local function queue(name, param) queued[#queued + 1] = { name, param } end
local proxy_adopted = false
local function destroy_proxies()
	if proxy_id and not proxy_adopted then objects[proxy_id] = nil end
	proxy_id, proxy_adopted = nil, false
end
local function sector_by_macro(m)
	for id, macro in pairs(SECTORS) do if macro == m then return id end end
end

-- md model
function AddUITriggeredEvent(screen, control, args)
	assert(screen == "x4coop", "unexpected screen " .. tostring(screen))
	md_events[control] = (md_events[control] or 0) + 1
	if clock < md_loaded_at then return end  -- md not running yet: event lost
	if control == "lua_ready" then
		destroy_proxies(); queue("x4coop.md_ready")
	elseif control == "spawn" then
		destroy_proxies()
		local sector = sector_by_macro(args[1])
		if not sector then queue("x4coop.spawn_failed", "unknown sector " .. tostring(args[1])); return end
		spawn_sectors[#spawn_sectors + 1] = tostring(args[1])
		if args[11] == 1 and args[10] ~= "" then
			for id, o in pairs(objects) do
				if id ~= PLAYER and o.idcode == args[10] and not proxy_id then
					proxy_id, proxy_adopted = id, true
					o.sector, o.x, o.y, o.z, o.yaw, o.pitch, o.roll = sector, args[3], args[4], args[5], args[6], args[7], args[8]
					adoptions = adoptions + 1
				end
			end
		end
		if not proxy_id then
			proxy_id, next_id = next_id, next_id + 1
			objects[proxy_id] = { sector = sector, x = args[3], y = args[4], z = args[5], yaw = args[6], pitch = args[7], roll = args[8],
				macro = args[2], vel = { 0, 0, 0 }, pilot = args[12] == 1 }
			spawns = spawns + 1
		end
		queue("x4coop.proxy_spawned", proxy_id)
	elseif control == "despawn" then
		destroy_proxies(); queue("x4coop.proxy_despawned")
	elseif control == "warp" then
		local sector = sector_by_macro(args[1])
		local o = proxy_id and objects[proxy_id]
		if o and sector then
			o.sector, o.x, o.y, o.z, o.yaw, o.pitch, o.roll = sector, args[2], args[3], args[4], args[5], args[6], args[7]
			warps = warps + 1
			queue("x4coop.warped", proxy_id)
		end
	elseif control == "move" then
		local o = proxy_id and objects[proxy_id]
		if o then
			moves = moves + 1
			if args[10] == 1 then o.x, o.y, o.z, o.yaw, o.pitch, o.roll = args[1], args[2], args[3], args[4], args[5], args[6] end
			o.vel = { args[7], args[8], args[9] }
		end
	elseif control == "probe" then
		local o = objects[PLAYER]
		local m = engine_mat(o.yaw, o.pitch, o.roll)
		local r, u, f = col(m, 1), col(m, 2), col(m, 3)
		blackboard["$x4coop_probe"] = { o.yaw, o.pitch, o.roll, f[1], f[2], f[3], r[1], r[2], r[3], u[1], u[2], u[3] }
		queue("x4coop.probe_result")
	elseif control == "npc_mirror" then
		blackboard["$x4coop_mirrors"] = blackboard["$x4coop_mirrors"] or {}
		local in_sector = sector_by_macro(args[4]) or 500
		for oid, o in pairs(objects) do
			if o.idcode == args[1] and oid ~= PLAYER and oid ~= proxy_id and not o.mirror and o.sector == in_sector then
				local list = blackboard["$x4coop_mirrors"]
				list[#list + 1] = { args[1], oid, 0 }  -- our own copy, outside the scan
				found_own[args[1]] = oid
				queue("x4coop.npc_mirror")
				return
			end
		end
		local id = next_id
		next_id = next_id + 1
		objects[id] = { sector = in_sector, x = args[5], y = args[6], z = args[7], yaw = args[8], pitch = args[9], roll = args[10],
			macro = args[2], owner = args[3], idcode = "MIR-" .. id, hull = 100, mirror = true }
		mirror_of_code[args[1]] = id
		local list = blackboard["$x4coop_mirrors"]
		list[#list + 1] = { args[1], id, 1 }
		queue("x4coop.npc_mirror")
	elseif control == "relations_read" then
		rel_reads = rel_reads + 1
		local list = {}
		for _, id in ipairs(args) do if our_relations[id] then list[#list + 1] = { id, our_relations[id] } end end
		blackboard["$x4coop_relations"] = list
		queue("x4coop.relations")
	elseif control == "relations_sync" then
		for k = 1, #args - 1, 2 do
			local id, value = args[k], args[k + 1]
			if our_relations[id] and math.abs(our_relations[id] - value) > 0.0001 then
				our_relations[id] = value
				rel_actions[#rel_actions + 1] = string.format("set:%s=%.4f", id, value)
			end
		end
	elseif control == "relation_add" then
		local id, change, tag = args[1], args[2], args[3]
		if our_relations[id] then
			our_relations[id] = math.max(-1, math.min(1, our_relations[id] + change))
			rel_actions[#rel_actions + 1] = string.format("add:%s%+.4f", id, change)
		end
		queue("x4coop.relation_applied", tag)
	elseif control == "unlocks" then
		unlock_switch[#unlock_switch + 1] = tostring(args[1])
	elseif control == "unlock" then
		unlock_requests[#unlock_requests + 1] = table.concat(args, ":")
	elseif control == "relations_joiner" then
		rel_actions[#rel_actions + 1] = "joiner:" .. tostring(args[1])
	elseif control == "money" then
		player_money = player_money + args[1]
		money_requests[#money_requests + 1] = args[1]
	elseif control == "empire_income" then
		empire_requests[#empire_requests + 1] = tostring(args[1]) .. ":" .. tostring(args[2])
	elseif control == "economy" then
		local list = {}
		if args[1] == 1 then
			for id = 701, 705 do if objects[id] then list[#list + 1] = id end end
			blackboard["$x4coop_stations"] = list
			queue("x4coop.stations")
		end
	elseif control == "stock" then
		local o = objects[args[1]]
		if o and o.station then
			for k = 3, #args - 1, 2 do
				local ware, change = args[k], args[k + 1]
				o.cargo[ware] = (o.cargo[ware] or 0) + change
				if o.cargo[ware] <= 0 then o.cargo[ware] = nil end
				stock_actions[#stock_actions + 1] = string.format("%s:%s%+d", o.idcode, ware, change)
			end
			if args[2] ~= "" then queue("x4coop.stock_applied", args[2]) end
		end
	elseif control == "npc_clear" then
		for id, o in pairs(objects) do if o.mirror then objects[id] = nil end end
	elseif control:sub(1, 4) == "obj_" then
		local id = args[1]
		local o = objects[id]
		assert(id ~= PLAYER and id ~= proxy_id, "obj_ action on the player or proxy")
		obj_actions[#obj_actions + 1] = control .. ":" .. tostring(id) .. (args[2] and ("," .. args[2]) or "")
		if o and (control == "obj_kill" or (control == "obj_remove" and (not o.playerowned or o.mirror))) then
			objects[id] = nil
		elseif o and control == "obj_hull" then
			o.hull = args[2]
		end
	elseif control == "proxy_status" then
		last_status = table.concat(args, ",")
	elseif control == "guestship" then
		local pl = objects[PLAYER]
		local id = next_id
		next_id = next_id + 1
		objects[id] = { sector = pl.sector, x = pl.x + 60, y = pl.y, z = pl.z, yaw = pl.yaw, pitch = pl.pitch, roll = pl.roll,
			macro = pl.macro, idcode = "GST-" .. id, guest = true }
		blackboard["$x4coop_guestship"] = id
	elseif control == "bubble" then
		bubble_radius = args[1]
	elseif control == "fire" then
		if proxy_id and objects[proxy_id].pilot then world_requests[#world_requests + 1] = "fire:" .. table.concat(args, ",") end
	elseif control == "world_kill" or control == "world_hull" then
		world_requests[#world_requests + 1] = control .. ":" .. table.concat(args, ",")
	elseif control == "velocity" then
		local o = proxy_id and objects[proxy_id]
		if o then o.vel = { args[1], args[2], args[3] } end
	elseif control == "join" then
		local o = proxy_id and objects[proxy_id]
		if o then
			local pl = objects[PLAYER]
			pl.sector, pl.x, pl.y, pl.z = o.sector, o.x + 80, o.y, o.z
			say("  md join: player warped beside the proxy")
		end
	elseif control == "notify" then
		say("  notify %6.2f %s", clock, tostring(args))
		notifications[#notifications + 1] = tostring(args)
	end
end

---------------------------------------------------------------------------
-- Fake pipes API + partner (echo with offset, separate clock, 40 ms each way)
local pipe_reader, partner_queue, pipe_writes, pipe_names = nil, {}, {}, {}
local ECHO_OFFSET, ONE_WAY = { 150, 0, 0 }, 0.04
local partner_clock_offset = 1000
if sc.pipes then
	package.preload["extensions.sn_mod_support_apis.ui.named_pipes.Interface"] = function()
		return {
			winpipe_loaded = true,
			Close_Pipe = function(name)
				if pipe_reader then pipe_reader("ERROR") end
			end,
			Schedule_Read = function(name, cb, continuous)
				pipe_reader = cb
				pipe_names[#pipe_names + 1] = name
				partner_queue[#partner_queue + 1] = { at = clock + 0.05, msg = "W|bridge ready (test)" }
				partner_queue[#partner_queue + 1] = { at = clock + 0.05, msg = "N|partner connected" }
				if sc.role then partner_queue[#partner_queue + 1] = { at = clock + 0.05, msg = "R|" .. sc.role } end
			end,
			Schedule_Write = function(name, cb, msg)
				local f = {}
				for part in (msg .. "|"):gmatch("([^|]*)|") do f[#f + 1] = part end
				pipe_writes[#pipe_writes + 1] = msg
				if f[1] == "L" then
					local reply = string.format("L|%s|%s|HOS-001|%s", sc.partner_world or f[2], f[3] == "host" and "join" or "host",
						sc.partner_protocol or f[5])
					partner_queue[#partner_queue + 1] = { at = clock + 2 * ONE_WAY, msg = reply }
				elseif f[1] == "M" then
					partner_queue[#partner_queue + 1] = { at = clock + 2 * ONE_WAY, msg = "M|Echo|you said: " .. tostring(f[3]) }
				elseif f[1] == "U" and f[2] == "add" then
					unlock_sends[#unlock_sends + 1] = f[3] .. ":" .. f[4] .. ":" .. f[5]
					partner_queue[#partner_queue + 1] = { at = clock + 2 * ONE_WAY, msg = "U|ack|" .. f[3] }
				elseif f[1] == "V" and f[2] == "change" then
					rel_changes_seen[#rel_changes_seen + 1] = f[3]
					if not rel_named[f[3]] then
						rel_named[f[3]] = true
						HOST_RELATIONS[f[4]] = HOST_RELATIONS[f[4]] + tonumber(f[5])
					end
					partner_queue[#partner_queue + 1] = { at = clock + 2 * ONE_WAY, msg = "V|ack|" .. f[3] }
				elseif f[1] == "T" and f[2] == "trade" then
					trades_seen[#trades_seen + 1] = f[3]
					if not host_named[f[3]] then
						host_named[f[3]] = f[4]
						HOST_STOCK[f[4]][f[5]] = (HOST_STOCK[f[4]][f[5]] or 0) + tonumber(f[6])
					end
					partner_queue[#partner_queue + 1] = { at = clock + 2 * ONE_WAY, msg = "T|ack|" .. f[3] }
				elseif f[1] == "C" and f[2] == "give" then
					if not next(partner_gives_acked) then
						partner_gives_acked[f[3]] = f[4]
						partner_queue[#partner_queue + 1] = { at = clock + 2 * ONE_WAY, msg = "C|ack|" .. f[3] }
					end
				elseif f[1] == "P" then
					partner_queue[#partner_queue + 1] = { at = clock + 2 * ONE_WAY, msg = "Q|" .. f[2] }
				elseif f[1] == "S" then
					f[2] = tostring(tonumber(f[2]))
					f[3] = string.format("%.4f", tonumber(f[3]) + partner_clock_offset)  -- partner's clock differs
					f[6] = string.format("%.2f", tonumber(f[6]) + ECHO_OFFSET[1])
				if sc.partner_sector then f[4] = SECTORS[sc.partner_sector] end
					f[15] = "Echo"
					if sc.partner_ship then f[16] = sc.partner_ship end
					partner_queue[#partner_queue + 1] = { at = clock + 2 * ONE_WAY, msg = table.concat(f, "|") }
				end
			end,
		}
	end
end
local next_b = 0
local function fake_host_bubble()
	if sc.npc_test ~= "join" or not pipe_reader or clock < next_b or #history < 2 then return end
	next_b = clock + 0.1
	local h, h0 = history[#history], player_at(clock - 0.05)
	local entries = {}
	for i = 1, NPC_COUNT + 3 do
		local code = i <= NPC_COUNT and ("NPC-" .. i) or ({ "NPC-9", "NPC-10", "NPC-11" })[i - NPC_COUNT]
		local x, y, z = npc_truth(i, clock, h)
		local x0, y0, z0 = npc_truth(i, h0.t, h0)  -- velocity over the actual history step
		local dt0 = clock - h0.t
		entries[#entries + 1] = string.format("%s,%s,pirate,%.1f,%.2f,%.2f,%.2f,%.5f,0,0,%.2f,%.2f,%.2f", code, SHIP_MACRO,
			i == 1 and 55 or 100, x, y, z, i * 0.5, (x - x0) / dt0, (y - y0) / dt0, (z - z0) / dt0)
	end
	partner_queue[#partner_queue + 1] = { at = clock + ONE_WAY,
		msg = string.format("B|%.4f|%s|6000|1|%s", clock + partner_clock_offset, SECTORS[500], table.concat(entries, ";")) }
end

local function fake_joiner_bubble()
	if (sc.npc_test ~= "apart" and sc.npc_test ~= "apart_join") or not pipe_reader or clock < next_b or #history < 2 then return end
	next_b = clock + 0.1
	local h, h0 = history[#history], player_at(clock - 0.05)
	local c = { x = h.x + ECHO_OFFSET[1], y = h.y, z = h.z }
	local c0 = { x = h0.x + ECHO_OFFSET[1], y = h0.y, z = h0.z }
	local entries = {}
	for i = 21, 21 + NPC_COUNT do  -- NPC-21..24, then NPC-25: the host has no such ship
		local x, y, z = npc_truth(i, clock, c)
		local x0, y0, z0 = npc_truth(i, h0.t, c0)
		local dt0 = clock - h0.t
		entries[#entries + 1] = string.format("NPC-%d,%s,pirate,%.1f,%.2f,%.2f,%.2f,%.5f,0,0,%.2f,%.2f,%.2f", i, SHIP_MACRO,
			i == 21 and 55 or 100, x, y, z, (i - 20) * 0.5, (x - x0) / dt0, (y - y0) / dt0, (z - z0) / dt0)
	end
	entries[#entries + 1] = string.format("NPC-1,%s,pirate,100.0,%.2f,%.2f,%.2f,0,0,0,0,0,0", SHIP_MACRO, c.x, c.y, c.z)
	partner_queue[#partner_queue + 1] = { at = clock + ONE_WAY,
		msg = string.format("B|%.4f|%s|6000|1|%s", clock + partner_clock_offset, SECTORS[501], table.concat(entries, ";")) }
end

local econ_next, econ_pass, econ_index = 0, 1, 0
local HOST_ORDER = { "STN-1", "STN-2", "STN-3", "STN-4", "STN-5", "STN-9" }
local function fake_host_stock()
	if sc.econ_test ~= "join" or not pipe_reader or clock < econ_next or clock < 3 then return end
	econ_next = clock + 0.1
	if clock > 15 then HOST_STOCK["STN-3"].water = nil end
	econ_index = econ_index + 1
	if econ_index > #HOST_ORDER then econ_index, econ_pass = 1, econ_pass + 1 end
	local code = HOST_ORDER[econ_index]
	local wares = {}
	for ware, amount in pairs(HOST_STOCK[code]) do wares[#wares + 1] = ware .. ":" .. amount end
	table.sort(wares)
	local named = {}
	for tid, at in pairs(host_named) do if at == code then named[#named + 1] = tid end end
	partner_queue[#partner_queue + 1] = { at = clock + ONE_WAY, msg = string.format("E|stock|%d|%d|%d|%s|%s|%s", econ_pass,
		econ_index, #HOST_ORDER, code, table.concat(wares, ","), table.concat(named, ",")) }
end

local death_steps = {
	{ 15, function() queue("x4coop.area_death", (sc.npc_test == "apart" and "NPC-2|" or "NPC-3|") .. SHIP_MACRO .. "|" .. SECTORS[500]) end },
	{ 16, function() queue("x4coop.area_death", "NPC-21|" .. SHIP_MACRO .. "|" .. SECTORS[501]) end },
}
local function death_script()
	if sc.npc_test ~= "apart" and sc.npc_test ~= "apart_join" then return end
	while death_steps[1] and clock >= death_steps[1][1] do table.remove(death_steps, 1)[2]() end
end

local credit_steps = {
	{ 6, function() ExecuteDebugCommand("x4coop", "set credit_timeout 5") end },
	{ 8, function() ExecuteDebugCommand("x4coop", "give 5,000") end },
	{ 9, function() ExecuteDebugCommand("x4coop", "give 999999999") end },
	{ 10, function() pipe_reader("C|give|00c0ffee|1234|Partner") end },
	{ 12, function() pipe_reader("C|give|00c0ffee|1234|Partner") end },  -- offered again: count once
	{ 14, function() ExecuteDebugCommand("x4coop", "give 700") end },      -- never confirmed: comes back
}
local trade_done, max_after_trade, host_trade_steps = false, 0, {
	{ 10, function() pipe_reader("T|trade|0abc|STN-2|hullparts|50") end },
	{ 12, function() pipe_reader("T|trade|0abc|STN-2|hullparts|50") end },  -- sent again: counted once
}
local function trade_script()
	if sc.econ_test == "join" then
		if not trade_done and clock >= 12 and pipe_reader then
			trade_done = true  -- we sell 200 energy cells' worth... we buy 200 from STN-1: the game changes our copy at once
			objects[701].cargo.energycells = objects[701].cargo.energycells - 200
			blackboard["$x4coop_trades"] = { { 701, "energycells", -200 } }
			queue("x4coop.joiner_trade")
		end
		if trade_done and clock > 12.2 then
			max_after_trade = math.max(max_after_trade, objects[701].cargo.energycells or 0)
		end
	elseif sc.econ_test == "host" and pipe_reader then
		while host_trade_steps[1] and clock >= host_trade_steps[1][1] do table.remove(host_trade_steps, 1)[2]() end
	end
end

local rel_next, rel_changed, rel_max_after = 3, false, -2
local rel_host_steps = {
	{ 10, function() pipe_reader("V|change|0bcd|teladi|0.020000") end },
	{ 12, function() pipe_reader("V|change|0bcd|teladi|0.020000") end },  -- sent again: counted once
}
local function relations_script()
	if not sc.rel_test or not pipe_reader then return end
	if sc.rel_test == "join" then
		if clock >= rel_next then  -- the host's report, every 2 s here
			rel_next = clock + 2
			local values, named = {}, {}
			for id, v in pairs(HOST_RELATIONS) do values[#values + 1] = string.format("%s:%.6f", id, v) end
			for tid in pairs(rel_named) do named[#named + 1] = tid end
			partner_queue[#partner_queue + 1] = { at = clock + ONE_WAY,
				msg = "V|state|" .. table.concat(values, ",") .. "|" .. table.concat(named, ",") }
		end
		if not rel_changed and clock >= 12 then  -- we anger Argon: the game lowers it here at once
			rel_changed = true
			our_relations.argon = our_relations.argon - 0.05
			blackboard["$x4coop_relchanges"] = { { "argon", -0.05 } }
			queue("x4coop.relation_changed")
		end
		if rel_changed and clock > 12.2 then rel_max_after = math.max(rel_max_after, our_relations.argon) end
	else
		while rel_host_steps[1] and clock >= rel_host_steps[1][1] do table.remove(rel_host_steps, 1)[2]() end
	end
end

local unlock_steps = {
	{ 10, function()  -- we finish a research here
		blackboard["$x4coop_unlocks"] = { { "r", "research_teleportation", "" } }
		queue("x4coop.unlock")
	end },
	{ 11, function() pipe_reader("U|add|00aa|b|weapon_gen_m_laser_01_mk1|w") end },
	{ 13, function() pipe_reader("U|add|00aa|b|weapon_gen_m_laser_01_mk1|w") end },  -- sent again: added once
	{ 15, function() pipe_reader("U|add|00ab|l|argon|police") end },
}
local function unlock_script()
	if not sc.unlock_test or not pipe_reader then return end
	while unlock_steps[1] and clock >= unlock_steps[1][1] do table.remove(unlock_steps, 1)[2]() end
end

local function credit_script()
	if not sc.credits_test or not pipe_reader then return end
	while credit_steps[1] and clock >= credit_steps[1][1] do
		table.remove(credit_steps, 1)[2]()
	end
end

local function deliver_pipe()
	if not pipe_reader then return end
	local keep = {}
	for _, item in ipairs(partner_queue) do
		if item.at <= clock then pipe_reader(item.msg) else keep[#keep + 1] = item end
	end
	partner_queue = keep
end

---------------------------------------------------------------------------
-- Load the mod and run
if sc.mode ~= "ghost" then blackboard["$x4coop_mode"] = sc.mode end
if sc.own_world then blackboard["$x4coop_world"] = sc.own_world end
if sc.forced_backend then blackboard["$x4coop_backend"] = sc.forced_backend end
local chunk = assert(loadfile(MOD))
chunk()
assert(on_update, "mod did not register onUpdate")
local api = X4Coop

-- math self-checks with the mod's own functions
do
	local M = api.math
	local worst, n = 0, 0
	math.randomseed(1)
	for _, order in ipairs({ "YXZ", "YZX", "XYZ", "XZY", "ZXY", "ZYX" }) do
		for sy = -1, 1, 2 do for sp = -1, 1, 2 do for sr = -1, 1, 2 do
			local conv = { order = order, sy = sy, sp = sp, sr = sr }
			for i = 1, 60 do
				local y, p, r = (math.random() * 2 - 1) * math.pi, (math.random() * 2 - 1) * math.pi / 2, (math.random() * 2 - 1) * math.pi
				if i <= 6 then p = (i % 2 == 0 and 1 or -1) * (math.pi / 2 - 10 ^ -(i)) end  -- near gimbal lock
				local m = M.mat_from_euler(conv, y, p, r)
				local q = M.quat_from_mat(m)
				local y2, p2, r2 = M.euler_from_mat(conv, M.mat_from_quat(q))
				local e = mat_angle(m, M.mat_from_euler(conv, y2, p2, r2))
				worst, n = math.max(worst, e), n + 1
			end
		end end end
	end
	say("math: euler->quat->euler round trip over %d samples x 48 conventions, worst %.2e rad", n / 48, worst)
	if worst > 1e-3 then say("FAIL: round trip"); finish(false); return end

	-- angular velocity / advance consistency
	local q0 = M.quat_from_mat(engine_mat(0.3, 0.2, -0.4))
	local q1 = M.quat_from_mat(engine_mat(0.35, 0.18, -0.3))
	local w = M.angular_velocity(q0, q1, 0.05)
	local q2 = M.quat_advance(q0, w, 0.05)
	local ea = M.quat_angle(q1, q2)
	say("math: angular velocity round trip error %.2e rad", ea)
	if ea > 1e-6 then say("FAIL: angular velocity"); finish(false); return end
end

if sc.mode ~= "ghost" or sc.backend then
	clock = 0.1
end
local commanded, chatted, hostile_sent, world_sent, piped, fire_sent = false, false, false, false, false, false
local guest_done, took_ship, checked, shared_in, miss_sent = false, false, false, false, false
local adopted_seen = false
-- Malformed or malicious partner messages: all must be dropped without errors or odd spawns.
local HOSTILE = {
	"S|1|nan|cluster_01_sector001_macro|ship_arg_s_fighter_01_a_macro|0|0|0|0|0|0|0|0|0|evil",
	"S|1|5|evil sector;|ship_arg_s_fighter_01_a_macro|0|0|0|0|0|0|0|0|0|evil",
	"S|1|5|cluster_01_sector001_macro|ship_arg_s_fighter_01_a_macro|1e12|0|0|0|0|0|0|0|0|evil",
	"S|1|5|cluster_01_sector001_macro|ship_arg_s_fighter_01_a_macro|0|0|0|inf|0|0|0|0|0|evil",
	"S|1|5|cluster_01_sector001_macro|ship|0|0",
	"S|",
	"Q|not a number",
	"P|evil|stuff",
	"M|evil" .. string.char(10) .. "name|line1" .. string.char(13, 10) .. "line2",
	"",
	"|||||",
}
local pos_errs, rot_errs, npc_errs, mirror_errs = {}, {}, {}, {}
local mapping_sent, mapped_mirror = false, nil
local found_errs, mode_test_done = {}, false
local first_live_at, calibrated_at
local max_proxies = 0
while clock < sc.duration do
	clock = clock + frame_dt
	step_player(frame_dt)
	if sc.npc_test == "host" or sc.npc_test == "apart" or sc.npc_test == "apart_join" then
		local h = history[#history]
		for i = 1, NPC_COUNT do
			local o = objects[400 + i]
			o.x, o.y, o.z = npc_truth(i, clock, h)
		end
	end
	if bubble_radius > 0 and math.floor(clock) ~= math.floor(clock - frame_dt) then
		local pl, list = objects[PLAYER], {}
		for id, o in pairs(objects) do
			if id ~= PLAYER and id ~= proxy_id and not o.mirror and o.sector == pl.sector
				and math.sqrt((o.x - pl.x) ^ 2 + (o.y - pl.y) ^ 2 + (o.z - pl.z) ^ 2) <= bubble_radius then
				list[#list + 1] = id
			end
		end
		blackboard["$x4coop_bubble"] = list
		blackboard["$x4coop_bubble_complete"] = 1
		local near, px = {}, proxy_id and objects[proxy_id]
		if px then
			for id, o in pairs(objects) do
				if id ~= PLAYER and id ~= proxy_id and not o.mirror and o.sector == px.sector
					and math.sqrt((o.x - px.x) ^ 2 + (o.y - px.y) ^ 2 + (o.z - px.z) ^ 2) <= bubble_radius then
					near[#near + 1] = id
				end
			end
		end
		blackboard["$x4coop_bubble_partner"] = near
		blackboard["$x4coop_bubble_partner_complete"] = px and 1 or 0
		if handlers["x4coop.bubble"] then handlers["x4coop.bubble"]("x4coop.bubble") end
	end
	fake_host_bubble()
	fake_joiner_bubble()
	fake_host_stock()
	credit_script()
	death_script()
	trade_script()
	relations_script()
	unlock_script()
	if sc.partner_restart_at and clock >= sc.partner_restart_at and partner_clock_offset == 1000 then
		partner_clock_offset = -500
		say("t=%.1f partner restarted their game (clock jumped back)", clock)
	end
	-- md backend physics: constant velocity
	if proxy_id and objects[proxy_id].vel then
		local o, v = objects[proxy_id], objects[proxy_id].vel
		o.x, o.y, o.z = o.x + v[1] * frame_dt, o.y + v[2] * frame_dt, o.z + v[3] * frame_dt
	end
	if clock >= md_loaded_at and clock - frame_dt < md_loaded_at then queue("x4coop.md_ready") end  -- event_game_loaded
	local events = queued
	queued = {}
	for _, e in ipairs(events) do
		if handlers[e[1]] then handlers[e[1]](e[1], e[2]) end
	end
	deliver_pipe()
	if not commanded and clock > 1 then
		commanded = true
		if sc.backend then ExecuteDebugCommand("x4coop", "backend " .. sc.backend) end
		ExecuteDebugCommand("refreshmd", "")   -- must pass through to the game
	end
	if sc.mode == "net" and sc.pipes and pipe_reader and not hostile_sent and clock > 5 then
		hostile_sent = true
		for _, msg in ipairs(HOSTILE) do pipe_reader(msg) end
	end
	if sc.npc_test == "join" and not mapping_sent and clock > 20 and mirror_of_code["NPC-9"] then
		mapping_sent = true
		local mid = mirror_of_code["NPC-9"]
		mapped_mirror = mid
		-- we shoot the stand-in: the host must hear about NPC-9, not the stand-in's own code
		handlers["x4coop.world"]("x4coop.world", "D|MIR-" .. mid .. "|" .. SHIP_MACRO .. "|" .. SECTORS[500] .. "|70")
		-- the host fires at and kills NPC-9: that must reach the stand-in
		pipe_reader("F|NPC-9|" .. SHIP_MACRO .. "|" .. SECTORS[500])
		pipe_reader("K|NPC-9|" .. SHIP_MACRO .. "|" .. SECTORS[500])
	end
	if sc.fire_test and not fire_sent and clock > 12 then
		fire_sent = true
		handlers["x4coop.world"]("x4coop.world", "D|TGT-001|ship_arg_s_fighter_01_a_macro|cluster_01_sector001_macro|80|1")
		handlers["x4coop.world"]("x4coop.world", "D|FRIEND-1|ship_arg_s_fighter_01_a_macro|cluster_01_sector001_macro|90|0")
		handlers["x4coop.world"]("x4coop.world", "A|TGT-001|ship_arg_s_fighter_01_a_macro|cluster_01_sector001_macro")  -- throttled
	end
	if sc.fire_test and not miss_sent and clock > 14 then
		miss_sent = true  -- firing and missing still makes the ghost fire
		handlers["x4coop.world"]("x4coop.world", "A|TGT-002|ship_arg_s_fighter_01_a_macro|cluster_01_sector001_macro")
	end
	if sc.world_test == "host" and not guest_done and clock > 12 then
		guest_done = true
		ExecuteDebugCommand("x4coop", "guestship")  -- md answers next frame
	end
	if sc.world_test == "host" and guest_done and not took_ship and clock > 13 then
		took_ship = true
		ExecuteDebugCommand("x4coop", "takeship")
		ExecuteDebugCommand("x4coop", "share")
	end
	if sc.world_test == "linked" and not shared_in and clock > 14 then
		shared_in = true
		ExecuteDebugCommand("x4coop", "loadshared")  -- nothing received yet: must refuse
		pipe_reader("X|received|quicksave")
		ExecuteDebugCommand("x4coop", "loadshared")
	end
	if sc.world_test and not world_sent and clock > 10 then
		world_sent = true
		local sector = "cluster_01_sector001_macro"
		handlers["x4coop.world"]("x4coop.world", "K|ABC-123|ship_arg_s_fighter_01_a_macro|" .. sector)
		handlers["x4coop.world"]("x4coop.world", "D|ABC-124|ship_arg_s_fighter_01_a_macro|" .. sector .. "|57.5LF|1")
		handlers["x4coop.world"]("x4coop.world", "D|ABC-124|ship_arg_s_fighter_01_a_macro|" .. sector .. "|50")  -- throttled
		handlers["x4coop.world"]("x4coop.world", "K|bad id;|ship_arg_s_fighter_01_a_macro|" .. sector)
		for _, msg in ipairs({
			"K|XYZ-999|ship_arg_s_fighter_01_a_macro|" .. sector,
			"D|XYZ-998|ship_arg_s_fighter_01_a_macro|" .. sector .. "|33.3",
			"D|XYZ-997|ship_arg_s_fighter_01_a_macro|" .. sector .. "|500",
			"K|XYZ 996|ship_arg_s_fighter_01_a_macro|" .. sector,
			"K|XYZ-995|ship;evil|" .. sector,
			"F|XYZ-990|ship_arg_s_fighter_01_a_macro|" .. sector,
		}) do pipe_reader(msg) end
	end
	if sc.world_test == "linked" and not piped and clock > sc.duration - 4 then
		piped = true
		ExecuteDebugCommand("x4coop", "pipe x4_coop_b")
	end
	if sc.world_test == "linked" and not mode_test_done and clock > sc.duration - 1 then
		mode_test_done = true
		ExecuteDebugCommand("x4coop", "ghost")
		pipe_reader("K|XYZ-777|" .. SHIP_MACRO .. "|" .. SECTORS[500])
	end
	if sc.mode == "net" and sc.pipes and not sc.world_test and not player_ship_lost and clock > sc.duration - 0.5 then
		player_ship_lost = true  -- our ship is destroyed: the partner should hear about it
	end
	if not checked and clock > sc.duration - 1.5 then
		checked = true
		ExecuteDebugCommand("x4coop", "check")
	end
	if not chatted and clock > sc.duration - 2 then
		chatted = true
		ExecuteDebugCommand("x4coop", "say hello   there")
		ExecuteDebugCommand("x4coop", "join")
	end
	on_update()

	local S = api.state()
	if proxy_id == PARKED and S.proxy.state == "live" then adopted_seen = true end
	if S.probe.measured and not calibrated_at then
		calibrated_at = clock
	end
	if proxy_id and S.proxy.state == "live" then
		first_live_at = first_live_at or clock
		-- ground truth: where the partner should be right now
		local o = objects[proxy_id]
		local truth
		if sc.mode == "net" then
			local h = player_at(clock - ONE_WAY)
			truth = { sector = sc.partner_sector or h.sector, x = h.x + ECHO_OFFSET[1], y = h.y, z = h.z, m = h.m }
		else
			local h = history[#history]
			local cfg = api.config
			local r, u, f = col(h.m, 1), col(h.m, 2), col(h.m, 3)
			local function off(i) return r[i] * cfg.ghost_right + u[i] * cfg.ghost_up + f[i] * cfg.ghost_forward end
			truth = { sector = h.sector, x = h.x + off(1), y = h.y + off(2), z = h.z + off(3), m = h.m }
		end
		if not chatted and clock > math.max(10, (calibrated_at or 1e9) + 1) and o.sector == truth.sector and (not sc.jump_at or math.abs(clock - sc.jump_at) > 2) and (not sc.partner_restart_at or math.abs(clock - sc.partner_restart_at) > 2) then
			pos_errs[#pos_errs + 1] = math.sqrt((o.x - truth.x) ^ 2 + (o.y - truth.y) ^ 2 + (o.z - truth.z) ^ 2)
			rot_errs[#rot_errs + 1] = mat_angle(engine_mat(o.yaw, o.pitch, o.roll), truth.m)
		end
	end
	if (sc.npc_test == "apart" or sc.npc_test == "apart_join") and clock > 8 and not chatted then
		local h = history[#history]
		local c = { x = h.x + ECHO_OFFSET[1], y = h.y, z = h.z }
		for i = 1, NPC_COUNT do
			local o = objects[420 + i]
			local x, y, z = npc_truth(20 + i, clock, c)
			npc_errs[#npc_errs + 1] = math.sqrt((o.x - x) ^ 2 + (o.y - y) ^ 2 + (o.z - z) ^ 2)
		end
		local mid = mirror_of_code["NPC-25"]
		if mid and objects[mid] then
			apart_mirror_sector = objects[mid].sector
			local x, y, z = npc_truth(25, clock, c)
			local o = objects[mid]
			mirror_errs[#mirror_errs + 1] = math.sqrt((o.x - x) ^ 2 + (o.y - y) ^ 2 + (o.z - z) ^ 2)
		end
	end
	if sc.npc_test == "join" and clock > 8 and not chatted then
		local h = history[#history]
		if found_own["NPC-10"] then
			local x, y, z = npc_truth(NPC_COUNT + 2, clock, h)
			local o = objects[410]
			found_errs[#found_errs + 1] = math.sqrt((o.x - x) ^ 2 + (o.y - y) ^ 2 + (o.z - z) ^ 2)
		end
		local mid = mirror_of_code["NPC-9"]
		if mid and objects[mid] then
			local x, y, z = npc_truth(NPC_COUNT + 1, clock, h)
			local o = objects[mid]
			mirror_errs[#mirror_errs + 1] = math.sqrt((o.x - x) ^ 2 + (o.y - y) ^ 2 + (o.z - z) ^ 2)
		end
		for i = 1, NPC_COUNT do
			local o = objects[400 + i]
			local x, y, z = npc_truth(i, clock, h)
			npc_errs[#npc_errs + 1] = math.sqrt((o.x - x) ^ 2 + (o.y - y) ^ 2 + (o.z - z) ^ 2)
		end
	end
	local count = 0
	for id, o in pairs(objects) do  -- proxies only: not the player, scenario ships (400+), the parked ship or stand-ins
		if id ~= PLAYER and id < 400 and id ~= PARKED and not o.mirror and not o.guest then count = count + 1 end
	end
	max_proxies = math.max(max_proxies, count)
end

ExecuteDebugCommand("x4coop", "status")
ExecuteDebugCommand("x4coop", "off")
for _ = 1, 5 do
	clock = clock + frame_dt
	local events = queued
	queued = {}
	for _, e in ipairs(events) do if handlers[e[1]] then handlers[e[1]](e[1], e[2]) end end
	on_update()
end

local ok_status = true
local function stats(t)
	if #t == 0 then return "n/a", 0, 0 end
	table.sort(t)
	local sum = 0
	for _, v in ipairs(t) do sum = sum + v end
	return string.format("mean %.2f  p95 %.2f  max %.2f", sum / #t, t[math.floor(#t * 0.95)], t[#t]), t[#t], t[math.floor(#t * 0.95)]
end
local S = api.state()
say("md events: %s", (function() local s = {} for k, v in pairs(md_events) do s[#s + 1] = k .. "=" .. v end table.sort(s) return table.concat(s, " ") end)())
say("spawns %d, warps %d, md moves %d, max proxies alive %d, proxy left after 'off': %s", spawns, warps, moves, max_proxies, tostring(proxy_id ~= nil))
say("backend resolved: %s, angles in degrees: %s, convention: %s (%s at t=%s)", tostring(S.backend), tostring(S.lua_degrees),
	api.math.conv_name(S.conv), S.probe.measured and "measured" or "assumed", calibrated_at and string.format("%.1f", calibrated_at) or "-")
local ps, pmax, p95 = stats(pos_errs)
local rs, rmax, r95 = stats(rot_errs)
say("position error (m): %s   [%d frames]", ps, #pos_errs)
say("rotation error (rad): %s", rs)
say("lua errors logged: %d", lua_errors)
for _, line in ipairs(report) do
	if line:find("health:", 1, true) then say("last health line seen: %s", line:match("health: (.*)")) end
end

local said = table.concat(notifications, " / ")
if not sc.expect_no_proxy then
	say("partner status shown on the proxy: %s", tostring(last_status))
	ok_status = last_status == "63,40"
end
if sc.mode == "net" and sc.pipes and not sc.world_test then
	local told = table.concat(pipe_writes, string.char(10)):find("M|Tester|my ship was destroyed", 1, true) ~= nil
	say("partner told our ship was destroyed: %s", tostring(told))
	ok_status = ok_status and told
end
local check_line = said:match("check: ([^/]*)") or "(none)"
say("check said: %s", check_line)
local want_check = sc.expect_no_proxy and "Mod Support APIs" or (sc.mode == "ghost" and "mode is ghost")
	or sc.want_check or (sc.world_test == "linked" and "all good") or (sc.world_test == "mismatch" and "different worlds") or nil
local ok = (not want_check or check_line:find(want_check, 1, true) ~= nil) and lua_errors == 0 and ok_status and proxy_id == nil and max_proxies <= 1
for _, sector in ipairs(spawn_sectors) do
	if not SECTORS[500] or (sector ~= SECTORS[500] and sector ~= SECTORS[501]) then
		say("FAIL: proxy spawned from a bad snapshot (sector %s)", sector)
		ok = false
	end
end
if not sc.expect_no_proxy then
	local want_chat = sc.mode == "ghost" and "Ghost: hello there" or "Echo: you said: hello there"
	local chat_ok = said:find(want_chat, 1, true) ~= nil
	local where_ok = said:find("in Sector 50", 1, true) ~= nil
	say("chat reply seen: %s, partner location reported: %s, join requests: %d", tostring(chat_ok), tostring(where_ok), md_events.join or 0)
	ok = ok and chat_ok and where_ok and (md_events.join or 0) == 1
end
if sc.world_test then
	local said = table.concat(notifications, " / ")
	local sent_k, sent_d, sent_f, fires, others = {}, {}, {}, {}, {}
	for _, w in ipairs(pipe_writes) do
		if w:sub(1, 2) == "K|" then sent_k[#sent_k + 1] = w end
		if w:sub(1, 2) == "D|" then sent_d[#sent_d + 1] = w end
		if w:sub(1, 2) == "F|" then sent_f[#sent_f + 1] = w end
	end
	for _, r in ipairs(world_requests) do
		if r:sub(1, 5) == "fire:" then fires[#fires + 1] = r else others[#others + 1] = r end
	end
	world_requests = others
	say("fire: sent %s ; applied %s ; adopted partner ship: %s (%d adoptions)", table.concat(sent_f, " "), table.concat(fires, " "),
		tostring(adopted_seen), adoptions)
	say("world: sent %s | %s ; applied %s", table.concat(sent_k, " "), table.concat(sent_d, " "), table.concat(world_requests, " "))
	if sc.world_test == "linked" or sc.world_test == "host" then
		ok = ok and said:find("world: linked", 1, true) ~= nil
			and #sent_k == 1 and sent_k[1] == "K|ABC-123|ship_arg_s_fighter_01_a_macro|cluster_01_sector001_macro"
			and #sent_d == 1 and sent_d[1] == "D|ABC-124|ship_arg_s_fighter_01_a_macro|cluster_01_sector001_macro|57.50"
			and #world_requests == 2
			and world_requests[1] == "world_kill:XYZ-999,ship_arg_s_fighter_01_a_macro,cluster_01_sector001_macro"
			and world_requests[2] == "world_hull:XYZ-998,ship_arg_s_fighter_01_a_macro,cluster_01_sector001_macro,33.3"
	end
	if sc.world_test == "linked" then
		ok = ok and #sent_f == 1 and sent_f[1] == "F|ABC-124|ship_arg_s_fighter_01_a_macro|cluster_01_sector001_macro"
			and #fires == 1 and fires[1] == "fire:XYZ-990,ship_arg_s_fighter_01_a_macro,cluster_01_sector001_macro"
			and adopted_seen and objects[PARKED] ~= nil  -- adopted, and released (not destroyed) after 'off'
	end
	if sc.world_test == "mismatch" then
		ok = ok and #sent_f == 0 and #fires == 0
	end
	if sc.world_test == "linked" then
		local savedir_sent = table.concat(pipe_writes, string.char(10)):find("X|savedir|C:/fake/Egosoft/X4/1/save", 1, true) ~= nil
		say("loadshared: loads %s, savedir told %s", table.concat(game_loads, ","), tostring(savedir_sent))
		ok = ok and #game_loads == 1 and game_loads[1] == "quicksave" and savedir_sent and said:find("no save from the host yet", 1, true) ~= nil
		local leaked = table.concat(world_requests, " "):find("XYZ-777", 1, true) ~= nil
		say("partner kill after leaving net mode applied: %s", tostring(leaked))
		ok = ok and not leaked
	end
	if sc.world_test == "linked" then
		say("pipes used: %s", table.concat(pipe_names, ", "))
		ok = ok and pipe_names[#pipe_names] == "x4_coop_b"  -- switched, and chat (checked above) still works
	end
	if sc.world_test == "host" then
		local guest = blackboard["$x4coop_guestship"]
		say("guest ship %s, teleports %s", tostring(guest), table.concat(teleports, ","))
		ok = ok and guest ~= nil and #teleports == 1 and teleports[1] == guest and said:find("moved to the guest ship", 1, true) ~= nil
		local share_sent = table.concat(pipe_writes, string.char(10)):find("X|share|C:/fake/Egosoft/X4/1/save|quicksave.xml.gz", 1, true) ~= nil
		say("share: saves %s, share request sent %s", table.concat(game_saves, ","), tostring(share_sent))
		ok = ok and #game_saves == 1 and game_saves[1] == "quicksave" and share_sent
		ok = ok and said:find("new co-op world", 1, true) ~= nil and type(blackboard["$x4coop_world"]) == "string"
	end
	if sc.world_test == "mismatch" then
		ok = ok and said:find(sc.want_check or "different worlds", 1, true) ~= nil and #sent_k == 0 and #sent_d == 0 and #world_requests == 0
	end
end
if sc.npc_test then
	local bs = {}
	for _, w in ipairs(pipe_writes) do if w:sub(1, 2) == "B|" then bs[#bs + 1] = w end end
	if sc.npc_test == "apart" or sc.npc_test == "apart_join" then
		local last = ""  -- our last report from our own sector (at the end, /x4coop join takes us to the joiner)
		for _, b in ipairs(bs) do if b:find("|" .. SECTORS[500] .. "|", 1, true) then last = b end end
		local st, emax, e95 = stats(npc_errs)
		local mst, mmax, m95 = stats(mirror_errs)
		local mid = mirror_of_code["NPC-25"]
		local acts = table.concat(obj_actions, " ")
		say("npc apart: our copies near the joiner vs its truth (m): %s   [%d samples]; stand-in NPC-25 = %s in sector %s: %s",
			st, #npc_errs, tostring(mid), tostring(apart_mirror_sector), mst)
		say("npc apart: NPC-1 moved by us %d times; our last B lists NPC-1: %s, NPC-21: %s; actions: %s",
			setpos_count[401] or 0, tostring(last:find("NPC-1,", 1, true) ~= nil), tostring(last:find("NPC-21,", 1, true) ~= nil), acts)
		local sent = table.concat(pipe_writes, "\n")
		local ours = sc.npc_test == "apart" and "K|NPC-2|" or "K|NPC-3|"
		say("npc %s: death in our area reported: %s; death in the partner's area reported: %s", sc.npc_test,
			tostring(sent:find(ours, 1, true) ~= nil), tostring(sent:find("K|NPC-21|", 1, true) ~= nil))
		ok = ok and sent:find(ours, 1, true) ~= nil and sent:find("K|NPC-21|", 1, true) == nil
		ok = ok and #npc_errs > 1000 and e95 < 5
			and mid ~= nil and apart_mirror_sector == 501 and #mirror_errs > 500 and m95 < 10
			and (setpos_count[401] or 0) == 0                            -- our own area stays ours
			-- we report our own area (as joiner, not NPC-1: the host claims that one, falsely, so it is the host's)
			and last:find(sc.npc_test == "apart" and "NPC-1," or "NPC-2,", 1, true) ~= nil and last:find("NPC-21,", 1, true) == nil
			and acts:find("obj_remove:427", 1, true) ~= nil             -- only we had it, in the joiner's area
			and acts:find("obj_remove:428", 1, true) == nil             -- player-owned: kept
			and acts:find("obj_hull:421,55", 1, true) ~= nil            -- the joiner's lower hull taken
			and acts:find("obj_remove:40", 1, true) == nil              -- nothing of our own area removed
	elseif sc.npc_test == "host" then
		local last = bs[#bs] or ""
		local codes = 0
		for i = 1, NPC_COUNT do if last:find("NPC-" .. i .. ",", 1, true) then codes = codes + 1 end end
		-- the entry for NPC-1 must carry the ship's position at send time (within a frame of motion)
		local x = tonumber(last:match("NPC%-1,[%w_]+,[%w_]+,[%d%.]+,([%-%d%.]+),"))
		ok = ok and last:match("^B|[%d%.]+|[%w_]+|6000|1|") ~= nil  -- radius and "complete" in the header
		local o = objects[401]
		say("npc host: %d B messages (%.1f/s), last one lists %d of %d ships, NPC-1 x %.1f vs %.1f",
			#bs, #bs / sc.duration, codes, NPC_COUNT, x or -1, o.x)
		ok = ok and #bs > 8 * (sc.duration - 2) and codes == NPC_COUNT and x and math.abs(x - o.x) < 20
	else
		local st, emax, e95 = stats(npc_errs)
		-- we report our own area, never the host's: everything here is near the host, so no ships at all
		local listed = 0
		for _, b in ipairs(bs) do
			for _, code in ipairs({ "NPC-1,", "NPC-2,", "NPC-3,", "NPC-4,", "NPC-7,", "OWN-8,", "NPC-9,", "NPC-10,", "NPC-11," }) do
				if b:find(code, 1, true) then listed = listed + 1 end
			end
		end
		say("npc join: copies vs host truth (m): %s   [%d samples]; B sent by us: %d, listing host-area ships %d times",
			st, #npc_errs, #bs, listed)
		ok = ok and #npc_errs > 1000 and e95 < 5 and #bs > 8 * (sc.duration - 5) and listed == 0
		local mst, mmax, m95 = stats(mirror_errs)
		local mid = mirror_of_code["NPC-9"]
		local acts = table.concat(obj_actions, " ")
		local sent = table.concat(pipe_writes, "\n")
		say("npc join: stand-in for NPC-9 = %s, vs host truth (m): %s; actions: %s", tostring(mid), mst, acts)
		local fst, fmax, f95 = stats(found_errs)
		local stand_ins = 0
		for _ in pairs(mirror_of_code) do stand_ins = stand_ins + 1 end
		say("npc join: stand-ins created %d (md events %d), own far copy NPC-10 found: %s, vs host truth (m): %s",
			stand_ins, md_events.npc_mirror or 0, tostring(found_own["NPC-10"]), fst)
		ok = ok and stand_ins == 2 and mirror_of_code["NPC-11"] ~= nil and mirror_of_code["NPC-10"] == nil
			and found_own["NPC-10"] == 410 and #found_errs > 300 and f95 < 10
		ok = ok and mid ~= nil and #mirror_errs > 500 and m95 < 10
			and acts:find("obj_remove:407", 1, true) ~= nil            -- joiner-only NPC removed
			and acts:find("obj_remove:408", 1, true) == nil            -- player-owned ship kept
			and acts:find("obj_hull:401,55", 1, true) ~= nil           -- host's lower hull taken
			and acts:find("obj_hull:402", 1, true) == nil              -- never raised / never for undamaged
			and mid == mapped_mirror                                    -- no second stand-in after the kill
			and acts:find("obj_fire:" .. tostring(mapped_mirror), 1, true) ~= nil -- host fires at NPC-9 -> our stand-in
			and acts:find("obj_kill:" .. tostring(mapped_mirror), 1, true) ~= nil -- host kills NPC-9 -> our stand-in
			and sent:find("D|NPC-9|", 1, true) ~= nil                   -- our hit on the stand-in, as NPC-9
			and sent:find("D|MIR-", 1, true) == nil
	end
end
if sc.econ_test == "host" then
	local sent, per_station, last_by_code, last_named = 0, {}, {}, {}
	for _, w in ipairs(pipe_writes) do
		local pass, index, count, code, wares, named = w:match("^E|stock|(%d+)|(%d+)|(%d+)|([%w%-]+)|([^|]*)|(.*)$")
		if code then
			sent = sent + 1
			per_station[code] = (per_station[code] or 0) + 1
			last_by_code[code] = wares
			last_named[code] = named
		end
	end
	local exact = 0
	for i = 1, 5 do  -- what we sent last must be what our stations hold at the end
		local o, want = objects[700 + i], {}
		for ware, amount in pairs(o.cargo) do want[#want + 1] = ware .. ":" .. amount end
		table.sort(want)
		if last_by_code[o.idcode] == table.concat(want, ",") then exact = exact + 1 end
	end
	local acks, counted = 0, 0
	for _, w in ipairs(pipe_writes) do if w == "T|ack|0abc" then acks = acks + 1 end end
	for _, a in ipairs(stock_actions) do if a == "STN-2:hullparts+50" then counted = counted + 1 end end
	say("econ host: the joiner's trade counted %d time(s), acknowledged %d times, named in our STN-2 report: %s",
		counted, acks, tostring(last_named["STN-2"]))
	ok = ok and counted == 1 and acks == 2 and last_named["STN-2"] == "0abc" and objects[702].cargo.hullparts == 850
	say("econ host: %d station reports sent (%.1f/s); each of the 5 stations sent %s times; exact contents %d of 5",
		sent, sent / sc.duration, tostring(per_station["STN-1"]), exact)
	ok = ok and sent > 80 and exact == 5 and per_station["STN-9"] == nil and #stock_actions == 1
end
if sc.econ_test == "join" then
	local passes, first, late_zero = {}, nil, 0
	for _, line in ipairs(log_lines) do
		local pass, matched, missing, drift = line:match("economy: pass (%d+): (%d+) stations matched, (%d+) not in this world.-drifted ([%d%.]+)%%")
		if pass then
			passes[#passes + 1] = { tonumber(pass), tonumber(matched), tonumber(missing), tonumber(drift) }
			first = first or passes[#passes]
		end
	end
	for _, p in ipairs(passes) do
		if p[1] > 30 and p[4] == 0 and p[2] == 5 and p[3] == 1 then late_zero = late_zero + 1 end
	end
	local equal = 0
	for i = 1, 5 do
		local o, want, same = objects[700 + i], HOST_STOCK["STN-" .. i], true
		for ware, amount in pairs(want) do if amount > 0 and o.cargo[ware] ~= amount then same = false end end
		for ware, amount in pairs(o.cargo) do if (want[ware] or 0) ~= amount then same = false end end
		if same then equal = equal + 1 end
	end
	local acts = table.concat(stock_actions, " ")
	say("econ join: %d passes logged; first: %s matched, %s missing, drift %s%%; late passes with no drift: %d; stations equal to the host's at the end: %d of 5",
		#passes, first and first[2] or "-", first and first[3] or "-", first and first[4] or "-", late_zero, equal)
	say("econ join: stock changes: %s", acts:sub(1, 300))
	say("econ join: our trade sent %d time(s); STN-1 energy cells after it: highest %d, at the end %d, host %d",
		#trades_seen, max_after_trade, objects[701].cargo.energycells or 0, HOST_STOCK["STN-1"].energycells)
	ok = ok and #trades_seen >= 1 and #trades_seen <= 2 and max_after_trade == 5000
		and objects[701].cargo.energycells == 5000 and HOST_STOCK["STN-1"].energycells == 5000
	ok = ok and #passes > 30 and first and first[4] > 0 and late_zero > 5 and equal == 5
		and acts:find("STN-1:energycells+300", 1, true) ~= nil and acts:find("STN-2:silicon-120", 1, true) ~= nil
		and acts:find("STN-3:water-100", 1, true) ~= nil and acts:find("STN-3:water-2500", 1, true) ~= nil
		and acts:find("STN-4:energycells-50", 1, true) ~= nil and acts:find("STN-5:", 1, true) == nil
end
if sc.rel_test == "join" then
	local acts = table.concat(rel_actions, " ")
	say("relations join: Argon %.4f (host %.4f), highest after our change %.4f; our change sent %d time(s); md: %s",
		our_relations.argon, HOST_RELATIONS.argon, rel_max_after, #rel_changes_seen, acts:sub(1, 200))
	ok = ok and math.abs(our_relations.argon - 0.25) < 1e-6 and math.abs(HOST_RELATIONS.argon - 0.25) < 1e-6
		and rel_max_after < 0.25 + 1e-6 and #rel_changes_seen >= 1 and #rel_changes_seen <= 2
		and acts:find("set:argon=0.3000", 1, true) ~= nil and acts:find("set:xenon", 1, true) == nil
		and acts:find("joiner:1", 1, true) ~= nil
end
if sc.rel_test == "host" then
	local acks, states, named_ok = 0, 0, false
	for _, w in ipairs(pipe_writes) do
		if w == "V|ack|0bcd" then acks = acks + 1 end
		if w:sub(1, 8) == "V|state|" then
			states = states + 1
			named_ok = w:find("teladi:-0.180000", 1, true) ~= nil and w:find("|0bcd", 1, true) ~= nil
		end
	end
	local adds = 0
	for _, a in ipairs(rel_actions) do if a:sub(1, 4) == "add:" then adds = adds + 1 end end
	say("relations host: %d reports (%d reads), the joiner's change added %d time(s), acknowledged %d times, last report includes and names it: %s",
		states, rel_reads, adds, acks, tostring(named_ok))
	ok = ok and states >= 2 and adds == 1 and acks == 2 and named_ok and math.abs(our_relations.teladi + 0.18) < 1e-6
		and table.concat(rel_actions, " "):find("joiner:", 1, true) == nil
end
if sc.unlock_test then
	local acks = 0
	for _, w in ipairs(pipe_writes) do if w == "U|ack|00aa" then acks = acks + 1 end end
	local ours = 0
	for _, u in ipairs(unlock_sends) do if u:find(":r:research_teleportation", 1, true) then ours = ours + 1 end end
	say("unlocks: ours sent %d time(s); md adds: %s; acks for the partner's blueprint: %d; switch: %s",
		ours, table.concat(unlock_requests, ", "), acks, table.concat(unlock_switch, ","))
	ok = ok and ours == 1 and table.concat(unlock_requests, ", ") == "b:weapon_gen_m_laser_01_mk1:w, l:argon:police"
		and acks == 2 and unlock_switch[1] == "1"
		and said:find("shared with your partner: research research_teleportation", 1, true) ~= nil
		and said:find("from your partner: blueprint weapon_gen_m_laser_01_mk1", 1, true) ~= nil
end
if sc.credits_test then
	local acks = 0
	for _, w in ipairs(pipe_writes) do if w == "C|ack|00c0ffee" then acks = acks + 1 end end
	local offers_700 = 0
	for _, w in ipairs(pipe_writes) do if w:match("^C|give|%x+|700|") then offers_700 = offers_700 + 1 end end
	say("credits: wallet %d (expected 96234); md money changes: %s; acks sent for the partner's gift: %d; offers of 700: %d; empire switch: %s",
		player_money, table.concat(money_requests, ","), acks, offers_700, table.concat(empire_requests, ","))
	ok = ok and player_money == 96234
		and table.concat(money_requests, ",") == "-5000,1234,-700,700"
		and acks == 2 and offers_700 >= 2
		and said:find("your partner received 5,000 Cr", 1, true) ~= nil
		and said:find("Partner sent you 1,234 Cr", 1, true) ~= nil
		and select(2, said:gsub("Partner sent you", "")) == 1
		and said:find("you have only 95,000 Cr", 1, true) ~= nil
		and said:find("didn't confirm 700 Cr", 1, true) ~= nil
		and empire_requests[1] == "1:abc123"
end
if sc.fire_test then
	local fires = {}
	for _, r in ipairs(world_requests) do if r:sub(1, 5) == "fire:" then fires[#fires + 1] = r end end
	say("ghost fire requests: %s", table.concat(fires, " "))
	ok = ok and #fires == 2 and fires[1] == "fire:TGT-001,ship_arg_s_fighter_01_a_macro,cluster_01_sector001_macro"
		and fires[2] == "fire:TGT-002,ship_arg_s_fighter_01_a_macro,cluster_01_sector001_macro"
end
if sc.expect_no_proxy then
	ok = ok and spawns == 0 and said:find("Mod Support APIs not installed", 1, true) ~= nil
else
	local max_pos, max_rot = sc.max_pos_err or 15, sc.max_rot_err or 0.08
	ok = ok and #pos_errs > 600 and p95 < max_pos and r95 < max_rot and S.probe.measured
	if sc.true_conv.order ~= "YXZ" or sc.true_conv.sy * sc.true_conv.sp * sc.true_conv.sr ~= 1 then
		ok = ok and api.math.conv_name(S.conv) == string.format("%s%s%s%s", sc.true_conv.order, sc.true_conv.sy > 0 and "+" or "-", sc.true_conv.sp > 0 and "+" or "-", sc.true_conv.sr > 0 and "+" or "-")
	end
	if sc.setpos == "degrees" then ok = ok and S.lua_degrees end
	if sc.forced_backend then ok = ok and api.config.backend == sc.forced_backend end
	if sc.setpos == "ignore" then ok = ok and S.backend == "md" end
	if sc.jump_at then ok = ok and warps >= 1 end
end
finish(ok)
