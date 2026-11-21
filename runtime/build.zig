const std = @import("std");

// OMORI native runtime â€” build definition.
//
// Targets:
//   zig build                     â†’ native dev build (headless-capable)
//   zig build -Dtarget=aarch64-linux-gnu.2.31 -Doptimize=ReleaseSafe
//                                  â†’ R36S / RK3326 PortMaster build
//   zig build test                â†’ run the deterministic test battery
//
// v28: the R36S build is DYNAMICALLY linked (aarch64-linux-gnu, glibc
// 2.31 floor = Ubuntu 20.04/ArkOS) â€” the v27 static-musl binary could not
// dlopen at all ("Dynamic loading not supported" on the device), which is
// why no window ever appeared. SDL2 stays a runtime dlopen (with a
// port-local omori/libs/ fallback); --headless is the explicit validation
// mode, never a silent fallback.

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = .{
            // The R36S (RK3326) is an ARM64 Cortex-A35 running a glibc-based
            // PortMaster distribution; 2.31 is the Ubuntu 20.04 (focal)
            // glibc of ArkOS-class images.
            .abi = .gnu,
        },
    });

    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "omori-native",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    exe.root_module.addCSourceFile(.{
        .file = b.path("src/codec/jpeg.c"),
        .flags = &.{"-O2"},
    });
    // v30 (M10): stb_vorbis â€” Ogg Vorbis decode, public domain, compiled
    // with its implementation section. The Zig side binds via extern in
    // src/audio/mixer.zig; no headers needed beyond zig cc's libc.
    exe.root_module.addCSourceFile(.{
        .file = b.path("src/audio/stb_vorbis.c"),
        .flags = &.{ "-DSTB_VORBIS_IMPLEMENTATION=1", "-O2" },
    });
    exe.root_module.addCSourceFile(.{
        .file = b.path("src/audio/audio_decode.c"),
        .flags = &.{"-O2"},
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the native runtime");
    run_step.dependOn(&run_cmd.step);

    // Opt-in real SDL2 pixel readback checks; uses a system TTF and a
    // synthetic title sheet, so no proprietary payload is required.
    const render_smoke = b.addExecutable(.{
        .name = "omori-render-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("render_smoke.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    render_smoke.root_module.addCSourceFile(.{
        .file = b.path("src/codec/jpeg.c"),
        .flags = &.{"-O2"},
    });
    const render_smoke_run = b.addRunArtifact(render_smoke);
    if (b.args) |args| render_smoke_run.addArgs(args);
    b.step("render-smoke", "Check title pixels, texture ownership and fades through SDL2").dependOn(&render_smoke_run.step);

    // Input-driven opening regression against a user-supplied game root.
    const opening_smoke = b.addExecutable(.{
        .name = "omori-opening-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("door_repro.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    opening_smoke.root_module.addCSourceFile(.{
        .file = b.path("src/codec/jpeg.c"),
        .flags = &.{"-O2"},
    });
    opening_smoke.root_module.addCSourceFile(.{
        .file = b.path("src/audio/stb_vorbis.c"),
        .flags = &.{ "-DSTB_VORBIS_IMPLEMENTATION=1", "-O2" },
    });
    opening_smoke.root_module.addCSourceFile(.{
        .file = b.path("src/audio/audio_decode.c"),
        .flags = &.{"-O2"},
    });
    const opening_run = b.addRunArtifact(opening_smoke);
    if (b.args) |args| opening_run.addArgs(args);
    b.step("opening-smoke", "Play the real opening, door, save and continue flow through SDL2").dependOn(&opening_run.step);

    // A separate process starts at Map999 before loading external saves.
    // This catches stale boot-map state that same-process Continue misses.
    const restart_smoke = b.addExecutable(.{
        .name = "omori-restart-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("restart_repro.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    for ([_][]const u8{ "src/audio/stb_vorbis.c", "src/audio/audio_decode.c", "src/codec/jpeg.c" }) |source| {
        restart_smoke.root_module.addCSourceFile(.{ .file = b.path(source), .flags = &.{"-O2"} });
    }
    const restart_run = b.addRunArtifact(restart_smoke);
    if (b.args) |args| restart_run.addArgs(args);
    b.step("restart-smoke", "Load a private save in a fresh process, select a slot, walk and open the menu").dependOn(&restart_run.step);

    // Optional controller-driven preference persistence and credits readback.
    const options_smoke = b.addExecutable(.{
        .name = "omori-options-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("options_repro.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    for ([_][]const u8{ "src/audio/stb_vorbis.c", "src/audio/audio_decode.c", "src/codec/jpeg.c" }) |source| {
        options_smoke.root_module.addCSourceFile(.{ .file = b.path(source), .flags = &.{"-O2"} });
    }
    const options_run = b.addRunArtifact(options_smoke);
    if (b.args) |args| options_run.addArgs(args);
    b.step("options-smoke", "Check external-game Options, fresh-process preferences and credits through SDL2").dependOn(&options_run.step);

    const catalog_smoke = b.addExecutable(.{
        .name = "omori-catalog-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("catalog_smoke.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const catalog_run = b.addRunArtifact(catalog_smoke);
    if (b.args) |args| catalog_run.addArgs(args);
    b.step("catalog-smoke", "Load every catalog map and initialize each populated battle troop").dependOn(&catalog_run.step);

    const collision_smoke = b.addExecutable(.{
        .name = "omori-collision-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("collision_smoke.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const collision_run = b.addRunArtifact(collision_smoke);
    if (b.args) |args| collision_run.addArgs(args);
    b.step("collision-smoke", "Check the real Map088 table trap and reachable floor").dependOn(&collision_run.step);

    // Separate from input-driven progression: measure the real field's
    // draw count, cache reuse, memory plateau and decoded-cache eviction.
    const field_smoke = b.addExecutable(.{
        .name = "omori-field-render-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("field_render_smoke.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    field_smoke.root_module.addCSourceFile(.{
        .file = b.path("src/codec/jpeg.c"),
        .flags = &.{"-O2"},
    });
    field_smoke.root_module.addCSourceFile(.{
        .file = b.path("src/audio/stb_vorbis.c"),
        .flags = &.{ "-DSTB_VORBIS_IMPLEMENTATION=1", "-O2" },
    });
    field_smoke.root_module.addCSourceFile(.{
        .file = b.path("src/audio/audio_decode.c"),
        .flags = &.{"-O2"},
    });
    const field_run = b.addRunArtifact(field_smoke);
    if (b.args) |args| field_run.addArgs(args);
    b.step("field-render-smoke", "Check real field draw stability and cache eviction through SDL2").dependOn(&field_run.step);

    // Deterministic unit tests (fully headless â€” no SDL2 required).
    const lib_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = .Debug,
            .link_libc = true,
        }),
    });
    lib_tests.root_module.addCSourceFile(.{
        .file = b.path("src/codec/jpeg.c"),
        .flags = &.{"-O2"},
    });
    lib_tests.root_module.addCSourceFile(.{
        .file = b.path("src/audio/stb_vorbis.c"),
        .flags = &.{ "-DSTB_VORBIS_IMPLEMENTATION=1", "-O2" },
    });
    lib_tests.root_module.addCSourceFile(.{
        .file = b.path("src/audio/audio_decode.c"),
        .flags = &.{"-O2"},
    });
    const run_lib_tests = b.addRunArtifact(lib_tests);
    const test_step = b.step("test", "Run runtime unit tests");
    test_step.dependOn(&run_lib_tests.step);

    // v31 debugging: the audio-crash reproduction harness (temporary â€”
    // not shipped). `zig build repro -- <data-root> [seconds]`
    const repro = b.addExecutable(.{
        .name = "omori-repro",
        .root_module = b.createModule(.{
            .root_source_file = b.path("repro.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    repro.root_module.addCSourceFile(.{
        .file = b.path("src/codec/jpeg.c"),
        .flags = &.{"-O2"},
    });
    repro.root_module.addCSourceFile(.{
        .file = b.path("src/audio/stb_vorbis.c"),
        .flags = &.{ "-DSTB_VORBIS_IMPLEMENTATION=1", "-O2" },
    });
    repro.root_module.addCSourceFile(.{
        .file = b.path("src/audio/audio_decode.c"),
        .flags = &.{"-O2"},
    });
    b.installArtifact(repro);
    const repro_step = b.step("repro", "Build the v31 audio reproduction harness");
    repro_step.dependOn(b.getInstallStep());
}
