# v40 validation — Options, menu timing and game-font credits

R36S port by José Pilas. Validation date: 20 November 2026.

## Menu behavior

The supplied device log receives Start correctly. In White Space, the
original initialization and knife events disable the field menu until
knife pickup; v40 preserves that authored lock. OPTIONS remains available
from the title and from the field menu once the story enables it.

A brief Start/B tap during a normal tile glide is now retained until
landing. Dialogue, cutscenes, fades, transfers and story menu locks discard
pending requests. An interaction started by confirm takes priority over
a queued menu. Held D-pad navigation in the field menu now uses the same
repeat cadence as Load and Options. Controller mapping and the existing
Start + Select exit chord are retained.

## Useful preferences

Options has eight working preferences: Always Run, master volume, music
volume, ambience volume, jingle volume, sound volume, screen flashes and
screen shake. A ninth row restores these preferences to their defaults.
Use up/down to select, left/right or A to change, and B to save and return.
Always Run inverts walk/held-dash behavior while respecting map restrictions.

Preferences persist independently in `omori/saves/port-options.json`.
Changing them does not rewrite the original game configuration or any
checkpoint. Restore Defaults only changes port preferences. Malformed
preference fields use safe defaults or bounded values. Failed writes show
an error and let a second B press return to the running session with its
current in-memory settings. Text currently appears immediately; no unwired
text-speed option is exposed.

Mixer gains apply to live PCM output, including already-playing tracks,
with separate BGM/BGS/ME/SE channels and a master multiplier. Muting does
not restart the decoder, reset playback position, or alter the original
event volume, fade, pitch or saved track volume. Save/load therefore does not
apply the user's gain a second time.

Field flash overlays and camera shake now follow their authored timers.
Disabling their rendering leaves those timers, interpreter waits and
scene fades running. Flash is composited after screen tint and before
brightness/fade, while message windows stay fixed. Active flash/shake
progress survives save/load; older native saves that omitted it clear
stale transient effects instead of inheriting the previously loaded field.

## Credit and movement parity

The credit reads exactly `R36S PORT BY José Pilas` and uses the game font
throughout. The supplied font lacks é/É. A bounded virtual glyph fallback
composes each from that font's own e/E and reflected grave-accent ink,
preserving the base letter's advance and kerning. Existing mapped glyphs
always take precedence. No proprietary font file is modified or bundled.

The interpreter now evaluates the exact player `isMoving()` and
`isStopping()` predicates from the actual motion snapshot rather than held
direction. Child interpreters receive the current snapshot. This fixes
the White Space idle counter while walking and still lets the counter
advance when a held direction is blocked. The original parallel event's
normal per-frame restart behavior is preserved.

## Measured checks

All **220 native Debug tests pass**, with external battle/audio fixtures
and the actual game font enabled. Focused checks include controller menu
requests, authored locks, D-pad repetition, malformed/persisted options,
write failure, independent live channel gains, flash/shake progression,
legacy screen-state reset, and retained save/collision regressions.

Three separate real-data SDL processes pass the Options flow: edit and
credit capture (156 frames), fresh-process reload and Restore Defaults
(90 frames), and a second restart confirming defaults (6 frames). They exercise title navigation, controller
adjustments, return to title and on-disk persistence using private save
copies. Tests also verify that returning from field Options keeps the
live session and player position. The credit glyph probe passes at 24,
32 and 48 pixels, preserving the base body pixels and spelling.

The real Map087 idle-event checks pass: 180 frames of movement keep its
idle counter at zero, while a blocked held direction can reach the authored
idle threshold. The supplied PC and Android versions have matching
normalized commands for this event.

Four fresh SDL processes repeat the Continue regression against private
save copies: current File1, the existing recovered File6 checkpoint, a
legacy Map088 table-trap save, and a corrupt primary with a valid backup.
All pass map/player/data identity, restored position, movement and menu
checks, without save writes. The legacy trap restores to `(11,19)`.
The recovered checkpoint remains a separate existing file; v40 does not
replace a user's checkpoint or recreate the recovery slot.

The PC gameplay regression passes **8,816 SDL frames**: credits, intro,
journal confirm/cancel/Escape, all four White Space objects, knife, door,
friends' room, save/title/file-selection/Continue, recruitment of all four
party members, stairs to Map089 and a focused diagnostic battle. It makes
89 tile steps and compares 6,348 door-picture pixels against source data.
Sampled host RSS peaks at 120 MiB. The battle is entered with a developer
hotkey; this does not establish natural story battle progression.

The Android journal/opening/save/Continue regression passes **6,296 SDL
frames**, with the same door pixel checks and sampled peak RSS of 117 MiB.
Actual collision checks for both providers preserve 117 reachable floor
cells, reject 87 invalid solid/arrow entries and keep the table trap
inaccessible. The private legacy trap fixture still recovers safely.

The final AArch64 ReleaseSafe executable passes **1,387 synthetic frames**
under QEMU, including title, walking, battle, Save and file-list Continue.
Real SDL input self-tests pass controller, raw joystick, hat, axis,
keyboard and exit-chord dispatch. Linux packaging preflight checks the
shell files, actual kernel shebang execution, ELF target, archive identity
and Unix executable permissions. Earlier results remain in
[v39 validation](VALIDATION-v39.md).

## Boundaries

The native runtime is still incomplete. Battle flash/shake rendering,
complete multi-actor battle command control, arbitrary plugin scripts,
authored tag common-event animation, movie playback and late-story/full-game
compatibility remain unimplemented or unverified. Battle commands currently
control one actor; other living members attack automatically. These field
effect checks do not establish complete animation compatibility. Save
compatibility across PC/Android story editions is not established beyond
the supplied fixtures.

Host SDL and emulated AArch64 checks do not replace a new R36S hardware run.
The current device log confirms Start dispatch and the earlier exit chord;
no new hardware run is claimed. Private game data, saves, logs, screenshots
and font fixtures remain outside release archives. Runtime installation
must preserve `original/`, `saves/` and `logs/`, including existing options
and recovery files.
