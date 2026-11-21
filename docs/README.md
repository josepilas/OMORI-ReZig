# OMORI ReZig documentation

| Topic | Start here |
| --- | --- |
| Install and play on R36S | [PortMaster installation, controls and saves](../R36S.MD) |
| Build the Zig runtime on Linux or WSL | [Toolchain, game preparation and command-line options](BUILDING.md) |
| Reproduce and verify a change | [Test matrix and release checks](VERIFICATION.md) |
| Find engine modules and resource ownership | [Architecture](ARCHITECTURE.md) |
| See current compatibility and remaining work | [Compatibility and reference behavior](COMPATIBILITY.md) |
| Bring up another platform | [Platform porting guide](PORTING.md) |
| Diagnose a launch, rendering or gameplay fault | [Logs and crash reports](LOGGING.md) |
| Contribute a change | [Contribution guide](CONTRIBUTING.md) |

## Release evidence

Validation reports record specific builds, data, hardware and test routes. Use the report for the version under discussion when comparing results.

- [v42](VALIDATION-v42.md) covers camera pans, reaction balloons and encounter pacing.
- [v41](VALIDATION-v41.md) covers recruitment and followers, flower inspection, progressive dialogue, a party battle, and PC and Android startup catalogs.
- [v40](VALIDATION-v40.md) covers persistent preferences and ARM64 startup.
- [v39](VALIDATION-v39.md) covers Continue and existing save recovery.
- [v38](VALIDATION-v38.md), [v37](VALIDATION-v37.md) and [v36](VALIDATION-v36.md) document earlier preparation, launch and gameplay regressions.

The [behavioral specification](BEHAVIORAL_SPEC.md) records discoveries from earlier Android and PC investigations. The [v41 C++ comparison](REFERENCE-COMPARISON.md) maps that release's changes to a pinned console reference.
