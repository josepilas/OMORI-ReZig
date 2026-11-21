# OMORI Behavioral Specification

This document is the **compatibility knowledge extracted from the v1–v21
project, restated as a specification** rather than as an implementation.
The native Zig runtime implements these behaviors; the original JavaScript
implementation (preserved under `reference/nwjs/`) is the oracle when
behavior is unclear.

> Core principle: **port the behavior, not the environment.**

Everything below was either directly observed on hardware (v13/v15/v16/v17/
v18/v19/v20 real-device runs) or proven by payload inspection during the
v1–v21 engineering effort, with current payload corrections identified
explicitly. Implementation and validation scope is tracked separately in
`VALIDATION-v36.md`.

---

## 1. The payload

| Fact | Value | Evidence |
|---|---|---|
| Source artifact | OMORI Android APK v1.0.8.1 (BYO-data) | user-supplied |
| Game root inside APK | `assets/www/` | extractor convention |
| Engine | Modified RPG Maker MV 1.6.1 (PixiJS 4.8.9 Canvas path) | payload `js/` |
| Logical resolution | 640 x 480 | v36 inspection: enabled YEP_CoreEngine parameters in `js/plugins.js`; overrides MV's 816 x 624 default |
| Plugins | 175 entries in `js/plugins.js` | parsed with Node eval |
| Data files | 13 database files + ~500 Map*.json | `data/` |

## 2. Hybrid filesystem semantics (v15)

The Android payload's `require("fs")` must behave as BOTH standard Node fs
AND the Android nwcompat fs (`js/porting/compat/nwjs.js`). The native VFS
(`runtime/src/filesystem/vfs.zig`) implements the semantics:

### 2.1 `_DIRECTORY` virtual directories (v14 — the boot-critical fix)

* The APK ships a physical `<dir>/_DIRECTORY.json` per directory (44
  markers) containing the JSON array of names the game may see.
* `readdirSync(dir)` MUST return the marker's array. A physical listing is
  acceptable ONLY when no marker exists, and MUST filter out
  `_DIRECTORY` and `_DIRECTORY.json`.
* `statSync("X/_DIRECTORY")` MUST NOT throw ENOENT; it resolves to the
  physical `X/_DIRECTORY.json` (a file).
* `statSync(X)` probes `X/_DIRECTORY.json` first: success ⇒ directory.
  Missing paths report non-existence (Android stat never throws).

**The failure chain this prevents** (documented from the v13 real-device
run):

```text
stat("Languages/_DIRECTORY") → ENOENT
  → Text_Language_Processor.loadAllLanguageFiles() throws
  → GTP_OmoriFixes.js IIFE aborts
  → AtlasManager.initAtlasData() never runs
  → $atlasData stays undefined
  → Scene_Boot dies at loadSystemWindowImage
```

### 2.2 Case-variant reads

`readFileSync(path)` tries, in order:
1. the exact path,
2. first letter of the last component capitalized,
3. the whole last component lowercased.

### 2.3 Save routing

* Paths whose second-to-last component is `save` route to the persistent
  save root (`omori/saves/`) — the NativeFunctions bridge equivalent.
* `writeFileSync` outside `save/` is an error (Android forbids it; the
  game never writes elsewhere in normal operation).
* `statSync`: `.../save` ⇒ directory; `.../save/<f>` ⇒ file.
* `unlinkSync` is a no-op in the payload.

### 2.4 Alternative-name resolution

* `cachedAlternativeName(path)`: if the path exists ⇒ itself; otherwise a
  case-insensitive scan of the parent listing (`findAlternativeName`),
  memoized (`window.ALT_CACHE`).
* Consumed by `Bitmap._requestImage` on every image load.

## 3. OMORI asset path mangling (748 files)

`Bitmap._requestImage` (VND_OmoriFixes.js) resolves:

```js
url = replaceSpecialSymbols(url);                // URL-decode + mangle
url = require("fs").cachedAlternativeName(url);  // case-insensitive fs
```

The APK renamed asset files to avoid special characters; the game data
still references the ORIGINAL names. The mangling table (in order):

| Char | Replacement |
|---|---|
| `!` | `_PIDOR_` |
| `[` | `_SUPER_` |
| `]` | `_PEDIK_` |
| `$` | `_SEMENCUM_` |
| `%` | `_RAZRABI_PIDORASI` |
| `(` | `_SOSI_` |
| `)` | `_BEBRA_` |

`decodeURIComponent` runs first; invalid escapes fall back to the raw
string (the payload wraps it in try/catch).

Example: `img/pictures/!BS_self.png` → physical
`img/pictures/_PIDOR_BS_self.png`.

## 4. Image formats — WebP in disguise (verified)

**2485 of 2486 `img/**` files are WebP streams with `.png` extensions.**
Every atlas sheet is WebP. The one genuine PNG and two JPEGs are
exceptions. Consequences:

* Memory accounting must parse RIFF/WEBP headers (VP8X / VP8L / VP8
  chunks), not trust extensions.
* The renderer milestone must use a WebP-capable decoder.
* Example: `img/atlases/Omori_TitleScreen.png` is a 1464 x 1053 WebP
  (~5.8 MiB decoded RGBA).
* `img/atlases/` also carries TexturePacker metadata (`.json`, `.yaml`,
  `.tps`) which the runtime must not confuse with the game's own
  `data/Atlas.yaml`.

## 5. Atlas system (core runtime functionality)

* `data/Atlas.yaml` — js-yaml subset: top-level `source:`, 2-space entry
  keys, 4-space properties, inline flow maps, quoted `'y'` keys (YAML 1.1
  boolean trap), whitespace before commas.
* **940 entries** (the exact number the v15 hardware run observed:
  `$atlasData already initialized (entries=940)`).
* Entry shape: `{ atlasName, rect{x,y,width,height},
  sourceRect{x,y,width,height}, makeFunction?{name,arguments} }` (OMORI
  ships no makeFunction entries).
* Atlas KEYS are virtual: `img/pictures/OMO_WS.png` never exists on disk;
  it is cut from the SHEET `img/atlases/<atlasName>.png`.
* The payload's global atlas preload path is already inert (commented
  out); sheets load ON DEMAND via `loadAtlasKeyBitmap` →
  `ImageManager.loadAtlas`.

## 6. Memory behavior (RK3326, ~896 MiB RAM)

The measured facts that make desktop assumptions fail on the R36S:

| Observation | Value |
|---|---|
| Aetherflow global image preload | 102 images, ~110.8 MiB decoded RGBA, never evicted |
| Community_Basic cache target | 80,000,000 pixels (~305 MiB RGBA) |
| Validated bounded image cache | 12,582,912 pixels = 48 MiB RGBA |
| Governor thresholds (trim-only) | 220 / 160 / 100 MiB |
| v15 renderer kill | `Tab Killed` during the ~315-request post-boot asset wave |

Native policy (§8–§11 of the pivot): **register resources without
allocating, load on demand, keep hot resources cached, evict cold ones.**
The just-loaded resource is always delivered; a budget smaller than the
pinned working set is reported, never silently dropped.

## 7. Audio

* ~990 OGG files under `audio/{bgm,bgs,me,se}/` plus a few M4A/other.
* Extension probing order for a name: `ogg, m4a, aac, wav, mp3`.
* The original system-audio preload contributed to boot memory pressure
  and was neutralized in the low-memory profile; native audio is lazy and
  streaming-oriented.

## 8. Language subsystem

* `LanguageManager.loadAllLanguageFiles()`:
  `readdirSync("Languages/")` → `["en"]` (the virtual listing) →
  `statSync("Languages/<name>")` (must not throw) → enumerate `*.yaml`.
* `Languages/en/` carries **209 YAML files** (verified).
* `process.mainModule.filename` is derived as `<game root>/OMORI.exe` by
  plugins (YEP_EventCopier/Spawner/Morpher, Text_Language_Processor,
  Atlas Loader, StorageManager all take `path.dirname()` of it).

## 9. Boot sequence contract (milestones)

The observable startup order the native runtime reproduces:

```text
game tree verification (index.html, package.json, js/, data/, img/, audio/, Languages/)
database load (Actors, Classes, Skills, Items, Weapons, Armors, Enemies,
               States, Troops, Animations, Tilesets, CommonEvents, System)
language enumeration (en, 209 files)
Atlas initialization ($atlasData, 940 entries)
AssetManager ready (bounded cache)
MV state (2001 switches, 2001 variables — from System.json)
memory diagnostics
renderer (SDL2 window / headless validation)
```

`FATAL_JS` / `FATAL_ATLAS` classifications from the v14 watchdog are
preserved.

## 10. Input model (R36S)

The v21 gptokeyb mapping documented the logical controls the game needs
(physical layer kept OUT of game logic):

| R36S control | OMORI logical action | gptokeyb evidence |
|---|---|---|
| D-pad / analog | up/down/left/right | arrows |
| A | confirm | `z` |
| B | cancel | `x` |
| X | dash | `shift` |
| Y | page_down | `l` |
| L1 | page_up | `l` |
| R1 | page_down | `r` |
| Start | menu | `esc` |
| Select | debug_3 | `f12` |
| L2/R2 | debug_1/debug_2 | `f4`/`f2` |

## 11. Video

Five `.webm` files under `movies/` (endings/credits sequences). The
browser video path is retired; the native backend will be selected at the
video milestone based on what the R36S stack can decode.

## 12. Data quirks

* `js/plugins.js` is JavaScript, not strict JSON: `var $plugins = [...]`,
  raw control characters (unescaped newlines) inside description strings,
  trailing commas in some editor edge cases. A tolerant parser is
  REQUIRED (the native data loader implements one).
* MV data files are 1-indexed arrays with `null` at index 0.
* Variables/switches count: 2000 (System.json) + null entry.
