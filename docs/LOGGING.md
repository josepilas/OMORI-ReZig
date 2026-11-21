# Diagnostics: `omori/logs/` (v25)

**The v25 logs-first contract: logs exist even if nothing works.** The
launcher creates `<port>/omori/logs/` (with a `/tmp/omori-logs` fallback
if the port dir is read-only) BEFORE any other step, writes every launcher
line to `launcher.log` (stderr + file, timestamped), tees the extractor
into `extract.log`, tees the native runtime's console output into
`runtime.log`, and an EXIT trap writes `short.txt` — a one-paragraph
outcome summary — on EVERY exit path (no APK, bad APK, extraction
failure, missing runtime, wrapper failure, runtime crash, normal exit).

File inventory (launcher-written):

| File | Writer | Content |
|---|---|---|
| `launcher.log` | OMORI.sh | every launcher step, timestamped |
| `extract.log` | extractor (via `OMORI_EXTRACT_LOG`) | PySDL2 import status, SDL UI diagnostics, text-mode progress, crash tracebacks |
| `runtime.log` | OMORI.sh (tee) | the native runtime's stdout/stderr |
| `short.txt` | OMORI.sh (EXIT trap) | outcome summary: duration, outcome, cause, where to read more |

The native runtime writes three artifacts into the same directory (the
launcher passes `--log-dir`; `--log-dir` / `OMORI_LOG_DIR` override):

## `detailed.txt` — hyper-technical log

Everything, with a global sequence number, wall clock + monotonic time,
category (SYS / VFS / DATA / ATLAS / MV / RES / MEM / SAVE / GPU / INPUT /
AUDIO / CRASH) and severity (TRC / DBG / INF / NOT / WRN / ERR / FTL):

* Environment header at session start: target/ABI, build mode,
  endianness, page size, pid/ppid, argv, selected environment, and
  `/proc/self/status`, `/proc/version`, `/proc/self/limits` excerpts.
* **Every VFS operation:** `stat` resolution path (physical /
  _DIRECTORY.json probe / marker), `readdir` (virtual vs physical,
  name count), `read` case-variant hit (exact / capitalized /
  lowercased) with byte counts.
* Data loading: per-file parse times, entry counts, map command totals.
* MV core events: actor setup, party members, transfers, scene
  transitions, parallel common events.
* Memory samples (RSS / asset bytes / peaks / system available).
* Structured `key = value` records and hex dumps.
* **Crash reports** (below) — appended in place, with the last ~96
  events before the crash as a ring snapshot.
* Rotation: the previous session is kept as `detailed.txt.old`, so a
  crash report survives into the next launch.

## `simple.txt` — readable log

One line per notable event (`[HH:MM:SS] LEVEL message`): milestones,
warnings, errors, section banners, and a one-line crash pointer.

## `boot.state` — supervisor contract

The v14/v20 single-writer milestone trail (`BOOT_START` … `SCENE_TITLE`
… `FATAL_*`), preserved for the old tooling.

## Crash reports

Captured for SIGSEGV, SIGILL, SIGBUS, SIGFPE, SIGABRT **and** every Zig
runtime panic (unwrap / bounds / overflow / unreachable). The signal
path is async-signal-safe (fixed buffers, raw `write(2)`, no locks, no
allocation). Each report contains:

* signal number + code, fault address, thread id
* integer registers (x86_64 gregs / aarch64 X0–X30, SP, PC, PSTATE)
* frame-pointer backtrace — raw addresses; resolve offline with
  `addr2line -e omori/bin/omori-native <ra>` (the shipped binary keeps
  its debug info for exactly this)
* `/proc/self/maps` excerpt around the fault address
* ring snapshot of the last ~96 log events

The process then dies with the **correct signal status** (the reporter
unblocks the signal before re-raising — the kernel blocks a signal while
its handler runs).

### Self-tests

```sh
omori/bin/omori-native --data-root <game> --save-root <saves> \
    --log-dir <logs> --headless --self-crash   # exit 139 (SIGSEGV)
omori/bin/omori-native ... --self-panic        # exit 134 (SIGABRT)
```

Both write the full report into `detailed.txt` and the one-line pointer
into `simple.txt`.


## v26 — the unconditional guarantee

The v25 device report ("three logs, no detailed.txt, no title") proved
the runtime can die before its logging initializes. v26 closes that
hole with a three-layer guarantee:

1. **Runtime logs-first boot** — `log.earlyInit()` runs as the first
   statement of `main()`, before argv parsing; the crash reporter
   installs immediately after. Directory resolution: `$OMORI_LOG_DIR`
   → `<exe_dir>/../logs` (port layout) → cwd fallback; `--log-dir`
   retargets (early records stay in the first dir).
2. **Launcher-written stubs** — the EXIT trap calls
   `ensure_runtime_logs()`: if detailed.txt is missing, the launcher
   writes detailed.txt + simple.txt itself (outcome, exit code, device
   env, binary ELF magic + arch hint, full runtime.log, extract.log
   and launcher.log tails). `runtime.log`/`extract.log` are created at
   launcher start.
3. **Permission repair** — ESUDO runs leave root-owned files; the
   launcher restores logs/saves ownership at exit so the next run can
   rotate.

The launcher battery proves both directions: a dead runtime (SIGSEGV,
zero output) still yields detailed.txt/simple.txt/short.txt; a logging
runtime is never overwritten.
