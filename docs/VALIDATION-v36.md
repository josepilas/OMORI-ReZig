# v36 validation — 2026-11-19

This release continues the native runtime against the supplied Android
payload. The development target is a playable opening. Proprietary APK,
extracted game files and test saves remain external to the release.
The extraction pipeline is unchanged.

The final frozen source passes the combined actual-input opening,
recruitment and diagnostic-battle walkthrough. The release binaries also
pass the host/ARM64 synthetic checks described below. These results do not
establish complete-game or physical R36S compatibility.

## Current results

| Check | Result |
|---|---|
| Unit suite, Zig 0.15.2, Linux x86_64 Debug | 163/163 passed, no skips, real-data audio/battle enabled |
| Final native and ARM64 builds | ReleaseSafe succeeds; ARM64 target `aarch64-linux-gnu.2.31`, 11,647,120-byte binary, highest required GLIBC version 2.29 |
| Final native/ARM64 synthetic integration | Both pass the 1,378-frame title/new-game/walk/battle/save/continue chain; ARM64 runs under QEMU |
| Final native SDL lifecycle/input | 240 title frames exit cleanly; input selftest passes controller, joystick, hat, axis, keyboard and quit dispatch |
| Input-driven actual opening | Pass, exit 0: NEW GAME → Map 999 → White Space → four objects → knife → OPEN door → Map 88 TV dialogue → SAVE → QUIT → CONTINUE |
| Restored opening state | Checkpoint at frame 5,228: Map 88 at (20,22), equipped SHINY KNIFE/+5 ATK, SAD POEM 26, object count 4 and door/knife-page switches |
| Door pixels | 6,348 exact source/readback pixels |
| Natural neighboring-room extension | Pass: watermelon/STUFFED TOY → Aubrey quest → Hero YES → four party members → stairs → Map 89 initializer; 89 actual walking steps |
| Combined actual route + diagnostic battle | Pass: opening/save/continue, recruitment/stairs, then explicit diagnostic troop 34 via L1+R1; SKILL SAD POEM list/target/cancel, empty ITEM list, ATTACK → victory → field |
| Combined memory/time | 7,520 presented frames, exit 0; sampled RSS 108 MiB, process max RSS 120,868 KiB (118.0 MiB); 20.21 s with harness frame delay disabled |
| Actual field renderer, SDL software backend | 720 frames at 436 draw operations/frame; 5 initial texture uploads and 5 cached sheets |
| Field memory after warm-up | RSS 61,204 → 61,468 KiB: +264 KiB over 720 frames |
| Decoded-cache eviction | 6 forced evictions/reloads produce exactly the original pixels; GPU uploads are invalidated before decoded storage is reused |
| Actual title/font/sprite geometry | 640×480 canvas; single 306×350 title pose; standard character sheet uses 12×8 grid of 32×32 frames |
| Actual font rasterization | OMORI_GAME2 E/G/g/y at 24/32/48 px preserve ink and alpha without clipping |
| Equipment/early skill | 5 focused tests pass, including actual Map 87 command 319: SHINY KNIFE equipped, ATK 5→10, inventory copy consumed; SAD POEM 26 enabled and equipped-knife condition true |
| Dialogue portraits/item-get | Focused tests and actual captures pass: checked 106 px/four-column face cells, late Hero index 40, correct STUFFED TOY pickup text; stacked CANDY/armor cases unit-covered |
| Skill-list filtering/event gain adapters | Focused tests and final route pass: SKILL shows SAD POEM, hides internal type-0/Hide In Menu entries; commands 127/128 update gained-item naming |
| Save memory ownership | 3 focused tests pass; 32 save/load cycles under the strict testing allocator, including retained strings and partial loads |
| Audio | 5 focused tests pass, including supplied BGS and one-shot ME through SDL dummy output |
| Authored enemy AI/effects | 9 focused battle tests pass, including supplied Forest Bunny rules and BE CUTE state stages |
| Event battle UI bridge | Focused regression passes victory, escape and defeat branches, including child-interpreter ownership and authored escape/loss rules |
| Battle SKILL/ITEM UI | 9 focused tests pass: learned/affordable skills, owned usable items, targeting/cancel, cost/effect, single consumption, revival and supported enemy-or-ally selection |
| Battle text/name ownership | 3 focused tests pass; generated messages and repeated enemy display names are released |
| R36S display, speaker and controller | Not yet verified for this release |

The field-render check prepares Map 87 directly. It measures stable draw
counts, cache reuse, memory and pixel identity. The separate opening check
reaches it through the real game loop using movement, confirm and cancel
input. It interacts with all four White Space objects (variable 101 = 4),
walks 27 tile steps to collect the spawned knife and 50 steps in total
through the TV interaction. It does not inject player position, inventory
or progress switches. The RSS observations cover these measured scenes
and intervals, rather than every possible game working set.

## Runtime changes covered

The enabled game configuration uses a 640×480 logical canvas. Title,
dialogue, choices, menu and battle geometry now use that size. The title
atlas region contains three poses; drawing crops a single 306×350 frame.
Standard character sheets are 12×8 cells (four by two characters, each
with three animation columns and four directions); `$` sheets remain 3×4.

Tiled maps supply layers, collision, regions, event positions and camera
movement. Autorun pages can follow one another, while parallel events keep
independent interpreters. Choice results reach the interpreter that owns
the choice, including child events. Input gates are released as dialogue
and scene transitions finish. A confirm that closes dialogue is consumed
before checking nearby objects, preventing the same object from reopening.
The opening's knife position script and movement locks have bounded native
implementations.

Tone, fades and picture movement advance each frame; fade interpolation
uses its authored target. Windows use the correct regions of MV's Window
image rather than treating the full palette as a nine-slice. Dialogue
layout wraps and paginates within the window. The supplied editor-only
DEV_TEST marker is hidden according to the game plugin's rule. Canceling
field OPTIONS returns to the field, while title OPTIONS returns to title.
Dialogue portraits use the game's 106 px face cells across four columns;
indices are bounds-checked against the decoded sheet, including late rows
such as Hero index 40. Item-get formatting tracks the latest gained kind,
ID and amount separately from the last item used, and resolves names for
regular items, weapons and armor. Focused regressions pass; the final
walkthrough shows the correct STUFFED TOY name and readable Aubrey portrait.
Weapon/armor event commands use the same gain methods, so item-get text does
not reuse the previous weapon's name. Readback is captured before SDL
RenderPresent in the test wrapper; production rendering is unchanged.
Language YAML decodes plain, single-quoted and double-quoted values with
their distinct escape rules. The fresh door screenshot has clean text and
choices, without literal outer quotes or the `\!` wait code. Script
conditions support the exact party-size expressions used by the adjacent
room: `$gameParty.members().length` or `$gameParty.size()` compared with an
integer. Tests reject unsupported compound expressions rather than treating
them as a successful match.

Actors use their authored attack skill IDs. Battle target scopes, repeats,
state parameter multipliers and supported ordered enemy AI note rules are
covered by regressions. In 100 seeded Forest Bunny turns, its first-passing
rules selected skill 209 55 times, 210 20 times and 211 25 times. State 186
forces skill 209 before random rules. The actual BE CUTE note advances
states 92 → 93 → 94 with ATK multipliers 0.9/0.8/0.7 and six-turn expiry.
Event command 301 enters the interactive battle UI; victory, escape and
defeat return to the requesting parent or child interpreter's result branch.
The event's canEscape/canLose settings are preserved.

SKILL lists the active actor's learned skills that are usable in battle
and affordable, excluding internal type-0 and Hide In Menu entries according
to the game's skill-window rules. ITEM lists owned items that are usable in battle. Selection
and cancel handling lead to the native action engine's target scopes,
costs and effects. Execution rechecks inventory and affordability; repeated
or all-target effects consume an item once, nonconsumables remain, and
dead allies can be selected for revival. The supported OMORI enemy-or-actor
note lets the same action select either side. The current command UI accepts
one active actor's command; other living party members automatically use
their authored attack skill. It does not yet offer a complete party-wide
command queue.

Authored equipment command 319 equips the requested item and updates its
inventory ownership. The supplied Map 87 knife command equips SHINY KNIFE:
ATK changes from 5 to 10 and the equipped-knife door condition becomes true.
The bounded `equipSkill(0,26)` script handler enables SAD POEM without
duplicates. Five focused equipment tests include the actual game data.

BGM and BGS have independent channels. ME resolves from `audio/me`, plays
once, holds the BGM decoder position and lets BGS continue; completion
resumes BGM with a 0.5-second fade. Actual AMB_SLIDE and BGS_abstract_echo
produce nonzero PCM and each queue 1,048,576 bytes in the paused dummy
device. Actual xx_victory produces nonzero PCM and ends after 827 chunks.
These checks establish decode and queue behavior, not physical sound.

The main runtime uses a reclaiming general-purpose allocator. Per-frame
and temporary work is released, while decoded art remains cached across
frames. Save parsing and serialization use operation-scoped arenas; actor
names, audio names, weather and parallax strings survive in game-owned
storage. Replacing a load releases the previous retained arena. The
regression poisons freed scratch storage, checks partial-load fallbacks
and detects leaks with `std.testing.allocator`. Field recovery leaves key
items and ineffective consumables in the inventory. Generated battle text
and repeated enemy display-name allocations are also released, covered by
three focused strict-allocator ownership tests.

## Repeat the checks

Use Linux/WSL, Zig 0.15.2 and an installed SDL2. `GAME_ROOT` must name the
user's extracted game root containing `data/`, `img/`, `audio/` and `fonts/`.
Do not copy that tree into the source or install package.

```bash
cd runtime
zig build test --summary all
OMORI_AUDIO_SMOKE_ROOT="$GAME_ROOT" OMORI_BATTLE_SMOKE_ROOT="$GAME_ROOT" \
    zig build test --summary all
zig build render-smoke -- "$GAME_ROOT/fonts/OMORI_GAME2.ttf" \
    /tmp/omori-title.ppm "$GAME_ROOT/img/atlases/Omori_TitleScreen.png" \
    "$GAME_ROOT/img/characters/DW_OMORI.png"
zig build field-render-smoke -- "$GAME_ROOT" /tmp/omori-field.ppm
zig build opening-smoke -- "$GAME_ROOT" /tmp/omori-opening
zig build opening-smoke -- "$GAME_ROOT" /tmp/omori-neighbors --neighbors-to-stump
zig build opening-smoke -- "$GAME_ROOT" /tmp/omori-battle --battle-smoke
```

The renderer and opening harnesses select SDL's dummy video/software
backend. Their screenshots and logs remain local test evidence. The
synthetic headless fixture and ARM64 build commands are documented in
`BUILDING.md`; historical v35 evidence remains in `VALIDATION-v35.md`.

The main executable's generic `--headless` scripted driver is a synthetic
fixture check. It is not an input plan for the actual game: against the
supplied payload it reaches White Space, then fails `ScriptedShellIncomplete`
at its `save_menu` phase because the authored game keeps that menu disabled
until progression. That run is not an actual-game full pass. The
`opening-smoke` route above follows the real object/knife/door sequence;
the optional extension follows the room's quest and recruitment events.
`--battle-smoke` adds a separate developer encounter with actual troop 34
through L1+R1. It does not claim a naturally triggered story encounter,
and does not inject inventory, stats or progression flags.

## Remaining scope

Progression beyond the Map 89 initializer, later battles and full plugin compatibility have
not been established. Enemy AI covers supported Random/Always/State rules;
ally-target AI, arbitrary AI EVAL predicates and general action-sequence
scripting remain unsupported. Audio pan is tracked without stereo panning,
and save/replay of a switched track starts from zero. Battle commands are
currently selected for one actor, with authored auto-attacks for the other
living party members.

Text/plugin formatting is also bounded. The supplied item-get cases pass
their unit/route checks; complete message-macro compatibility is unverified.

R36S KMSDRM/OpenGLES presentation, physical speaker output and physical
controller behavior still require device testing. Software SDL and QEMU
checks cannot establish those results. Preserve `omori/logs/` after a failed
hardware run so a rendering or scene-transition failure can be diagnosed.

## Release identity

The final ARM64 runtime is 11,647,120 bytes, SHA256
`eec8455e20f40d005b0f4509243cf83e0182a369417388ae9c41a4586ea0009d`.
The install ZIP is 3,776,889 bytes, SHA256
`6754c4ce08bb23160c85929489d49bd48958ff7653e87d8c773452fb5b4acf54`.
The source-archive identity is recorded separately in the release manifest.

## Installation verification

The requested `E:\ports` installation is populated and verified. All 5,157
payload files (872,129,257 bytes) match their source SHA256 values, and all
56 runtime files, including the launcher, match their intended hashes.
The payload tree digest is
`9f3f0777631f9311859bf6f20cc7dc82f1c8da5a914eded2505375ed9521bcd1`.
Existing other ports are preserved; the save folder is empty and contains
no test fixtures. The OMORI gamelist entry/image are present. The preloaded
data lets the launcher skip extraction. This verifies installation, not
execution on a handheld.
