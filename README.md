# X4 Co-op (prototype)

Two players fly side by side. Each player runs their own normal single-player universe; the
other player appears as a **proxy ship** that copies their ship's position and rotation, sent
20 times a second. NPCs, combat, trading and missions are **not** shared yet. This is the
movement foundation everything else would build on.

Status (2026-10-08): **ghost mode works in-game.** In the first session (Terran start, v9.00) the
ghost spawned and flew in formation. The self-test found that `SetObjectSectorPos` takes
**degrees**, and the mod adapts automatically. The probe measured the engine's rotation
convention as **YXZ+--** (pitch and roll opposite to right-handed maths), now the default. Networking between two real players is not tested
yet. Offline tests: see [Developer tests](#developer-tests).

## How it works

```
 your PC                                                              partner's PC
 ui/x4_coop.lua ⇄ pipe ⇄ x4_coop_bridge.py ⇄ UDP ⇄ x4_coop_bridge.py ⇄ pipe ⇄ ui/x4_coop.lua
      │  spawn / warp / despawn requests
      ▼
 md/x4_coop.xml ──► proxy ship, moved every frame by Lua (SetObjectSectorPos, or MD warp+velocity)
```

* **Lua** (`ui/x4_coop.lua`) does the maths and networking. It reads your ship with
  `GetObjectPositionInSector` (sector coordinates, which both universes share), sends snapshots,
  keeps a short buffer of the partner's snapshots, and dead-reckons them to the present
  (position, velocity, and angular velocity, then smooths corrections). Every frame it places
  the proxy with `SetObjectSectorPos`, the same call the game's map editor uses.
* **MD** (`md/x4_coop.xml`) does what Lua cannot. It spawns the proxy (your partner's actual
  ship model, player-owned, no pilot, hull cannot drop), warps it when your partner changes
  sector, and destroys it on load, on `/reloadui` and when it goes stale. It also provides
  a fallback mover (`warp` plus `set_object_velocity`) in case `SetObjectSectorPos` turns out
  not to work on ships.
* **Bridge** (`bridge/x4_coop_bridge.py`) connects the game's named pipe to UDP. It is
  standard-library Python with no installs. X4 reaches the pipe through
  [SirNukes' Mod Support APIs](https://github.com/bvbohnen/x4-projects), which provides the
  pipe DLL to Lua.

Self-calibration on first flight:
* **Backend self-test**: the proxy is nudged 30 m and read back. If `SetObjectSectorPos` has no
  effect, the mod switches to the MD fallback. If it takes degrees instead of radians, that is
  detected too.
* **Rotation probe**: MD reports the engine's own forward, right and up vectors. Lua uses them
  to work out the order and signs of the yaw/pitch/roll convention. This takes a few seconds of
  flying with some pitch and roll. Level flight is ambiguous, so it keeps sampling until only
  one convention fits.

## Install

Copy this folder to `X4 Foundations/extensions/x4_coop/` (it is already there if you are
reading this in place). New extensions are enabled by default (`enabled="1"` in content.xml).
To check, start X4 and open **Extensions** from the main menu: "X4 Co-op (prototype)" should
be listed and ticked. Toggling an extension needs a game restart. While any non-Egosoft
extension is active, X4 marks the game as modified.

To see what the mod is doing, set X4's Steam launch options (Library → right-click X4 →
Properties → Launch Options) to `-debug scripts -logfile debuglog.txt`. Lua messages are logged
as errors and always appear; `-debug scripts` adds the MD `debug_text` lines (proxy spawned,
and so on). The log goes to `Documents/Egosoft/X4/<id>/debuglog.txt`; search it for `[x4coop]`
and `x4coop:`.

## Chat commands

Commands go in X4's chat window, which has no key by default. To bind one: **Settings → Controls →
General Controls**, then scroll to the bottom section **"Expert Settings - Use with Caution!"** →
**Toggle Chat Window**. Press that key in flight and type:

| command | effect |
|---|---|
| `/x4coop status` | mode, backend, proxy state, where your partner is and how far, link/RTT, rotation convention |
| `/x4coop join` | warp your ship beside your partner (pilot seat, undocked) |
| `/x4coop say <text>` | send a chat line to your partner (in ghost mode the ghost repeats it) |
| `/x4coop ghost` / `net` / `off` | switch mode (remembered in the savegame) |
| `/x4coop backend auto` / `lua` / `md` | movement backend (auto = self-test, then pick) |
| `/x4coop probe` | redo the rotation calibration |
| `/x4coop set <key> <number>` | tweak a setting live, e.g. `set ghost_right 400`, `set predict 0` |

The settings are in the `config` table at the top of `ui/x4_coop.lua`. If chat commands
don't work for you, edit them there and reload your save (or type `/reloadui`).

## Test 1: ghost (single player, no dependencies)

The default mode is `ghost`. Your own snapshots go through a simulated network (120 ms latency,
30 ms jitter) and come back as a copy of your ship, **120 m ahead and 60 m to the right**, so
it's in view from the cockpit.

1. Load any save and sit in the pilot seat of a ship.
2. Within a second, "[Co-op] Ghost" should appear ahead of you and copy your manoeuvres.
3. Fly straight, turn, roll and boost. It should hold its spot relative to you.
4. `/x4coop status`, then check the log for the self-test, probe and `health:` lines.

Move it with `/x4coop set ghost_forward 200`, `ghost_right`, `ghost_up` (metres). For L/XL
ships, use a few hundred metres or the ghost will collide with you. The rotation probe needs
a few seconds of real flying with some pitch and roll; level flight or sitting still can't
tell the conventions apart.

## Test 2: networking on one PC

1. Install **SirNukes' Mod Support APIs** (Steam Workshop or Nexus) and turn **off**
   *Protected UI Mode* (Settings → Extensions). The pipe DLL needs that.
2. In game: `/x4coop net`.
3. Terminal 1: `python extensions/x4_coop/bridge/x4_coop_bridge.py --host`
4. Terminal 2: `python extensions/x4_coop/bridge/fake_peer.py`. It echoes your ship back 150 m
   along the sector X axis, or use `--mode orbit` to circle you.
5. Your status should show `bridge connected` and an RTT.

## Test 3: two players

* Both need the same galaxy: same DLCs and a sector your partner has too. The proxy is placed
  by sector macro name; if you don't have the sector, you get a "could not place partner" notice.
* One player hosts: `python x4_coop_bridge.py --host --password <something>`. The host must be
  reachable on **UDP 47810**: either forward that port on the router, or both join a VPN like
  Tailscale or ZeroTier, which is easier and private.
* The other joins: `python x4_coop_bridge.py --join <host address> --password <something>`
* Both type `/x4coop net`. Then one of you types `/x4coop join` to warp beside the other,
  or you both fly into the same sector.
* The password is optional but recommended. Packets are signed with it (HMAC), and packets
  without it are dropped and logged. A host serves one partner and ignores others until that
  partner has been silent for 10 s.

## What to check first

The offline tests can't answer these; one in-game session can:

Confirmed in the first sessions: the proxy spawns, the self-test passes (angles in degrees), the
ghost follows you, the engine keeps it exactly where it's put (no physics fight), chat works, and
the MD fallback mover is much worse than the Lua one. Still open:

1. **Probe line**: `engine rotation convention is …`. If it says ambiguous, fly with more
   pitch and roll. If it says `no convention fits`, send the raw numbers.
2. **`health:` lines** (every 15 s while a proxy exists): distance to you, snapshots/s, Lua
   updates/s and the longest gap between them, the average and maximum prediction correction,
   and how far the engine moves the proxy between updates. With `engine_fx` on, expect about
   speed × frame time there. If the ghost stutters, these numbers show whether it's frame gaps
   (long gaps) or prediction (large corrections).
3. **Engine trails** (experiment, `engine_fx` 1 by default): the proxy also gets matching physics
   velocity. Compare with `/x4coop set engine_fx 0`.
4. **Smoothness and FPS** of the ghost at speed, in both backends (`/x4coop backend md` to compare).
5. Anything odd: collisions, warnings about a ship without a pilot.

Paste the `[x4coop]` and `x4coop:` log lines back into the conversation that's developing this.

## Known limitations / next steps

* Only movement is shared. Universes are separate (NPCs and stations differ per player).
* The proxy is player-owned so it shows as friendly, which also means it appears in your
  property list. A dedicated faction would be cleaner.
* Weapons and damage are not synced yet. The game offers `event_weapon_fired` (detects your
  shots) and the AI action `shoot_at` (makes a ship fire, but needs a pilot and a target in your
  universe). Whether a partner's shots should be cosmetic or do damage is the next design question.
* No docking, highway or travel-drive visuals yet. SETA (time acceleration)
  is not synchronised.
* One partner at a time. With `--password`, packets are authenticated but not encrypted, so
  positions are visible to anyone on the path. A VPN is still the better option.
* The proxy is saved into savegames and destroyed on load. Before uninstalling the mod,
  type `/x4coop off` and save, so no proxy is left behind.

## Developer tests

```
python extensions/x4_coop/dev/run_tests.py
```

From a checkout outside the game folder, set `X4_GAME_DIR` to the X4 install first.

* Validates `md/*.xml` against the game's own `md.xsd`, extracted from the `.cat` archives.
  This needs `lxml`, and is skipped without it.
* Loads `ui/x4_coop.lua` into **X4's own LuaJIT** (`lua51_64.dll`) with stubbed engine
  functions (`dev/sim.lua`), and flies it through 10 scenarios with ground-truth error
  measurement, plus chat, `join` and hostile or malformed partner messages. These cover: unusual engine rotation conventions, degree angles, an ignored
  `SetObjectSectorPos`, the MD backend, the network path with RTT, a partner restarting their
  game, a sector jump, near-vertical flight, and missing Mod Support APIs.
* Runs the real bridge + `fake_peer.py` with `dev/game_sim.py` standing in for X4's pipe client:
  reconnects, chat, matching and wrong passwords, and a second partner trying to barge in.

Typical results: proxy within ~2–3 m (95th percentile) and ~2° of the truth, at 220–300 m/s
while manoeuvring. The MD fallback is within ~6 m and ~9°.

## Files

| path | purpose |
|---|---|
| `content.xml`, `ui.xml` | extension manifest, Lua registration |
| `md/x4_coop.xml` | proxy spawn/despawn/warp, MD movement backend, rotation probe, notifications |
| `ui/x4_coop.lua` | sampling, wire format, buffer/prediction, proxy driver, ghost, pipe client, chat commands |
| `bridge/x4_coop_bridge.py` | named pipe ⇄ UDP bridge (stdlib only) |
| `bridge/fake_peer.py` | fake partner for single-PC network tests |
| `dev/` | offline test kit (`run_tests.py`, `sim.lua`, `run_lua.py`, `game_sim.py`, `catx.py`) |
