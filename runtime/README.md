# OMORI ReZig runtime

The gameplay and presentation code is written in Zig. C libraries supply Vorbis, MP3, WAV and JPEG decoding. The desktop and R36S builds use SDL2 for presentation, sound output and input. Assets come from a player-supplied game tree.

Build and run the native executable from this directory using Zig 0.15.2.

```sh
zig build -Doptimize=ReleaseSafe
./zig-out/bin/omori-native --data-root "$GAME_ROOT" --save-root "$SAVE_ROOT" --log-dir "$LOG_ROOT"
zig build test --summary all
```

For a new target, start with the headless simulation and then connect the display, controller and audio backend. The porting guide identifies the Linux-specific parts. [Build and validation commands](../docs/BUILDING.md) · [Platform porting guide](../docs/PORTING.md) · [Architecture](../docs/ARCHITECTURE.md)
