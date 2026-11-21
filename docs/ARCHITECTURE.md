# OMORI ReZig architecture

OMORI ReZig executes the behavior of a prepared OMORI game tree in Zig. The preparation tools create a shared input layout from player-supplied Android or PC files. The runtime reads that tree through the VFS and writes saves and logs to separate roots.

~~~text
Android APK or PC installation
  -> preparation and extraction
  -> game tree and explicit writable save/log roots
  -> VFS, database, language and image loading
  -> scenes, game objects, map and battle simulation
  -> logical input, draw commands and audio playback
  -> native Linux SDL2 backend
~~~

## Find a subsystem

All paths in the table are relative to `runtime/src/`.

| Area | Entry points | Ownership or behavior |
| --- | --- | --- |
| Process lifecycle | `main.zig`, `core/log.zig`, `core/crash.zig` | Logging starts before game initialization. The executable loads data, wires devices and drives either the interactive engine or the explicit synthetic validation path. |
| Storage and paths | `filesystem/vfs.zig`, `filesystem/path.zig`, `core/fs_compat.zig`, `omori/paths.zig` | Enforces distinct data and save routes. Resolves Android virtual directory markers, case variants and special-symbol filenames. |
| Data and language | `data/json.zig`, `data/database.zig`, `omori/language.zig`, `omori/text.zig` | Parses a prepared database and language messages, retaining data whose lifetime spans maps. |
| Scenes and field | `mv/scenes.zig`, `mv/game_loop.zig`, `mv/data_manager.zig`, `mv/game.zig`, `mv/interpreter.zig` | Owns scene changes, runtime game state, event command scheduling, waits, map transfer and input routing. |
| Map and dialogue | `mv/map.zig`, `mv/tiled.zig`, `mv/map_render.zig`, `mv/event_routes.zig`, `mv/dialogue.zig`, `mv/window.zig` | Decodes map data, selects active pages, evaluates collision and layers, and builds field and dialogue draws. |
| Battle | `mv/battle.zig`, `mv/game_loop.zig` | Initializes troops, handles actor choices and resolves actions and outcomes. The game loop links event-driven battles to field execution. |
| Saves and preferences | `mv/save.zig`, `mv/config.zig` | Saves game state with LZString and JsonEx-compatible fields, validates loads and backs up known-good saves. Preferences have a distinct file. |
| Images and draw commands | `assets/atlas.zig`, `assets/manager.zig`, `mv/sprites.zig`, `codec/`, `text/font.zig`, `renderer/draw.zig` | Resolves native formats and sheets, rasterizes glyphs, and supplies frame-scoped draw commands on a 640 × 480 logical canvas. |
| Platform output and input | `renderer/renderer.zig`, `platform/sdl2.zig`, `platform/dyn.zig`, `input/input.zig`, `core/frame_clock.zig` | Resolves SDL2, owns texture uploads and presentation, and maps controller inputs into logical actions. |
| Audio and memory | `audio/audio.zig`, `audio/mixer.zig`, `memory/budget.zig` | Mixes background music, ambience and effects, tracks voice lifetime, and reports memory and asset budgets. |

## Platform boundaries

The simulation runs at 60 ticks per second. The current Linux renderer discovers SDL2 with dynamic loading and binds its exported functions in a table. The backend seam is in the source. A new platform still needs compatible file, clock, input, graphics, audio and diagnostic bindings. [Porting guide](PORTING.md)

The R36S vendor kernel tested in early device work was Linux 4.4.189. Zig's newer filesystem APIs can issue syscalls unavailable there, including `statx`. Device-side data and directory helpers use `core/fs_compat.zig` for the compatible stat, read and mkdir paths. Audit new calls against the actual target kernel. QEMU user-mode runs can help trace calls and the physical device establishes their behavior on its firmware.

The boot and input paths share the same game state in windowed use and headless validation. The draw-list validator replaces presentation in the explicit synthetic mode. Coverage and its limits are tracked in the release results. [Verification](VERIFICATION.md) · [Release evidence](README.md#release-evidence)

## Ownership and persistence

The asset manager budgets estimated decoded RGBA bytes from image headers and evicts unpinned resources. The decoded sprite cache separately targets 24 MiB. A frame may temporarily use more memory while pixels are pinned for queued draws. The draw list owns surface metadata for the frame, and draw buffers retain decoded pixels until the renderer finishes. Decoded eviction invalidates matching GPU textures. The active renderer's SDL table owns cleanup across scene changes.

State held across maps belongs to game objects, the database or retained save storage. Use a scratch arena for transient parsing and keep long-lived strings in owned storage. Use a prepared tree for asset reads and the configured save root for writes. Keep the save replacement atomic and retain a known-good backup. Cold start, same-process Continue and backup recovery are separate regression paths. [Verification](VERIFICATION.md#player-supplied-fixture-checks)

## Behavioral references

The field interpreter implements specific commands and script patterns used by the game. Map catalog runs exercise setup, while an input replay advances authored event state through a route. The behavioral specification records observations from earlier project work. The compatibility guide connects current areas of the engine to a pinned console reference. [Behavioral specification](BEHAVIORAL_SPEC.md) · [Compatibility](COMPATIBILITY.md)
