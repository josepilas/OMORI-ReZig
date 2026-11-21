# Compatibility and reference behavior

OMORI ReZig is a native Zig runtime for player-supplied game data. PC preparation and Android extraction produce a game tree read by the same engine. Linux SDL2 is the development backend. R36S uses an ARM64 Linux build and a PortMaster launcher.

| Area | Established coverage | Remaining questions |
| --- | --- | --- |
| Data and startup | The v41 catalog run loaded 517 supplied maps and initialized 337 populated troops with each tested provider. Both catalogs include Map513 without a corresponding map file. | Later maps can load while their event scripts still need work. Unchecked game variants need their own evidence. |
| Field and dialogue | The v41 controller replays covered the journal, White Space, the door, friends' room, recruitment and the transfer to Map089. Followers keep independent motion and retire authored NPC copies on recruitment. | Complex move routes, broader script commands and later scenes need targeted tests. |
| Battle | The diagnostic battle covered command selection, targeting, revisiting a choice and returning to the field. | Verify later fight mechanics, game-specific actions, menus and presentation independently. |
| Saves | Cold-start Continue was exercised with native, legacy and backup fixtures. | Check cross-version and cross-provider loads with private copies of the relevant saves. |
| Platform | Linux software rendering and ARM64 user-mode emulation have separate checks. The release report records physical device results when available. | A new console target needs platform bindings and measurements on that hardware. |

The v41 report gives tested routes, inputs and limits. Use the verification matrix to select the next check for a specific symptom. [Release evidence](VALIDATION-v41.md) · [Verification](VERIFICATION.md)

The v42 report covers authored camera and reaction cues and the fallback encounter lifecycle for MV maps. [v42 release evidence](VALIDATION-v42.md)

## Comparing a behavior

Pin the reference revision in the issue or change notes. The current comparison uses C++ commit `bec8f898dfa95239d7eed7f98e0968d1742faf48`. Follow the original game data to the command or condition that triggers the behavior. Compare the observable state change, timing and output with ReZig. A focused Zig regression with a small synthetic fixture can express the result independent of a game's content.

| Behavior | ReZig entry point | Pinned console reference |
| --- | --- | --- |
| Event commands and wait modes | `runtime/src/mv/interpreter.zig` | [Interpreter](https://github.com/meetox80/omori/blob/bec8f898dfa95239d7eed7f98e0968d1742faf48/engine/src/rpg/interpreter.cpp) |
| Map setup, movement and encounters | `runtime/src/mv/game.zig`, `runtime/src/mv/game_loop.zig` | [Map](https://github.com/meetox80/omori/blob/bec8f898dfa95239d7eed7f98e0968d1742faf48/engine/src/rpg/map.cpp) · [Player](https://github.com/meetox80/omori/blob/bec8f898dfa95239d7eed7f98e0968d1742faf48/engine/src/rpg/player.cpp) |
| Dialogue and choices | `runtime/src/mv/dialogue.zig`, `runtime/src/mv/window.zig` | [Message scene](https://github.com/meetox80/omori/blob/bec8f898dfa95239d7eed7f98e0968d1742faf48/engine/src/omori/message.cpp) |
| Battle commands and scene transitions | `runtime/src/mv/battle.zig`, `runtime/src/mv/game_loop.zig` | [Battle scene](https://github.com/meetox80/omori/blob/bec8f898dfa95239d7eed7f98e0968d1742faf48/engine/src/omori/battle_scene.cpp) |
| Map and picture presentation | `runtime/src/mv/map_render.zig`, `runtime/src/mv/field_effects.zig` | [Map scene](https://github.com/meetox80/omori/blob/bec8f898dfa95239d7eed7f98e0968d1742faf48/engine/src/omori/scene_map.cpp) · [Spritesets](https://github.com/meetox80/omori/blob/bec8f898dfa95239d7eed7f98e0968d1742faf48/engine/src/omori/spriteset.cpp) |

Keep player-supplied assets private and use independently written tests and code. Project ownership, the original MV notices and the reference license are documented separately. [Third-party notices](THIRD_PARTY.md) · [Reference license](https://github.com/meetox80/omori/blob/bec8f898dfa95239d7eed7f98e0968d1742faf48/LICENSE)
