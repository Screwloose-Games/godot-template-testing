# Multiplayer Requirements — Brief

**Owner:** Michael
**Source:** July 31, 2026 design kickoff; local multiplayer decision, August 1, 2026
**Version:** 1.0

---

## 1. Scope of ownership

Michael owns multiplayer implementation. No one else on the team is assigned to it.

**Local multiplayer is to be working first. Network multiplayer follows.**

---

## 2. Multiplayer requirements

| Requirement | Decision |
|---|---|
| Player count target | 2 |
| 3–4 players | Not a design target. Acceptable if it works, acceptable if it doesn't |
| Single-player | Must be a first-class experience, not a degraded mode |
| Local multiplayer | Required. To be working before network multiplayer |
| Network multiplayer | Required. Real-time and synchronous |
| Network authority model | Host-authoritative. Player 1 is the authority |
| Session length | ~5 minutes per run, more if time permits |
| Competitive play | None. PvE co-op only |

### Local input configurations

Both must be supported:

1. Keyboard and mouse + one gamepad
2. Two gamepads

---

## 4. Game systems affecting multiplayer implementation

### Player
- First-person, zero gravity.
- Six degrees of freedom, thruster-based, Newtonian physics.
- Player may / may not collide with other players. This is a design decision to be made later.

### Shared power/oxygen tank
- One unit, shared by all players.
- Physically carried, pushed, or dragged by a player.
- Tether limits player distance from the unit.
- Shared drain across the crew self-balances by player count.
- Players may abandon the tether ("cut the cord").

---

## Multiplayer — Top Things to Think About

### Local multiplayer

1. **Input device routing.** InputMap actions are global by default. Per-player input sources; no direct `Input` reads in gameplay code.
2. **Device assignment.** Which gamepad is which player, and hot-plug.
3. **Join flow.** Press-a-button-to-join, or assign at the menu. Mid-run joining or start-of-run only.
4. **Leave flow.** Drop-out mid-run: what happens to the character, and to the tank if they were carrying it. Does the viewport collapse back to full screen.
5. **6DoF on a gamepad.** Two sticks, four axes, six needed. Roll and vertical thrust have nowhere obvious to go.
6. **Split-screen render cost.** Scene renders once per viewport. Sets the art and lighting budget.
7. **Per-viewport audio listeners.** Otherwise both players hear from one position.
8. **Mouse capture serves one player.** Gamepad look curve needs tuning to match.
9. **Shared speakers.** Both players' audio cues mix together.
10. **No singletons assuming one player.** Any "the player" autoload breaks with two.

---

### Network multiplayer

#### Connection
1. **Transport choice.** `ENetMultiplayerPeer` (UDP, desktop-only, fewest moving parts) vs. `WebRTCMultiplayerPeer` (required for web export, needs supporting infrastructure).
2. **How players find each other.** Direct IP entry, room/lobby codes, or a lobby service. Room codes are the cheap middle ground.
3. **Signaling server.** Required for WebRTC — exchanges SDP offers/answers and ICE candidates before peers connect. Needs hosting, usually WebSocket. Doubles as the room-code broker.
4. **STUN.** Discovers each peer's public address for NAT traversal. Free public servers exist.
5. **TURN.** Relays when direct connection fails, roughly 20–30% of the time. Costs bandwidth. Decide whether to run one or accept the failure rate.
6. **Port forwarding.** ENet direct connections need it unless a relay is in front. Determines whether testers can connect without setup.
7. **Topology.** Peer-to-peer with one peer authoritative. No dedicated server.

#### State
8. **Abstract the input source.** Local device or remote peer should be interchangeable.
9. **Authority as an explicit property.** Host-authoritative, player 1 is peer ID 1.
10. **Terrain syncs operations, not meshes.** Requires deterministic regeneration from identical inputs.
11. **The shared tank changes hands.** Levels, position, carrier, crank state — ownership transfers mid-run.
12. **Physics authority for ore chunks.** Host-owned with interpolation, or assigned on mining.
13. **Noise events must be authoritative.** Client-side firing desyncs creature detection.
14. **No cheating threat model.** Clients can own their own player state. Likely no prediction or reconciliation.
15. **Five-minute sessions.** No host migration, reconnection, or persistence. Decide on late-join.
