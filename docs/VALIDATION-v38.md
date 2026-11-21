# v38 validation — startup and PC data

R36S port by José Pilas. Validation date: 19 November 2026.

## Startup correction

The v37 launcher contained CRLF line endings, including its shebang.
Linux interpreted the carriage return as part of `/bin/bash` and rejected
the launcher before logging began. The source and installed launcher were
normalized to UTF-8 without BOM and Unix LF. The v37 runtime on the card
matched its release hash; the immediate launch failure was in packaging.

`tools/analysis/check_release.py` now checks the launcher bytes, `bash -n`,
actual kernel shebang execution in an isolated stub, ARM64 ELF headers,
ZIP byte identity, Unix execute permissions, and every shell file in the
install ZIP. Its nine Linux regression tests pass, including reproduction
of the CRLF failure. Packaging runs the Linux preflight before and after
building the install ZIP. `.gitattributes` retains LF for source checkouts.

## PC input and preparation

The supplied PC Build 8879120 was prepared from its original installation
into a private validation directory: 5,112 files, 1,812,833,301 source bytes.
The supplied installation is read; its Windows executable is never run.
Game files and the installation-specific key are excluded from releases.

Copy the PC installation contents into `omori/original/`, with `www/`
beside its supplied `Launch_OMORI.bat`. A complete installation folder
inside `original/` is also detected. A `www`-only copy requires its matching
32-character data key in `omori-pc-key.txt`. Do not mix different builds.

The launcher invokes the existing progress UI. `prepare_pc.py` uses Python
and OpenSSL to decode database/plugin files and RPG Maker media wrappers,
normalizes `Languages/`, and validates the canonical `assets/www` tree.
It stages before publishing, keeps copied PC input, preserves the previous
extraction as a sibling backup, and fingerprints the source to skip later
launches. PC input takes precedence over an existing Android extraction.
Saves remain outside the prepared tree. Failed imports preserve previous
data; source changes during preparation prevent publication.

Fourteen importer tests and three executions of the real Linux launcher
pass using generated fixtures. Coverage includes an independent AES-CTR
known-answer vector, copied layouts, lowercase languages, wrong/missing
keys, transformed-name collisions, cancellation, previous-data recovery,
Android first extraction and reuse, PC replacement of previous data, and
re-preparation after a source update. The launcher tests use a stub runtime
and exercise the real UI's text fallback without requiring a display.

## Media and rendering

Every one of the prepared PC tree's 2,471 PNG/JPEG images decodes through
the native image dispatcher. All 2,461 PNG RGBA hashes match the independent
Pillow reference. The ten JPEG images have matching dimensions and mean
absolute channel errors below 0.023 on the 0–255 scale; maximum difference
is three, consistent with decoder rounding. No native allocator leak was
reported by the corpus helper.

PNG support includes row filters, palettes, transparency, packed samples,
16-bit channels and Adam7. The decoder keeps two scanlines plus flate
history rather than a full filtered-image buffer. The supplied
`FA_AUBREY_Stump` image has a non-reduced Adler checksum: 65521 represents
zero modulo 65521. The decoder accepts that equivalent representation
while retaining chunk CRC and decoded-length checks. The reference check
normalizes only that checksum in memory; the supplied/prepared asset is
unchanged. A dedicated generated regression covers this case.

JPEG support is compiled separately with JPEG-only stb_image. Android's
VP8L-in-`.png` files retain their native decoder. Dispatch follows file
contents. PC assets containing `!`, `$` and brackets now resolve using
their original names before trying Android's filename replacements.

The wrapped PC audio corpus contains 984 Ogg, two MP3 and four WAV files.
The latter six keep the `.ogg` names requested by game data, and the native
streaming decoder identifies their contents. Every one of those six tracks
was decoded to EOF and rewound on both x86-64 and ARM64/QEMU, with matching
frame counts and peaks. BGM/BGS reuse their bounded decode windows; entire
songs are not expanded into retained PCM buffers. Existing Ogg mixing,
one-shots, ME interruption and BGS independence remain covered by tests.

## Gameplay checks

All 188 native Debug tests pass with the real Android audio and battle
fixtures enabled. The supplied Android and prepared PC data each pass the
6,284-frame SDL opening/journal walkthrough: title, authored intro, White
Space object interactions, knife acquisition, door choices, transfer to
the next room, dialogue, save, return to title and continue. The journal
opens three times and closes using confirm, cancel and Escape; log off
returns to the field. Door source/readback checks match 6,348 pixels.

The final PC walkthrough has no missing-sprite or decode-failure warnings.
Sampled host RSS peaks at 118 MiB for PC and 117 MiB for Android. These are
software SDL measurements, not measurements of the R36S graphics driver.

Both data sets also pass SDL title-frame/glyph readback, texture ownership,
ordered fade and character-frame checks, plus a 240-frame runtime title
launch. The real SDL input dispatch self-test passes controller, raw
joystick, hats, axes, keyboard and exit-chord cases. Journal and José Pilas
credit captures were visually checked with prepared PC data.

The final AArch64 ReleaseSafe runtime passes the 1,378-frame synthetic
title/new-game/walk/battle/save/continue chain under QEMU. ARM64 media
helpers also decode the actual PC title, palette windowskin, noncanonical
checksum sprite and JPEG thumbnail, matching native hashes. The ELF uses
the ARM64 glibc interpreter and requires no symbol newer than GLIBC 2.29
within its configured 2.31 target. This establishes executable/codec checks;
it does not establish handheld display-driver performance.

## Scope and remaining work

The native engine remains in development. Full-game PC compatibility,
later story routes, every plugin animation and video playback are not
established. Battle commands currently control one actor while other living
members attack automatically. The authored tag common-event animation is
not reproduced. Save compatibility between different game editions is
not established. See the retained v37 notes for control/timing coverage.

Linux/SDL and ARM64/QEMU checks do not verify the physical handheld's
KMSDRM display, audio output or actual controller. After installation,
launch on the R36S and retain `omori/logs/` if any device-specific failure
remains. Existing data, saves and logs are preserved by the SD update.
