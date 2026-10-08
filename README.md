# X4 Co-op (prototype)

Two players fly together in X4: Foundations. Each runs their own game; the mod keeps them in step
by sending messages between them, using only X4's own modding interfaces (no memory hacking).

* **Any two saves:** you see each other's ship fly beside you (30 updates a second, with lag
  hidden by prediction) and can chat. Nothing else is shared.
* **Shared world** (both load the host's save): on top of that, kills and damage sync, your
  partner's guns fire at what they shoot at, the host's NPCs near you are in the same places on
  both sides, and each of you sees the other's real ship and its hull and shields.

**Status (2026-10-08):** single-player ghost mode is tested in-game (Terran start, X4 9.00): the
ghost spawns and follows, the engine's angle unit (degrees) and rotation convention (YXZ+--)
were measured and are built in. **Networking and the shared world are only tested offline** (a
simulator running this Lua in X4's own LuaJIT, plus real bridges on one PC); the first real
two-player sessions are next.

## Requirements

* X4 9.00 on both PCs, with the same DLCs (the partner is placed by sector name).
* For playing together (not for the ghost test): SirNukes'
  [Mod Support APIs](https://github.com/bvbohnen/x4-projects) (Steam Workshop or Nexus) and
  **Protected UI Mode off** (Settings → Extensions). Its pipe DLL is how the game talks to the
  bridge.
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
3. When both are in a ship, your partner appears ("Aaron is in Mars, 412 km away"). `/x4coop join`
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
* **"pipe DLL blocked":** Protected UI Mode is on. **"Mod Support APIs not installed":** subscribe
  in the Workshop and restart.
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
| `bridge/fake_peer.py` | a fake partner for testing on one PC |
| `dev/` | offline tests (`run_tests.py`, `sim.lua`, `run_lua.py`, `game_sim.py`, `share_test.py`, `catx.py`) |
