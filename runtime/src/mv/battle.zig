//! M8 — the MV battle core, ported from the rpg_managers.js /
//! rpg_objects.js oracle (the exact MV 1.6 core the OMORI payload runs):
//!
//!   * `GameEnemy` — Enemies.json-driven battler with trait-based
//!     params, drops, AI action patterns (conditionType 1-6,
//!     rating-weighted selection with the max-3 window).
//!   * `Troop` — Troops.json setup (members/hidden/lettering), unique
//!     names, turn counting, battle-event pages (span 0/1/2, turn/HP/
//!     actor/switch conditions) driven through the existing
//!     Game_Interpreter, exp/gold/drop rewards.
//!   * `Action` — Game_Action: hit/eva/cri, damage formula evaluation
//!     (the payload's `a.atk * 4 - b.def * 2` forms via a dedicated
//!     expression parser — no JS engine), element rates, variance,
//!     guard, critical x3, drain, and the item effect set (11/12/13/
//!     21/22/31..34/41/42/43/44).
//!   * `Manager` — BattleManager phases (setup/start/input/turn/turnEnd/
//!     aborting/battleEnd), action order by speed, counter/reflection/
//!     substitute, victory rewards, defeat/escape, and the battle-event
//!     interpreter callback that sets the 601/602/603 branch result.
//!
//! Deviations, documented honestly:
//!   * Battles run as an ATOMIC step of the interpreter loop (the full
//!     turn/action flow with a deterministic seeded RNG) instead of a
//!     frame-paced pushed scene. The observable game-state outcome —
//!     branch result, HP/MP/states, switches/variables, rewards,
//!     messages — is the MV contract.
//!   * TP reserve/gain and motion/animation presentation are logged
//!     only (OMORI does not use TP).
//!   * OMORI's emotion system is state-based (HAPPY/SAD/ANGRY states
//!     with rate traits); the state + trait-rate math below is the
//!     engine-level substrate emotions ride on. Plugin-specific battle
//!     UI remains presentation work (draw-list level).

const std = @import("std");
const log = @import("../core/log.zig");
const json = @import("../data/json.zig");
const database = @import("../data/database.zig");
const game_mod = @import("game.zig");
const map_mod = @import("map.zig");
const interpreter_mod = @import("interpreter.zig");

const GameActor = game_mod.GameActor;
const GameParty = game_mod.GameParty;
const GameActors = game_mod.GameActors;

pub const PHASE_NAMES = [_][]const u8{
    "init", "start", "input", "turn", "action", "turnEnd", "aborting", "battleEnd",
};

// ---------------------------------------------------------------------------
// Deterministic RNG (the whole battle is reproducible in tests)
// ---------------------------------------------------------------------------

pub const Rng = struct {
    s: u64,

    pub fn init(seed: u64) Rng {
        return .{ .s = seed ^ 0x9E3779B97F4A7C15 };
    }

    pub fn next(self: *Rng) u64 {
        // splitmix64
        self.s +%= 0x9E3779B97F4A7C15;
        var z = self.s;
        z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
        return z ^ (z >> 31);
    }

    pub fn float(self: *Rng) f64 {
        return @as(f64, @floatFromInt(self.next() >> 11)) * (1.0 / 9007199254740992.0);
    }

    pub fn int(self: *Rng, max: u32) u32 {
        if (max == 0) return 0;
        return @intCast(self.next() % max);
    }
};

// ---------------------------------------------------------------------------
// Game_Enemy (rpg_objects.js Game_Enemy + Game_Battler battle state)
// ---------------------------------------------------------------------------

pub const GameEnemy = struct {
    alloc: std.mem.Allocator,
    db: *database.Database,
    /// Troop-members array index (MV enemy index for 331/332/...).
    index: usize = 0,
    enemy_id: i32 = 0,
    screen_x: i32 = 0,
    screen_y: i32 = 0,
    original_name: []const u8 = "",
    letter: []const u8 = "",
    plural: bool = false,
    screen_name: []const u8 = "",
    screen_name_owned: bool = false,
    hp: i32 = 1,
    mp: i32 = 0,
    tp: i32 = 0,
    hidden: bool = false,
    immortal: bool = false,
    appeared: bool = true,
    /// state_id → turns (0 = infinite).
    states: std.AutoHashMap(i32, i32),
    /// 8 slots: +2 max buff / -2 debuff.
    buffs: [8]i32 = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
    /// Queue of scheduled actions (AI-produced Game_Action shapes).
    actions: std.ArrayList(Action),
    speed_value: f64 = 0,

    pub fn init(alloc: std.mem.Allocator, db: *database.Database) GameEnemy {
        return .{
            .alloc = alloc,
            .db = db,
            .states = std.AutoHashMap(i32, i32).init(alloc),
            .actions = .empty,
        };
    }

    pub fn deinit(self: *GameEnemy) void {
        if (self.screen_name_owned) self.alloc.free(self.screen_name);
        self.states.deinit();
        self.actions.deinit(self.alloc);
    }

    fn enemyData(self: *const GameEnemy) ?json.Value {
        const f = self.db.get("data/Enemies.json") orelse return null;
        const items = f.value.arrayItems();
        if (self.enemy_id <= 0 or self.enemy_id >= items.len) return null;
        if (items[@intCast(self.enemy_id)] == .null) return null;
        return items[@intCast(self.enemy_id)];
    }

    /// Game_Enemy.setup: params from Enemies.json, recoverAll.
    pub fn setup(self: *GameEnemy, enemy_id: i32, x: i32, y: i32) void {
        if (self.screen_name_owned) self.alloc.free(self.screen_name);
        self.screen_name = "";
        self.screen_name_owned = false;
        self.letter = "";
        self.plural = false;
        self.enemy_id = enemy_id;
        self.screen_x = x;
        self.screen_y = y;
        self.hidden = false;
        self.immortal = false;
        if (self.enemyData()) |d| {
            self.original_name = d.getString("name") orelse "";
            const params = if (d.get("params")) |p| p.arrayItems() else &[_]json.Value{};
            const hp_max: i32 = @intCast(if (params.len > 0) params[0].asInt() else 1);
            const mp_max: i32 = @intCast(if (params.len > 1) params[1].asInt() else 0);
            self.hp = @max(hp_max, 1);
            self.mp = mp_max;
            self.immortal = d.getBool("immortal", false);
        }
        self.appeared = true;
    }

    pub fn name(self: *const GameEnemy) []const u8 {
        return if (self.screen_name.len > 0) self.screen_name else self.original_name;
    }

    // -- param surface -----------------------------------------------------

    pub fn paramBase(self: *const GameEnemy, param_id: usize) i64 {
        const d = self.enemyData() orelse return 0;
        const params = if (d.get("params")) |p| p.arrayItems() else &[_]json.Value{};
        if (param_id >= params.len) return 0;
        return params[param_id].asInt();
    }

    /// Trait-sum over the enemy's traits (rates only for M8 math).
    fn traitRateSum(self: *const GameEnemy, code: i32, data_id: i32) f64 {
        const d = self.enemyData() orelse return 0;
        const traits = if (d.get("traits")) |t| t.arrayItems() else &[_]json.Value{};
        var sum: f64 = 0;
        for (traits) |t| {
            if (t.getInt("code", 0) == code and t.getInt("dataId", -1) == data_id) {
                sum += t.get("value").?.asFloat();
            }
        }
        return sum;
    }

    fn stateTraitRateSum(self: *const GameEnemy, code: i32, data_id: i32) f64 {
        var sum: f64 = 0;
        var it = self.states.keyIterator();
        while (it.next()) |sid| {
            const st = stateData(self.db, sid.*) orelse continue;
            const traits = if (st.get("traits")) |t| t.arrayItems() else &[_]json.Value{};
            for (traits) |t| {
                if (t.getInt("code", 0) == code and t.getInt("dataId", -1) == data_id) {
                    sum += t.get("value").?.asFloat();
                }
            }
        }
        return sum;
    }

    pub fn param(self: *const GameEnemy, param_id: usize) i64 {
        // MV: (base + buff-level*10? no) — param with buffs: base + buff*?
        // MV buff = ±25% per level applied as rate. param =
        // floor((base + plus) * rate * buffRate) clamped 1..9999.
        const base = self.paramBase(param_id);
        var rate: f64 = 1.0 + self.traitRateSum(21, @intCast(param_id)) + self.stateTraitRateSum(21, @intCast(param_id));
        const buff = self.buffs[param_id];
        rate *= std.math.pow(f64, 1.25, @floatFromInt(buff));
        var v: i64 = @intFromFloat(@floor(@as(f64, @floatFromInt(base)) * rate));
        if (v < 1) v = 1;
        if (v > 9999) v = 9999;
        return v;
    }

    pub fn mhp(self: *const GameEnemy) i32 {
        return @intCast(self.param(0));
    }
    pub fn mmp(self: *const GameEnemy) i32 {
        return @intCast(self.param(1));
    }
    pub fn hpRate(self: *const GameEnemy) f64 {
        return @as(f64, @floatFromInt(self.hp)) / @as(f64, @floatFromInt(@max(self.mhp(), 1)));
    }
    pub fn mpRate(self: *const GameEnemy) f64 {
        return if (self.mmp() > 0) @as(f64, @floatFromInt(self.mp)) / @as(f64, @floatFromInt(self.mmp())) else 0;
    }

    pub fn isAlive(self: *const GameEnemy) bool {
        return self.hp > 0 and !self.hidden;
    }
    pub fn isDead(self: *const GameEnemy) bool {
        return self.hp <= 0;
    }
    pub fn isHidden(self: *const GameEnemy) bool {
        return self.hidden;
    }
    pub fn isAppeared(self: *const GameEnemy) bool {
        return self.appeared and !self.hidden;
    }

    pub fn gainHp(self: *GameEnemy, value: i32) void {
        const before = self.hp;
        self.hp = std.math.clamp(self.hp + value, 0, self.mhp());
        if (self.hp == 0 and before > 0 and !self.immortal) {
            log.detail(.mv, "enemy {d} '{s}' died", .{ self.index, self.name() });
        }
    }

    pub fn gainMp(self: *GameEnemy, value: i32) void {
        self.mp = std.math.clamp(self.mp + value, 0, self.mmp());
    }

    pub fn gainTp(self: *GameEnemy, value: i32) void {
        self.tp = std.math.clamp(self.tp + value, 0, 100);
    }

    /// addState with death handling (1 = KO).
    pub fn addState(self: *GameEnemy, state_id: i32) void {
        if (state_id == 1) {
            if (!self.immortal) self.hp = 0;
            return;
        }
        const turns = stateTurns(self.db, state_id);
        self.states.put(state_id, turns) catch {};
    }

    pub fn removeState(self: *GameEnemy, state_id: i32) void {
        _ = self.states.remove(state_id);
    }

    pub fn isStateAffected(self: *const GameEnemy, state_id: i32) bool {
        return self.states.contains(state_id);
    }

    pub fn recoverAll(self: *GameEnemy) void {
        self.hp = self.mhp();
        self.mp = self.mmp();
        self.states.clearRetainingCapacity();
        self.buffs = .{ 0, 0, 0, 0, 0, 0, 0, 0 };
    }

    pub fn appear(self: *GameEnemy) void {
        self.hidden = false;
        self.appeared = true;
    }

    /// Enemy transform (336): swap enemy data, keep position.
    pub fn transform(self: *GameEnemy, new_enemy_id: i32) void {
        const keep_x = self.screen_x;
        const keep_y = self.screen_y;
        self.setup(new_enemy_id, keep_x, keep_y);
        log.detail(.mv, "enemy {d} transformed into enemy {d} ('{s}')", .{ self.index, new_enemy_id, self.name() });
    }

    // -- battle surface ----------------------------------------------------

    pub fn exp(self: *const GameEnemy) i64 {
        const d = self.enemyData() orelse return 0;
        return d.getInt("exp", 0);
    }

    pub fn gold(self: *const GameEnemy) i64 {
        const d = self.enemyData() orelse return 0;
        return d.getInt("gold", 0);
    }

    pub fn battlerName(self: *const GameEnemy) []const u8 {
        const d = self.enemyData() orelse return "";
        return d.getString("battlerName") orelse "";
    }

    pub fn battlerHue(self: *const GameEnemy) i32 {
        const d = self.enemyData() orelse return 0;
        return @intCast(d.getInt("battlerHue", 0));
    }

    /// makeDropItems — kind 1=item 2=weapon 3=armor, denominator roll.
    pub fn makeDropItems(self: *const GameEnemy, rng: *Rng, drop_rate: f64) []DropItem {
        var out = std.ArrayList(DropItem).empty;
        defer out.deinit(self.alloc);
        const d = self.enemyData() orelse return &.{};
        const drops = if (d.get("dropItems")) |di| di.arrayItems() else &[_]json.Value{};
        var result = std.ArrayList(DropItem).empty;
        defer result.deinit(self.alloc);
        _ = &out;
        for (drops) |di| {
            const kind: i32 = @intCast(di.getInt("kind", 0));
            const data_id: i32 = @intCast(di.getInt("dataId", 0));
            const denom: i32 = @intCast(di.getInt("denominator", 1));
            if (kind > 0 and data_id > 0) {
                const roll = rng.float() * @as(f64, @floatFromInt(@max(denom, 1)));
                if (roll < drop_rate) {
                    result.append(self.alloc, .{ .kind = kind, .data_id = data_id }) catch {};
                }
            }
        }
        const final = self.alloc.dupe(DropItem, result.items) catch return &.{};
        return final;
    }

    pub const DropItem = struct { kind: i32, data_id: i32 };

    /// makeActions (AI): filter valid actions, rating window (max-3),
    /// rating-weighted random pick per action slot.
    pub fn makeActions(self: *GameEnemy, troop_turn: i32, party: *const GameParty, actors: *GameActors, switches: *game_mod.Switches, rng: *Rng) void {
        self.actions.clearRetainingCapacity();
        const d = self.enemyData() orelse return;
        // YEP_BattleAICore replaces the JSON action table when the enemy
        // has an ordered <AI Priority> list. The opening FOREST BUNNY
        // supplies its entire action selection through these notes.
        if (self.makePriorityAction(d, party, actors, rng)) return;
        const acts = if (d.get("actions")) |a| a.arrayItems() else &[_]json.Value{};
        var valid = std.ArrayList(json.Value).empty;
        defer valid.deinit(self.alloc);
        for (acts) |a| {
            if (self.meetsCondition(a, troop_turn, party, actors, switches)) {
                if (skillData(self.db, @intCast(a.getInt("skillId", 1))) != null) {
                    valid.append(self.alloc, a) catch {};
                }
            }
        }
        if (valid.items.len == 0) {
            // No valid action: MV enemies do nothing this turn.
            return;
        }
        var rating_max: i64 = 0;
        for (valid.items) |a| rating_max = @max(rating_max, a.getInt("rating", 0));
        const rating_zero = rating_max - 3;
        // MV action-plus traits are code 61 (independent chance each).
        // Code 31 is attack element and must not create extra actions.
        var num_actions: usize = 1;
        for (if (d.get("traits")) |t| t.arrayItems() else &[_]json.Value{}) |t| {
            if (t.getInt("code", 0) == 61) {
                const chance = if (t.get("value")) |v| v.asFloat() else 0;
                if (rng.float() < chance) num_actions += 1;
            }
        }
        var sum: i64 = 0;
        for (valid.items) |a| sum += a.getInt("rating", 0) - rating_zero;
        if (sum <= 0) return;
        var i: usize = 0;
        while (i < num_actions) : (i += 1) {
            var value: i64 = rng.int(@intCast(sum));
            for (valid.items) |a| {
                value -= a.getInt("rating", 0) - rating_zero;
                if (value < 0) {
                    self.actions.append(self.alloc, .{
                        .kind = .skill,
                        .skill_id = @intCast(a.getInt("skillId", 1)),
                        .target_index = -1,
                    }) catch {};
                    break;
                }
            }
        }
    }

    /// Ordered numeric-skill rules from the supplied YEP_BattleAICore.
    /// Supported conditions are Random %, Always and State ===/!== State
    /// ID. Unsupported rule forms remain undecided and use the real JSON
    /// table fallback, rather than inventing a default attack.
    fn makePriorityAction(self: *GameEnemy, data: json.Value, party: *const GameParty, actors: *GameActors, rng: *Rng) bool {
        const note = data.getString("note") orelse return false;
        var ai_level: f64 = 1; // supplied plugin Default AI Level = 100
        var lines = std.mem.splitScalar(u8, note, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (std.ascii.startsWithIgnoreCase(line, "<AI Level:") and std.mem.endsWith(u8, line, ">")) {
                const value = std.mem.trim(u8, line[10 .. line.len - 1], " \t");
                ai_level = std.math.clamp((std.fmt.parseFloat(f64, value) catch 100) / 100, 0, 1);
            }
        }
        lines = std.mem.splitScalar(u8, note, '\n');
        var in_priority = false;
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (std.ascii.eqlIgnoreCase(line, "<AI Priority>")) {
                in_priority = true;
                continue;
            }
            if (std.ascii.eqlIgnoreCase(line, "</AI Priority>")) break;
            if (!in_priority or line.len == 0) continue;
            // The source rolls its AI-level gate for every candidate line.
            if (rng.float() > ai_level) continue;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const condition = std.mem.trim(u8, line[0..colon], " \t");
            const rhs = std.mem.trim(u8, line[colon + 1 ..], " \t");
            if (!std.ascii.startsWithIgnoreCase(rhs, "SKILL ")) continue;
            const comma = std.mem.indexOfScalar(u8, rhs, ',') orelse rhs.len;
            const skill_id = std.fmt.parseInt(i32, std.mem.trim(u8, rhs[6..comma], " \t"), 10) catch continue;
            const skill = skillData(self.db, skill_id) orelse continue;
            if (skill.getInt("mpCost", 0) > self.mp or skill.getInt("tpCost", 0) > self.tp) continue;
            if (skill.getInt("occasion", 0) >= 2) continue;

            var state_id: ?i32 = null;
            var require_state = true;
            if (std.ascii.startsWithIgnoreCase(condition, "Random ")) {
                const percent = std.mem.indexOfScalar(u8, condition, '%') orelse continue;
                const rate = std.fmt.parseFloat(f64, std.mem.trim(u8, condition[7..percent], " \t")) catch continue;
                if (rng.float() >= rate / 100) continue;
            } else if (std.ascii.startsWithIgnoreCase(condition, "State === State ")) {
                state_id = std.fmt.parseInt(i32, std.mem.trim(u8, condition[16..], " \t"), 10) catch continue;
            } else if (std.ascii.startsWithIgnoreCase(condition, "State !== State ")) {
                state_id = std.fmt.parseInt(i32, std.mem.trim(u8, condition[16..], " \t"), 10) catch continue;
                require_state = false;
            } else if (!std.ascii.eqlIgnoreCase(condition, "Always")) continue;

            const selector = if (comma < rhs.len) std.mem.trim(u8, rhs[comma + 1 ..], " \t") else "RANDOM";
            const scope = skill.getInt("scope", 1);
            var candidates = std.ArrayList(i32).empty;
            defer candidates.deinit(self.alloc);
            if (scope >= 1 and scope <= 6) {
                for (party.members.items, 0..) |actor_id, unit_index| {
                    const actor = actors.actor(actor_id) orelse continue;
                    if (actor.hp <= 0) continue;
                    if (state_id) |sid| {
                        if (actor.isStateAffected(sid) != require_state) continue;
                    }
                    candidates.append(self.alloc, @intCast(unit_index)) catch {};
                }
            } else if (scope == 11) {
                if (state_id == null or self.isStateAffected(state_id.?) == require_state) {
                    candidates.append(self.alloc, @intCast(self.index)) catch {};
                }
            } else continue; // ally-target AI needs the troop group, not a guessed target
            if (candidates.items.len == 0) continue;
            const target = if (std.ascii.eqlIgnoreCase(selector, "FIRST")) candidates.items[0] else candidates.items[rng.int(@intCast(candidates.items.len))];
            self.actions.append(self.alloc, .{ .kind = .skill, .skill_id = skill_id, .target_index = target }) catch return false;
            log.detail(.mv, "enemy AI '{s}': '{s}' -> skill {d}, unit target {d}", .{ self.name(), condition, skill_id, target });
            return true;
        }
        return false;
    }

    fn meetsCondition(self: *const GameEnemy, action: json.Value, troop_turn: i32, party: *const GameParty, actors: *GameActors, switches: *game_mod.Switches) bool {
        const p1 = action.getInt("conditionParam1", 0);
        const p2 = action.getInt("conditionParam2", 0);
        switch (action.getInt("conditionType", 0)) {
            1 => { // turn: param2==0 → turn==p1; else turn%p2==p1% p2 and >= p1
                if (p2 == 0) return troop_turn == p1;
                return troop_turn > 0 and troop_turn >= p1 and @rem(troop_turn, @as(i32, @intCast(p2))) == @rem(p1, @as(i32, @intCast(p2)));
            },
            2 => { // HP% in [p1, p2]
                const rate = self.hpRate() * 100;
                return rate >= @as(f64, @floatFromInt(p1)) and rate <= @as(f64, @floatFromInt(p2));
            },
            3 => {
                const rate = self.mpRate() * 100;
                return rate >= @as(f64, @floatFromInt(p1)) and rate <= @as(f64, @floatFromInt(p2));
            },
            4 => return self.isStateAffected(@intCast(p1)),
            5 => { // party level
                var highest: i32 = 0;
                for (party.members.items) |id| {
                    if (actors.actor(id)) |a| highest = @max(highest, a.level);
                }
                return highest >= p1;
            },
            6 => return switches.value(@intCast(@max(p1, 1))),
            else => return true,
        }
    }
};

// ---------------------------------------------------------------------------
// Shared data lookups
// ---------------------------------------------------------------------------

pub fn stateData(db: *database.Database, state_id: i32) ?json.Value {
    const f = db.get("data/States.json") orelse return null;
    const items = f.value.arrayItems();
    if (state_id <= 0 or state_id >= items.len) return null;
    if (items[@intCast(state_id)] == .null) return null;
    return items[@intCast(state_id)];
}

pub fn skillData(db: *database.Database, skill_id: i32) ?json.Value {
    const f = db.get("data/Skills.json") orelse return null;
    const items = f.value.arrayItems();
    if (skill_id <= 0 or skill_id >= items.len) return null;
    if (items[@intCast(skill_id)] == .null) return null;
    return items[@intCast(skill_id)];
}

pub fn itemData(db: *database.Database, item_id: i32) ?json.Value {
    const f = db.get("data/Items.json") orelse return null;
    const items = f.value.arrayItems();
    if (item_id <= 0 or item_id >= items.len) return null;
    if (items[@intCast(item_id)] == .null) return null;
    return items[@intCast(item_id)];
}

/// State auto-removal timing in turns (minTurns..maxTurns → random).
pub fn stateTurns(db: *database.Database, state_id: i32) i32 {
    const st = stateData(db, state_id) orelse return 1;
    const min_turns: i32 = @intCast(st.getInt("minTurns", 1));
    const max_turns: i32 = @intCast(st.getInt("maxTurns", 1));
    if (max_turns <= min_turns) return @max(min_turns, 1);
    return min_turns + @as(i32, @intCast(std.crypto.random.int(u32) % @as(u32, @intCast(max_turns - min_turns + 1))));
}

// ---------------------------------------------------------------------------
// Game_Action
// ---------------------------------------------------------------------------

pub const ActionKind = enum { attack, skill, item };

pub const Action = struct {
    kind: ActionKind = .attack,
    skill_id: i32 = 0,
    item_id: i32 = 0,
    target_index: i32 = -1,
    /// YEP <Enemy or Actor Select>: explicit side for a single target.
    target_friends: ?bool = null,
    forcing: bool = false,
    /// subject: actor id (>=1) or enemy index (-1-x for enemy x).
    subject_is_enemy: bool = false,
    subject_index: usize = 0,
    /// MV action repeat/prepare scratch state.
    prepared: bool = false,

    pub fn item(self: *const Action, db: *database.Database) ?json.Value {
        return switch (self.kind) {
            .attack => skillData(db, 1), // attack skill id 1
            .skill => skillData(db, self.skill_id),
            .item => itemData(db, self.item_id),
        };
    }

    pub fn clear(self: *Action) void {
        self.* = .{ .kind = .attack, .skill_id = 1, .item_id = 0, .target_index = -1 };
    }
};

// ---------------------------------------------------------------------------
// Battler view (uniform math surface for damage/action code)
// ---------------------------------------------------------------------------

pub const Battler = union(enum) {
    actor: *GameActor,
    enemy: *GameEnemy,

    pub fn index(self: Battler) usize {
        return switch (self) {
            .actor => |a| @intCast(@max(a.actor_id, 0)),
            .enemy => |e| e.index,
        };
    }

    pub fn name(self: Battler) []const u8 {
        return switch (self) {
            .actor => |a| a.name,
            .enemy => |e| e.name(),
        };
    }

    pub fn hp(self: Battler) i32 {
        return switch (self) {
            .actor => |a| a.hp,
            .enemy => |e| e.hp,
        };
    }

    pub fn mp(self: Battler) i32 {
        return switch (self) {
            .actor => |a| a.mp,
            .enemy => |e| e.mp,
        };
    }

    pub fn mhp(self: Battler) i32 {
        return switch (self) {
            .actor => |a| @intCast(a.param(0)),
            .enemy => |e| e.mhp(),
        };
    }

    pub fn mmp(self: Battler) i32 {
        return switch (self) {
            .actor => |a| @intCast(a.param(1)),
            .enemy => |e| e.mmp(),
        };
    }

    pub fn param(self: Battler, param_id: usize) i64 {
        return switch (self) {
            .actor => |a| a.param(param_id),
            .enemy => |e| e.param(param_id),
        };
    }

    pub fn isEnemy(self: Battler) bool {
        return self == .enemy;
    }

    pub fn isAlive(self: Battler) bool {
        return switch (self) {
            .actor => |a| a.hp > 0,
            .enemy => |e| e.isAlive(),
        };
    }

    pub fn isStateAffected(self: Battler, state_id: i32) bool {
        return switch (self) {
            .actor => |a| a.isStateAffected(state_id),
            .enemy => |e| e.isStateAffected(state_id),
        };
    }

    pub fn addState(self: Battler, db: *database.Database, state_id: i32) void {
        switch (self) {
            .actor => |a| a.addState(db, state_id),
            .enemy => |e| e.addState(state_id),
        }
    }

    pub fn removeState(self: Battler, state_id: i32) void {
        switch (self) {
            .actor => |a| a.removeState(state_id),
            .enemy => |e| e.removeState(state_id),
        }
    }
};

// ---------------------------------------------------------------------------
// Game_Troop
// ---------------------------------------------------------------------------

pub const Troop = struct {
    alloc: std.mem.Allocator,
    db: *database.Database,
    troop_id: i32 = 0,
    in_battle: bool = false,
    turn_count: i32 = 0,
    /// Troop-page executed flags (span 0 = once, 1 = once per turn,
    /// 2 = every time).
    event_flags: std.AutoHashMap(usize, bool),
    /// Letter counter per original name (unique-name suffixing).
    names_count: std.StringHashMap(usize),
    enemies: std.ArrayList(*GameEnemy),

    pub fn init(alloc: std.mem.Allocator, db: *database.Database) Troop {
        return .{
            .alloc = alloc,
            .db = db,
            .event_flags = std.AutoHashMap(usize, bool).init(alloc),
            .names_count = std.StringHashMap(usize).init(alloc),
            .enemies = .empty,
        };
    }

    pub fn deinit(self: *Troop) void {
        for (self.enemies.items) |e| {
            e.deinit();
            self.alloc.destroy(e);
        }
        self.enemies.deinit(self.alloc);
        self.event_flags.deinit();
        self.names_count.deinit();
    }

    fn troopData(self: *const Troop) ?json.Value {
        const f = self.db.get("data/Troops.json") orelse return null;
        const items = f.value.arrayItems();
        if (self.troop_id <= 0 or self.troop_id >= items.len) return null;
        if (items[@intCast(self.troop_id)] == .null) return null;
        return items[@intCast(self.troop_id)];
    }

    /// Game_Troop.setup: members from Troops.json (hidden flag honored).
    pub fn setup(self: *Troop, troop_id: i32, game: *game_mod.GameObjects) void {
        for (self.enemies.items) |e| {
            e.deinit();
            self.alloc.destroy(e);
        }
        self.enemies.clearRetainingCapacity();
        self.event_flags.clearRetainingCapacity();
        self.names_count.clearRetainingCapacity();
        self.troop_id = troop_id;
        self.turn_count = 0;
        const d = self.troopData() orelse {
            log.event(.mv, .err, "Game_Troop.setup: no troop {d} in Troops.json", .{troop_id});
            return;
        };
        const troop_members = if (d.get("members")) |m| m.arrayItems() else &[_]json.Value{};
        for (troop_members, 0..) |m, i| {
            const enemy_id: i32 = @intCast(m.getInt("enemyId", 0));
            const x: i32 = @intCast(m.getInt("x", 0));
            const y: i32 = @intCast(m.getInt("y", 0));
            const hidden = m.getBool("hidden", false);
            if (enemyDataExists(self.db, enemy_id)) {
                const e = self.alloc.create(GameEnemy) catch continue;
                e.* = GameEnemy.init(self.alloc, self.db);
                e.index = i;
                e.setup(enemy_id, x, y);
                if (hidden) {
                    e.hidden = true;
                    e.appeared = false;
                }
                self.enemies.append(self.alloc, e) catch {};
            }
        }
        self.makeUniqueNames();
        log.event(.mv, .note, "Game_Troop.setup: troop {d} ('{s}') — {d} enemy(ies)", .{
            troop_id, d.getString("name") orelse "?", self.enemies.items.len,
        });
        _ = game;
    }

    /// Public wrapper (the M8 validator in main.zig uses it).
    pub fn enemyDataExistsPub(db: *database.Database, enemy_id: i32) bool {
        return enemyDataExists(db, enemy_id);
    }

    fn enemyDataExists(db: *database.Database, enemy_id: i32) bool {
        const f = db.get("data/Enemies.json") orelse return false;
        const items = f.value.arrayItems();
        if (enemy_id <= 0 or enemy_id >= items.len) return false;
        return items[@intCast(enemy_id)] != .null;
    }

    /// makeUniqueNames: A/B/C suffixes per repeated original name.
    pub fn makeUniqueNames(self: *Troop) void {
        const letters = "ABCDEFGHIJ";
        for (self.enemies.items) |e| {
            if (e.isAlive() and e.letter.len == 0) {
                const n = self.names_count.get(e.original_name) orelse 0;
                const li = n % letters.len;
                e.letter = letters[li .. li + 1];
                self.names_count.put(e.original_name, n + 1) catch {};
            }
        }
        for (self.enemies.items) |e| {
            const n = self.names_count.get(e.original_name) orelse 0;
            if (n >= 2) e.plural = true;
            // screen name = original + letter
            if (e.screen_name_owned) e.alloc.free(e.screen_name);
            e.screen_name_owned = true;
            e.screen_name = std.fmt.allocPrint(self.alloc, "{s}{s}", .{ e.original_name, e.letter }) catch blk: {
                e.screen_name_owned = false;
                break :blk e.original_name;
            };
        }
    }

    pub fn members(self: *const Troop) []*GameEnemy {
        return self.enemies.items;
    }

    pub fn aliveMembers(self: *const Troop) []*GameEnemy {
        var out = std.ArrayList(*GameEnemy).empty;
        defer out.deinit(self.alloc);
        for (self.enemies.items) |e| {
            if (e.isAlive()) out.append(self.alloc, e) catch {};
        }
        return out.toOwnedSlice(self.alloc) catch &.{};
    }

    pub fn deadMembers(self: *const Troop) []*GameEnemy {
        var out = std.ArrayList(*GameEnemy).empty;
        defer out.deinit(self.alloc);
        for (self.enemies.items) |e| {
            if (e.isDead()) out.append(self.alloc, e) catch {};
        }
        return out.toOwnedSlice(self.alloc) catch &.{};
    }

    pub fn isAllDead(self: *const Troop) bool {
        for (self.enemies.items) |e| {
            if (e.isAlive()) return false;
        }
        return true;
    }

    pub fn enemyNames(self: *const Troop) [][]const u8 {
        var out = std.ArrayList([]const u8).empty;
        defer out.deinit(self.alloc);
        for (self.enemies.items) |e| {
            if (e.isAppeared()) out.append(self.alloc, e.name()) catch {};
        }
        return out.toOwnedSlice(self.alloc) catch &.{};
    }

    /// increaseTurn + reset span-1 page flags.
    pub fn increaseTurn(self: *Troop) void {
        const d = self.troopData() orelse {
            self.turn_count += 1;
            return;
        };
        const pages = if (d.get("pages")) |p| p.arrayItems() else &[_]json.Value{};
        for (pages, 0..) |_, i| {
            // span==1 pages re-arm each turn (span values: 0 once, 1
            // per turn, 2 always).
            if (pageSpan(d, i) == 1) _ = self.event_flags.remove(i);
        }
        self.turn_count += 1;
    }

    fn pageSpan(d: json.Value, page_index: usize) i32 {
        const pages = if (d.get("pages")) |p| p.arrayItems() else &[_]json.Value{};
        if (page_index >= pages.len) return 0;
        return @intCast(pages[page_index].getInt("span", 0));
    }

    /// meetsConditions for a troop battle-event page.
    pub fn meetsPageConditions(self: *Troop, page: json.Value, party: *GameParty, actors: *GameActors, switches: *game_mod.Switches) bool {
        _ = party;
        const c = page.get("condition") orelse return false;
        const turn_valid = c.getBool("turnValid", false);
        if (turn_valid) {
            const a: i32 = @intCast(c.getInt("turnA", 0));
            const b: i32 = @intCast(c.getInt("turnB", 0));
            if (b == 0) {
                if (self.turn_count != a) return false;
            } else {
                if (!(self.turn_count >= a and @rem(self.turn_count, @max(b, 1)) == @rem(a, @max(b, 1)))) return false;
            }
        }
        const enemy_valid = c.getBool("enemyValid", false);
        if (enemy_valid) {
            const idx: i32 = @intCast(c.getInt("enemyIndex", 0));
            const hp_pct: i32 = @intCast(c.getInt("enemyHp", 0));
            const enemy = if (idx >= 0 and idx < self.enemies.items.len) self.enemies.items[@intCast(idx)] else null;
            if (enemy == null or enemy.?.hpRate() * 100 > @as(f64, @floatFromInt(hp_pct))) return false;
        }
        const actor_valid = c.getBool("actorValid", false);
        if (actor_valid) {
            const actor_id: i32 = @intCast(c.getInt("actorId", 0));
            const hp_pct: i32 = @intCast(c.getInt("actorHp", 0));
            const actor = actors.actor(actor_id);
            if (actor == null or @as(f64, @floatFromInt(actor.?.hp)) / @as(f64, @floatFromInt(@max(actor.?.paramMax(0), 1))) * 100 > @as(f64, @floatFromInt(hp_pct))) return false;
        }
        const switch_valid = c.getBool("switchValid", false);
        if (switch_valid) {
            const switch_id: i32 = @intCast(c.getInt("switchId", 0));
            if (!switches.value(@intCast(@max(switch_id, 1)))) return false;
        }
        return true;
    }

    /// setupBattleEvent: find the first unexecuted page whose conditions
    /// hold; returns its command list (caller runs the interpreter).
    pub fn findBattleEventPage(self: *Troop, party: *GameParty, actors: *GameActors, switches: *game_mod.Switches) ?[]const map_mod.Command {
        const d = self.troopData() orelse return null;
        const pages = if (d.get("pages")) |p| p.arrayItems() else &[_]json.Value{};
        for (pages, 0..) |page, i| {
            if (self.event_flags.get(i) orelse false) continue;
            if (!self.meetsPageConditions(page, party, actors, switches)) continue;
            const span = pageSpan(d, i);
            if (span <= 1) self.event_flags.put(i, true) catch {};
            log.event(.mv, .note, "troop battle event: troop {d} page {d} (span {d})", .{ self.troop_id, i + 1, span });
            if (page.get("list")) |lv| {
                return map_mod.parseCommands(self.alloc, lv) catch null;
            }
            return null;
        }
        return null;
    }

    // -- rewards ------------------------------------------------------------

    pub fn expTotal(self: *const Troop) i64 {
        var total: i64 = 0;
        for (self.enemies.items) |e| {
            if (e.isDead()) total += e.exp();
        }
        return total;
    }

    pub fn goldTotal(self: *const Troop) i64 {
        var total: i64 = 0;
        for (self.enemies.items) |e| {
            if (e.isDead()) total += e.gold();
        }
        return total;
    }

    pub fn makeDropItems(self: *Troop, rng: *Rng, drop_rate: f64) []GameEnemy.DropItem {
        var out = std.ArrayList(GameEnemy.DropItem).empty;
        defer out.deinit(self.alloc);
        for (self.enemies.items) |e| {
            if (!e.isDead()) continue;
            const items = e.makeDropItems(rng, drop_rate);
            defer self.alloc.free(items);
            for (items) |it| out.append(self.alloc, it) catch {};
        }
        return out.toOwnedSlice(self.alloc) catch &.{};
    }
};

// ---------------------------------------------------------------------------
// Damage formula evaluator — the payload's `a.atk * 4 - b.def * 2` forms
// ---------------------------------------------------------------------------

pub const FormulaError = error{ Syntax, UnknownIdent, OutOfMemory };

const TokenKind = enum { num, ident, lparen, rparen, lbracket, rbracket, add, sub, mul, div, mod, comma, dot };

const Token = struct {
    kind: TokenKind,
    num: f64 = 0,
    text: []const u8 = "",
};

/// Evaluate an MV damage formula. Supported: numbers, + - * / % ( ),
/// `a.<param>` / `b.<param>` (mhp mmp atk def mat mdf agi luk hp mp
/// level exp), `v[N]` game variables, `Math.floor/ceil/round/max/min`,
/// `Math.random()` (seeded), `a.isStateAffected(n)`/`b.isStateAffected(n)`.
pub const FormulaEnv = struct {
    db: *database.Database,
    variables: *game_mod.Variables,
    a: Battler,
    b: Battler,
    rng: *Rng,

    fn battlerParam(self: *const FormulaEnv, who: u8, name: []const u8) ?f64 {
        const bt = if (who == 'a') self.a else self.b;
        if (std.mem.eql(u8, name, "mhp")) return @floatFromInt(bt.mhp());
        if (std.mem.eql(u8, name, "mmp")) return @floatFromInt(bt.mmp());
        if (std.mem.eql(u8, name, "atk")) return @floatFromInt(bt.param(2));
        if (std.mem.eql(u8, name, "def")) return @floatFromInt(bt.param(3));
        if (std.mem.eql(u8, name, "mat")) return @floatFromInt(bt.param(4));
        if (std.mem.eql(u8, name, "mdf")) return @floatFromInt(bt.param(5));
        if (std.mem.eql(u8, name, "agi")) return @floatFromInt(bt.param(6));
        if (std.mem.eql(u8, name, "luk")) return @floatFromInt(bt.param(7));
        if (std.mem.eql(u8, name, "hp")) return @floatFromInt(bt.hp());
        if (std.mem.eql(u8, name, "mp")) return @floatFromInt(bt.mp());
        if (std.mem.eql(u8, name, "level")) {
            return switch (bt) {
                .actor => |act| @floatFromInt(act.level),
                .enemy => 1,
            };
        }
        if (std.mem.eql(u8, name, "exp")) {
            return switch (bt) {
                .actor => |act| @floatFromInt(act.exp),
                .enemy => |e| @floatFromInt(e.exp()),
            };
        }
        return null;
    }
};

const FormulaParser = struct {
    src: []const u8,
    pos: usize = 0,
    env: *const FormulaEnv,

    fn peek(self: *FormulaParser) !Token {
        var i = self.pos;
        while (i < self.src.len and (self.src[i] == ' ' or self.src[i] == '\t' or self.src[i] == '\n' or self.src[i] == '\r')) i += 1;
        if (i >= self.src.len) return error.Syntax;
        const c = self.src[i];
        switch (c) {
            '(' => return .{ .kind = .lparen },
            ')' => return .{ .kind = .rparen },
            '[' => return .{ .kind = .lbracket },
            ']' => return .{ .kind = .rbracket },
            '+' => return .{ .kind = .add },
            '-' => return .{ .kind = .sub },
            '*' => return .{ .kind = .mul },
            '/' => return .{ .kind = .div },
            '%' => return .{ .kind = .mod },
            ',' => return .{ .kind = .comma },
            '.' => {
                // JS float literal with a leading dot: `.50` (the real
                // payload's enemy skills use e.g. `b.mhp * .50`). JS
                // member access is never dot+digit (`a.5` is invalid),
                // so a dot followed by a digit is always a number.
                if (i + 1 < self.src.len and self.src[i + 1] >= '0' and self.src[i + 1] <= '9') {
                    var j = i + 1;
                    while (j < self.src.len and ((self.src[j] >= '0' and self.src[j] <= '9') or self.src[j] == '.')) j += 1;
                    const num = std.fmt.parseFloat(f64, self.src[i..j]) catch return error.Syntax;
                    return .{ .kind = .num, .num = num };
                }
                return .{ .kind = .dot };
            },
            '0'...'9' => {
                var j = i;
                while (j < self.src.len and ((self.src[j] >= '0' and self.src[j] <= '9') or self.src[j] == '.')) j += 1;
                const num = std.fmt.parseFloat(f64, self.src[i..j]) catch return error.Syntax;
                return .{ .kind = .num, .num = num };
            },
            'a'...'z', 'A'...'Z', '_', '$' => {
                var j = i;
                while (j < self.src.len and ((self.src[j] >= 'a' and self.src[j] <= 'z') or (self.src[j] >= 'A' and self.src[j] <= 'Z') or self.src[j] == '_' or (self.src[j] >= '0' and self.src[j] <= '9') or self.src[j] == '$')) j += 1;
                return .{ .kind = .ident, .text = self.src[i..j] };
            },
            else => return error.Syntax,
        }
    }

    fn next(self: *FormulaParser) !Token {
        const t = try self.peek();
        // advance past the token
        while (self.pos < self.src.len and (self.src[self.pos] == ' ' or self.src[self.pos] == '\t' or self.src[self.pos] == '\n' or self.src[self.pos] == '\r')) self.pos += 1;
        if (self.pos >= self.src.len) return error.Syntax;
        switch (self.src[self.pos]) {
            '(', ')', '[', ']', '+', '-', '*', '/', '%', ',' => self.pos += 1,
            '.' => {
                // mirror peek(): dot+digit is a leading-dot float
                if (self.pos + 1 < self.src.len and self.src[self.pos + 1] >= '0' and self.src[self.pos + 1] <= '9') {
                    while (self.pos < self.src.len and ((self.src[self.pos] >= '0' and self.src[self.pos] <= '9') or self.src[self.pos] == '.')) self.pos += 1;
                } else {
                    self.pos += 1;
                }
            },
            '0'...'9' => {
                while (self.pos < self.src.len and ((self.src[self.pos] >= '0' and self.src[self.pos] <= '9') or self.src[self.pos] == '.')) self.pos += 1;
            },
            'a'...'z', 'A'...'Z', '_', '$' => {
                while (self.pos < self.src.len and ((self.src[self.pos] >= 'a' and self.src[self.pos] <= 'z') or (self.src[self.pos] >= 'A' and self.src[self.pos] <= 'Z') or self.src[self.pos] == '_' or (self.pos < self.src.len and (self.src[self.pos] >= '0' and self.src[self.pos] <= '9')) or self.src[self.pos] == '$')) self.pos += 1;
            },
            else => return error.Syntax,
        }
        return t;
    }

    /// expr := term (('+'|'-') term)*
    fn parseExpr(self: *FormulaParser) anyerror!f64 {
        var left = try self.parseTerm();
        while (true) {
            const t = self.peek() catch break;
            switch (t.kind) {
                .add => {
                    _ = try self.next();
                    left += try self.parseTerm();
                },
                .sub => {
                    _ = try self.next();
                    left -= try self.parseTerm();
                },
                else => break,
            }
        }
        return left;
    }

    /// term := factor (('*'|'/'|'%') factor)*
    fn parseTerm(self: *FormulaParser) anyerror!f64 {
        var left = try self.parseFactor();
        while (true) {
            const t = self.peek() catch break;
            switch (t.kind) {
                .mul => {
                    _ = try self.next();
                    left *= try self.parseFactor();
                },
                .div => {
                    _ = try self.next();
                    const r = try self.parseFactor();
                    left = if (r != 0) left / r else 0;
                },
                .mod => {
                    _ = try self.next();
                    const r = try self.parseFactor();
                    const lr = @round(left);
                    const rr = @round(r);
                    left = if (rr != 0) @mod(lr, rr) else 0;
                },
                else => break,
            }
        }
        return left;
    }

    /// factor := number | ident-chain | '(' expr ')' | '-' factor
    fn parseFactor(self: *FormulaParser) anyerror!f64 {
        const t = try self.next();
        switch (t.kind) {
            .num => return t.num,
            .sub => return -(try self.parseFactor()),
            .add => return try self.parseFactor(),
            .lparen => {
                const v = try self.parseExpr();
                const close = try self.next();
                if (close.kind != .rparen) return error.Syntax;
                return v;
            },
            .ident => return try self.parseIdentChain(t.text),
            else => return error.Syntax,
        }
    }

    /// ident-chain: a.atk, v[3], Math.floor(x), Math.random(),
    /// a.isStateAffected(4)
    fn parseIdentChain(self: *FormulaParser, first: []const u8) anyerror!f64 {
        // v[N] or v(N) — game variable
        if (std.mem.eql(u8, first, "v")) {
            const open = try self.next();
            if (open.kind != .lparen and open.kind != .lbracket) return error.Syntax;
            const idx_tok = try self.next();
            var idx: f64 = 0;
            if (idx_tok.kind == .num) {
                idx = idx_tok.num;
                _ = try self.next(); // ) or ]
            } else return error.Syntax;
            const v = self.env.variables.value(@intCast(@max(@as(i64, @intFromFloat(idx)), 1)));
            return @floatFromInt(v);
        }
        // a / b — subject or target
        if (std.mem.eql(u8, first, "a") or std.mem.eql(u8, first, "b")) {
            const who: u8 = first[0];
            const dot = self.peek() catch return error.Syntax;
            if (dot.kind == .dot) {
                _ = try self.next();
                const prop = try self.next();
                if (prop.kind != .ident) return error.Syntax;
                if (std.mem.eql(u8, prop.text, "isStateAffected")) {
                    const open = try self.next();
                    if (open.kind != .lparen) return error.Syntax;
                    const sid = try self.next();
                    const close = try self.next();
                    _ = close;
                    if (sid.kind != .num) return error.Syntax;
                    const affected = if (who == 'a') self.env.a.isStateAffected(@intFromFloat(sid.num)) else self.env.b.isStateAffected(@intFromFloat(sid.num));
                    return if (affected) 1 else 0;
                }
                if (self.env.battlerParam(who, prop.text)) |v| return v;
                return error.UnknownIdent;
            }
            return error.UnknownIdent;
        }
        // Math.floor / Math.ceil / Math.round / Math.max / Math.min / Math.random
        if (std.mem.eql(u8, first, "Math")) {
            const dot = try self.next();
            if (dot.kind != .dot) return error.Syntax;
            const func = try self.next();
            if (func.kind != .ident) return error.Syntax;
            const open = try self.next();
            if (open.kind != .lparen) return error.Syntax;
            if (std.mem.eql(u8, func.text, "random")) {
                _ = try self.next(); // )
                return self.env.rng.float();
            }
            const arg1 = try self.parseExpr();
            var result: f64 = arg1;
            const t = self.peek() catch return error.Syntax;
            if (t.kind == .comma) {
                _ = try self.next();
                const arg2 = try self.parseExpr();
                if (std.mem.eql(u8, func.text, "max")) result = @max(arg1, arg2);
                if (std.mem.eql(u8, func.text, "min")) result = @min(arg1, arg2);
            } else {
                if (std.mem.eql(u8, func.text, "floor")) result = @floor(arg1);
                if (std.mem.eql(u8, func.text, "ceil")) result = @ceil(arg1);
                if (std.mem.eql(u8, func.text, "round")) result = @round(arg1);
            }
            const close = try self.next();
            if (close.kind != .rparen) return error.Syntax;
            return result;
        }
        return error.UnknownIdent;
    }
};

/// Evaluate a damage formula string; 0 on failure (MV catch → 0).
pub fn evalFormula(src: []const u8, env: *const FormulaEnv) f64 {
    var parser = FormulaParser{ .src = src, .env = env };
    const v = parser.parseExpr() catch {
        log.detail(.mv, "damage formula eval failed: '{s}'", .{src});
        return 0;
    };
    // MV: Math.max(eval, 0) * sign — the sign handling lives in the
    // caller (recovery types 3/4 invert).
    return v;
}

// ---------------------------------------------------------------------------
// BattleManager
// ---------------------------------------------------------------------------

pub const Phase = enum {
    init,
    start,
    input,
    turn,
    action,
    turn_end,
    aborting,
    battle_end,

    pub fn name(self: Phase) []const u8 {
        return @tagName(self);
    }
};

pub const BattleResult = enum(i32) {
    win = 0,
    escape = 1,
    lose = 2,
};

pub const ActionOrderEntry = struct {
    battler: Battler,
    speed: f64,
};

/// The battle driver. Owns the flow from setup() to a BattleResult;
/// the interpreter's command 301 runs it atomically (headless contract:
/// same observable state outcome as the frame-paced MV scene).
pub const Manager = struct {
    alloc: std.mem.Allocator,
    db: *database.Database,
    game: *game_mod.GameObjects,
    troop: *Troop,
    rng: Rng,

    phase: Phase = .init,
    can_escape: bool = false,
    can_lose: bool = false,
    preemptive: bool = false,
    surprise: bool = false,
    escaped: bool = false,
    escape_ratio: f64 = 0,
    result: ?BattleResult = null,
    rewards_gold: i64 = 0,
    rewards_exp: i64 = 0,
    rewards_items: []GameEnemy.DropItem = &.{},
    action_queue: std.ArrayList(Battler),
    subject: ?Battler = null,
    /// Party actions set by the driver (scripted input): per-actor
    /// (skill_id | item) — default attack.
    party_skill_ids: []const i32 = &.{},
    /// Original unit index chosen in the battle target window, or -1
    /// for automatic targeting. Dead selections retarget a living unit.
    party_target_index: i32 = -1,
    /// Confirmed commands in party input order. Backtracking simply pops the
    /// last choice. Inventory and JUICE are spent only when actions execute.
    party_commands: std.ArrayList(Action) = .empty,
    turn_limit: i32 = 200, // safety bound (infinite-loop guard)
    turns_executed: i32 = 0,
    commands_executed: i64 = 0,

    pub fn init(alloc: std.mem.Allocator, db: *database.Database, game: *game_mod.GameObjects, troop: *Troop, seed: u64) Manager {
        return .{
            .alloc = alloc,
            .db = db,
            .game = game,
            .troop = troop,
            .rng = Rng.init(seed),
            .action_queue = .empty,
        };
    }

    pub fn deinit(self: *Manager) void {
        self.party_commands.deinit(self.alloc);
        self.action_queue.deinit(self.alloc);
        if (self.rewards_items.len > 0) self.alloc.free(self.rewards_items);
        if (self.party_skill_ids.len > 0) self.alloc.free(self.party_skill_ids);
    }

    // -- BattleManager.setup ------------------------------------------------

    pub fn setup(self: *Manager, troop_id: i32, can_escape: bool, can_lose: bool) void {
        self.phase = .init;
        self.can_escape = can_escape;
        self.can_lose = can_lose;
        self.preemptive = false;
        self.surprise = false;
        self.escaped = false;
        self.result = null;
        self.rewards_gold = 0;
        self.rewards_exp = 0;
        self.rewards_items = &.{};
        self.action_queue.clearRetainingCapacity();
        self.party_commands.clearRetainingCapacity();
        self.subject = null;
        self.turns_executed = 0;
        self.troop.setup(troop_id, self.game);
        self.game.party.in_battle = true;
        self.troop.in_battle = true;
        // makeEscapeRatio: 1.5 * party agi / troop agi (clamped 0..1)
        self.escape_ratio = self.computeEscapeRatio();
        log.event(.mv, .info, "BattleManager.setup: troop {d} canEscape={s} canLose={s} escapeRatio={d:.2}", .{
            troop_id, if (can_escape) "true" else "false", if (can_lose) "true" else "false", self.escape_ratio,
        });
    }

    fn computeEscapeRatio(self: *Manager) f64 {
        var party_agi: f64 = 0;
        var n: f64 = 0;
        for (self.game.party.members.items) |id| {
            if (self.game.actors.actor(id)) |a| {
                party_agi += @floatFromInt(a.param(6));
                n += 1;
            }
        }
        var troop_agi: f64 = 0;
        var m: f64 = 0;
        for (self.troop.enemies.items) |e| {
            if (!e.isAlive()) continue;
            troop_agi += @floatFromInt(e.param(6));
            m += 1;
        }
        if (m == 0) return 1.0;
        const ratio = 1.5 * (party_agi / n) / (troop_agi / m);
        return std.math.clamp(ratio, 0.0, 1.0);
    }

    // -- startBattle / startInput / startTurn -------------------------------

    pub fn startBattle(self: *Manager) void {
        self.phase = .start;
        self.game.system.battle_count += 1;
        // displayStartMessages: '%1 emerged!' into the message window
        for (self.troop.enemies.items) |e| {
            if (e.isAppeared()) {
                if (std.fmt.allocPrint(self.alloc, "{s} appeared!", .{e.name()})) |message| {
                    self.game.message.addOwned(message);
                } else |_| self.game.message.add("An enemy appeared!");
            }
        }
        log.event(.mv, .note, "battle start: {d} vs {d} enemy(ies)", .{ self.game.party.members.items.len, self.troop.enemies.items.len });
    }

    /// startInput: party scripted actions + enemy AI actions.
    pub fn startInput(self: *Manager) void {
        self.phase = .input;
        // Party makeActions — scripted: default attack or the provided
        // skill sequence (cycled per member).
        for (self.game.party.members.items, 0..) |id, i| {
            const actor = self.game.actors.actor(id) orelse continue;
            var skill_id: i32 = actor.battleAttackSkillId();
            if (self.party_skill_ids.len > 0) {
                skill_id = self.party_skill_ids[i % self.party_skill_ids.len];
            }
            actor.queueAction(.{ .kind = if (skillData(self.db, skill_id) != null) .skill else .attack, .skill_id = skill_id, .item_id = 0, .target_index = self.party_target_index, .subject_is_enemy = false, .subject_index = @intCast(@max(actor.actor_id, 0)) });
        }
        self.prepareEnemies();
    }

    pub fn nextCommandActor(self: *Manager) ?*GameActor {
        for (self.game.party.members.items) |id| {
            const actor = self.game.actors.actor(id) orelse continue;
            if (actor.hp <= 0) continue;
            for (self.party_commands.items) |chosen| {
                if (chosen.subject_index == actor.actor_id) break;
            } else return actor;
        }
        return null;
    }

    pub fn freeItemCount(self: *Manager, item_id: i32) i64 {
        var count = self.game.party.numItems(item_id);
        const data = itemData(self.db, item_id) orelse return 0;
        if (data.getBool("consumable", true)) {
            for (self.party_commands.items) |chosen| {
                if (chosen.kind == .item and chosen.item_id == item_id) count -= 1;
            }
        }
        return @max(count, 0);
    }

    pub fn startSelectedInput(self: *Manager) void {
        self.phase = .input;
        for (self.game.party.members.items) |id| {
            if (self.game.actors.actor(id)) |actor| actor.battle_action = null;
        }
        for (self.party_commands.items) |chosen| {
            const actor = self.game.actors.actor(@intCast(chosen.subject_index)) orelse continue;
            if (actor.hp > 0) actor.queueAction(chosen);
        }
        self.party_commands.clearRetainingCapacity();
        self.prepareEnemies();
    }

    fn prepareEnemies(self: *Manager) void {
        for (self.troop.enemies.items) |e| {
            if (e.isAlive()) {
                e.makeActions(self.troop.turn_count, &self.game.party, &self.game.actors, &self.game.switches, &self.rng);
            }
        }
    }

    pub fn startTurn(self: *Manager) void {
        self.phase = .turn;
        self.troop.increaseTurn();
        self.makeActionOrders();
        log.detail(.mv, "turn {d} begins: {d} battler(s) in order", .{ self.troop.turn_count, self.action_queue.items.len });
    }

    fn actionPriority(self: *Manager, action: ?Action) i64 {
        const chosen = action orelse return 0;
        const data = chosen.item(self.db) orelse return 0;
        return data.getInt("speed", 0);
    }

    /// Apply the selected skill/item speed to the battler's initiative.
    /// A multi-action enemy's slowest action determines its turn position.
    fn makeActionOrders(self: *Manager) void {
        self.action_queue.clearRetainingCapacity();
        var entries = std.ArrayList(ActionOrderEntry).empty;
        defer entries.deinit(self.alloc);
        if (!self.surprise) {
            for (self.game.party.members.items) |id| {
                const actor = self.game.actors.actor(id) orelse continue;
                if (actor.hp > 0) {
                    const speed = @as(f64, @floatFromInt(actor.param(6))) + @as(f64, @floatFromInt(self.actionPriority(actor.battle_action))) + self.rng.float() * 5.0;
                    entries.append(self.alloc, .{ .battler = .{ .actor = actor }, .speed = speed }) catch {};
                }
            }
        }
        if (!self.preemptive) {
            for (self.troop.enemies.items) |e| {
                if (e.isAlive()) {
                    var priority: i64 = 0;
                    for (e.actions.items, 0..) |action, i| {
                        const modifier = self.actionPriority(action);
                        priority = if (i == 0) modifier else @min(priority, modifier);
                    }
                    const speed = @as(f64, @floatFromInt(e.param(6))) + @as(f64, @floatFromInt(priority)) + self.rng.float() * 5.0;
                    entries.append(self.alloc, .{ .battler = .{ .enemy = e }, .speed = speed }) catch {};
                }
            }
        }
        std.mem.sort(ActionOrderEntry, entries.items, {}, struct {
            fn lessThan(_: void, a: ActionOrderEntry, b: ActionOrderEntry) bool {
                return a.speed > b.speed;
            }
        }.lessThan);
        for (entries.items) |e| self.action_queue.append(self.alloc, e.battler) catch {};
    }

    // -- turn engine ---------------------------------------------------------

    /// updateTurn: pop the next subject; process its action(s).
    pub fn updateTurn(self: *Manager) void {
        if (self.subject == null) {
            self.subject = self.getNextSubject();
        }
        if (self.subject) |subj| {
            self.processSubject(subj);
        } else {
            self.endTurn();
        }
    }

    fn getNextSubject(self: *Manager) ?Battler {
        while (self.action_queue.items.len > 0) {
            const b = self.action_queue.orderedRemove(0);
            const alive = switch (b) {
                .actor => |a| a.hp > 0,
                .enemy => |e| e.isAlive(),
            };
            if (alive) return b;
        }
        return null;
    }

    fn processSubject(self: *Manager, subj: Battler) void {
        switch (subj) {
            .actor => |a| {
                if (a.dequeueAction()) |action| {
                    self.runAction(subj, action);
                    return;
                }
                // No action: onAllActionsEnd → next subject
                self.subject = self.getNextSubject();
            },
            .enemy => |e| {
                if (e.actions.items.len > 0) {
                    const action = e.actions.orderedRemove(0);
                    self.runAction(subj, action);
                    return;
                }
                self.subject = self.getNextSubject();
            },
        }
    }

    /// endTurn: state turns tick down (regeneration/slip damage are
    /// state effects — logged), then back to input.
    fn endTurn(self: *Manager) void {
        self.phase = .turn_end;
        self.preemptive = false;
        self.surprise = false;
        self.tickStates();
        self.turns_executed += 1;
    }

    /// State auto-removal: decrement turns, remove expired.
    fn tickStates(self: *Manager) void {
        for (self.game.party.members.items) |id| {
            if (self.game.actors.actor(id)) |a| a.tickStateTurns();
        }
        for (self.troop.enemies.items) |e| {
            var expired = std.ArrayList(i32).empty;
            defer expired.deinit(self.alloc);
            var it = e.states.iterator();
            while (it.next()) |kv| {
                if (kv.value_ptr.* > 0) {
                    kv.value_ptr.* -= 1;
                    if (kv.value_ptr.* <= 0) expired.append(self.alloc, kv.key_ptr.*) catch {};
                }
            }
            for (expired.items) |sid| {
                log.detail(.mv, "enemy {d} state {d} expired", .{ e.index, sid });
                _ = e.states.remove(sid);
            }
        }
    }

    // -- action execution (Game_Action.apply contract) -----------------------

    fn runAction(self: *Manager, subject: Battler, action: Action) void {
        self.commands_executed += 1;
        // Recheck at execution: an earlier action may drain JUICE or
        // consume the last item after the command window was shown.
        if (!self.canUseAction(subject, action)) return;
        const item_opt = action.item(self.db);
        if (item_opt == null) {
            log.detail(.mv, "action has no item data — skipped", .{});
            return;
        }
        const item: json.Value = item_opt.?;
        const targets = self.makeTargets(subject, item, action.target_index, action.target_friends);
        defer self.alloc.free(targets);
        log.detail(.mv, "action: '{s}' uses '{s}' → {d} target(s)", .{ subject.name(), item.getString("name") orelse "?", targets.len });

        // MV useItem pays once, before repeats or target iteration.
        if (action.kind == .item) {
            if (item.getBool("consumable", true)) self.game.party.gainItem(action.item_id, -1);
        } else self.payCost(subject, item);

        const repeats = std.math.clamp(item.getInt("repeats", 1), 1, 100);
        for (targets) |target| {
            var repeat: i64 = 0;
            while (repeat < repeats) : (repeat += 1) self.invokeAction(subject, target, action, item);
        }
        // TP gain for physical hit — OMORI no-op (logged)
    }

    fn makeTargets(self: *Manager, subject: Battler, item: json.Value, target_index: i32, target_friends: ?bool) []Battler {
        const scope = if (target_friends) |friends| @as(i64, if (friends) 7 else 1) else item.getInt("scope", 1);
        var targets = std.ArrayList(Battler).empty;
        defer targets.deinit(self.alloc);
        switch (scope) {
            1, 7 => { // one living opponent / one living ally
                const pool = if (scope == 1) self.opponentsOf(subject) else self.friendsOf(subject);
                defer self.alloc.free(pool);
                if (pool.len > 0) {
                    var selected: ?Battler = null;
                    if (target_index >= 0) for (pool) |candidate| {
                        if (self.unitIndex(candidate) == target_index) {
                            selected = candidate;
                            break;
                        }
                    };
                    targets.append(self.alloc, selected orelse pool[self.rng.int(@intCast(pool.len))]) catch {};
                }
            },
            2, 8 => { // all enemies / all allies
                const pool = if (scope == 2) self.opponentsOf(subject) else self.friendsOf(subject);
                defer self.alloc.free(pool);
                targets.appendSlice(self.alloc, pool) catch {};
            },
            9, 10 => { // one dead ally / all dead allies
                const dead = self.deadFriendsOf(subject);
                defer self.alloc.free(dead);
                if (scope == 10) {
                    targets.appendSlice(self.alloc, dead) catch {};
                } else if (dead.len > 0) {
                    var selected = dead[0];
                    for (dead) |candidate| {
                        if (self.unitIndex(candidate) == target_index) selected = candidate;
                    }
                    targets.append(self.alloc, selected) catch {};
                }
            },
            3...6 => { // random opponents x1, x2, x3, x4 (with replacement)
                const pool = self.opponentsOf(subject);
                defer self.alloc.free(pool);
                if (pool.len > 0) {
                    var n: i64 = 0;
                    while (n < scope - 2) : (n += 1) targets.append(self.alloc, pool[self.rng.int(@intCast(pool.len))]) catch {};
                }
            },
            11 => targets.append(self.alloc, subject) catch {}, // user
            else => {}, // none
        }
        return targets.toOwnedSlice(self.alloc) catch &.{};
    }

    fn unitIndex(self: *Manager, battler: Battler) i32 {
        return switch (battler) {
            .enemy => |enemy| @intCast(enemy.index),
            .actor => |actor| blk: {
                for (self.game.party.members.items, 0..) |id, index| {
                    if (id == actor.actor_id) break :blk @intCast(index);
                }
                break :blk -1;
            },
        };
    }

    fn opponentsOf(self: *Manager, subject: Battler) []Battler {
        var out = std.ArrayList(Battler).empty;
        defer out.deinit(self.alloc);
        switch (subject) {
            .actor => for (self.troop.enemies.items) |e| {
                if (e.isAlive()) out.append(self.alloc, .{ .enemy = e }) catch {};
            },
            .enemy => for (self.game.party.members.items) |id| {
                if (self.game.actors.actor(id)) |a| {
                    if (a.hp > 0) out.append(self.alloc, .{ .actor = a }) catch {};
                }
            },
        }
        return out.toOwnedSlice(self.alloc) catch &.{};
    }

    fn friendsOf(self: *Manager, subject: Battler) []Battler {
        var out = std.ArrayList(Battler).empty;
        defer out.deinit(self.alloc);
        switch (subject) {
            .actor => for (self.game.party.members.items) |id| {
                if (self.game.actors.actor(id)) |a| {
                    if (a.hp > 0) out.append(self.alloc, .{ .actor = a }) catch {};
                }
            },
            .enemy => for (self.troop.enemies.items) |e| {
                if (e.isAlive()) out.append(self.alloc, .{ .enemy = e }) catch {};
            },
        }
        return out.toOwnedSlice(self.alloc) catch &.{};
    }

    fn deadFriendsOf(self: *Manager, subject: Battler) []Battler {
        var out = std.ArrayList(Battler).empty;
        defer out.deinit(self.alloc);
        switch (subject) {
            .actor => for (self.game.party.members.items) |id| {
                if (self.game.actors.actor(id)) |a| {
                    if (a.hp <= 0) out.append(self.alloc, .{ .actor = a }) catch {};
                }
            },
            .enemy => for (self.troop.enemies.items) |e| {
                if (e.isDead()) out.append(self.alloc, .{ .enemy = e }) catch {};
            },
        }
        return out.toOwnedSlice(self.alloc) catch &.{};
    }

    pub fn canUseAction(self: *Manager, subject: Battler, action: Action) bool {
        if (!subject.isAlive()) return false;
        const item = action.item(self.db) orelse return false;
        if (item.getInt("occasion", 0) >= 2) return false;
        if (action.kind == .item) {
            return subject == .actor and self.game.party.numItems(action.item_id) > 0;
        }
        const mp_cost = @max(item.getInt("mpCost", 0), 0);
        const tp_cost = @max(item.getInt("tpCost", 0), 0);
        return switch (subject) {
            .actor => |actor| actor.mp >= mp_cost and actor.tp >= tp_cost,
            .enemy => |enemy| enemy.mp >= mp_cost and enemy.tp >= tp_cost,
        };
    }

    fn payCost(self: *Manager, subject: Battler, item: json.Value) void {
        _ = self;
        const mp_cost: i32 = @intCast(@max(item.getInt("mpCost", 0), 0));
        const tp_cost: i32 = @intCast(@max(item.getInt("tpCost", 0), 0));
        switch (subject) {
            .actor => |a| {
                a.mp -= mp_cost;
                a.tp -= tp_cost;
            },
            .enemy => |e| {
                e.gainMp(-mp_cost);
                e.tp -= tp_cost;
            },
        }
    }

    /// invokeAction: counter-attack / reflection / substitute checks
    /// (traits 6/14 etc. — simplified to the common path; logged).
    fn invokeAction(self: *Manager, subject: Battler, target: Battler, action: Action, item: json.Value) void {
        _ = subject;
        _ = action;
        self.applyActionNoteStates(target, item);
        self.applyAction(target, item);
    }

    /// A deliberately bounded action-sequence subset: whole-action state
    /// commands, literal target state tests, and equivalent EVAL calls.
    /// No arbitrary JavaScript is executed. Unknown conditions suppress
    /// their entire branch chain so an unknown IF cannot enable its ELSE.
    fn applyActionNoteStates(self: *Manager, target: Battler, item: json.Value) void {
        const note = item.getString("note") orelse return;
        const Branch = struct { parent: bool, active: bool, taken: bool, supported: bool };
        var branches: [16]Branch = undefined;
        var depth: usize = 0;
        var in_whole = false;
        var lines = std.mem.splitScalar(u8, note, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (std.ascii.eqlIgnoreCase(line, "<whole action>")) {
                in_whole = true;
                depth = 0;
                continue;
            }
            if (std.ascii.eqlIgnoreCase(line, "</whole action>")) {
                in_whole = false;
                depth = 0;
                continue;
            }
            if (!in_whole or line.len == 0) continue;
            if (std.ascii.startsWithIgnoreCase(line, "else if ")) {
                if (depth == 0) continue;
                const b = &branches[depth - 1];
                const condition = noteStateCondition(target, line[8..]);
                if (condition == null) b.supported = false;
                b.active = b.parent and b.supported and !b.taken and (condition orelse false);
                b.taken = b.taken or b.active;
                if (condition == null) self.logUnsupportedStateNote(line);
                continue;
            }
            if (std.ascii.eqlIgnoreCase(line, "else")) {
                if (depth > 0) {
                    const b = &branches[depth - 1];
                    b.active = b.parent and b.supported and !b.taken;
                    b.taken = true;
                }
                continue;
            }
            if (std.ascii.eqlIgnoreCase(line, "end") or std.ascii.eqlIgnoreCase(line, "end if")) {
                if (depth > 0) depth -= 1;
                continue;
            }
            if (std.ascii.startsWithIgnoreCase(line, "if ")) {
                if (depth == branches.len) {
                    self.logUnsupportedStateNote(line);
                    return;
                }
                const parent = depth == 0 or branches[depth - 1].active;
                const condition = noteStateCondition(target, line[3..]);
                const active = parent and (condition orelse false);
                branches[depth] = .{ .parent = parent, .active = active, .taken = active, .supported = condition != null };
                depth += 1;
                if (condition == null) self.logUnsupportedStateNote(line);
                continue;
            }
            if (depth > 0 and !branches[depth - 1].active) continue;
            const op = parseNoteStateOperation(line) orelse {
                self.logUnsupportedStateNote(line);
                continue;
            };
            if (stateData(self.db, op.state_id) == null) {
                self.logUnsupportedStateNote(line);
                continue;
            }
            if (op.add) target.addState(self.db, op.state_id) else target.removeState(op.state_id);
            log.detail(.mv, "action note: '{s}' {s}state {d}", .{ target.name(), if (op.add) "+" else "-", op.state_id });
        }
    }

    fn logUnsupportedStateNote(self: *Manager, line: []const u8) void {
        _ = self;
        log.detail(.mv, "unsupported action-note state statement: {s}", .{line});
    }

    fn noteStateCondition(target: Battler, raw: []const u8) ?bool {
        var condition = std.mem.trim(u8, raw, " \t");
        while (condition.len >= 2 and condition[0] == '(' and condition[condition.len - 1] == ')') condition = std.mem.trim(u8, condition[1 .. condition.len - 1], " \t");
        var invert = false;
        if (std.mem.startsWith(u8, condition, "!")) {
            invert = true;
            condition = std.mem.trim(u8, condition[1..], " \t");
        }
        const prefix = "target.isStateAffected(";
        if (!std.mem.startsWith(u8, condition, prefix) or !std.mem.endsWith(u8, condition, ")")) return null;
        const state_id = std.fmt.parseInt(i32, std.mem.trim(u8, condition[prefix.len .. condition.len - 1], " \t"), 10) catch return null;
        const affected = target.isStateAffected(state_id);
        return if (invert) !affected else affected;
    }

    const NoteStateOperation = struct { add: bool, state_id: i32 };

    fn parseNoteStateOperation(raw: []const u8) ?NoteStateOperation {
        var line = std.mem.trim(u8, raw, " \t");
        if (std.ascii.startsWithIgnoreCase(line, "eval:")) line = std.mem.trim(u8, line[5..], " \t");
        if (std.mem.endsWith(u8, line, ";")) line = std.mem.trim(u8, line[0 .. line.len - 1], " \t");
        inline for (.{ .{ "target.addState(", true }, .{ "target.removeState(", false } }) |form| {
            if (std.mem.startsWith(u8, line, form[0]) and std.mem.endsWith(u8, line, ")")) {
                const id = std.fmt.parseInt(i32, std.mem.trim(u8, line[form[0].len .. line.len - 1], " \t"), 10) catch return null;
                return if (id > 0) .{ .add = form[1], .state_id = id } else null;
            }
        }
        inline for (.{ .{ "add state ", true }, .{ "remove state ", false } }) |form| {
            if (std.ascii.startsWithIgnoreCase(line, form[0])) {
                const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
                if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[colon + 1 ..], " \t"), "target")) return null;
                const id = std.fmt.parseInt(i32, std.mem.trim(u8, line[form[0].len..colon], " \t"), 10) catch return null;
                return if (id > 0) .{ .add = form[1], .state_id = id } else null;
            }
        }
        return null;
    }

    /// Game_Action.apply on one target: hit/eva → damage → effects.
    fn applyAction(self: *Manager, target: Battler, item: json.Value) void {
        const success_rate: f64 = @as(f64, @floatFromInt(item.getInt("successRate", 95))) / 100.0;
        const hit_rate = if (self.currentSubjectIsPhysical()) success_rate else success_rate;
        const roll = self.rng.float();
        if (roll >= hit_rate) {
            log.detail(.mv, "action on '{s}' missed (roll {d:.2} vs {d:.2})", .{ target.name(), roll, hit_rate });
            return;
        }
        if (item.get("damage")) |dmg| {
            const dmg_type = dmg.getInt("type", 0);
            if (dmg_type > 0) {
                const value = self.makeDamageValue(target, dmg);
                self.executeDamage(target, dmg_type, value);
            }
        }
        // item effects
        const effects = if (item.get("effects")) |ef| ef.arrayItems() else &[_]json.Value{};
        for (effects) |ef| {
            self.applyItemEffect(target, ef);
        }
    }

    fn currentSubjectIsPhysical(self: *Manager) bool {
        const s = self.subject orelse return false;
        _ = s;
        return true; // OMORI's skills are overwhelmingly physical-type
    }

    fn makeDamageValue(self: *Manager, target: Battler, dmg: json.Value) i64 {
        const formula = dmg.getString("formula") orelse "0";
        const subject = self.subject orelse return 0;
        var env = FormulaEnv{
            .db = self.db,
            .variables = &self.game.variables,
            .a = subject,
            .b = target,
            .rng = &self.rng,
        };
        var base = evalFormula(formula, &env);
        if (base < 0) base = 0;
        // sign: damage types 3/4 = recovery → negative for HP gain
        const dtype = dmg.getInt("type", 0);
        if (dtype == 3 or dtype == 4) base = -base;
        // element rate
        const element_id = dmg.getInt("elementId", -1);
        if (element_id > 0) {
            base *= self.elementRate(target, element_id);
        }
        // variance
        const variance = dmg.getInt("variance", 0);
        if (variance > 0) {
            const amp = @floor(@abs(base) * @as(f64, @floatFromInt(variance)) / 100.0);
            if (amp > 0) {
                const r1: i64 = self.rng.int(@intFromFloat(amp + 1));
                const r2: i64 = self.rng.int(@intFromFloat(amp + 1));
                const v: i64 = r1 + r2 - @as(i64, @intFromFloat(amp));
                base += if (base >= 0) @as(f64, @floatFromInt(v)) else -@as(f64, @floatFromInt(v));
            }
        }
        // critical: 1/32 default chance (subject cri vs target cev)
        if (dmg.getInt("critical", 0) != 0) {
            if (self.rng.float() < 1.0 / 32.0) {
                base *= 3;
                log.detail(.mv, "CRITICAL on '{s}'!", .{target.name()});
            }
        }
        if (base > 0 and self.hasGuardState(target)) base *= 0.5;
        const rounded: i64 = @intFromFloat(@round(base));
        return rounded;
    }

    fn hasGuardState(self: *Manager, target: Battler) bool {
        var ids = switch (target) {
            .actor => |actor| actor.states.keyIterator(),
            .enemy => |enemy| enemy.states.keyIterator(),
        };
        while (ids.next()) |id| {
            const state = stateData(self.db, id.*) orelse continue;
            const traits = state.get("traits") orelse continue;
            for (traits.arrayItems()) |trait| {
                if (trait.getInt("code", 0) == 62 and trait.getInt("dataId", -1) == 1) return true;
            }
        }
        return false;
    }

    fn elementRate(self: *Manager, target: Battler, element_id: i64) f64 {
        _ = self;
        // Element rate: sum of trait code 11 rates on the target's
        // states/traits. Enemies: direct trait lookup. Default 1.0.
        switch (target) {
            .enemy => |e| {
                const rate = e.traitRateSum(11, @intCast(element_id)) + e.stateTraitRateSum(11, @intCast(element_id));
                return 1.0 + rate;
            },
            .actor => return 1.0, // actor element rates: equip traits (M10)
        }
    }

    fn executeDamage(self: *Manager, target: Battler, dmg_type: i64, value: i64) void {
        switch (dmg_type) {
            1, 5 => { // HP damage / HP drain
                const v: i32 = @intCast(value);
                self.gainHp(target, -v);
                log.detail(.mv, "damage: '{s}' takes {d} HP ({d} → {d})", .{ target.name(), v, target.hp() + v, target.hp() });
            },
            3 => { // HP recover
                const v: i32 = @intCast(-value);
                self.gainHp(target, v);
                log.detail(.mv, "recover: '{s}' gains {d} HP", .{ target.name(), v });
            },
            2, 6 => { // MP damage / MP drain
                self.gainMp(target, -@as(i32, @intCast(value)));
            },
            4 => { // MP recover
                self.gainMp(target, @intCast(-value));
            },
            else => {},
        }
    }

    fn gainHp(self: *Manager, target: Battler, value: i32) void {
        _ = self;
        switch (target) {
            .actor => |a| {
                const before = a.hp;
                a.gainHp(value);
                if (a.hp == 0 and before > 0) {
                    log.detail(.mv, "actor '{s}' died", .{a.name});
                }
            },
            .enemy => |e| e.gainHp(value),
        }
    }

    fn gainMp(self: *Manager, target: Battler, value: i32) void {
        _ = self;
        switch (target) {
            .actor => |a| a.gainMp(value),
            .enemy => |e| e.gainMp(value),
        }
    }

    /// Item effect application (the MV effect codes OMORI uses).
    fn applyItemEffect(self: *Manager, target: Battler, effect: json.Value) void {
        const code = effect.getInt("code", 0);
        const data_id: i32 = @intCast(effect.getInt("dataId", 0));
        const v1 = if (effect.get("value1")) |x| x.asFloat() else 0;
        const v2 = if (effect.get("value2")) |x| x.asFloat() else 0;
        switch (code) {
            11 => { // RECOVER_HP: mhp * v1 + v2
                const amount: i32 = @intFromFloat(@as(f64, @floatFromInt(target.mhp())) * v1 + v2);
                self.gainHp(target, amount);
                log.detail(.mv, "effect: '{s}' HP {d}", .{ target.name(), amount });
            },
            12 => { // RECOVER_MP
                const amount: i32 = @intFromFloat(@as(f64, @floatFromInt(target.mmp())) * v1 + v2);
                self.gainMp(target, amount);
            },
            13 => { // GAIN_TP (OMORI: unused)
            },
            21 => { // ADD_STATE
                target.addState(self.db, data_id);
                log.detail(.mv, "effect: '{s}' +state {d}", .{ target.name(), data_id });
            },
            22 => { // REMOVE_STATE
                target.removeState(data_id);
            },
            31, 32 => { // ADD_BUFF / ADD_DEBUFF (param dataId)
                const delta: i32 = if (code == 31) 1 else -1;
                self.applyBuff(target, @intCast(data_id), delta, @intFromFloat(v1));
            },
            33, 34 => { // REMOVE_BUFF / REMOVE_DEBUFF
                self.applyBuff(target, @intCast(data_id), 0, 0);
            },
            41 => { // SPECIAL (0 = escape)
                if (data_id == 0 and target.isEnemy()) {
                    log.detail(.mv, "special: '{s}' escapes battle", .{target.name()});
                }
            },
            42 => { // GROW: param dataId + v1
                switch (target) {
                    .actor => |a| a.param_plus[@intCast(@max(data_id, 0) & 7)] += @intFromFloat(v1),
                    .enemy => {},
                }
            },
            43 => { // LEARN_SKILL
                switch (target) {
                    .actor => |a| {
                        if (data_id > 0) a.learnSkill(data_id);
                        log.detail(.mv, "effect: '{s}' learned skill {d}", .{ a.name, data_id });
                    },
                    .enemy => {},
                }
            },
            44 => { // COMMON_EVENT — queued post-battle (logged)
                log.detail(.mv, "effect: common event {d} queued (post-battle)", .{data_id});
            },
            else => {},
        }
    }

    fn applyBuff(self: *Manager, target: Battler, param_id: usize, delta: i32, turns: i32) void {
        _ = turns;
        switch (target) {
            .actor => |a| {
                const slot = @min(param_id, 7);
                a.buffs[slot] = std.math.clamp(a.buffs[slot] + delta, -2, 2);
            },
            .enemy => |e| {
                const slot = @min(param_id, 7);
                e.buffs[slot] = std.math.clamp(e.buffs[slot] + delta, -2, 2);
            },
        }
        _ = self;
    }

    // -- battle end ------------------------------------------------------------

    pub fn checkBattleEnd(self: *Manager) bool {
        if (self.phase != .init) {
            // All enemies dead → victory
            if (self.troop.isAllDead()) {
                self.processVictory();
                return true;
            }
            // All party dead → defeat
            var all_dead = self.game.party.members.items.len > 0;
            for (self.game.party.members.items) |id| {
                if (self.game.actors.actor(id)) |a| {
                    if (a.hp > 0) all_dead = false;
                }
            }
            if (all_dead) {
                self.processDefeat();
                return true;
            }
        }
        return false;
    }

    fn processVictory(self: *Manager) void {
        self.game.system.win_count += 1;
        self.rewards_gold = self.troop.goldTotal();
        self.rewards_exp = self.troop.expTotal();
        self.rewards_items = self.troop.makeDropItems(&self.rng, 1.0);
        // gainRewards: exp/gold/drops
        self.game.party.gainGold(self.rewards_gold);
        self.game.party.gainExp(self.rewards_exp, self.db);
        for (self.rewards_items) |it| {
            if (it.kind == 1) self.game.party.gainItem(it.data_id, 1);
            if (it.kind == 2) self.game.party.gainWeapon(it.data_id, 1);
            if (it.kind == 3) self.game.party.gainArmor(it.data_id, 1);
        }
        self.result = .win;
        self.phase = .battle_end;
        log.event(.mv, .info, "BATTLE VICTORY: exp={d} gold={d} items={d} — battle #{d} won", .{
            self.rewards_exp, self.rewards_gold, self.rewards_items.len, self.game.system.battle_count,
        });
    }

    fn processDefeat(self: *Manager) void {
        self.result = .lose;
        self.phase = .battle_end;
        log.event(.mv, .info, "BATTLE DEFEAT (canLose={s})", .{if (self.can_lose) "true" else "false"});
    }

    /// processEscape — can be scripted (BattleDriver input).
    pub fn processEscape(self: *Manager) bool {
        const success = if (self.preemptive) true else (self.rng.float() < self.escape_ratio);
        if (success) {
            self.escaped = true;
            self.game.system.escape_count += 1;
            self.result = .escape;
            self.phase = .battle_end;
            log.event(.mv, .info, "BATTLE ESCAPED (ratio {d:.2})", .{self.escape_ratio});
        } else {
            self.escape_ratio += 0.1;
            // The interactive driver starts one enemy-only turn when the
            // attempt fails, releasing any commands already selected.
            self.party_commands.clearRetainingCapacity();
        }
        return success;
    }

    pub fn endBattle(self: *Manager) void {
        self.game.party.in_battle = false;
        self.troop.in_battle = false;
        // A victory can end a turn before state durations tick. Clear the
        // database's battle-only states before returning actors to the field.
        var expired = std.ArrayList(i32).empty;
        defer expired.deinit(self.alloc);
        for (self.game.party.members.items) |actor_id| {
            const actor = self.game.actors.actor(actor_id) orelse continue;
            actor.battle_action = null;
            expired.clearRetainingCapacity();
            var ids = actor.states.keyIterator();
            while (ids.next()) |id| {
                const state = stateData(self.db, id.*) orelse continue;
                if (state.getBool("removeAtBattleEnd", false)) expired.append(self.alloc, id.*) catch {};
            }
            for (expired.items) |id| actor.removeState(id);
        }
        self.phase = .battle_end;
        // onBattleWin / onBattleEscape bookkeeping
        if (self.result != null and self.result.? == .win) {
            // (battle_count already counted at setup)
        }
    }

    // -- the atomic battle runner -------------------------------------------

    /// Runs the whole battle to a terminal result (setup must have been
    /// called). Scripted party behavior: attacks / the provided skills.
    pub fn run(self: *Manager) BattleResult {
        self.startBattle();
        var guard: i32 = 0;
        while (guard < self.turn_limit) : (guard += 1) {
            self.startInput();
            self.startTurn();
            var subject_guard: i32 = 0;
            while (subject_guard < 200) : (subject_guard += 1) {
                if (self.checkBattleEnd()) {
                    self.endBattle();
                    return self.result orelse .win;
                }
                self.updateTurn();
                if (self.phase == .turn_end) break;
            }
            if (self.checkBattleEnd()) {
                self.endBattle();
                return self.result orelse .win;
            }
        }
        log.warn("battle turn limit ({d}) reached — forcing abort", .{self.turn_limit});
        self.result = .escape;
        self.endBattle();
        return .escape;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const vfs_mod = @import("../filesystem/vfs.zig");

/// Developer-selected battle for the input-driven validation path. Empty
/// separator troops and invalid enemies are never accepted as a fight.
pub fn useFieldItem(db: *database.Database, game: *game_mod.GameObjects, item_id: i32) bool {
    if (game.party.numItems(item_id) <= 0) return false;
    const item = itemData(db, item_id) orelse return false;
    const occasion = item.getInt("occasion", 0);
    if (occasion == 1 or occasion == 3) return false;
    const actor = game.party.leader() orelse return false;
    var used = false;
    if (item.get("damage")) |damage| {
        const kind = damage.getInt("type", 0);
        if ((kind == 3 and actor.hp < actor.param(0)) or (kind == 4 and actor.mp < actor.param(1))) {
            var rng = Rng.init(game.frame_count_global);
            const env = FormulaEnv{ .db = db, .variables = &game.variables, .a = .{ .actor = actor }, .b = .{ .actor = actor }, .rng = &rng };
            const amount = evalFormula(damage.getString("formula") orelse "0", &env);
            if (std.math.isFinite(amount) and amount > 0 and amount < @as(f64, @floatFromInt(std.math.maxInt(i32)))) {
                if (kind == 3) actor.gainHp(@intFromFloat(amount)) else actor.gainMp(@intFromFloat(amount));
                used = true;
            }
        }
    }
    const effects = if (item.get("effects")) |value| value.arrayItems() else &.{};
    for (effects) |effect| {
        const kind = effect.getInt("code", 0);
        if (kind == 11 or kind == 12) {
            const hp = kind == 11;
            const maximum = actor.param(if (hp) 0 else 1);
            const current = if (hp) actor.hp else actor.mp;
            const rate = if (effect.get("value1")) |v| v.asFloat() else 0;
            const flat = if (effect.get("value2")) |v| v.asFloat() else 0;
            const value = @floor(@as(f64, @floatFromInt(maximum)) * rate + flat);
            if (current < maximum and std.math.isFinite(value) and value > 0 and value <= @as(f64, @floatFromInt(std.math.maxInt(i32)))) {
                if (hp) actor.gainHp(@intFromFloat(value)) else actor.gainMp(@intFromFloat(value));
                used = true;
            }
        }
    }
    // A key item, a battle-only item, or an ineffective recovery remains
    // in the inventory. A successful nonconsumable effect remains too.
    if (used and item.getBool("consumable", true)) game.party.gainItem(item_id, -1);
    return used;
}

pub fn debugTroopOverride(db: *database.Database) ?i32 {
    const raw = std.posix.getenv("OMORI_DEBUG_TROOP") orelse return null;
    const id = std.fmt.parseInt(i32, raw, 10) catch return null;
    if (id <= 0) return null;
    const file = db.get("data/Troops.json") orelse return null;
    const troops = file.value.arrayItems();
    if (id >= troops.len) return null;
    const troop = troops[@intCast(id)];
    const members = if (troop.get("members")) |m| m.arrayItems() else return null;
    var visible = false;
    for (members) |member| {
        const enemy_id = std.math.cast(i32, member.getInt("enemyId", 0)) orelse return null;
        if (!Troop.enemyDataExistsPub(db, enemy_id)) return null;
        if (!member.getBool("hidden", false)) visible = true;
    }
    return if (visible) id else null;
}

fn buildBattleDb(alloc: std.mem.Allocator) !*database.Database {
    // Deterministic temp tree (the interpreter-test pattern).
    const root_path = try alloc.dupe(u8, "/tmp/omori-battle-db-test");
    std.fs.cwd().makePath(root_path) catch {};
    std.fs.cwd().deleteTree(root_path) catch {};
    std.fs.cwd().makePath(try std.fs.path.join(alloc, &.{ root_path, "data" })) catch {};
    // Note: tmpDir cleanup is manual here; the db keeps the path only.
    {
        const p = try std.fs.path.join(alloc, &.{ root_path, "data", "System.json" });
        defer alloc.free(p);
        var f = try std.fs.cwd().createFile(p, .{});
        defer f.close();
        try f.writeAll("{\"gameTitle\":\"BT\",\"switches\":[null,\"s1\"],\"variables\":[null,\"v1\"],\"partyMembers\":[1]}");
    }
    {
        const p = try std.fs.path.join(alloc, &.{ root_path, "data", "Actors.json" });
        defer alloc.free(p);
        var f = try std.fs.cwd().createFile(p, .{});
        defer f.close();
        try f.writeAll("[null,{\"id\":1,\"name\":\"OMORI\",\"nickname\":\"\",\"profile\":\"\",\"classId\":1,\"initialLevel\":1,\"maxLevel\":99,\"equips\":[1],\"characterName\":\"\",\"faceName\":\"\"}]");
    }
    {
        const p = try std.fs.path.join(alloc, &.{ root_path, "data", "Classes.json" });
        defer alloc.free(p);
        var f = try std.fs.cwd().createFile(p, .{});
        defer f.close();
        try f.writeAll("[null,{\"id\":1,\"name\":\"C\",\"expParams\":[30,20,30,30],\"params\":[[500,500],[500,500],[50,55],[20,21],[20,20],[20,20],[20,20],[20,20]],\"learnings\":[{\"level\":1,\"skillId\":1}]}]");
    }
    {
        // Enemy 1: 60 HP, 10 atk/def, 20 exp, 15 gold, one action.
        const p = try std.fs.path.join(alloc, &.{ root_path, "data", "Enemies.json" });
        defer alloc.free(p);
        var f = try std.fs.cwd().createFile(p, .{});
        defer f.close();
        try f.writeAll("[null,{\"id\":1,\"name\":\"LARVA\",\"battlerName\":\"larva\",\"battlerHue\":0,\"params\":[60,20,12,6,8,8,10,6],\"exp\":20,\"gold\":15,\"dropItems\":[{\"kind\":1,\"dataId\":3,\"denominator\":2}],\"actions\":[{\"skillId\":1,\"rating\":5,\"conditionType\":0,\"conditionParam1\":0,\"conditionParam2\":0}],\"traits\":[]}]");
    }
    {
        const p = try std.fs.path.join(alloc, &.{ root_path, "data", "Troops.json" });
        defer alloc.free(p);
        var f = try std.fs.cwd().createFile(p, .{});
        defer f.close();
        try f.writeAll("[null,{\"id\":1,\"name\":\"LARVA x2\",\"members\":[{\"enemyId\":1,\"x\":300,\"y\":200,\"hidden\":false},{\"enemyId\":1,\"x\":500,\"y\":200,\"hidden\":false}],\"pages\":[]}]");
    }
    {
        // Skill 1 = attack (MV): physical, 1 enemy, damage formula.
        const p = try std.fs.path.join(alloc, &.{ root_path, "data", "Skills.json" });
        defer alloc.free(p);
        var f = try std.fs.cwd().createFile(p, .{});
        defer f.close();
        try f.writeAll("[null,{\"id\":1,\"name\":\"Attack\",\"mpCost\":0,\"successRate\":100,\"hitType\":1,\"scope\":1,\"damage\":{\"type\":1,\"elementId\":-1,\"formula\":\"a.atk * 4 - b.def * 2\",\"variance\":20,\"critical\":true},\"effects\":[]},{\"id\":2,\"name\":\"Emotion Hit\",\"mpCost\":5,\"successRate\":100,\"hitType\":1,\"scope\":2,\"damage\":{\"type\":1,\"elementId\":-1,\"formula\":\"a.atk * 3 - b.def\",\"variance\":15,\"critical\":false},\"effects\":[{\"code\":21,\"dataId\":6,\"value1\":3,\"value2\":0}]}]");
    }
    {
        const p = try std.fs.path.join(alloc, &.{ root_path, "data", "States.json" });
        defer alloc.free(p);
        var f = try std.fs.cwd().createFile(p, .{});
        defer f.close();
        try f.writeAll("[null,{\"id\":1,\"name\":\"KO\",\"restriction\":4},null,null,null,null,{\"id\":6,\"name\":\"HAPPY\",\"minTurns\":3,\"maxTurns\":5,\"traits\":[]}]");
    }
    {
        const p = try std.fs.path.join(alloc, &.{ root_path, "data", "Items.json" });
        defer alloc.free(p);
        var f = try std.fs.cwd().createFile(p, .{});
        defer f.close();
        try f.writeAll("[null,null,null,{\"id\":3,\"name\":\"Toast\",\"iconIndex\":0}]");
    }
    const vfs = try alloc.create(vfs_mod.Vfs);
    vfs.* = vfs_mod.Vfs.init(alloc, root_path, "/tmp/omori-battle-save-test");
    const db = try alloc.create(database.Database);
    db.* = database.Database.init(alloc, vfs);
    for ([_][]const u8{ "data/System.json", "data/Actors.json", "data/Classes.json", "data/Enemies.json", "data/Troops.json", "data/Skills.json", "data/States.json", "data/Items.json" }) |f| {
        _ = try db.loadFile(.database, f);
    }
    return db;
}

fn freeBattleDb(alloc: std.mem.Allocator, db: *database.Database) void {
    db.vfs.deinit();
    alloc.destroy(db.vfs);
    db.deinit();
    alloc.destroy(db);
}

test "battle: formula evaluator (damage math)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const db = try buildBattleDb(a);
    defer freeBattleDb(a, db);
    var game = game_mod.GameObjects.init(a, &db.*);
    try game.create();
    try game.party.members.append(a, 1);
    _ = game.actors.actor(1);

    var troop = Troop.init(a, &db.*);
    defer troop.deinit();
    troop.setup(1, &game);
    try testing.expectEqual(@as(usize, 2), troop.enemies.items.len);

    var rng = Rng.init(42);
    var env = FormulaEnv{
        .db = &db.*,
        .variables = &game.variables,
        .a = .{ .actor = game.actors.actor(1).? },
        .b = .{ .enemy = troop.enemies.items[0] },
        .rng = &rng,
    };
    // OMORI-level actor: atk 50 (class params[0] level row → 500? our
    // class fixture: params[atk][level] with level 1 → 50).
    const atk = env.a.param(2);
    const def = env.b.param(3);
    const v = evalFormula("a.atk * 4 - b.def * 2", &env);
    try testing.expectEqual(atk * 4 - def * 2, @as(i64, @intFromFloat(v)));
    // v[1] game variable
    game.variables.setValue(1, 7);
    const v2 = evalFormula("v[1] * 10", &env);
    try testing.expectEqual(@as(f64, 70), v2);
    // Math.floor / Math.max
    const v3 = evalFormula("Math.floor(Math.max(a.atk / 3, 5))", &env);
    try testing.expectEqual(@floor(@as(f64, @floatFromInt(@divTrunc(atk, 3)))), v3);
    // isStateAffected
    const v4 = evalFormula("a.isStateAffected(6) + 1", &env);
    try testing.expectEqual(@as(f64, 1), v4);
    // unknown identifier → 0
    const v5 = evalFormula("a.nonsense + 1", &env);
    try testing.expectEqual(@as(f64, 0), v5);
    // v36: leading-dot JS float literals (real payload enemy skill
    // `b.mhp * .50`) — a dot followed by a digit is a number, member
    // access is not. b's enemy fixture mhp:
    const b_mhp = env.b.mhp();
    const v6 = evalFormula("b.mhp * .50", &env);
    try testing.expectApproxEqAbs(@as(f64, @floatFromInt(b_mhp)) * 0.5, v6, 0.000001);
    // member access still works when the dot follows a digit-free
    // chain, and the literal can appear anywhere a number can
    const v7 = evalFormula("Math.max(.25, 1.5) * 2", &env);
    try testing.expectApproxEqAbs(@as(f64, 3.0), v7, 0.000001);
}

test "battle: selected enemy receives repeated hits and MV scopes keep allies separate" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const db = try buildBattleDb(a);
    defer freeBattleDb(a, db);
    var game = game_mod.GameObjects.init(a, db);
    try game.create();
    try game.party.members.append(a, 1);
    const actor = game.actors.actor(1).?;
    var mgr = Manager.init(a, db, &game, &game.troop, 7);
    defer mgr.deinit();
    mgr.setup(1, true, false);
    mgr.subject = .{ .actor = actor };
    var parser = try json.Parser.init(a, "{\"id\":1,\"scope\":1,\"repeats\":3,\"mpCost\":2,\"successRate\":100,\"damage\":{\"type\":1,\"formula\":\"5\",\"variance\":0,\"critical\":false},\"effects\":[]}");
    db.get("data/Skills.json").?.value.array.items[1] = try parser.parse();
    const mp_before = actor.mp;
    mgr.runAction(.{ .actor = actor }, .{ .kind = .skill, .skill_id = 1, .target_index = 1 });
    try testing.expectEqual(@as(i32, 60), game.troop.enemies.items[0].hp);
    try testing.expectEqual(@as(i32, 45), game.troop.enemies.items[1].hp);
    try testing.expectEqual(mp_before - 2, actor.mp); // cost once per action
    for ([_]i32{ 2, 3, 4, 5, 6, 7, 8, 11 }, [_]usize{ 2, 1, 2, 3, 4, 1, 1, 1 }) |scope, expected| {
        var entries = [_]json.Value.Entry{.{ .key = "scope", .value = .{ .number = @floatFromInt(scope) } }};
        const targets = mgr.makeTargets(.{ .actor = actor }, .{ .object = .{ .entries = &entries } }, 0, null);
        try testing.expectEqual(expected, targets.len);
        for (targets) |target| try testing.expectEqual(scope >= 7, target == .actor);
        a.free(targets);
    }
    actor.hp = 0;
    for ([_]i32{ 9, 10 }) |scope| {
        var entries = [_]json.Value.Entry{.{ .key = "scope", .value = .{ .number = @floatFromInt(scope) } }};
        const targets = mgr.makeTargets(.{ .actor = actor }, .{ .object = .{ .entries = &entries } }, 0, null);
        try testing.expectEqual(@as(usize, 1), targets.len);
        try testing.expectEqual(actor, targets[0].actor);
        a.free(targets);
    }
}

test "field items: recovery effects consume only on use and preserve key items" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const db = try buildBattleDb(a);
    defer freeBattleDb(a, db);
    var game = game_mod.GameObjects.init(a, db);
    try game.create();
    try game.party.members.append(a, 1);
    const actor = game.actors.actor(1).?;
    game.party.gainItem(3, 2);
    var parser = try json.Parser.init(a, "{\"id\":3,\"consumable\":true,\"occasion\":0,\"damage\":{\"type\":0},\"effects\":[{\"code\":11,\"value1\":0.1,\"value2\":5}]}");
    db.get("data/Items.json").?.value.array.items[3] = try parser.parse();
    try testing.expect(!useFieldItem(db, &game, 3)); // full HP is not a use
    try testing.expectEqual(@as(i32, 2), game.party.numItems(3));
    actor.hp -= 100;
    const hp_before = actor.hp;
    try testing.expect(useFieldItem(db, &game, 3));
    try testing.expectEqual(hp_before + @divTrunc(actor.param(0), 10) + 5, actor.hp);
    try testing.expectEqual(@as(i32, 1), game.party.numItems(3));
    var key_parser = try json.Parser.init(a, "{\"id\":3,\"consumable\":false,\"occasion\":3,\"effects\":[]}");
    db.get("data/Items.json").?.value.array.items[3] = try key_parser.parse();
    try testing.expect(!useFieldItem(db, &game, 3));
    try testing.expectEqual(@as(i32, 1), game.party.numItems(3));
}

test "battle: full battle to victory + rewards" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const db = try buildBattleDb(a);
    defer freeBattleDb(a, db);
    var game = game_mod.GameObjects.init(a, &db.*);
    try game.create();
    try game.party.members.append(a, 1);
    _ = game.actors.actor(1);

    const gold_before = game.party.gold;
    const exp_before = game.actors.actor(1).?.exp;
    const battles_before = game.system.battle_count;

    var mgr = Manager.init(a, &db.*, &game, &game.troop, 0xDEADBEEF);
    defer mgr.deinit();
    mgr.setup(1, true, false);
    try testing.expectEqual(@as(usize, 2), game.troop.enemies.items.len);
    try testing.expect(game.party.in_battle);

    const result = mgr.run();
    try testing.expectEqual(BattleResult.win, result);
    try testing.expect(game.troop.isAllDead());
    try testing.expect(!game.party.in_battle);
    // Rewards: 2 enemies × 20 exp, × 15 gold.
    try testing.expectEqual(exp_before + 40, game.actors.actor(1).?.exp);
    try testing.expectEqual(gold_before + 30, game.party.gold);
    try testing.expectEqual(battles_before + 1, game.system.battle_count);
    try testing.expect(game.system.win_count > 0);
}

test "battle: enemy AI action selection (rating window + conditions)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const db = try buildBattleDb(a);
    defer freeBattleDb(a, db);
    var game = game_mod.GameObjects.init(a, &db.*);
    try game.create();

    var troop = Troop.init(a, &db.*);
    defer troop.deinit();
    troop.setup(1, &game);
    const e = troop.enemies.items[0];

    var rng = Rng.init(7);
    e.makeActions(1, &game.party, &game.actors, &game.switches, &rng);
    try testing.expect(e.actions.items.len >= 1);
    try testing.expectEqual(@as(i32, 1), e.actions.items[0].skill_id);
}

test "battle: enemy AI priority uses ordered random and target-state rules" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const db = try buildBattleDb(a);
    defer freeBattleDb(a, db);
    var game = game_mod.GameObjects.init(a, db);
    try game.create();
    try game.party.members.append(a, 1);
    const actor = game.actors.actor(1).?;
    var enemy = GameEnemy.init(a, db);
    defer enemy.deinit();
    enemy.setup(1, 0, 0);
    var entries = [_]json.Value.Entry{.{ .key = "note", .value = .{
        .string = "<AI Level: 100>\n<AI Priority>\nState === State 6: SKILL 2, target\nRandom 0%: SKILL 2, target\nRandom 100%: SKILL 1, target\n</AI Priority>",
    } }};
    const data = json.Value{ .object = .{ .entries = &entries } };
    var rng = Rng.init(14);
    try testing.expect(enemy.makePriorityAction(data, &game.party, &game.actors, &rng));
    try testing.expectEqual(@as(i32, 1), enemy.actions.items[0].skill_id);
    enemy.actions.clearRetainingCapacity();
    actor.addState(db, 6);
    try testing.expect(enemy.makePriorityAction(data, &game.party, &game.actors, &rng));
    try testing.expectEqual(@as(i32, 2), enemy.actions.items[0].skill_id);
    try testing.expectEqual(@as(i32, 0), enemy.actions.items[0].target_index);
    enemy.actions.clearRetainingCapacity();
    enemy.mp = 0; // unaffordable state-priority skill must not be selected
    try testing.expect(enemy.makePriorityAction(data, &game.party, &game.actors, &rng));
    try testing.expectEqual(@as(i32, 1), enemy.actions.items[0].skill_id);
}

test "battle: optional actual Forest Bunny selects its authored AI skills" {
    const root = std.process.getEnvVarOwned(testing.allocator, "OMORI_BATTLE_SMOKE_ROOT") catch return error.SkipZigTest;
    defer testing.allocator.free(root);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var vfs = vfs_mod.Vfs.init(a, root, root);
    defer vfs.deinit();
    var db = database.Database.init(a, &vfs);
    defer db.deinit();
    for ([_][]const u8{ "data/System.json", "data/Actors.json", "data/Classes.json", "data/Enemies.json", "data/Troops.json", "data/Skills.json", "data/States.json", "data/Items.json" }) |path| _ = try db.loadFile(.database, path);
    var game = game_mod.GameObjects.init(a, &db);
    try game.create();
    try game.party.members.append(a, 1);
    var enemy = GameEnemy.init(a, &db);
    defer enemy.deinit();
    enemy.setup(19, 0, 0);
    try testing.expectEqual(@as(usize, 0), enemy.enemyData().?.get("actions").?.arrayItems().len);
    var rng = Rng.init(0xB011);
    var counts: [3]usize = @splat(0);
    for (0..100) |_| {
        enemy.makeActions(1, &game.party, &game.actors, &game.switches, &rng);
        try testing.expectEqual(@as(usize, 1), enemy.actions.items.len);
        const action = enemy.actions.items[0];
        try testing.expect(action.skill_id >= 209 and action.skill_id <= 211);
        try testing.expectEqual(@as(i32, 0), action.target_index);
        counts[@intCast(action.skill_id - 209)] += 1;
    }
    for (counts) |count| try testing.expect(count > 0);
    // Observe's authored target-state priority must override random rules.
    const actor = game.actors.actor(1).?;
    actor.addState(&db, 186);
    enemy.makeActions(2, &game.party, &game.actors, &game.switches, &rng);
    try testing.expectEqual(@as(i32, 209), enemy.actions.items[0].skill_id);
    std.debug.print("actual Forest Bunny AI over 100 turns: attack={d}, nothing={d}, cute={d}; Observe priority passed\n", .{ counts[0], counts[1], counts[2] });

    var manager = Manager.init(a, &db, &game, &game.troop, 7);
    defer manager.deinit();
    manager.subject = .{ .enemy = &enemy };
    const base_attack = actor.param(2);
    const cute = skillData(&db, 211).?;
    for ([_]i32{ 92, 93, 94 }, [_]f64{ 0.9, 0.8, 0.7 }) |expected_state, rate| {
        manager.invokeAction(.{ .enemy = &enemy }, .{ .actor = actor }, .{ .kind = .skill, .skill_id = 211 }, cute);
        for ([_]i32{ 92, 93, 94 }) |state_id| try testing.expectEqual(state_id == expected_state, actor.isStateAffected(state_id));
        try testing.expectEqual(@as(i32, 6), actor.states.get(expected_state).?);
        try testing.expectApproxEqAbs(rate, actor.paramRate(2), 0.00001);
        try testing.expectEqual(@as(i64, @intFromFloat(@floor(@as(f64, @floatFromInt(base_attack)) * rate))), actor.param(2));
    }
    for (0..5) |_| actor.tickStateTurns();
    try testing.expect(actor.isStateAffected(94));
    actor.tickStateTurns();
    try testing.expect(!actor.isStateAffected(94));
    try testing.expectEqual(base_attack, actor.param(2));
    std.debug.print("actual BE CUTE note: ATTACK DOWN92->93->94, parameter rates and six-turn expiry passed\n", .{});
}

test "battle: action-note state branches and literal EVAL calls are bounded" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const db = try buildBattleDb(a);
    defer freeBattleDb(a, db);
    var game = game_mod.GameObjects.init(a, db);
    try game.create();
    const actor = game.actors.actor(1).?;
    var manager = Manager.init(a, db, &game, &game.troop, 4);
    defer manager.deinit();
    var fields = [_]json.Value.Entry{.{ .key = "note", .value = .{
        .string = "<whole action>\nif (target.isStateAffected(6))\neval: target.removeState(6);\nelse\nadd state 6: target\nend\n</whole action>",
    } }};
    const item = json.Value{ .object = .{ .entries = &fields } };
    manager.applyActionNoteStates(.{ .actor = actor }, item);
    try testing.expect(actor.isStateAffected(6));
    manager.applyActionNoteStates(.{ .actor = actor }, item);
    try testing.expect(!actor.isStateAffected(6));
    fields[0].value = .{ .string = "<whole action>\nif target.hp > 0\nadd state 1: target\nelse\neval: target.addState(1);\nend\neval: arbitraryUnknownJavaScript();\n</whole action>" };
    const hp_before = actor.hp;
    manager.applyActionNoteStates(.{ .actor = actor }, item);
    try testing.expectEqual(hp_before, actor.hp);
    try testing.expect(!actor.isStateAffected(1));
}

test "battle: repeated display-name creation releases owned names" {
    const a = testing.allocator;
    var troop = Troop.init(a, undefined);
    defer troop.deinit();
    const enemy = try a.create(GameEnemy);
    enemy.* = GameEnemy.init(a, undefined);
    enemy.original_name = "SPROUT";
    try troop.enemies.append(a, enemy);
    for (0..16) |_| {
        troop.makeUniqueNames();
        try testing.expectEqualStrings("SPROUTA", enemy.name());
    }
}

test "battle: troop unique names + page conditions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const db = try buildBattleDb(a);
    defer freeBattleDb(a, db);
    var game = game_mod.GameObjects.init(a, &db.*);
    try game.create();

    var troop = Troop.init(a, &db.*);
    defer troop.deinit();
    troop.setup(1, &game);
    try testing.expectEqualStrings("LARVAA", troop.enemies.items[0].name());
    try testing.expectEqualStrings("LARVAB", troop.enemies.items[1].name());
    // No pages → no battle events.
    try testing.expect(troop.findBattleEventPage(&game.party, &game.actors, &game.switches) == null);
}
