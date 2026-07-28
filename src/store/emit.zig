// SPDX-License-Identifier: MPL-2.0
// Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
//
// Trope IR v0.2 Document emitter (the wire boundary, ADR-0002 §2).
//
// The document shape is fixed by trope-checker/schemas/trope-ir.schema.json:
//   {version, profile, nodes[], edges[], use_model{output, floor}}
// Grades and floors are re-emitted verbatim from the store's opaque JSON
// values via a small recursive writer — vocarium never interprets them.
// Vocarium-only fields (warrant_id, source) are stripped: the IR edge schema
// is additionalProperties:false; warrants are store-side obligations.

const std = @import("std");
const storemod = @import("store.zig");

fn writeJsonString(out: *std.ArrayListUnmanaged(u8), a: std.mem.Allocator, s: []const u8) !void {
    try out.append(a, '"');
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(a, "\\\""),
            '\\' => try out.appendSlice(a, "\\\\"),
            '\n' => try out.appendSlice(a, "\\n"),
            '\r' => try out.appendSlice(a, "\\r"),
            '\t' => try out.appendSlice(a, "\\t"),
            else => {
                if (c < 0x20) {
                    var buf: [6]u8 = undefined;
                    const hex = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch unreachable;
                    try out.appendSlice(a, hex);
                } else {
                    try out.append(a, c);
                }
            },
        }
    }
    try out.append(a, '"');
}

fn writeValue(out: *std.ArrayListUnmanaged(u8), a: std.mem.Allocator, v: std.json.Value) !void {
    switch (v) {
        .null => try out.appendSlice(a, "null"),
        .bool => |b| try out.appendSlice(a, if (b) "true" else "false"),
        .integer => |i| {
            var buf: [24]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable;
            try out.appendSlice(a, s);
        },
        .float => |f| {
            var buf: [40]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{f}) catch unreachable;
            try out.appendSlice(a, s);
        },
        .number_string => |s| try out.appendSlice(a, s),
        .string => |s| try writeJsonString(out, a, s),
        .array => |arr| {
            try out.append(a, '[');
            for (arr.items, 0..) |item, i| {
                if (i != 0) try out.append(a, ',');
                try writeValue(out, a, item);
            }
            try out.append(a, ']');
        },
        .object => |obj| {
            try out.append(a, '{');
            var i: usize = 0;
            var it = obj.iterator();
            while (it.next()) |entry| {
                if (i != 0) try out.append(a, ',');
                try writeJsonString(out, a, entry.key_ptr.*);
                try out.append(a, ':');
                try writeValue(out, a, entry.value_ptr.*);
                i += 1;
            }
            try out.append(a, '}');
        },
    }
}

/// Emit the invoke-slice Document for `target` under `um`, over the edges
/// selected by Store.pathInto. Output is a complete Trope IR v0.2 document.
pub fn emitDocument(
    a: std.mem.Allocator,
    store: *storemod.Store,
    trope_ids: [][]const u8,
    edge_indices: []usize,
    um: storemod.UseModel,
    target_id: []const u8,
) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.appendSlice(a,
        \\{"$schema":"https://github.com/hyperpolymath/trope-checker/schemas/trope-ir.schema.json","version":"0.2","profile":"prevent","nodes":[
    );
    for (trope_ids, 0..) |tid, i| {
        if (i != 0) try out.append(a, ',');
        const tr = store.tropes.get(tid).?;
        try out.appendSlice(a, "{\"id\":");
        try writeJsonString(&out, a, tr.id);
        try out.appendSlice(a, ",\"type\":\"Trope\",\"present\":[");
        var buf: [4][]const u8 = undefined;
        const present = tr.presentFields(&buf);
        for (present, 0..) |f, j| {
            if (j != 0) try out.append(a, ',');
            try writeJsonString(&out, a, f);
        }
        try out.appendSlice(a, "]}");
    }
    try out.appendSlice(a, "],\"edges\":[");
    for (edge_indices, 0..) |ei, i| {
        if (i != 0) try out.append(a, ',');
        const e = store.edges.items[ei];
        try out.appendSlice(a, "{\"id\":");
        try writeJsonString(&out, a, e.id);
        try out.appendSlice(a, ",\"effect\":");
        try writeJsonString(&out, a, e.effect);
        try out.appendSlice(a, ",\"inputs\":[");
        for (e.inputs, 0..) |inp, j| {
            if (j != 0) try out.append(a, ',');
            try writeJsonString(&out, a, inp);
        }
        try out.appendSlice(a, "],\"output\":");
        try writeJsonString(&out, a, e.output);
        try out.appendSlice(a, ",\"grade\":");
        try writeValue(&out, a, e.grade);
        try out.append(a, '}');
    }
    try out.appendSlice(a, "],\"use_model\":{\"id\":");
    try writeJsonString(&out, a, um.id);
    try out.appendSlice(a, ",\"output\":");
    try writeJsonString(&out, a, target_id);
    try out.appendSlice(a, ",\"floor\":");
    try writeValue(&out, a, um.floor);
    try out.appendSlice(a, "}}\n");
    return out.toOwnedSlice(a);
}

test "emitted document round-trips as JSON with required keys" {
    const fixture =
        \\{"t":"warrant","id":"w1","text":""}
        \\{"t":"trope","id":"a","quality":"authentic language","bearer":"quoted phrase","context":"ctx","record":"src"}
        \\{"t":"trope","id":"b","quality":"real language","bearer":"paraphrase","context":"","record":""}
        \\{"t":"edge","id":"e1","effect":"attenuate","inputs":["a"],"output":"b","grade":{"fate":{"quality":{"k":"Attenuated","delta":6},"bearer":{"k":"Present"},"context":{"k":"Present"},"record":{"k":"Present"}},"bond":{"k":"Intact"},"merge":{"k":"Single"}},"warrant_id":"w1"}
        \\{"t":"use_model","id":"casual-note","floor":{"fate":{"quality":{"k":"Attenuated","delta":10}}}}
    ;
    var diag = storemod.Diag{};
    var s = try storemod.Store.load(std.testing.allocator, fixture, &diag);
    defer s.deinit();
    const a = s.arena.allocator();
    var eidx: std.ArrayListUnmanaged(usize) = .empty;
    var tids: std.ArrayListUnmanaged([]const u8) = .empty;
    try s.pathInto("b", &eidx, &tids);
    const doc = try emitDocument(a, &s, tids.items, eidx.items, s.use_models.get("casual-note").?, "b");

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, doc, .{});
    const obj = parsed.object;
    try std.testing.expectEqualStrings("0.2", obj.get("version").?.string);
    try std.testing.expectEqualStrings("prevent", obj.get("profile").?.string);
    try std.testing.expectEqual(@as(usize, 2), obj.get("nodes").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 1), obj.get("edges").?.array.items.len);
    // vocarium-only fields must be stripped from IR edges
    const edge0 = obj.get("edges").?.array.items[0].object;
    try std.testing.expect(edge0.get("warrant_id") == null);
    try std.testing.expect(edge0.get("source") == null);
    // grade re-emitted verbatim
    const delta = edge0.get("grade").?.object.get("fate").?.object.get("quality").?.object.get("delta").?;
    try std.testing.expectEqual(@as(i64, 6), delta.integer);
    // use_model targets the invoked trope
    try std.testing.expectEqualStrings("b", obj.get("use_model").?.object.get("output").?.string);
}
