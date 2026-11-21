# v39 validation — resume, saves and room collision

R36S port by José Pilas. Validation date: 20 November 2026.

## Reported failures and resulting behavior

Cold Continue loaded the saved player but used `new_map_id` left behind
by the fresh process's intro setup. That loaded Map999 beneath a player
whose checkpoint belonged to another map. Same-process Continue had
passed because the stale transfer happened to refer to the previous field.
Continue now loads the restored map, clears pending transfer state, keeps
the saved Tiled level and erased events, and restores playtime. Older native
saves re-saved with the identifiable intro-map/player-map mismatch recover
the checkpoint map rather than the wrong map's event state.

The original OMORI save/load plugin exposes six files. Continue now opens
a file list, selects the latest existing file initially, supports D-pad
selection and B to return, and displays playtime/location. Save uses the
same six files. Occupied older native files 7–20 remain accessible. Empty
or incomplete files leave the list usable with an error message. Missing
or damaged global metadata no longer hides valid disk saves.

Saving records playtime before serialization, captures BGM/BGS into owned
strings and keeps a previous valid `.bak`. A corrupt current file cannot
replace its good backup. If the main file is missing or incomplete, Load
can read the previous valid backup and displays a notification; it does
not overwrite either file. Metadata has independent backup recovery.
Completed temporary writes are synchronized before atomic rename.

The reported table trap was a collision error, not an interpreter wait.
The old player-step check allowed entry into solid tile `(11,20)` in
Map088, then rejected every exit because the source tile was solid.
Movement now checks both the source edge and the destination's reverse
edge, matching MV/YED behavior. An upper-right partial-collision lookup
also used the wrong neighboring cell and is corrected.

Pre-v39 native saves already inside a fully solid tile have a narrowly
guarded recovery on load: an adjacent floor cell must be event-free, on
the same level, and connected to every other candidate without crossing
the solid tile or active events. Cutscenes, valid positions, one-way arrows,
out-of-bounds positions, ambiguous separated rooms and original PC/new
native saves are excluded. This changes only loaded memory until a normal
save. The actual table trap recovers to `(11,19)` in both supplied data sets.

## Independent checks

All **203 native Debug tests pass**, with actual Android battle/audio
fixtures enabled. This includes save/load, incomplete files, missing save
metadata, backup preservation/read-only recovery, 32 repeated reclaiming
allocator transactions, retained audio strings, cold boot, slot selection,
upper-floor state, collision boundaries and event rendering.

The retained-string stress check caught an arena-state copy made before
weather/parallax allocation completed. Later audio snapshot allocation
could overwrite those strings. All allocations now finish before the
arena state is copied; the repeated save/load checks pass without leaks.
The metadata-loss case also verifies that fallback playtime formatting
does not copy a buffer onto itself.

Four separate SDL processes exercise real Continue input: original device
File1, the separately prepared recovered checkpoint, a legacy table-trap
fixture, and a corrupted primary with a valid backup. Each begins at the
fresh boot map, opens Continue, cancels, reopens, selects the requested
file, checks map/player/data identities and position, walks, and opens and
closes the field menu. The backup case verifies its on-screen notice.
No source saves are written by these walkthroughs. Captures of the file
list and recovered White Space were visually checked.

The PC gameplay walkthrough passes **8,816 SDL frames**: credits, title,
intro, journal confirm/cancel/Escape, White Space objects, knife, door,
friends' room, save/title/file selection/continue, watermelon and stuffed
toy, recruitment of all four party members, stairs to Map089, and a focused
battle UI regression. It makes 89 actual tile steps. The battle is an
explicit diagnostic troop, not a claim that the natural story battle was
reached. Source/readback comparison checks 6,348 door-picture pixels.
Sampled host RSS peaks at 120 MiB.

The Android opening/journal/save/continue walkthrough passes **6,296 SDL
frames**, including the new Load scene. Sampled host RSS peaks at 117 MiB.
Actual Map088 collision queries for both providers retain 117 reachable
floor cells, reject 87 invalid solid/arrow entries, and verify legal steps
are reversible; all four entries into the reported trap are rejected.

The final AArch64 ReleaseSafe executable passes a 1,387-frame synthetic
title/walk/battle/save/file-selection/continue chain under QEMU. The explicit
headless driver now confirms the new Load scene instead of assuming the
old direct-Continue flow. Real SDL input self-tests also pass controller,
joystick, hat, axis, keyboard and exit-chord dispatch. The configured glibc
target is 2.31; the executable requires no symbol newer than GLIBC 2.29.

## Additional original-game rendering parity

Event notes and active-page comments now supply authored sprite offsets,
including the friends' room sparkle and card positions. Page changes reset
comment offsets correctly. Object sheets marked `!` use zero character
lift; ordinary characters retain the original six-pixel lift. Tiled draw
order includes the visual offset, while collision coordinates stay fixed.
Six renderer test blocks are now explicitly imported into the suite; they
assert destinations, sort keys, note/comment precedence and page reset.

## Boundaries

The native engine is still incomplete. Dynamic custom-frame scripts,
authored tag common-event animation, full plugin/late-story compatibility,
movie playback and complete multi-actor battle control remain unverified
or unimplemented. Static event offsets do not imply arbitrary script
compatibility. The battle interface still directly controls one actor;
other living members attack automatically. Cross-edition save compatibility
is not established beyond the supplied fixtures.

SDL software and ARM64/QEMU validation do not replace a new R36S run.
The latest actual device log already verifies Start+Select; its input
mapping is retained. Runtime updates preserve supplied game data and logs.
The separate user-specific recovery copy and original-save backups stay
outside both public release archives.
