# Port OMORI ReZig to another platform

The Linux desktop build provides a reference for gameplay at a logical resolution of 640 × 480 and a simulation rate of 60 updates per second. R36S installation and packaging live outside the simulation. A console such as the PS3 needs its own platform integration, SDK or toolchain and package. PS3 is a proposed target.

| Responsibility | Start here | Work for a new target |
| --- | --- | --- |
| Rules and game data | `runtime/src/mv/`, `data/`, `omori/` and `assets/` | Reuse the map parser, event state, battle logic and loaders. Provide the same prepared game paths to the VFS. |
| Files and saves | `runtime/src/filesystem/vfs.zig`, `core/fs_compat.zig`, `mv/save.zig` | Map the read-only game tree and writable save directory to the target filesystem. Preserve atomic save replacement and backup recovery. |
| Rendering | `runtime/src/renderer/draw.zig`, `renderer/renderer.zig`, `platform/sdl2.zig` | Implement texture upload, blending, text runs and presentation. Honor draw order, logical scaling and the lifetimes of borrowed pixel buffers. |
| Controls and timing | `runtime/src/input/input.zig`, `core/frame_clock.zig`, `mv/game_loop.zig` | Feed button and axis transitions into the logical input state. Advance a single simulation tick per scheduled frame and advance the previous input state once per tick. |
| Audio | `runtime/src/audio/mixer.zig`, `audio/audio_decode.c` | Connect the software mixer to a device queue. Verify the negotiated sample format, channel count, buffer duration and endianness. |
| Boot and diagnostics | `runtime/src/main.zig`, `platform/dyn.zig`, `core/crash.zig`, `core/log.zig`, `memory/budget.zig` | Supply an entry point, clock, paths and logging. The Linux build dynamically loads SDL and uses POSIX signals and Linux memory diagnostics. |

The SDL backend is part of the current renderer implementation. Bring up data loading and save round trips first, then render a synthetic frame and check controller transitions. On a big-endian target, compare a decoded RGBA pixel, stereo PCM sample pair and save-file round trip with the Linux output before running the opening. The headless driver and render checks provide repeatable inputs. [Build and test commands](BUILDING.md)

Finally, run the opening on the target through the journal, door, friends' room, recruitment and a cold Continue. Measure frame time, memory and audio on the device. Distribute the hardware package alongside its matching source and dependency notices. [R36S installation example](../R36S.MD) · [Third-party notices](THIRD_PARTY.md)
