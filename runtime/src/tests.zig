//! Test aggregator — `zig build test` runs every module's battery.
//! All tests are deterministic and headless (§24 of the pivot spec).

comptime {
    _ = @import("core/log.zig");
    _ = @import("core/crash.zig");
    _ = @import("core/fs_compat.zig");
    _ = @import("filesystem/path.zig");
    _ = @import("filesystem/vfs.zig");
    _ = @import("data/json.zig");
    _ = @import("data/database.zig");
    _ = @import("assets/atlas.zig");
    _ = @import("assets/manager.zig");
    _ = @import("omori/paths.zig");
    _ = @import("omori/language.zig");
    _ = @import("omori/text.zig");
    _ = @import("codec/vp8l.zig");
    _ = @import("codec/png.zig");
    _ = @import("codec/image.zig");
    _ = @import("text/font.zig");
    _ = @import("renderer/draw.zig");
    _ = @import("mv/title_scene.zig");
    _ = @import("mv/sprites.zig");
    _ = @import("mv/map_render.zig");
    _ = @import("mv/game_loop.zig");
    _ = @import("mv/config.zig");
    _ = @import("mv/event_routes.zig");
    _ = @import("platform/dyn.zig");
    _ = @import("platform/sdl2.zig");
    _ = @import("input/input.zig");
    _ = @import("memory/budget.zig");
    _ = @import("mv/state.zig");
    _ = @import("mv/map.zig");
    _ = @import("mv/tiled.zig");
    _ = @import("mv/game.zig");
    _ = @import("mv/data_manager.zig");
    _ = @import("mv/scenes.zig");
    _ = @import("mv/interpreter.zig");
    _ = @import("mv/battle.zig");
    _ = @import("mv/save.zig");
    _ = @import("audio/audio.zig");
    _ = @import("audio/mixer.zig");
    // renderer.zig and main.zig are exercised by the headless smoke run
    // (scripts/run_headless.sh), not by the unit battery.
}

test {
    @import("std").testing.refAllDecls(@This());
}
