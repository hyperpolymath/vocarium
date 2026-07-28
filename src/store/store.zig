// SPDX-License-Identifier: MPL-2.0
// Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
//
// The vocarium store: append-only JSONL replayed into in-memory indexes.
//
// Records (one JSON object per line):
//   {"t":"trope",     "id","quality","bearer","context","record"}   (strings; "" = field absent)
//   {"t":"edge",      "id","effect","inputs":[..],"output","grade":{..},"warrant_id","source"?}
//   {"t":"use_model", "id","floor":{..}}
//   {"t":"warrant",   "id","text"?}
//   {"t":"revocation", ...}   reserved for M2; accepted at parse, rejected at validate
//
// Grades and floors are carried as opaque JSON values: vocarium stores the
// loss-shape claim, it never interprets the grading algebra (ADR-0002 §4).

const std = @import("std");

pub const StoreError = error{
    Validation, // maps to exit 2 (mirrors tropecheck's validation-fault)
    OutOfMemory,
};

pub const Trope = struct {
    id: []const u8,
    quality: []const u8,
    bearer: []const u8,
    context: []const u8,
    record: []const u8,

    pub fn presentFields(self: Trope, buf: *[4][]const u8) [][]const u8 {
        var n: usize = 0;
        if (self.quality.len != 0) {
            buf[n] = "quality";
            n += 1;
        }
        if (self.bearer.len != 0) {
            buf[n] = "bearer";
            n += 1;
        }
        if (self.context.len != 0) {
            buf[n] = "context";
            n += 1;
        }
        if (self.record.len != 0) {
            buf[n] = "record";
            n += 1;
        }
        return buf[0..n];
    }
};

pub const Edge = struct {
    id: []const u8,
    effect: []const u8,
    inputs: [][]const u8,
    output: []const u8,
    grade: std.json.Value, // opaque loss-shape
    warrant_id: []const u8,
    source: []const u8, // "" if absent
};

pub const UseModel = struct {
    id: []const u8,
    floor: std.json.Value, // opaque floor grade
};

const effects = [_][]const u8{ "preserve", "project", "collapse", "detach", "attenuate", "fuse" };

fn isEffect(s: []const u8) bool {
    for (effects) |e| if (std.mem.eql(u8, e, s)) return true;
    return false;
}

/// Diagnostics for validation failures — filled in when load() returns
/// StoreError.Validation (line 0 = post-replay referential check).
pub const Diag = struct {
    line: usize = 0,
    msg: []const u8 = "",
};

pub const Store = struct {
    arena: *std.heap.ArenaAllocator,
    tropes: std.StringArrayHashMapUnmanaged(Trope) = .empty,
    edges: std.ArrayListUnmanaged(Edge) = .empty,
    use_models: std.StringArrayHashMapUnmanaged(UseModel) = .empty,
    warrants: std.StringArrayHashMapUnmanaged(void) = .empty,
    diag: *Diag,

    pub fn deinit(self: *Store) void {
        const child = self.arena.child_allocator;
        self.arena.deinit();
        child.destroy(self.arena);
    }

    fn fail(self: *Store, line: usize, msg: []const u8) StoreError {
        self.diag.line = line;
        self.diag.msg = msg;
        return StoreError.Validation;
    }

    fn getString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
        const v = obj.get(key) orelse return null;
        return switch (v) {
            .string => |s| s,
            else => null,
        };
    }

    /// Load and validate a JSONL byte stream. All memory lives in the store's
    /// arena; on error the arena is torn down before returning, and `diag`
    /// (caller-owned, may outlive the store) carries the fault.
    pub fn load(gpa: std.mem.Allocator, bytes: []const u8, diag: *Diag) StoreError!Store {
        const arena_ptr = gpa.create(std.heap.ArenaAllocator) catch return StoreError.OutOfMemory;
        arena_ptr.* = std.heap.ArenaAllocator.init(gpa);
        var self = Store{ .arena = arena_ptr, .diag = diag };
        const a = arena_ptr.allocator();
        errdefer self.deinit();

        var it = std.mem.splitScalar(u8, bytes, '\n');
        var lineno: usize = 0;
        while (it.next()) |raw| {
            lineno += 1;
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, line, .{}) catch
                return self.fail(lineno, "invalid JSON");
            const obj = switch (parsed) {
                .object => |o| o,
                else => return self.fail(lineno, "record is not a JSON object"),
            };
            const t = getString(obj, "t") orelse return self.fail(lineno, "missing record tag \"t\"");

            if (std.mem.eql(u8, t, "trope")) {
                const id = getString(obj, "id") orelse return self.fail(lineno, "trope: missing id");
                if (id.len == 0) return self.fail(lineno, "trope: empty id");
                const tr = Trope{
                    .id = id,
                    .quality = getString(obj, "quality") orelse return self.fail(lineno, "trope: quality must be a string (\"\" for absent)"),
                    .bearer = getString(obj, "bearer") orelse return self.fail(lineno, "trope: bearer must be a string (\"\" for absent)"),
                    .context = getString(obj, "context") orelse return self.fail(lineno, "trope: context must be a string (\"\" for absent)"),
                    .record = getString(obj, "record") orelse return self.fail(lineno, "trope: record must be a string (\"\" for absent)"),
                };
                const gop = self.tropes.getOrPut(a, id) catch return StoreError.OutOfMemory;
                if (gop.found_existing) return self.fail(lineno, "duplicate trope id");
                gop.value_ptr.* = tr;
            } else if (std.mem.eql(u8, t, "edge")) {
                const id = getString(obj, "id") orelse return self.fail(lineno, "edge: missing id");
                const effect = getString(obj, "effect") orelse return self.fail(lineno, "edge: missing effect");
                if (!isEffect(effect)) return self.fail(lineno, "edge: effect is not one of the six writable effects");
                const inputs_v = obj.get("inputs") orelse return self.fail(lineno, "edge: missing inputs");
                const inputs_arr = switch (inputs_v) {
                    .array => |arr| arr,
                    else => return self.fail(lineno, "edge: inputs must be an array"),
                };
                if (inputs_arr.items.len < 1 or inputs_arr.items.len > 2)
                    return self.fail(lineno, "edge: inputs must have 1..2 entries");
                var inputs = a.alloc([]const u8, inputs_arr.items.len) catch return StoreError.OutOfMemory;
                for (inputs_arr.items, 0..) |iv, i| {
                    inputs[i] = switch (iv) {
                        .string => |s| s,
                        else => return self.fail(lineno, "edge: inputs must be strings"),
                    };
                }
                const output = getString(obj, "output") orelse return self.fail(lineno, "edge: missing output");
                const grade = obj.get("grade") orelse return self.fail(lineno, "edge: missing grade");
                if (grade != .object) return self.fail(lineno, "edge: grade must be an object");
                const warrant_id = getString(obj, "warrant_id") orelse
                    return self.fail(lineno, "edge: missing warrant_id (a stored loss-shape is a claim; every claim needs a warrant)");
                if (warrant_id.len == 0)
                    return self.fail(lineno, "edge: empty warrant_id");
                self.edges.append(a, .{
                    .id = id,
                    .effect = effect,
                    .inputs = inputs,
                    .output = output,
                    .grade = grade,
                    .warrant_id = warrant_id,
                    .source = getString(obj, "source") orelse "",
                }) catch return StoreError.OutOfMemory;
            } else if (std.mem.eql(u8, t, "use_model")) {
                const id = getString(obj, "id") orelse return self.fail(lineno, "use_model: missing id");
                const floor = obj.get("floor") orelse return self.fail(lineno, "use_model: missing floor");
                if (floor != .object) return self.fail(lineno, "use_model: floor must be an object");
                const gop = self.use_models.getOrPut(a, id) catch return StoreError.OutOfMemory;
                if (gop.found_existing) return self.fail(lineno, "duplicate use_model id");
                gop.value_ptr.* = .{ .id = id, .floor = floor };
            } else if (std.mem.eql(u8, t, "warrant")) {
                const id = getString(obj, "id") orelse return self.fail(lineno, "warrant: missing id");
                if (id.len == 0) return self.fail(lineno, "warrant: empty id");
                self.warrants.put(a, id, {}) catch return StoreError.OutOfMemory;
            } else if (std.mem.eql(u8, t, "revocation")) {
                return self.fail(lineno, "revocation records are reserved for M2 (revoke is not implemented)");
            } else {
                return self.fail(lineno, "unknown record tag");
            }
        }

        // Referential validation (order-independent: after full replay).
        for (self.edges.items) |e| {
            for (e.inputs) |inp| {
                if (self.tropes.get(inp) == null)
                    return self.fail(0, "edge references unknown input trope");
            }
            if (self.tropes.get(e.output) == null)
                return self.fail(0, "edge references unknown output trope");
            if (self.warrants.get(e.warrant_id) == null)
                return self.fail(0, "edge cites an unknown warrant (unwarranted loss-shape claims are refused)");
        }
        return self;
    }

    /// The invoke slice: collect every edge on any path INTO `target_id`
    /// (reverse reachability to fixpoint). Returns edge indices in stable
    /// (file) order, plus the set of involved trope ids in first-seen order.
    pub fn pathInto(
        self: *Store,
        target_id: []const u8,
        edge_idx_out: *std.ArrayListUnmanaged(usize),
        trope_ids_out: *std.ArrayListUnmanaged([]const u8),
    ) StoreError!void {
        const a = self.arena.allocator();
        var reachable: std.StringArrayHashMapUnmanaged(void) = .empty;
        reachable.put(a, target_id, {}) catch return StoreError.OutOfMemory;
        var included = self.arena.child_allocator.alloc(bool, self.edges.items.len) catch return StoreError.OutOfMemory;
        defer self.arena.child_allocator.free(included);
        @memset(included, false);

        var changed = true;
        while (changed) {
            changed = false;
            for (self.edges.items, 0..) |e, i| {
                if (included[i]) continue;
                if (reachable.get(e.output) != null) {
                    included[i] = true;
                    changed = true;
                    for (e.inputs) |inp| {
                        reachable.put(a, inp, {}) catch return StoreError.OutOfMemory;
                    }
                }
            }
        }
        for (self.edges.items, 0..) |_, i| {
            if (included[i]) edge_idx_out.append(a, i) catch return StoreError.OutOfMemory;
        }
        // Involved tropes: every input/output of included edges, plus the target.
        var seen: std.StringArrayHashMapUnmanaged(void) = .empty;
        for (edge_idx_out.items) |i| {
            const e = self.edges.items[i];
            for (e.inputs) |inp| {
                const gop = seen.getOrPut(a, inp) catch return StoreError.OutOfMemory;
                if (!gop.found_existing) trope_ids_out.append(a, inp) catch return StoreError.OutOfMemory;
            }
            const gop = seen.getOrPut(a, e.output) catch return StoreError.OutOfMemory;
            if (!gop.found_existing) trope_ids_out.append(a, e.output) catch return StoreError.OutOfMemory;
        }
        const gop = seen.getOrPut(a, target_id) catch return StoreError.OutOfMemory;
        if (!gop.found_existing) trope_ids_out.append(a, target_id) catch return StoreError.OutOfMemory;
    }
};

// ---------------------------------------------------------------------------
// Unit tests (zig build test)
// ---------------------------------------------------------------------------

const t_fixture =
    \\{"t":"warrant","id":"w1","text":"editorial comparison"}
    \\{"t":"trope","id":"a","quality":"authentic language","bearer":"quoted phrase","context":"de Man / rhetoric","record":"source quotation"}
    \\{"t":"trope","id":"b","quality":"real language","bearer":"paraphrase","context":"casual gloss","record":"secondhand"}
    \\{"t":"edge","id":"e1","effect":"attenuate","inputs":["a"],"output":"b","grade":{"fate":{"quality":{"k":"Attenuated","delta":6},"bearer":{"k":"Present"},"context":{"k":"Present"},"record":{"k":"Present"}},"bond":{"k":"Intact"},"merge":{"k":"Single"}},"warrant_id":"w1"}
    \\{"t":"use_model","id":"casual-note","floor":{"fate":{"quality":{"k":"Attenuated","delta":10}}}}
;

test "replay builds indexes" {
    var diag = Diag{};
    var s = try Store.load(std.testing.allocator, t_fixture, &diag);
    defer s.deinit();
    try std.testing.expectEqual(@as(usize, 2), s.tropes.count());
    try std.testing.expectEqual(@as(usize, 1), s.edges.items.len);
    try std.testing.expectEqual(@as(usize, 1), s.use_models.count());
    try std.testing.expectEqual(@as(usize, 1), s.warrants.count());
}

test "presence projection skips empty fields" {
    var diag = Diag{};
    var s = try Store.load(std.testing.allocator,
        \\{"t":"trope","id":"x","quality":"q","bearer":"","context":"c","record":""}
    , &diag);
    defer s.deinit();
    const tr = s.tropes.get("x").?;
    var buf: [4][]const u8 = undefined;
    const present = tr.presentFields(&buf);
    try std.testing.expectEqual(@as(usize, 2), present.len);
    try std.testing.expectEqualStrings("quality", present[0]);
    try std.testing.expectEqualStrings("context", present[1]);
}

test "unwarranted edge is refused (validation)" {
    const bad =
        \\{"t":"trope","id":"a","quality":"q","bearer":"b","context":"c","record":"r"}
        \\{"t":"trope","id":"b2","quality":"q","bearer":"b","context":"c","record":"r"}
        \\{"t":"edge","id":"e1","effect":"preserve","inputs":["a"],"output":"b2","grade":{"fate":{}},"warrant_id":"missing"}
    ;
    var diag = Diag{};
    try std.testing.expectError(StoreError.Validation, Store.load(std.testing.allocator, bad, &diag));
}

test "edge without warrant_id is refused" {
    const bad =
        \\{"t":"trope","id":"a","quality":"q","bearer":"b","context":"c","record":"r"}
        \\{"t":"edge","id":"e1","effect":"preserve","inputs":["a"],"output":"a","grade":{"fate":{}}}
    ;
    var diag = Diag{};
    try std.testing.expectError(StoreError.Validation, Store.load(std.testing.allocator, bad, &diag));
}

test "reverse reachability collects the chain into the target" {
    const chain =
        \\{"t":"warrant","id":"w","text":""}
        \\{"t":"trope","id":"a","quality":"q","bearer":"b","context":"c","record":"r"}
        \\{"t":"trope","id":"b","quality":"q","bearer":"b","context":"c","record":"r"}
        \\{"t":"trope","id":"c","quality":"q","bearer":"b","context":"c","record":"r"}
        \\{"t":"trope","id":"lone","quality":"q","bearer":"b","context":"c","record":"r"}
        \\{"t":"edge","id":"e1","effect":"preserve","inputs":["a"],"output":"b","grade":{"g":1},"warrant_id":"w"}
        \\{"t":"edge","id":"e2","effect":"attenuate","inputs":["b"],"output":"c","grade":{"g":1},"warrant_id":"w"}
        \\{"t":"edge","id":"e3","effect":"preserve","inputs":["lone"],"output":"lone","grade":{"g":1},"warrant_id":"w"}
    ;
    var diag = Diag{};
    var s = try Store.load(std.testing.allocator, chain, &diag);
    defer s.deinit();
    var eidx: std.ArrayListUnmanaged(usize) = .empty;
    var tids: std.ArrayListUnmanaged([]const u8) = .empty;
    try s.pathInto("c", &eidx, &tids);
    try std.testing.expectEqual(@as(usize, 2), eidx.items.len); // e1,e2 not e3
    try std.testing.expectEqual(@as(usize, 3), tids.items.len); // a,b,c not lone
}

test "revocation records are reserved" {
    var diag = Diag{};
    try std.testing.expectError(StoreError.Validation, Store.load(std.testing.allocator,
        \\{"t":"revocation","id":"e1"}
    , &diag));
}
