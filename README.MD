<p align="center">
  <a href="https://ko-fi.com/josepilas" target="_blank" rel="noopener noreferrer">
    <img src="https://josepilas.github.io/kofi.webp" alt="Ko-fi" width="300" />
  </a>
</p>

# OMORI ReZig

**Play OMORI on R36S with a native engine written in Zig.**

[![R36S release](https://img.shields.io/github/v/release/josepilas/OMORI-ReZig?label=R36S%20release)](https://github.com/josepilas/OMORI-ReZig/releases/latest) [![License MPL 2.0](https://img.shields.io/badge/license-MPL%202.0-blue)](LICENSE)

[**Download for R36S**](https://github.com/josepilas/OMORI-ReZig/releases/latest) · [R36S setup and controls](R36S.MD) · [For developers](FOR_DEVS.MD)

## What is ReZig?

OMORI ReZig is an unofficial runtime for OMORI. It reads the maps, dialogue, artwork and audio from your own copy of the game and handles movement, rendering, controller input, battles and saves in Zig. The handheld release runs through PortMaster. The engine source is available for developers who want to improve compatibility or bring it to another platform.

**You need your own OMORI game files.** The download contains the engine and launcher. It accepts files from a supported PC installation or an OMORI Android APK. Those are two ways to provide game data for the same R36S build.

## Start playing

1. Download the **R36S PortMaster ZIP** from Releases.
2. Extract it into the SD card’s Ports folder so `OMORI.sh` sits next to the `omori/` folder.
3. Put your game files in `omori/original/`, then launch OMORI from the Ports menu. The first launch prepares them on the card.

See the handheld guide for the exact file layout, controller shortcuts and how to update while keeping saves. [R36S guide](R36S.MD)

## What works today

| Area | In the current build |
| --- | --- |
| Exploration | Controller movement, following party members, opening room interactions and scripted camera pans |
| Dialogue | Progressive text, an Instant Text option, choices and reaction balloons |
| Battles | Commands and targets for each living party member |
| Saves | File selection, Continue after a fresh launch and previous-save backup recovery |

This is an early compatibility release. The opening and recruitment routes pass with both tested PC and Android data sets. Later story branches, minigames and some battle mechanics still need verification. [0.0.1 engine test results](docs/VALIDATION-v42.md)

## Credits

R36S port by **José Pilas**. OMORI is by **OMOCAT and team**. Project-owned engine code is available under **MPL 2.0**. The game and its assets belong to their respective rights holders. [License](LICENSE) · [Third-party notices](docs/THIRD_PARTY.md)
