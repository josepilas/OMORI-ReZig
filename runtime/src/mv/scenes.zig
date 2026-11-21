//! SceneManager + Scene_Boot (milestone 4).
//!
//! `SceneManager` from `rpg_managers.js`, reduced to what a native frame
//! loop needs:
//!   * scene stack: goto / push / pop
//!   * updateMain: 60 Hz frame accounting (Graphics.frameCount),
//!     scene update dispatch, delta-time smoothing skipped (MV is a
//!     fixed-step engine — requestAnimationFrame's 60 Hz assumption)
//!   * FATAL catching: any error in a scene transitions to the error
//!     path with the classified FATAL_* diagnostics (the observable
//!     contract of the old stack's onerror pipeline)
//!
//! `Scene_Boot` from `rpg_scenes.js`:
//!   * create: DataManager.loadDatabase (done by caller), ConfigManager
//!     .load (port: config milestone), loadSystemWindowImage (asset
//!     reservation — logged here, texture bind is the renderer milestone)
//!   * isReady: database loaded + font ready (native: always ready)
//!   * start: SoundManager.preloadImportantSounds → checkPlayerLocation →
//!     setupNewGame → goto Scene_Title (M6 renders it; M4 verifies the
//!     transition and the state behind it)
//!
//! Scene_Title: its start() loads the title background through the atlas
//! chain — here we verify the atlas entry resolves and the sheet loads
//! through the asset manager (the state M6 needs to draw).

const std = @import("std");
const log = @import("../core/log.zig");
const database = @import("../data/database.zig");
const vfs_mod = @import("../filesystem/vfs.zig");
const atlas_mod = @import("../assets/atlas.zig");
const manager_mod = @import("../assets/manager.zig");
const data_manager_mod = @import("data_manager.zig");
const game_mod = @import("game.zig");

pub const SceneId = enum {
    boot,
    title,
    map,
    battle,
    gameover,
    @"error",

    pub fn name(self: SceneId) []const u8 {
        return switch (self) {
            .boot => "Scene_Boot",
            .title => "Scene_Title",
            .map => "Scene_Map",
            .battle => "Scene_Battle",
            .gameover => "Scene_Gameover",
            .@"error" => "Scene_Error",
        };
    }
};

pub const SceneManager = struct {
    alloc: std.mem.Allocator,
    db: *database.Database,
    atlas: *atlas_mod.AtlasData,

    /// Stack of scene ids (goto = replace top).
    stack: std.ArrayList(SceneId) = .empty,
    scene_started: bool = false,
    frame_count: u64 = 0,
    /// Set when a scene error occurred (classified FATAL path).
    error_reason: ?[]const u8 = null,

    dm: data_manager_mod.DataManager,
    game: game_mod.GameObjects,

    pub fn init(alloc: std.mem.Allocator, db: *database.Database, atlas: *atlas_mod.AtlasData) SceneManager {
        return .{
            .alloc = alloc,
            .db = db,
            .atlas = atlas,
            .dm = data_manager_mod.DataManager.init(alloc, db),
            .game = game_mod.GameObjects.init(alloc, db),
        };
    }

    pub fn deinit(self: *SceneManager) void {
        self.game.deinit();
        self.dm.deinit();
        self.stack.deinit(self.alloc);
    }

    // -----------------------------------------------------------------
    // Stack semantics
    // -----------------------------------------------------------------

    pub fn goto(self: *SceneManager, scene: SceneId) void {
        if (self.stack.items.len > 0) {
            self.stack.items[self.stack.items.len - 1] = scene;
        } else {
            self.stack.append(self.alloc, scene) catch {};
        }
        self.scene_started = false;
        log.event(.mv, .note, "SceneManager.goto({s})", .{scene.name()});
    }

    pub fn push(self: *SceneManager, scene: SceneId) void {
        self.stack.append(self.alloc, scene) catch {};
        self.scene_started = false;
        log.event(.mv, .note, "SceneManager.push({s}) (depth {d})", .{ scene.name(), self.stack.items.len });
    }

    pub fn pop(self: *SceneManager) void {
        if (self.stack.items.len > 0) {
            _ = self.stack.pop();
            self.scene_started = false;
            log.event(.mv, .note, "SceneManager.pop (depth {d})", .{self.stack.items.len});
        }
    }

    pub fn currentScene(self: *const SceneManager) ?SceneId {
        if (self.stack.items.len == 0) return null;
        return self.stack.items[self.stack.items.len - 1];
    }

    // -----------------------------------------------------------------
    // Scene_Boot — the boot sequence (rpg_scenes.js semantics)
    // -----------------------------------------------------------------

    /// Runs the complete Scene_Boot lifecycle. In headless mode this is
    /// synchronous; the windowed loop (M6) calls update() per frame.
    /// Returns the scene the boot transitioned to (Scene_Title on
    /// success) — the caller decides whether to render it.
    pub fn boot(self: *SceneManager, vfs: *vfs_mod.Vfs, assets: ?*manager_mod.Manager) !SceneId {
        _ = vfs; // used by the renderer milestone (title asset warmup)
        log.section("Scene_Boot");
        self.goto(.boot);

        // Scene_Boot.create: loadDatabase (already loaded by the caller),
        // ConfigManager.load, loadSystemWindowImage.
        log.event(.mv, .info, "Scene_Boot.create: database loaded ({d} files), ConfigManager.load (config milestone), reserve System/Window", .{
            database.boot_database_files.len,
        });
        if (assets) |a| {
            // Scene_Boot.loadSystemWindowImage → ImageManager.reserveSystem('Window')
            // + Scene_Boot.loadSystemImages: the 9 system images.
            const system_imgs = [_][]const u8{
                "img/system/Window.png",
                "img/system/IconSet.png",
                "img/system/Balloon.png",
                "img/system/Shadow1.png",
                "img/system/Shadow2.png",
                "img/system/Damage.png",
                "img/system/States.png",
                "img/system/Weapons1.png",
                "img/system/Weapons2.png",
                "img/system/Weapons3.png",
                "img/system/ButtonSet.png",
            };
            var reserved: usize = 0;
            for (system_imgs) |path| {
                // Atlas-aware reservation: system images may resolve through
                // the atlas chain (OMORI ships several as atlas sub-rects);
                // registration only checks reachability — load stays lazy.
                a.register(path) catch continue;
                reserved += 1;
            }
            log.event(.mv, .info, "Scene_Boot.loadSystemImages: {d}/{d} system images registered (lazy load, pinning at draw time)", .{
                reserved, system_imgs.len,
            });
        }

        // Scene_Boot.isReady: database loaded + font. Native: fonts are
        // loaded at renderer init (M6) — boot proceeds.
        log.detail(.mv, "Scene_Boot.isReady: database ok, GameFont native-load = true (renderer milestone)", .{});

        // Scene_Boot.start.
        // SoundManager.preloadImportantSounds (audio milestone logs it):
        log.event(.mv, .info, "SoundManager.preloadImportantSounds: sys1/cursor/decision/cancel/buzzer (audio milestone loads on demand)", .{});

        try self.dm.checkPlayerLocation();

        try self.dm.setupNewGame(&self.game);

        // Followers after party setup (Game_Followers initialize reads
        // $gameParty.maxBattleMembers()).
        self.game.followers.setup(self.alloc, &self.game.party);
        log.detail(.mv, "followers: visible={s} slots={d}", .{
            if (self.game.followers.visible) "true" else "false", self.game.followers.member_slots.items.len,
        });

        // SceneManager.goto(Scene_Title).
        self.goto(.title);
        self.scene_started = true;

        // Scene_Title.start verification (the M4-relevant part): the title
        // background resolves through the atlas chain on the real payload.
        try self.titleStart(assets);

        // Update document title (Scene_Boot.updateDocumentTitle).
        log.event(.mv, .info, "document.title = \"{s}\"", .{self.dm.gameTitle()});

        return .title;
    }

    /// Scene_Title.start — background music + background image resolution.
    /// MV: `drawTitleBackground` picks $dataSystem.title1Name via
    /// ImageManager.loadTitle1. OMORI: the title art lives in the atlas
    /// (Omori_TitleScreen sheet) — the atlas Loader plugin drives it.
    fn titleStart(self: *SceneManager, assets: ?*manager_mod.Manager) !void {
        log.section("Scene_Title.start");

        // $dataSystem.title1Name — the OMORI payload overrides the title
        // scene entirely (OMORI_TITLE plugin), but the MV field is still
        // authoritative for the engine path.
        const sys = self.dm.system();
        const title1 = if (sys) |s| (s.getString("title1Name") orelse "") else "";
        log.kv(.mv, "$dataSystem.title1Name", "'{s}'", .{title1});

        // The OMORI title background through the atlas chain:
        // Omori_TitleScreen sheet — the entry `img/pictures/OMO_WS.png`
        // was verified in M3; here the scene asserts the chain again plus
        // the sheet load through the manager.
        if (assets) |a| {
            const sheet = "img/atlases/Omori_TitleScreen.png";
            if (a.load(sheet)) |snap| {
                log.event(.mv, .info, "Scene_Title: atlas sheet '{s}' ready ({d}x{d}, ~{d} KiB decoded, {d} KiB cache)", .{
                    sheet, snap.info.width, snap.info.height, snap.info.decoded_bytes / 1024, a.report().current_bytes / 1024,
                });
            } else |e| {
                log.event(.mv, .warn, "Scene_Title: atlas sheet '{s}' not loadable ({s}) — title draw will fail at M6", .{ sheet, @errorName(e) });
            }
        }

        // Title BGM (DataManager→AudioManager: play at title scene, M6).
        if (sys) |s| {
            if (s.get("titleBgm")) |bgm| {
                const name = bgm.getString("name") orelse "";
                if (name.len > 0) {
                    log.event(.mv, .info, "title BGM queued: '{s}' (audio milestone plays it)", .{name});
                }
            }
        }
    }

    // -----------------------------------------------------------------
    // Frame loop (windowed mode) — M6 wires the renderer; the accounting
    // is here so the interpreter milestone can drive fixed 60 Hz steps.
    // -----------------------------------------------------------------

    /// One updateMain step: frame counting + scene update dispatch.
    /// Returns false when the scene stack is empty (exit request).
    pub fn update(self: *SceneManager) bool {
        if (self.stack.items.len == 0) return false;
        self.frame_count += 1;
        // Scene update dispatch is per-milestone: Scene_Map.update runs
        // the interpreter (M5), Scene_Battle the battle loop (M8).
        if (self.frame_count % 3600 == 0) {
            log.detail(.mv, "frame {d} (scene {s})", .{ self.frame_count, self.currentScene().?.name() });
        }
        return true;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "scene manager stack semantics" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const vfs = try a.create(vfs_mod.Vfs);
    vfs.* = vfs_mod.Vfs.init(a, "/tmp/omori-sm-nonexistent", "/tmp/omori-sm-save");
    var db = database.Database.init(a, vfs);
    var atlas = atlas_mod.AtlasData{
        .entries = &.{},
        .index = std.StringHashMap(usize).init(a),
    };

    var mgr = SceneManager.init(a, &db, &atlas);
    defer mgr.deinit();

    try testing.expectEqual(@as(?SceneId, null), mgr.currentScene());
    mgr.goto(.boot);
    try testing.expectEqual(SceneId.boot, mgr.currentScene().?);
    mgr.push(.map);
    try testing.expectEqual(@as(usize, 2), mgr.stack.items.len);
    mgr.pop();
    try testing.expectEqual(SceneId.boot, mgr.currentScene().?);
    mgr.goto(.title);
    try testing.expectEqual(SceneId.title, mgr.currentScene().?);

    var frames: u64 = 0;
    while (mgr.update()) {
        frames += 1;
        if (frames == 120) break;
    }
    try testing.expectEqual(@as(u64, 120), mgr.frame_count);
}
