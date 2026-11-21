# Build and run OMORI ReZig

Use **Zig 0.15.2** on Linux or WSL. Install the SDL2 runtime for windowed execution. The engine resolves SDL2 at runtime and needs no SDL development headers. The synthetic fixture generator uses Python 3, Pillow with WebP support and a TrueType font such as DejaVu Sans. [Zig downloads](https://ziglang.org/download/)

## Build and run on Linux

From the repository root:

~~~sh
cd runtime
zig build -Doptimize=ReleaseSafe
./zig-out/bin/omori-native --data-root "$GAME_ROOT" \
  --save-root "$SAVE_ROOT" --log-dir "$LOG_ROOT"
~~~

Set `GAME_ROOT` to a prepared game tree containing `data/`, `img/`, `audio/` and `fonts/`. Use separate, writable paths for `SAVE_ROOT` and `LOG_ROOT`. See the verification guide for unit tests, synthetic startup and controller walkthroughs. [Verification](VERIFICATION.md)

## Prepare player-supplied data

The PortMaster launcher guides Android extraction and PC preparation. The Android game tree comes from the APK's `assets/www/`. For PC, run the preparation tool from the repository root with your local installation directory and an output path. Python 3 and OpenSSL are required for preparation.

~~~sh
python3 omori/bin/prepare_pc.py "$PC_INSTALLATION" "$PREPARED_DIR"
~~~

Point the engine at the prepared `assets/www/` directory. The launcher uses the same prepared layout for both providers. [R36S player guide](../R36S.MD#install-and-prepare-the-game)

## Build for R36S

R36S uses dynamic ARM64 Linux. Build an AArch64 glibc executable in a separate prefix to keep the desktop binary and release binary apart. Retain debug symbols for crash diagnostics.

~~~sh
cd runtime
arm_build="$(mktemp -d)"
zig build -Dtarget=aarch64-linux-gnu.2.31 -Doptimize=ReleaseSafe \
  --prefix "$arm_build"
ARM64_BINARY="$arm_build/bin/omori-native"
file "$ARM64_BINARY"
readelf -l "$ARM64_BINARY" | grep interpreter
~~~

The ELF interpreter should be `/lib/ld-linux-aarch64.so.1`. This target supports opening the system SDL2 library or the PortMaster package's `omori/libs/libSDL2-2.0.so.0` fallback. The measured kernel baseline is discussed in the architecture guide. [Architecture](ARCHITECTURE.md#platform-boundaries)

## Runtime options

| Argument | Purpose |
| --- | --- |
| `--data-root DIR` | Prepared game tree |
| `--save-root DIR` | Persistent save directory |
| `--log-dir DIR` | Detailed and simple logs, plus boot state |
| `--image-cache-mib N` | Asset manager's estimated decoded-image budget, 48 MiB by default |
| `--headless` | Run the scripted synthetic validation |
| `--frames N` | Exit after a bounded number of frames |
| `--selftest-input` | SDL input dispatch probe, which needs no game data |
| `--verbose` | Debug-level logging |
| `--help` | List command-line options |

A normal launch needs a usable display and exits with status 3 if display initialization fails. Request non-windowed validation with `--headless` or `OMORI_HEADLESS=1`. Deliberate crash arguments are listed in the diagnostics guide. [Diagnostics](LOGGING.md)

Engine diagnostics accept `OMORI_SWAP_AB=0/1` for GO-Super face-button mapping and `OMORI_DEBUG_TEXT=1` for title text rectangles. The debug battle hook accepts `OMORI_DEBUG_TROOP=<id>` with a valid, populated troop. Texture lifetime diagnosis can compare the current cleanup to the old transition policy using `OMORI_FLUSH_DESTROY=0`.

## Package source and R36S builds

Create the source ZIP from the repository root. Set `VERSION` to the release version, such as `0.0.1`.

~~~sh
python3 tools/package_source.py "../OMORI-ReZig-${VERSION}-source.zip"
~~~

The source archive contains the Zig runtime, tools, synthetic fixtures, docs and licenses. It can regenerate itself after extraction. The R36S install archive carries `OMORI.sh` and `omori/` at its root, including the ARM64 binary, SDL2 fallback, launcher assets and empty game data, save and log directories. Keep both artifacts together for the same release version.

Run the package preflight against the staging tree that contains the ARM64 executable and the finished archive. Use Linux or WSL to test kernel shebang execution and shell syntax as well as ELF identity and Unix execute modes.

~~~sh
python3 tools/analysis/check_release.py --project "$STAGING_ROOT" \
  --archive "$R36S_ZIP"
python3 -m unittest discover -s tools/analysis -p test_check_release.py
python3 -m unittest discover -s tools/tests
~~~

Use UTF-8 shell files with LF endings and an executable mode. Confirm the source and install archives contain only the intended files before release.

## Direct Zig commands

Prefer `zig build` for dependency wiring. A direct `zig test` or `zig build-exe` against runtime modules may need `src/audio/audio_decode.c`, `src/audio/stb_vorbis.c`, `src/codec/jpeg.c` and `-lc`. [Dependency notices](THIRD_PARTY.md)
