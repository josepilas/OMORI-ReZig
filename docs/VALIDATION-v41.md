# OMORI ReZig v41 validation

R36S port by José Pilas. Game by OMOCAT and team.

## Gameplay changes

The follower chain now moves from tail to head whenever the leader takes a legal step. Each follower uses the previous member's old destination and has its own real coordinates, facing and animation clock. Scene transfers synchronize the chain, while the save loader restores a valid trail or synchronizes at the loaded tile when a legacy save lacks one. Visibility and the Gather Followers command now act on the chain. The map parser reads actor and item IDs from the authored page conditions. After recruitment, that activates the empty NPC pages for Hero, Aubrey and Kel.

The three small flower decorations in the friends' room are inspectable from an adjacent tile. The original map has no flower event at those tiles. ReZig adds a short inspection that uses the supplied game's localized flower description when available. Authored events take priority and collision stays active around the table.

Field dialogue uses a progressive UTF-8 reveal with support for authored waits and selected message controls. A can reveal text or advance a finished page. Existing version 1 preferences keep their previous instant presentation. New preferences default to progressive text and can be changed through Instant Text.

The battle interface collects a command from each living party member before resolution. Each member can pick their own target, use a skill or an item, or Guard when the matching skill is available. B returns to the previous member. Revising a command releases shared inventory reservations. The engine rechecks item counts and skill cost when applying actions.

Supported visual event routes update facing, sprites, frames, in-place jumps, opacity and visibility with authored waits. Field picture slots draw in ascending order and support mirrored scales, rotation and additive blending. Screen saves retain picture and weather progress. Rain, snow and storm draw a bounded number of particles above the map.

## Verification

All 230 native tests passed with the external game-data and font fixtures. A clean source extraction built on a case-sensitive Linux filesystem, passed the bundled fixture checks and ran the synthetic opening through Save and Continue. A case-insensitive lookup regression now resolves directory components as well as filenames.

The final SDL walkthroughs passed 10,988 frames with PC data and 10,662 with Android data. Each examined all three flowers, returned to the checkpoint, recruited the friends, checked the stationary NPC pages, and verified separate follower destinations, glides and regrouping at the stairs transfer. Each checked 6,348 door-picture pixels against the supplied source. The PC run also selected actions for all four actors in a diagnostic battle. Both editions passed separate tests for the authored recruitment pages.

The PC and Android catalog checks each loaded 517 supplied maps, including 470 Tiled maps, and started all 337 populated troops. Both catalogs reference Map513 without a corresponding map file. These checks measure initialization. The controller walkthrough separately exercises event execution and progression.

Native SDL readback verified mirror, rotation and additive blend isolation using a synthetic image, as well as the supplied title font, title graphic and character sheet. Three SDL Options runs verified edits to all nine preferences, restart persistence, game-font credits and Restore Defaults. Separate cold starts verified two legacy device save copies, the table-trap recovery fixture and backup fallback.

## Scope

The porting guide covers the reuse points and platform adapters for a future target. The tested backends are Linux SDL2 and the emulated R36S ARM64 build. Real R36S testing of v41 is pending. The device previously ran v40, including an observed Start + Select exit. PS3 support remains future backend work.

Spatial scripted event routes, arbitrary JavaScript, movies, full picture tint and advanced blend modes, specialized character graphics scripts and full battle presentation remain incomplete. The supplied-data walkthrough covers the opening and a diagnostic troop. Later story branches and minigames require further validation. [Reference comparison](REFERENCE-COMPARISON.md)
