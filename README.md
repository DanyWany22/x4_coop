# X4 Co-op (prototype)

Two players fly together in X4: Foundations. Each runs their own game; the mod keeps them in step
by sending messages between them, using only X4's own modding interfaces (no memory hacking).

* **Any two saves:** you see each other's ship fly beside you (30 updates a second, with lag
  hidden by prediction) and can chat. Nothing else is shared.
* **Shared world** (both load the host's save): on top of that, kills and damage sync, your
  partner's guns fire at what they shoot at, the host's NPCs near you are in the same places on
  both sides, and each of you sees the other's real ship and its hull and shields.

## For reviewers

This repository is the whole mod. There are **no compiled files**: every file is readable text, and
nothing is downloaded at runtime.

**Extension files.** These go in `X4 Foundations/extensions/x4_coop/`, and X4 loads them itself:

| file | what X4 does with it |
|---|---|
| [`content.xml`](content.xml) | extension manifest |
| [`ui.xml`](ui.xml) | registers the Lua file with the game's UI |
| [`ui/x4_coop.lua`](ui/x4_coop.lua) | Lua, run by the game's UI (LuaJIT) |
| [`md/x4_coop.xml`](md/x4_coop.xml) | Mission Director script (X4's XML scripting) |
| [`aiscripts/x4coop.proxy.fire.xml`](aiscripts/x4coop.proxy.fire.xml) | AI script that makes the partner's ship fire |

**Installation:** see [Install](#install) and [Playing together](#playing-together).

**Source code:** everything is here:
* `ui/`, `md/`, `aiscripts/`: the extension above.
* `bridge/`: the network program each player runs next to the game (Python, standard library
  only), its launchers and the telemetry tools.
* `dev/`: offline tests and the test doubles they use.
* `demo/`: a separate demo of reading and writing X4's memory. It isn't part of the mod.

### How a script mod can network

X4's Lua has no sockets, and this mod doesn't open any in Lua. The networking is done by a separate
program on each PC, the bridge, which the game reaches through a **Windows named pipe**:

```
X4 (ui/x4_coop.lua) <-> named pipe <-> bridge (Python: UDP/TCP sockets) <-> network <-> partner's bridge <-> pipe <-> partner's X4
```

* The Lua opens `\\.\pipe\x4_coop` with Windows' own `CreateFileA`, `ReadFile`, `WriteFile` and
  `PeekNamedPipe` from kernel32. It calls them through LuaJIT's FFI: on Windows, `ffi.C` also looks
  up kernel32. See the block marked "own pipe client" in `ui/x4_coop.lua`.
  `dev/pipe_test.py` runs exactly that block inside the game's own `lua51_64.dll` against a real
  bridge.
* Fallback, only used if that can't load: SirNukes' Mod Support APIs, an existing Workshop mod whose
  small DLL offers the same named pipe to Lua.
* The bridge ([`bridge/x4_coop_bridge.py`](bridge/x4_coop_bridge.py)) creates the pipe and accepts
  only `X4.exe` as its client. It relays each message over UDP (encrypted and signed with the
  players' password) to the partner's bridge, which writes it into the partner's pipe.

### Native code and memory addresses

The mod has **no DLLs, no hooks, no injection, and reads or writes no memory addresses**.
[`demo/x4_memory_demo.py`](demo/x4_memory_demo.py) is a separate tool that shows reading and
writing X4's memory is possible, on your credits; the mod never loads or calls it. The
[Memory demo](#memory-demo-not-part-of-the-mod) section also explains why the mod doesn't need
memory writes. The Lua calls functions by name through FFI:

* **6 Windows functions** for the pipe (listed above).
* **15 game functions.** Egosoft's own UI scripts call every one of them; one example file each, from
  the game's archives:

| function | used by vanilla, e.g. |
|---|---|
| `GetObjectPositionInSector` | `ui/addons/ego_detailmonitor/menu_map.lua` |
| `SetObjectSectorPos` | `ui/addons/ego_detailmonitor/menu_mapeditor.lua` |
| `GetPlayerOccupiedShipID` | `ui/addons/ego_chatwindow/chatwindow.lua` |
| `GetContextByClass`, `GetPlayerID` | `ui/addons/ego_detailmonitor/menu_docked.lua` |
| `GetObjectIDCode` | `ui/addons/ego_detailmonitor/menu_diplomacy.lua` |
| `GetPlayerName` | `ui/addons/ego_detailmonitor/menu_playerinfo.lua` |
| `IsComponentOperational`, `CanTeleportPlayerTo`, `TeleportPlayerTo`, `IsSaveListLoadingComplete` | `ui/addons/ego_detailmonitor/menu_map.lua` |
| `IsGamePaused` | `ui/addons/ego_helptext/helptext.lua` |
| `GetSaveFolderPath`, `IsSaveValid`, `ReloadSaveList` | `ui/addons/ego_gameoptions/gameoptions.lua` |

Everything else, such as spawning ships, damage, kills and weapons, is ordinary Mission Director
and AI script. The tests validate those files against the game's own XSD schemas.

### Test doubles (never used when playing together)

* **`ghost` mode,** the default until you type `/x4coop net`, is a single-player demo. The Lua feeds
  your own ship's position back to itself through a simulated delay and shows it as
  "[Co-op] Ghost". It never touches the pipe or the network.
* **`dev/fake_peer.py`** stands in for a partner, so one bridge can be tested alone.
* **`dev/sim.lua`, `dev/run_lua.py`, `dev/game_sim.py`** are test harnesses: a stubbed game engine
  for running the mod's Lua in X4's LuaJIT DLL outside the game, and a stand-in for the game's
  pipe client.
* **`dev/share_test.py`, `dev/trace_test.py`, `dev/pipe_test.py`** run real bridges on one PC,
  with stand-ins for the games.

### Checking it yourself

* Play on two PCs. `host.bat` and `join.bat` show the [telemetry overlay](#telemetry-seeing-and-proving-the-link)
  and record traces. `report.bat` matches every packet one PC sent to its arrival on the other.
* Capture port 47810 with Wireshark, or with `bridge/capture.bat` (Windows' own Packet Monitor).
  Every UDP payload starts with `X4C2 `, then the same HMAC tag the bridge's trace lists.
* `python dev/run_tests.py` runs the offline tests (set `X4_GAME_DIR` outside the game folder).

## Requirements

* X4 9.00 on both PCs, with the same DLCs (the partner is placed by sector name).
* For playing together (not for the ghost test): the bridge on both PCs. The mod opens the
  bridge's pipe with Windows' own functions. If `/x4coop check` says the pipe functions can't be
  reached, turn **Protected UI Mode** off (Settings → Extensions). SirNukes'
  [Mod Support APIs](https://github.com/bvbohnen/x4-projects) are an optional fallback.
* Python 3.8+ on Windows for the bridge (standard library only, nothing to install).
* A key for X4's chat window, where the `/x4coop` commands go: **Settings → Controls → General
  Controls**, bottom section **"Expert Settings - Use with Caution!"** → **Toggle Chat Window**.

## Install

Put this folder at `X4 Foundations/extensions/x4_coop/`. New extensions are enabled by default;
check under **Extensions** in the main menu. Both players need the same version of the mod.

Optional, to see what it's doing: Steam launch options `-debug scripts -logfile debuglog.txt`.
The log is `Documents/Egosoft/X4/<id>/debuglog.txt`; search it for `[x4coop]` and `x4coop:`.

## Quick start: the ghost (alone, no setup)

The default mode is `ghost`: your own ship comes back through a simulated network (120 ms
latency) as "[Co-op] Ghost", 120 m ahead and 60 m to your right.

1. Load any save and sit in a ship's pilot seat. The ghost appears within a second or two.
2. Fly around; it should hold its spot. Shoot at something: it fires at the same target.
3. `/x4coop say hello` (it answers), `/x4coop status`, `/x4coop check`.

Move it with `/x4coop set ghost_forward 200` (also `ghost_right`, `ghost_up`, in metres); for
big ships use a few hundred metres. In the first minute of flying with some pitch and roll the
mod double-checks the engine's rotation convention (`probe:` in the log).

## Playing together

1. **Bridges.** Each player runs one bridge next to their game (before or after starting X4).
   * Host: double-click `bridge\host.bat`. It shows your addresses and asks for a password.
   * Joiner: double-click `bridge\join.bat`, enter the host's address and the same password.
   * The joiner must reach the host on UDP and TCP **47810**, in one of three ways:
     * **Same home network:** use the host PC's home-network address (`192.168…`). Nothing to set up.
     * **Over the internet:** on the host's router, forward UDP and TCP 47810 to the host PC. The
       joiner then uses the host's public IP. Use a long password (12+ characters, such as a few
       random words), because it is the only thing keeping strangers out.
     * **[Tailscale](https://tailscale.com) or ZeroTier** on both PCs: no router setup. Use the host's
       Tailscale address.
     The first time, **allow Python through Windows Firewall** on the host.
   * The password encrypts and signs everything between the bridges, including the save.
2. **In game**, both: `/x4coop net`, then `/x4coop check`. It names the first thing in the way
   (missing mod, no bridge, partner not reaching you, …) and what to do.
3. When both are in a ship, your partner appears ("Nova is in Mars, 412 km away"). `/x4coop join`
   warps you beside them. `/x4coop say <text>` chats.

Same Steam account on both PCs? Put the second one's Steam in **Offline Mode** to run both, and
turn off Steam Cloud for X4 there so its saves don't overwrite the other PC's.

## Shared world

For kills, damage, gunfire and NPCs to sync, both run the **host's** save:

1. Host, with the bridge running and `/x4coop net`: **`/x4coop guestship`** parks a spare ship of
   your type next to you for your partner. Then **`/x4coop share`**: your game quicksaves and the
   bridge sends that save to your partner's bridge.
2. Joiner: when "the host's save arrived" shows, **`/x4coop loadshared`**. It's installed as your
   quicksave; your previous quicksave is kept next to it as `quicksave.xml.gz.bak-<time>`.
3. Joiner, after loading: `/x4coop net` if needed, then **`/x4coop takeship`** to move into the
   guest ship, and take its pilot seat. Both should show **"world: linked"** (`/x4coop check`
   says "all good").

What syncs while linked:
* **Your ships:** each of you sees the other's *real* ship (it exists in both worlds), with their
  hull and shields. Fire in your world can't take it below their real hull.
* **Kills and damage:** a ship one of you kills dies in the other's world too; hits lower its
  hull on the other side, so both players' damage adds up.
* **Gunfire:** your partner's ship fires at the ship they shoot at (hits or misses).
* **NPCs near you** (within 6 km): the host's world is the truth. The joiner's copies are moved
  to the host's positions 10 times a second and follow the host's hull; ships only the host has
  get a stand-in; ships only the joiner has, well inside the host's range, are removed from the
  joiner's (throwaway) copy. Their own AI still decides when to shoot.

Outside the area around you, the two worlds drift apart (economy, far-away NPCs). The host's
world is the real one: next session, share again.

## Commands

| command | effect |
|---|---|
| `/x4coop status` | mode, link, RTT, proxy state, where your partner is, rotation convention |
| `/x4coop check` | the first thing standing in the way of co-op, and what to do about it |
| `/x4coop ghost` / `net` / `off` | mode (remembered in the savegame) |
| `/x4coop join` | warp beside your partner (pilot seat, undocked) |
| `/x4coop say <text>` | chat line to your partner |
| `/x4coop guestship` | host: park a spare ship for the joiner (before sharing) |
| `/x4coop share` | host: quicksave and send it to the joiner's bridge |
| `/x4coop loadshared` | joiner: load the save the host sent |
| `/x4coop takeship` | joiner: move into the guest ship |
| `/x4coop pipe <name>` | another pipe name, for a second game on the same PC (session only) |
| `/x4coop backend auto` / `lua` / `md` | how the partner's ship is moved (auto: self-test) |
| `/x4coop probe` | redo the rotation calibration |
| `/x4coop set <key> <number>` | change a setting for this session |

Settings (`set`, or the `config` table at the top of `ui/x4_coop.lua`): `send_rate`, `predict`,
`smoothing`, `ghost_right/up/forward`, `engine_fx` (proxy gets physics velocity, for engine
effects), `fire_fx` (proxy fires; gives spawned proxies a pilot), `npc_sync`, `npc_radius`,
`npc_mirror`, `npc_remove`, `npc_hull` (the shared-world NPC parts), and more.

## Telemetry: seeing and proving the link

`host.bat` and `join.bat` start the bridge with `--overlay --trace`:

* **Overlay** (`x4_coop_overlay.py`): a small window on top of the game, updated 10 times a second:
  * the link state and encryption
  * this PC (name, process, X4's process, UDP binding, the address it sends from)
  * the partner PC (name, process, address, round trip measured by the bridges)
  * packets and KB per second each way
  * both ships as they cross the wire: position, speed, hull, shield and each machine's own game clock
  * the distance between the ships, hits, kills and chat
  * the latest datagrams' sizes, counters and first bytes (`58 34 43 32 20` is "X4C2 ")

  X4 must run **borderless or windowed**, because exclusive fullscreen covers other windows. The window
  lets clicks through to the game. **Ctrl+Shift+F12** lets you drag it, and right-click then closes it;
  press Ctrl+Shift+F12 again to lock it. **Ctrl+Shift+F11** hides or shows it.
* **Trace** (`bridge\traces\x4coop-<PC>-<role>-<time>.jsonl`, about 1.5 MB a minute): one JSON object
  per line, for:
  * the socket bindings
  * X4's pipe connection
  * the partner machine and round trip
  * the TCP save transfer
  * **every datagram**: direction, local and remote address and port, sizes, our header (magic, HMAC
    tag, session, counter, send time), the first 64 bytes as sent or received (`--trace-bytes 0` for
    all of them), the decrypted message and what the bridge did with it.
* **Two-machine report:** copy one PC's trace to the other and drag both onto `report.bat` (or run
  `python x4_coop_trace_report.py A.jsonl B.jsonl --html report.html`). Each datagram is matched to
  its arrival on the other PC by its 128-bit HMAC tag. The report shows:
  * how many arrived, and the one-way trip each way
  * the clock offset between the PCs, estimated from the packets
  * that the bytes and the decrypted text are identical on both sides
  * a side-by-side timeline of both PCs' own ships, each simulated by its own game with its own clock
  * every hit and kill, with when it reached the other PC
  * an HTML page with the two flight paths, trip times and both speeds over time
* **Independent capture:** `capture.bat` (run as administrator) records every packet on port 47810
  with Windows' own Packet Monitor and converts it to `.pcapng` for Wireshark and to text. The IP
  and UDP headers come from Windows, not from the mod. Each payload's first bytes and HMAC tag match
  a datagram in the bridge's trace.

## Memory demo (not part of the mod)

`demo/memory_demo.bat` (or `python demo/x4_memory_demo.py`) shows that X4's memory can be read and
written directly, using your credits. The co-op mod doesn't work this way and never runs this tool.

1. Load a **throwaway save**. A write in the wrong place can crash the game, so don't save afterwards.
2. Type the credits the game shows. The tool scans X4's writable memory for that number, as whole
   credits and as hundredths, using Windows' `ReadProcessMemory`.
3. If it finds many places, change your credits in game (buy or sell anything) and type the new
   amount. Only the places that changed to it are kept. Repeat until one or two are left.
4. **Read:** it shows each address, its 8 bytes and the value they hold.
5. **Write:** type an amount and confirm. The tool writes it with `WriteProcessMemory`, but only where
   the current amount still is, then reads it back. The credits display in the game changes. Press
   Enter to put the old amount back.

The addresses change every time the game starts, which is why the tool scans for them each time.
No administrator rights are needed. `dev/memdemo_test.py` checks the tool against a stand-in
process, not X4.

### Why the mod doesn't need memory writes

Everything co-op has to share can be reached through X4's own scripting. Scripts keep working
across game updates, while memory addresses move with every update, and a memory write can only
change a value that already exists; it can't create anything.

| what co-op shares | script command that reaches it | used by the mod today |
|---|---|---|
| ship position, rotation, speed | `SetObjectSectorPos` (Lua), `set_object_velocity`, `warp` | yes |
| hull, shields, kills | `set_object_hull`, `set_object_shield`, `destroy_object` | yes |
| firing at a target | `shoot_at` (AI script) | yes |
| NPC ships near the players | the same position and hull commands | yes |
| credits | `add_money`, `remove_money`, `transfer_money` | not yet |
| station stock, and so prices | `add_cargo`, `remove_cargo` | not yet |
| trade offers | `create_trade_offer`, `remove_trade_offer` | not yet |
| faction relations | `set_faction_relation` | not yet |
| research, blueprints, inventory | `add_research`, `add_blueprints`, `add_inventory` | not yet |
| time acceleration (SETA) | `set_timewarp_factor` | not yet |
| ownership, orders, missions | `set_owner`, `create_order`, `create_mission` | not yet |

All of these, except `SetObjectSectorPos` and `shoot_at`, are Mission Director commands from the
game's own schema (`libraries/md.xsd`, `libraries/common.xsd`).

* **What scripts can't set:** the game clock, and small per-frame details such as weapon heat on
  the partner's ship. The details are cosmetic. The clock is risky to overwrite, because the game
  schedules everything on it.
* **What neither scripts nor memory writes can do:** these are the engine's behaviour, not stored
  values, so they would need changes to the game's own code:
  * fully simulating a sector far from the player
  * creating projectiles
  * a headless server

## Troubleshooting

* `/x4coop check` first.
* **Partner never connects:** same password on both bridges? Same bridge version on both? Host's
  firewall allows Python? Joiner using the right address for how you connect? Both PCs' clocks right
  (within a minute)? The bridge windows log `partner connected` / `rejected packets … <reason>`.
* **Over the internet, the host's bridge never logs a partner:** check the port forward (UDP 47810 to
  the host PC's home-network address). If the router's own "WAN IP" differs from what "what is my
  ip" shows, or starts with `100.64`–`100.127`, the ISP shares one address between customers
  (CGNAT) and forwarding can't work. Then the other player hosts, or use Tailscale, or try
  `--peer` on both sides (each names the other's public IP; many routers let that through because
  both send first):
  `python x4_coop_bridge.py --peer <their public IP> --role host --password …` (the joiner uses `--role join`).
* **"can't reach Windows' pipe functions":** turn Protected UI Mode off (Settings → Extensions) and
  load the save again. `/x4coop status` shows which pipe client is in use ("via own" or "via
  SirNukes"); `/x4coop pipeclient own|sirnukes|auto` switches.
* **Partner's ship jitters:** the `health:` lines (every 15 s) show updates/s and the longest
  frame gap (stutter from frame timing) and prediction corrections (from the network). `/x4coop
  set engine_fx 0` and `fire_fx 0` turn off the two experiments.
* Bring the `[x4coop]` / `x4coop:` log lines from both PCs and both bridge windows' output.

## How it works

```
 your PC                                                              partner's PC
 ui/x4_coop.lua ⇄ pipe ⇄ x4_coop_bridge.py ⇄ UDP/TCP ⇄ x4_coop_bridge.py ⇄ pipe ⇄ ui/x4_coop.lua
      ⇅ requests and events
 md/x4_coop.xml (+ aiscripts/x4coop.proxy.fire.xml)
```

* **Lua** (`ui/x4_coop.lua`, loaded like Egosoft's own UI) reads your ship's sector position with
  `GetObjectPositionInSector`, sends it as a one-line message, buffers the partner's messages,
  predicts where they are now, and places their ship every frame with `SetObjectSectorPos` (the
  map editor's function). It also runs the link check, NPC bubble, chat and commands.
* **MD** (`md/x4_coop.xml`, X4's Mission Director scripting) does what only scripts can: spawn or
  adopt ships, warp, set hull/shields, destroy, find ships by ID code, notice your kills, hits and
  shots, list ships near you. The AI script makes a proxy fire.
* **Pipe client** (in `ui/x4_coop.lua`): Windows' kernel32 named-pipe functions through LuaJIT's
  FFI, or SirNukes' Mod Support APIs as a fallback.
* **Bridge** (`bridge/x4_coop_bridge.py`) carries the messages: named pipe to the game (only
  `X4.exe` on this PC may connect), UDP to the partner (encrypted and signed with keys made from
  the password, replay protected, one partner at a time), TCP for the save handoff (encrypted too).

Messages (one text line each): `S` snapshot (position, rotation, velocity, ship, hull, shield),
`P`/`Q` ping, `M` chat, `L` world link, `K` kill, `D` hit, `F` firing at, `B` host's nearby
ships; `R`/`W`/`N`/`X` are between a game and its own bridge.

Self-calibration: on first contact the proxy is nudged and read back (does `SetObjectSectorPos`
work, and in which angle unit), and the rotation convention is checked against the engine's own
axis vectors. In-game results so far: degrees, YXZ+--.

## Known limitations

* Ships in the shared world match by ID code; a ship bought by one player after the shared save
  only exists on their side (it shows up as a stand-in on the joiner's side when near the host).
* Proxies are player-owned (friendly, but listed in your property).
* No highway or travel-drive visuals for the partner; they reappear when they leave the highway.
  SETA (time acceleration) is not synchronised; avoid it while playing together.
* The bridge's encryption uses Python's standard library only: scrypt for the key, a SHAKE-256
  keystream, HMAC-SHA256. That is sound, but it is home-made, not a reviewed protocol like
  Tailscale's WireGuard. A weak password can be guessed offline by anyone who records your traffic.
* Proxies are saved with the game and removed on load. Before uninstalling: `/x4coop off`, save.

## Developer tests

```
python extensions/x4_coop/dev/run_tests.py [--quick]
```

* MD and AI scripts validated against the game's own schemas (from the `.cat` archives; needs
  `lxml`; `--quick` skips the slow AI-script schema).
* `ui/x4_coop.lua` flown through ~20 scenarios in **X4's own LuaJIT** (`lua51_64.dll`) with a
  stubbed engine (`dev/sim.lua`): unusual rotation conventions, degree angles, the MD fallback,
  network with RTT, partner restarts, sector jumps, near-vertical flight, shared-world link and
  mismatch, kills/hits/fire, adoption, NPC bubble host and joiner (stand-ins, removal, hull),
  hostile messages, guest ship, save handoff commands. Errors are measured against ground truth:
  the partner within ~2–3 m and ~2° (95th percentile) at 220–300 m/s; NPC copies within ~3.5 m.
* Bridge: password codec (encryption, replay, tamper, stale, other versions), reconnects, chat, wrong password, partner
  injecting bridge messages, non-X4 pipe clients, second partner, and a real save handoff
  between two bridges (`dev/share_test.py`).
* Telemetry: two bridges record traces while two stand-in games fly different paths and report a
  hit and a kill; the report must match every datagram both ways with identical bytes and text
  (`dev/trace_test.py`; `--keep DIR --overlay 12` also shows the overlay).

From a checkout outside the game folder, set `X4_GAME_DIR` first.

To give the mod to another PC: `python dev/package.py` writes `x4_coop-<commit>.zip` (committed
files only, no test kit) to your Desktop. Unzip it into `X4 Foundations/extensions/`.

## Files

| path | purpose |
|---|---|
| `content.xml`, `ui.xml` | extension manifest, Lua registration |
| `ui/x4_coop.lua` | sampling, messages, prediction, proxy driver, ghost, shared world, NPC bubble, commands |
| `md/x4_coop.xml` | spawn/adopt/warp proxies, hull/shields, kill/hit/fire events, NPC scan and stand-ins, guest ship |
| `aiscripts/x4coop.proxy.fire.xml` | makes a proxy fire at a ship for a moment |
| `bridge/x4_coop_bridge.py`, `host.bat`, `join.bat` | the bridge and its launchers |
| `bridge/x4_coop_overlay.py` | live telemetry window over the game |
| `bridge/x4_coop_trace_report.py`, `report.bat` | lines up two machines' traces; text and HTML report |
| `bridge/capture.bat` | Windows Packet Monitor capture of port 47810 (pcapng for Wireshark) |
| `demo/x4_memory_demo.py`, `memory_demo.bat` | separate demo: read and write your credits in X4's memory (not used by the mod) |
| `dev/fake_peer.py` | test double: a fake partner, for testing one bridge on one PC |
| `dev/` | offline tests (`run_tests.py`, `sim.lua`, `run_lua.py`, `game_sim.py`, `pipe_test.py`, `share_test.py`, `trace_test.py`, `memdemo_test.py`, `catx.py`) |
