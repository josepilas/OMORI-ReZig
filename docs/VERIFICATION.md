# Verify changes to OMORI ReZig

Choose the smallest check that can expose the difference. Record the runtime version or revision, data provider, platform, command and result. Use private directories for game data, saves, logs and captures.

| Environment | Useful evidence | Coverage it adds |
| --- | --- | --- |
| Native Linux or WSL, synthetic data | Unit results and a deterministic boot, battle, Save and Continue | Engine logic and startup without external game data |
| Native Linux, player-supplied game data | Catalog counts, controller playback, SDL pixel reads and fresh-process loads | Actual map and plugin inputs, opening behavior and render output |
| ARM64 user-mode QEMU | Target executable startup and the synthetic route | Target ABI and cross-build behavior under an emulator |
| Physical R36S | Launcher and runtime logs, control and audio checks, and observed gameplay | Firmware, kernel, graphics, physical controller and SD card behavior |

Catalog checks measure map and troop initialization. A story route verifies the events it exercises. Reproducing an R36S failure requires the affected firmware and hardware where possible. [Release reports](README.md#release-evidence)

## Bundled fixtures

From the project root, build and test the runtime. The synthetic generator writes to an empty scratch location.

```sh
scratch="$(mktemp -d)"
bash tools/analysis/make_synth_tree.sh "$scratch/game"
cd runtime
zig build test --summary all
sh scripts/run_headless.sh "$scratch/game" "$scratch/logs"
```

The headless script asserts the simulation completed the synthetic title, movement, battle and save chain. Use the real-input walkthrough for a player-supplied game tree. The two paths use different progression data.

For native SDL input dispatch, run the main executable with `--selftest-input`. On a host without a graphical session, use SDL's dummy drivers.

```sh
SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
  ./zig-out/bin/omori-native --selftest-input --log-dir "$scratch/input"
```

## Player-supplied fixture checks

Set `GAME_ROOT` to a prepared PC or Android tree and `PRIVATE_EVIDENCE` to a writable directory outside the checkout. Run these commands from `runtime/`. Keep evidence for each provider and each run in a separate directory.

```sh
OMORI_AUDIO_SMOKE_ROOT="$GAME_ROOT" OMORI_BATTLE_SMOKE_ROOT="$GAME_ROOT" \
  OMORI_FONT_SMOKE_PATH="$GAME_ROOT/fonts/OMORI_GAME2.ttf" \
  zig build test --summary all
zig build catalog-smoke -- "$GAME_ROOT"
zig build collision-smoke -- "$GAME_ROOT"
zig build opening-smoke -- "$GAME_ROOT" "$PRIVATE_EVIDENCE/opening" --journal-smoke --neighbors-to-stump
```

The real opening replay checks actual interactions, choices and transitions through Save and Continue. `--neighbors-to-stump` extends the route through recruitment and the stairs. `--battle-smoke` also reaches a diagnostic troop-34 battle via L1+R1 and verifies party action selection, targeting, victory and return to the field. That marker exercises the battle interface rather than a story-triggered encounter.

For sprite or rendering changes, the render harness reads back SDL pixels and the field harness checks draw and cache stability on Map087.

```sh
zig build render-smoke -- "$GAME_ROOT/fonts/OMORI_GAME2.ttf" \
  "$PRIVATE_EVIDENCE/title.ppm" "$GAME_ROOT/img/atlases/Omori_TitleScreen.png" \
  "$GAME_ROOT/img/characters/DW_OMORI.png"
zig build field-render-smoke -- "$GAME_ROOT" "$PRIVATE_EVIDENCE/field.ppm"
```

For a save regression, use a private copy and substitute the known slot, map and player coordinates. The harness launches a new process, verifies the restored player position and checks movement and menu input. Add `--expect-backup` after the coordinates for a private corrupt-primary and valid-backup fixture.

```sh
zig build restart-smoke -- "$GAME_ROOT" "$PRIVATE_SAVE_COPY" "$PRIVATE_EVIDENCE/restart" 1 87 28 22
```

For Options, use a new private preferences directory and run the three modes in order. The harness saves changes, checks them in a fresh process, restores defaults and checks those on a third launch.

```sh
zig build options-smoke -- "$GAME_ROOT" "$PRIVATE_OPTIONS_SAVE_DIR" "$PRIVATE_EVIDENCE/edit" edit
zig build options-smoke -- "$GAME_ROOT" "$PRIVATE_OPTIONS_SAVE_DIR" "$PRIVATE_EVIDENCE/reload" reload
zig build options-smoke -- "$GAME_ROOT" "$PRIVATE_OPTIONS_SAVE_DIR" "$PRIVATE_EVIDENCE/defaults" defaults
```

## ARM64 and R36S

Build the [ARM64 artifact](BUILDING.md#build-for-r36s) before running the same synthetic tree in user-mode QEMU. Set `ARM64_SYSROOT` to a compatible ARM64 Linux sysroot and `ARM64_BINARY` to the cross-built executable.

```sh
qemu-aarch64 -L "$ARM64_SYSROOT" "$ARM64_BINARY" \
  --data-root "$scratch/game" --save-root "$scratch/arm-saves" \
  --log-dir "$scratch/arm-logs" --headless
```

Check the exit status, the `scripted shell: VERIFIED` and `headless validation complete` markers, and any errors in the log. Use the matching Linux binary for SDL input dispatch tests.

Physical-device verification starts with the intended installation package. Record the firmware and launch through PortMaster. Confirm that the title and Options frames are readable, audio plays, and the handheld's physical controls perform the actions in the player guide. Exercise White Space, the journal, the door and a fresh Continue. For a field or battle change, repeat the affected portion of the opening with the real controller. Verify Start + Select on exit. Inspect the matching run in [the log files](LOGGING.md).

Packaging and archive preflight commands live in the [build guide](BUILDING.md#package-source-and-r36s-builds).
