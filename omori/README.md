# OMORI ReZig for R36S

R36S port by **José Pilas**. Game by OMOCAT and team. This package runs a player-supplied copy of OMORI using the OMORI ReZig engine.

## Installation

Extract `OMORI-ReZig-0.0.1-R36S.zip` into the Ports directory. For a new installation, copy your Android APK or your complete PC installation contents into `omori/original/`, then start OMORI ReZig. Existing installations use the same `OMORI.sh`, prepared data and save directory.

For PC, copy `www/` and its matching supplied `Launch_OMORI.bat` together. A complete installation folder under `original/` also works. A copy containing only `www/` needs its matching data key in `omori-pc-key.txt`. The launcher prepares `omori/original/extracted/assets/www/`, retains the supplied PC files and reuses an unchanged preparation. When an Android extraction is already present, successful PC preparation preserves it as a sibling backup. Allow room for both sets of data. A supplied Android APK is removed after successful extraction.

## Controls

| Input | Action |
| --- | --- |
| D-pad or left stick | Walk or navigate |
| A | Interact, confirm or advance dialogue |
| B or Start | Cancel, go back or open the field menu when the story permits |
| X | Hold to dash |
| Hold Y and press left or right | Choose the leader when tagging is enabled. Release Y or press A to confirm. |
| L or R | Page up or down where supported |
| Start + Select | Exit |

Options is available from the title. White Space unlocks the field menu when OMORI picks up the knife. A Start tap during a step opens the menu after landing. In Options, use the D-pad to select and change values, then B to save. Port preferences live in `omori/saves/port-options.json`.

During dialogue, A reveals the rest of the text or advances a finished page. Instant Text in Options shows text immediately between authored waits. In the friends' room, face a flower from a neighboring tile and press A to examine it. Once the friends join, they follow in single file. In battle, choose actions for each living member and press B to revisit an earlier choice.

## Saves

Choose CONTINUE at the title, select a file with the D-pad and press A. B returns to the title. SAVE in the field menu uses the same six slots. Older occupied slots through 20 remain accessible. A good previous save is retained as a `.bak`. If loading uses this backup, a message appears and the next normal save records resumed progress. Save files are in `omori/saves/` and diagnostics are in `omori/logs/`. When updating, keep both directories and `omori/original/`.

## Engine source

The matching engine source is `OMORI-ReZig-0.0.1-source.zip`, provided alongside the R36S release. OMORI ReZig's project-owned source is available under MPL 2.0. [License](licenses/MPL-2.0.txt) · [Third-party notices](THIRD_PARTY.md)
