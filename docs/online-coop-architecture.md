<!--
Copyright (c) Uladzislau Nikalayevich <thenormalnij@gmail.com>. All rights reserved.
Licensed under the MIT license. See LICENSE file in the project root for details.
-->

# Online coop architecture

This document describes how the mod moves from the current local (splitscreen)
2-player coop to online 2-PC coop. It is the reference for the later features in
this task and is meant to be kept up to date as the online path is built out.

## 1. Current state (what ships today)

Today the mod is **local splitscreen on one PC**:

- **Single process, single run.** Both heroes live in one game process and share
  one `CurrentRun` table. `game/scripts/logic/CoopPlayers.lua` holds the roster
  (`CoopHeroes[]`, the `PlayerUnitIdToHero` map, and `CurrentRun["Hero"..id]`).
- **Players distinguished by local gamepad index.** Each player is bound to a
  physical controller through the native call `CoopSetPlayerGamepad(playerId,
  controllerId)` from `game/scripts/logic/CoopControl.lua`. Input from a given
  controller is attributed to the matching player.
- **Per-hero input dispatch.** `game/scripts/hooks/ControlHooks.lua`
  `OnControlPressed` resolves which hero fired an input from
  `triggerArgs.triggeredById` and runs the gameplay handler through
  `HeroContext.RunWithHeroContext` (`game/scripts/logic/HeroContext.lua`), which
  tags the running coroutine so the shared `CurrentRun` is routed to the correct
  hero.
- **Event bus.** `game/scripts/logic/Events.lua` exposes Observable buses
  (`engine`, `run`, `game`) with `on` / `once` / `trigger`.
- **Native bridge.** `game/src/extensions/LuaFunctionDefs.cpp` registers the
  `Coop*` C functions via `lua_register`; `CoopContext`
  (`game/src/CoopContext.cpp` / `game/src/CoopContext.h`) is the native singleton.

Because both heroes already run in one simulation and input is already routed
per hero, the local build gives us most of the machinery an online host needs.

## 2. Chosen model: HOST-AUTHORITATIVE

Online play uses a **host-authoritative** model.

- **Host** runs the full existing simulation with **both heroes in-process,
  exactly as the local build does today.** The host owns all game state: RNG,
  loot, enemy AI, physics, run progression. Player 1 is the local player on the
  host PC.
- **Client** is a **thin peer**. It does not run the authoritative simulation
  for the shared run. It:
  1. captures its local input and sends input/intent messages to the host, and
  2. renders the remote hero (its own avatar as simulated by the host, plus the
     host player) from host-streamed **state snapshots** (position, animation,
     facing, health, death).

The host drives its local player directly and drives the remote (client) player
by **injecting the client's received input** into the same per-hero dispatch the
local build already uses. The client's screen is effectively a networked view of
the host's simulation for the units it does not own.

### 2.1 Why host-authoritative over deterministic lockstep

Deterministic lockstep would run the full simulation independently on both PCs
and exchange only inputs, relying on both processes producing bit-identical
results every frame. That is **out of reach here**:

- Hades II is a **closed engine**. Its RNG, loot rolls, and enemy-AI decisions
  are not guaranteed to be reproducible across two independent processes, and we
  cannot rewrite the engine to make them so. Any divergence (a different RNG
  draw, a different AI branch) desynchronizes the two runs permanently.
- Lockstep also needs careful input-delay and rollback handling to stay
  playable, all on top of a simulation we cannot make deterministic.

Host-authoritative avoids the determinism requirement entirely: only the host
simulates, so there is exactly one source of truth. It also maps cleanly onto
**seams the mod already has**:

- **Per-hero routing** already exists via `HeroContext` coroutine tagging
  (`game/scripts/logic/HeroContext.lua`).
- **Per-hero input dispatch** already exists via
  `ControlHooks.OnControlPressed` keyed by `triggeredById`
  (`game/scripts/hooks/ControlHooks.lua`).

So the host can drive the remote hero from network input with minimal change to
existing gameplay code, instead of rewriting the engine for determinism.

### 2.2 Trade-offs accepted

- The client sees state at host-tick granularity plus network latency; remote
  units are interpolated/rendered from snapshots, not locally simulated.
- The host is the single point of authority and failure; if the host leaves, the
  session ends. This is acceptable for a 2-player coop mod.
- Bandwidth scales with snapshot size and rate; we keep snapshots to the small
  set of fields listed below and send them at a fixed tick rate.

## 3. Message protocol

Transport is a single reliable, ordered stream between the two PCs (TCP; see
FEAT-002). Messages are **length-prefixed frames** so the receiver can split the
stream back into discrete messages. The implemented framing is:

```
[ uint32 payload_length (little-endian) ][ payload bytes ... ]
```

`payload_length` is a 4-byte little-endian count of the payload bytes that
follow it. The native layer (`NetTransport`) frames only the length; it does not
carry a separate binary kind byte. The message **kind is the first character of
the payload**, a text tag set by the Lua encoder (`NetProtocol`): `H` Hello,
`W` Welcome, `I` InputEvent, `S` StateSnapshot, `B` Heartbeat. The payload is a
dependency-free text encoding: the kind tag, then fields joined by ASCII
separator control characters (`\31` field, `\30` unit field, `\29` unit record).
This text-over-uint32-length format is the shipping wire format; a compact binary
payload remains a possible future optimization behind the same length framing.

Message kinds:

| Kind | Direction | Purpose | Payload fields |
| --- | --- | --- | --- |
| `Hello` | client -> host | Join request / handshake | protocol version, client name |
| `Welcome` | host -> client | Accept join, assign the client its player id | protocol version, assigned player id, initial session info |
| `InputEvent` | client -> host | One input from the client player | control name (e.g. the Hades control id), analog axes (x, y), player id, pressed/released flag |
| `StateSnapshot` | host -> client | Authoritative state for remote unit(s) | per unit: unit/hero id, transform (x, y), facing, current animation, health, death flag |
| `Heartbeat` | both | Keepalive / latency probe | timestamp |

Rules:

- `Hello` / `Welcome` are exchanged once at session start before gameplay
  messages flow.
- `InputEvent` carries the client player id so the host injects it against the
  correct hero.
- `StateSnapshot` is sent by the host at a fixed tick rate and describes the
  units the receiver does not own.
- `Heartbeat` is sent when the stream is otherwise idle to detect a dropped peer
  and to estimate round-trip latency.

Protocol version is checked in `Hello` / `Welcome`; a mismatch aborts the join
with a clear message instead of desyncing.

## 4. Integration map (which file each later feature touches)

Each later feature hooks into an existing seam rather than introducing a parallel
system:

| Existing file | Role in online coop |
| --- | --- |
| `game/scripts/logic/CoopControl.lua` | Choose the **input source** per player: device (gamepad) for the local player vs **network** for the remote player. Local player still binds a gamepad via `CoopSetPlayerGamepad`; the remote player's input arrives from the transport. |
| `game/scripts/hooks/ControlHooks.lua` | `OnControlPressed` is the **host-side injection point**: received `InputEvent` messages are dispatched here as if they came from the remote player's controller, reusing `HeroContext.RunWithHeroContext`. |
| `game/scripts/logic/CoopPlayers.lua` | Owns the **networked remote hero / unit**: mapping the assigned player id to a hero and unit so snapshots can be applied to the right remote unit. |
| `game/scripts/logic/Events.lua` | The per-tick **send/receive pump** hangs off the event bus: drain inbound messages and flush outbound input/snapshots each tick. |
| `game/src/extensions/LuaFunctionDefs.cpp` + `game/src/CoopContext.cpp` / `game/src/CoopContext.h` | The **native transport binding**: new `Coop*` functions (connect/listen, send, poll) registered via `lua_register`, backed by state on the `CoopContext` singleton. |
| `game/scripts/GamemodeInit.lua` | **Session startup**: when `CoopMode == "Online"`, start host/client transport and wire the pump during gamemode init. |
| `game/scripts/mainmenu/CoopMenu.lua` | **Host / join UI**: let the player pick Host or Client, enter host address and port, and start the session. |
| `game/scripts/config.lua` | Holds the inert config switch (`CoopMode`, `Online`) that gates all of the above. Added in FEAT-001. |

## 5. Feature breakdown

- **FEAT-001 (this feature, docs + config only):** this document and the inert
  `CoopMode` / `Online` config fields. No runtime behavior changes; default stays
  `Local`.
- **FEAT-002 (native TCP transport):** Winsock-based connect/listen/send/poll on
  the native side, exposed as `Coop*` Lua functions through
  `LuaFunctionDefs.cpp` and `CoopContext`, with the length-prefixed framing from
  section 3. Kept in self-contained files that only need the standard library and
  the existing Lua headers.
- **FEAT-003 (Lua session + sync):** session handshake (`Hello` / `Welcome`),
  the per-tick send/receive pump on `Events.lua`, host-side input injection via
  `ControlHooks.lua`, remote hero/unit mapping in `CoopPlayers.lua`, snapshot
  apply on the client, and the host/join UI in `CoopMenu.lua`, all gated on
  `CoopMode == "Online"`.

## 6. What is implemented vs stubbed

Keep this section current as the online path lands.

| Area | Status |
| --- | --- |
| Local splitscreen coop | **Implemented** (ships today, unchanged by the online work). |
| `CoopMode` / `Online` config switch | **Implemented** (FEAT-001). Fields exist and default to `Local`; nothing reads them to change behavior yet. |
| This architecture doc | **Implemented** (FEAT-001). |
| Native TCP transport (Winsock) | **Implemented** (FEAT-002). `NetTransport` in `game/src/net/` plus `Coop*` Lua bindings. The Winsock code path compiles only on the Windows/MSVC target (guarded by `#ifdef _WIN32`, linked against `ws2_32`); other platforms get a no-op fallback branch. |
| Length-prefixed framing + message kinds | **Framing implemented** (FEAT-002): 4-byte little-endian length prefix in `NetTransport`, no separate binary kind byte. Message kinds implemented (FEAT-003) in `logic/net/NetProtocol.lua` as an explicit text kind-tag + separator encoding for Hello / Welcome / InputEvent / StateSnapshot / Heartbeat; the kind is the first character of the payload. Section 3 above documents the exact framing. Numeric fields use two formatters: integer ids (`playerId` / `unitId` / version) go through `%.0f` so large engine `ObjectId`s round-trip exactly, while floats (`x` / `y` / `angle` / `health`) use `%.4g`; `Decode` parses both with `tonumber`. |
| Session handshake, send/receive pump | **Implemented** (FEAT-003). `logic/net/NetSession.lua` starts host/client from config, sends `Hello` on connect, and runs `Pump()` each frame (poll then drain/dispatch). The pump is driven off the existing `Events.engine "tick"` bus, which `hooks/EngineHooks.lua` (`EngineHooks.post.draw`) already triggers every frame, so no new per-frame driver was added. **`Hello` / `Welcome` handshake and protocol-version enforcement are now implemented** (`NetSession.RegisterHandshake`): the host answers a received `Hello` with a `Welcome`, and both sides compare the peer's `version` against `NetProtocol.VERSION`. A mismatch sets `versionRejected`, logs via `DebugPrint`, and calls `Close()` so an incompatible peer is rejected instead of silently desyncing. `handshakeComplete` records a confirmed compatible peer. This is pure Lua over the existing transport (no engine internals). |
| Heartbeat + disconnect handling | **Implemented** (FEAT-003 review follow-up). `NetSession.Pump` sends a `Heartbeat` on a fixed tick cadence while connected (`HEARTBEAT_INTERVAL_TICKS`, measured in pump ticks because the Lua layer has no wall-clock source) and detects a mid-session drop by watching `CoopNetIsConnected()` for a connected -> not-connected transition. On a drop it fires `OnPeerDropped` once, which triggers a `PeerDropped` message and calls `Close()` to tear the session down, so the pump no longer runs against a dead transport. Received `Heartbeat` messages need no handler (the `Observable` bus ignores kinds with no listener). The heartbeat timestamp field is currently sent as 0: without a Lua time source there is no round-trip latency estimate yet, which is the remaining stub here. |
| Host-side input injection from network | **Implemented** (FEAT-003). `logic/net/InputSync.lua` + the online branch in `hooks/ControlHooks.lua`: the client forwards local presses as `InputEvent`; the host replays them as player 2 via `HeroContext.RunWithHeroContext`. The client forward-and-return is scoped to **controls that resolve to a hero** (`CoopPlayers.GetHeroByUnit(triggeredById)`, the same resolution the offline path uses), so non-hero controls (menus, UI, system inputs) still fall through to normal local handling and the client can drive its own menus. The offline `OnControlPressed` path is unchanged (guarded by `NetSession.IsOnline()` / `IsClient()`). **Stubbed:** analog movement sampling. `OnControlPressed` only reports a discrete press, so `dx`/`dy` are always 0; continuous analog input needs a per-frame input-poll hook that does not exist in the Lua layer yet. |
| Remote hero/unit mapping + snapshot apply | **Partially implemented** (FEAT-003). `logic/net/HostSync.lua` maps player 2 via `CoopPlayers.GetHero(2)` / `hero.ObjectId`, builds a `StateSnapshot` on the host, and applies health on the client (`hero.Health`, a proven field) after **clamping the wire value** to `>= 0` and to `hero.MaxHealth` when the mod exposes it, so a malformed/zero/overflowing snapshot cannot drive the local display out of range. **Stubbed engine accessors** (isolated in named locals with TODOs, not invented engine symbols): `ReadUnitPosition` reads `GetLocation{Id}` defensively (proven call, unverified return shape) and falls back to 0; `ReadUnitAngle` and `ReadUnitAnimation` return defaults (no proven facing/animation getter in the Lua layer); `ApplyUnitPosition` and `ApplyUnitAnimation` are no-op placeholders (no proven absolute-coordinate teleport or `SetAnimation` call). Only `GetLocation{Id}`, `Teleport{Id,DestinationId}` and the `hero.Health` field are proven present elsewhere in the mod. |
| Host / join menu UI | **Config-driven, no menu widgets** (FEAT-003). Host/join is selected by editing `config.lua` (`Online.Role` / `Online.HostAddress` / `Online.Port`); the session starts from `GamemodeInit` via `NetSession.StartFromConfig()`. `mainmenu/CoopMenu.lua` is left unchanged except for a documentation comment, because adding host/join widgets to the existing controller-selection menu risked breaking the local flow. Interactive host/join menu UI remains **planned**. |

## 7. How a full build validates this

There is no compile/test gate in the Linux development sandbox: the build is
Windows/MSVC-only and the engine-interface submodule is unavailable there, so the
online code is written and reviewed but not compiled here. On a Windows machine
the mod is validated by the documented build:

```powershell
cmake -A x64 . -B build_msvc
cmake --build build_msvc --config Release
```

End-to-end validation then means: build the DLL, install it, run two PCs with
one set to `Online` host and one to `Online` client, confirm the client joins,
both heroes move, and remote state (position, animation, health, death) stays in
sync; with `CoopMode = "Local"` the existing splitscreen path must be unchanged.
