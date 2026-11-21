# OMORI ReZig v42 validation

R36S port by José Pilas. Build v42 is the engine baseline for the public 0.0.1 release.

## Field behavior

Map Scroll now advances the camera in tile units on each field update. A second scroll waits for the first one and retries afterward. Map boundaries stop a pan that can no longer move. The field camera and parallax share the same scrolling methods. A map change clears the pan. Continue restores a pan saved mid-motion together with its display position. Camera and interpreter behavior were compared with the supplied RPG Maker runtime and the console reference. [Map reference](https://github.com/meetox80/omori/blob/bec8f898dfa95239d7eed7f98e0968d1742faf48/engine/src/rpg/map.cpp) · [Interpreter reference](https://github.com/meetox80/omori/blob/bec8f898dfa95239d7eed7f98e0968d1742faf48/engine/src/rpg/interpreter.cpp)

Show Balloon now plays the supplied reaction sprites above player and event characters. The original OMORI overrides use eight 32×24 cells and no additional hold. ReZig advances the cells on field ticks, supports overlapping cues, and resumes waiting commands when the target cue ends. Event erasure and transfer clear the applicable cues. Save and Continue preserve the known balloon sheet selection. [Sprite reference](https://github.com/meetox80/omori/blob/bec8f898dfa95239d7eed7f98e0968d1742faf48/engine/src/omori/map_sprites.cpp)

MV maps with encounter tables now use a per-step countdown, destination regions and weighted troop selection. The runtime checks the encounter toggle and party encounter traits. Authored touch events get priority over step encounters. Save and Continue preserve the countdown. The supplied OMORI maps use authored battles and have empty encounter tables, so the random encounter regression uses synthetic map data. [Player reference](https://github.com/meetox80/omori/blob/bec8f898dfa95239d7eed7f98e0968d1742faf48/engine/src/rpg/player.cpp)

## Coverage

All 235 native tests passed with the external fixtures enabled. The cold Continue regression restores an in-progress pan, displayed position and encounter counter. The source archive built and repacked on case-sensitive Linux, passed 226 bundled cases with nine external cases skipped, passed 26 Python tests, and ran the synthetic title through Save and Continue.

The supplied PC and Android walkthroughs passed 11,168 and 10,842 SDL frames respectively. Both observed identical room balloon pixels and progressed through dialogue, journal controls, the door, flower inspection, recruitment and follower synchronization on the stairs transfer. Both compared 6,348 door-picture pixels against source data. PC also exercised a four-member diagnostic battle. Camera movement and the retry after an active pan were tested with a synthetic scroll sequence away from map edges.

The ARM64 ReleaseSafe executable passed 1,467 frames in the QEMU synthetic run. The native SDL input test passed. An earlier physical v41 run on the R36S used OpenGL ES 2, continued in White Space, reached North Coast and exited normally with Start + Select. Physical execution of v42 is pending.

The verification matrix separates synthetic tests, supplied-data walkthroughs, ARM64 emulation and physical R36S observations. Full game coverage still needs more story routes, including spatial movement scripts, full character animation effects, movies and later battle mechanics. [Verification](VERIFICATION.md) · [Compatibility](COMPATIBILITY.md)
