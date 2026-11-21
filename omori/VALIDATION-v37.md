# v37 validation — 2026-11-19

v37 addresses the device report of fast movement, the moving debug square,
the laptop journal trapping input, controller/quit handling, animation timing
and the requested R36S credit. The supplied APK data remains external to
the distributable project.

## Verification status

| Check | Result |
|---|---|
| Journal button conditions and scheduler | 4 focused tests pass: held/queued logical buttons, escape alias, actual common-event child return, and independent parallel children |
| Actual laptop journal and opening | SDL software/dummy run passes: credit screen/back, journal opened three times and closed with A, B and Start/Escape, LOG OFF, four objects, knife/door, next room, SAVE/QUIT/CONTINUE |
| Final journal run measurements | 6,284 presented frames, exit 0, 129.25 s on the host with the harness delay stub and concurrent builds; maximum RSS 124,408 KiB, sampled end 102 MiB, sampled peak 108 MiB; 6,348 exact door pixels; no GPA/FATAL/crash report |
| Credit readback | Actual 640×480 SDL readback shows `R36S PORT BY José Pilas`, including the accented `é`; B returns to title |
| Timing and animation | 15 focused tests pass, plus supplied title/sprite/font SDL rendering and visual inspection |
| Controller and event-path checks | 21 focused checks and 66/66 real SDL event-path selfchecks pass, including raw/controller/keyboard/hat/axis, queued taps, hotplug, quit and tag cases |
| Final combined source unit suite | 179/179 passed, no skips, with actual audio and battle fixtures enabled |
| Final native/ARM64 builds and packaged-binary checks | ReleaseSafe builds pass; ARM64 target aarch64-linux-gnu.2.31, 11,743,000-byte executable; highest GLIBC requirement 2.29. Native and QEMU ARM64 1,378-frame title/new-game/walk/battle/save/continue checks pass |
| Installation of v37 | Installed to E:/ports; 60 runtime/metadata files verified, 5,157 payload files preserved, seven critical payload files checked; saves and device logs unchanged |
| Physical R36S execution of v37 | Not yet established |

The final journal walkthrough above ran after tag-selector and control
integration froze. Its private delay stub proves event/render/input behavior,
not real-time handheld performance; its host elapsed time is not a handheld
speed benchmark. Physical compatibility cannot be established from SDL's
dummy/software backend or emulation alone.

## Laptop journal

The supplied Map 87 laptop event draws `ws_laptop_journal`, then calls
Common Event 1, **Wait for Input**. That event loops over command 111 button
conditions for `ok` and `cancel`. The original journal is a static picture:
there is no authored list-selection or scrolling scene in this interaction.
Confirm or cancel closes it and returns to the three laptop options.

The previous interpreter returned false for every button condition. The
common event therefore never finished, regardless of controller input.
Command 111 now reads the logical held-input snapshot. The field scheduler
passes it to the main interpreter, common-event children and independent
parallel chains. Queued same-pump press edges survive the snapshot; escape
also satisfies cancel, matching the supplied `Input.isPressed` behavior.

An actual-data census found these button predicates: `ok` 145, `cancel` 138,
`up` 41, `left` 40, `right` 40, `down` 39 and `shift` 1. Those names are
covered, along with the native menu/escape/page-up/page-down actions.

The `--journal-smoke` developer route selects JOURNAL through the actual
laptop choice window, waits with no input, closes it through A, B and
Start/Escape in separate visits, then selects LOG OFF. It continues through
the full opening and checks saved/restored equipped SHINY KNIFE, its +5 ATK,
SAD POEM 26, object count, door state and map position. It injects controller
buttons, never inventory, coordinates, switches or transfer destinations.

Readback happens before `SDL_RenderPresent`, using a harness-only wrapper.
The inspected private evidence includes `journal-confirm.png`,
`journal-cancel.png`, `journal-escape.png`, `journal-menu-restored.png` and
`credits-jose-pilas.png` under `work/v37/journal/`. Final copies with
`-final.png` suffixes avoid stale image-viewer caching. The restored laptop
capture shows STARE AT THE SCREEN, OPEN YOUR JOURNAL and LOG OFF.

## Movement and animation timing

The supplied device log progressed near 60 updates per second (about
58.67 in the reviewed interval). The principal movement discrepancy was
the native always-run default, which forced dash. It now defaults off,
matching the supplied ConfigManager. The dash button inverts the preference,
respects the map's disable-dashing flag and latches speed for the tile step.
On 32-pixel Tiled maps, walking uses 0.09375 tiles/update; dash uses 0.1875.

The old fixed 16 ms frame period could run at 62.5 Hz. Pacing now cycles
16/17/17 ms for 60 updates per 1000 ms under budget. Late frames reset the
deadline instead of creating a catch-up burst; SDL tick wrap is tested.

Character animation advances during field updates instead of every fourth
draw. The native path uses the supplied moving/standing animation counters,
the `(9 - realMoveSpeed) * 3` wait, and the four-step pose order. Walking
advances a pose every ten updates and dashing every eight. Idle return,
stationary step animation, page/map reset and extra draws are covered.

Tiled animation already matched YED_Tiled's duration/60 Hz calculation;
the existing 200 ms boundary checks pass. Title animation now includes the
authored bulb-line strip with `[0,1,2,1]` frames at sixteen updates each.
OMORI's twenty-one-update pose timing is preserved. The supplied title atlas,
font and character sheet were rendered through SDL2 and visually inspected.

General event movement routes, custom ExtraMovementFrames sheets and all
later-game animation sequences are not established by these checks.

## Overlay, credit and controls

The visual moving liveness/progress square was removed from presentation.
The renderer's logging heartbeat and present watchdog remain available for
diagnosis without drawing over the game.

The PORTED BY screen credits **José Pilas** for the R36S port. The supplied
OMORI font has no `é`, so that credit uses the supplied Noto Sans font;
the rendered accent was checked in the actual SDL screenshot.

The reviewed GO-Super/R36S raw Select/Start pair is 12/13. Quit behavior now
targets the actual pair rather than assuming a generic 8/9 pair or requiring
a frame-count hold. The event pump drains the complete SDL batch while
latching an exit request, so queued release events are not abandoned.
The controller/keyboard/hat/axis, hotplug, same-pump tap, nonoverlapping
quit-button presses and simultaneous quit cases pass the 66-check SDL test.

The supplied Omori BASE default mapper uses keyboard A and gamepad Y for
tag, with shoulders reserved for page-up/page-down. The native selector
updates leader/order, the authored leader variable 20 and follower state.
The original Common Event 11 transition animation remains unimplemented;
functional tagging does not establish complete tag-animation parity.
These checks do not claim 100% compatibility with arbitrary controllers or
a physical v37 handheld test.

## Repeat the checks

Use Zig 0.15.2 under Linux/WSL and an available SDL2. `GAME_ROOT` is the
user-supplied extracted root containing `data/`, `img/`, `audio/` and `fonts/`.
Keep proprietary data, logs, readbacks and generated test saves outside the
source/install packages.

```bash
cd runtime
OMORI_AUDIO_SMOKE_ROOT="$GAME_ROOT" OMORI_BATTLE_SMOKE_ROOT="$GAME_ROOT" \
    SDL_AUDIODRIVER=dummy zig build test --summary all
zig build opening-smoke -Doptimize=ReleaseSafe -- \
    "$GAME_ROOT" "$PRIVATE_EVIDENCE" --journal-smoke
```

Focused evidence is recorded in `work/v37/journal-tests.log`,
`journal-run.log`, `timing-tests.log`, `timing-validation.md`,
`title-render-smoke.log` and `gamepad-tests.log`. The final release manifest
must identify the exact binaries, archives and install verification once
those steps complete. Complete-game/plugin parity remains a separate scope.

## Final release checks

Native SDL startup/shutdown passes 240 title frames. The final native
executable passes the expanded input selftest, including virtual raw and
mapped devices. The final ARM64 binary passes the synthetic integration
chain under QEMU with no GPA, FATAL or crash report.

The native wall-clock check measured 3.8051 seconds for one title frame
and 5.7737 seconds for 121 title frames, including startup: the additional
120 frames take 1.9686 seconds. Startup variance makes this a coarse check;
the rational frame-clock regressions verify the exact 60/1000 ms schedule.

An extra ARM64 windowed SDL selftest could not run in the emulation sysroot
because libXinerama.so.1 is unavailable there. This is not counted as a
pass. All 44 directly-required SDL symbols checked in the loader are
exported by the bundled ARM64 SDL. Native SDL event checks and ARM64
headless tests pass separately; physical v37 handheld execution is pending.

Release runtime SHA256:
`4ffd74d20bab0d0e425c60550f4d55ef635eefb8ce949129128bd9f3040106a0`.

Archive checksums are written to outputs/SHA256SUMS-v37.txt. The private
installation manifest records unchanged saves, logs and game-data layout.

## Installed artifacts

The SD-card runtime matches the release SHA256 above. The updater backed
up changed v36 files, atomically replaced the runtime, updated the Ports
menu description and preserved existing game data, saves and device logs.
`omori/install-v37.json` records the verification. No generated test saves
were copied to the card. Physical execution of v37 remains unverified.

The data-free install ZIP is 3,812,486 bytes, SHA256
`8738a90afc5d0f39f764f99dc7b75acb62ca3edb59c803f558159fe584ffd0af`.
The full project archive checksum is in `outputs/SHA256SUMS-v37.txt`.
