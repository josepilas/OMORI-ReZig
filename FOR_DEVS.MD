# Develop OMORI ReZig

ReZig is an engine project with an R36S release target. The Zig runtime lives in `runtime/`. The PortMaster launcher, data preparation tools and bundled dependency notices live at the repo root and under `omori/`.

## Build on Linux or WSL

Use **Zig 0.15.2** and the SDL2 runtime. From the repository root:

```sh
cd runtime
zig build test --summary all
zig build -Doptimize=ReleaseSafe
```

Run `zig-out/bin/omori-native` with `--data-root` pointing to your prepared game tree and separate `--save-root` and `--log-dir` paths. The build guide covers PC preparation, runtime options and cross-compiling the ARM64 binary. [Build guide](docs/BUILDING.md)

## Find the engine code

| Area | Start here |
| --- | --- |
| Maps, events, battles and saves | `runtime/src/mv/` |
| Rendering and texture upload | `runtime/src/renderer/` |
| Input and platform bindings | `runtime/src/input/` and `runtime/src/platform/` |
| Audio and supplied game data | `runtime/src/audio/`, `runtime/src/assets/` and `runtime/src/filesystem/` |

The Linux SDL2 backend is the development reference. A future console port, such as PS3, needs its own graphics, input, audio and storage adapters. [Architecture](docs/ARCHITECTURE.md) · [Porting guide](docs/PORTING.md)

## Verify a change

Start with the synthetic fixture for engine logic. Use private, player-supplied data for map, sprite, dialogue and save regressions. The verification guide explains what desktop SDL, ARM64 emulation and a physical R36S each establish. [Verification](docs/VERIFICATION.md) · [Compatibility](docs/COMPATIBILITY.md) · [0.0.1 engine test results](docs/VALIDATION-v42.md)

ReZig compares behaviors with the supplied RPG Maker runtime and the pinned C++ console reference. The comparison documents which systems have been implemented in Zig and where gaps remain. [Reference comparison](docs/REFERENCE-COMPARISON.md)

## Contribute

Reproduce the issue on a repeatable route, keep captured game data and saves private, and include the smallest regression that demonstrates the fix. [Contribution guide](docs/CONTRIBUTING.md) · [Documentation index](docs/README.md) · [Third-party notices](docs/THIRD_PARTY.md)
