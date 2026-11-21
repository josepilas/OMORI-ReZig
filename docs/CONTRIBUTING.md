# Contributing to OMORI ReZig

Build the Linux runtime and start with the synthetic fixture. For a compatibility change, reproduce the behavior on a repeatable route, then add a focused code regression if the existing tests miss the fault. Use the pinned C++ reference and the behavior of your supplied data to explain the expected result. [Build guide](BUILDING.md) · [Compatibility](COMPATIBILITY.md) · [Verification](VERIFICATION.md)

When recording a bug, include the ReZig version, game data provider, platform or handheld firmware, location and input sequence. Note whether it occurs after New Game, in an uninterrupted session or after a fresh Continue. Include the expected and observed behavior. A short relevant log excerpt can help distinguish launch, asset, interpreter and rendering faults. Keep personal paths, live saves, game files and unredacted logs out of source changes. [Diagnostics](LOGGING.md)

Format Zig changes with `zig fmt`. Follow the platform and resource ownership boundaries used by the current engine. Keep game-specific test fixtures synthetic or point the harness to privately supplied inputs. Preserve any existing license notices. [Architecture](ARCHITECTURE.md) · [MPL 2.0](../LICENSE) · [Third-party notices](THIRD_PARTY.md)

A source distribution contains the engine, build scripts, synthetic fixtures, local release tooling and documentation. The source packager's allowlist defines this set. A PortMaster package carries the compiled ARM64 executable and launcher assets for R36S. [Packaging](BUILDING.md#package-source-and-r36s-builds)
