// SPDX-License-Identifier: MPL-2.0
// Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
//
// voc — the vocarium store CLI (M1 invoke slice, ADR-0002).
//
//   voc ingest <store.jsonl>
//       Replay + validate; print record counts. Exit 2 on any validation
//       fault (unknown refs, unwarranted edges, malformed records).
//
//   voc invoke --store <store.jsonl> --use-model <id> <trope-id>
//       Emit the Trope IR v0.2 Document for the path into <trope-id> under
//       the named use-model, on stdout. Pipe it to `tropecheck` for the
//       verdict; voc itself renders no verdict.
//
// Exit codes mirror tropecheck conventions:
//   0 success · 2 validation fault · 3 io error · 64 usage

const std = @import("std");
const Io = std.Io;
const storemod = @import("store.zig");
const emitmod = @import("emit.zig");

const usage_text =
    \\voc — vocarium trope store (M1 invoke slice)
    \\
    \\usage:
    \\  voc ingest <store.jsonl>
    \\  voc invoke --store <store.jsonl> --use-model <id> <trope-id>
    \\
;

fn errPrint(io: Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    Io.File.stderr().writeStreamingAll(io, msg) catch {};
}

pub fn main(init: std.process.Init) u8 {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    const args = init.minimal.args.toSlice(arena) catch return 3;
    if (args.len < 2) {
        errPrint(io, "{s}", .{usage_text});
        return 64;
    }
    const cmd = args[1];

    if (std.mem.eql(u8, cmd, "ingest")) {
        if (args.len != 3) {
            errPrint(io, "{s}", .{usage_text});
            return 64;
        }
        return runIngest(io, gpa, args[2]);
    }
    if (std.mem.eql(u8, cmd, "invoke")) {
        return runInvoke(io, gpa, args[2..]);
    }
    errPrint(io, "{s}", .{usage_text});
    return 64;
}

fn loadStore(io: Io, gpa: std.mem.Allocator, path: []const u8, diag: *storemod.Diag) ?storemod.Store {
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024 * 1024)) catch |e| {
        errPrint(io, "voc: cannot read {s}: {s}\n", .{ path, @errorName(e) });
        return null;
    };
    defer gpa.free(bytes);
    return storemod.Store.load(gpa, bytes, diag) catch null;
}

fn runIngest(io: Io, gpa: std.mem.Allocator, path: []const u8) u8 {
    var diag = storemod.Diag{};
    var s = loadStore(io, gpa, path, &diag) orelse {
        if (diag.msg.len != 0) {
            errPrint(io, "voc: validation fault (line {d}): {s}\n", .{ diag.line, diag.msg });
            return 2;
        }
        return 3;
    };
    defer s.deinit();
    errPrint(io, "voc: ok — {d} tropes, {d} edges, {d} use-models, {d} warrants\n", .{
        s.tropes.count(), s.edges.items.len, s.use_models.count(), s.warrants.count(),
    });
    return 0;
}

fn runInvoke(io: Io, gpa: std.mem.Allocator, rest: []const [:0]const u8) u8 {
    var store_path: ?[]const u8 = null;
    var um_id: ?[]const u8 = null;
    var target: ?[]const u8 = null;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const arg = rest[i];
        if (std.mem.eql(u8, arg, "--store")) {
            i += 1;
            if (i >= rest.len) return 64;
            store_path = rest[i];
        } else if (std.mem.eql(u8, arg, "--use-model")) {
            i += 1;
            if (i >= rest.len) return 64;
            um_id = rest[i];
        } else if (target == null) {
            target = arg;
        } else {
            errPrint(io, "{s}", .{usage_text});
            return 64;
        }
    }
    const sp = store_path orelse {
        errPrint(io, "{s}", .{usage_text});
        return 64;
    };
    const um_name = um_id orelse {
        errPrint(io, "{s}", .{usage_text});
        return 64;
    };
    const target_id = target orelse {
        errPrint(io, "{s}", .{usage_text});
        return 64;
    };

    var diag = storemod.Diag{};
    var s = loadStore(io, gpa, sp, &diag) orelse {
        if (diag.msg.len != 0) {
            errPrint(io, "voc: validation fault (line {d}): {s}\n", .{ diag.line, diag.msg });
            return 2;
        }
        return 3;
    };
    defer s.deinit();

    const um = s.use_models.get(um_name) orelse {
        errPrint(io, "voc: unknown use-model: {s}\n", .{um_name});
        return 2;
    };
    if (s.tropes.get(target_id) == null) {
        errPrint(io, "voc: unknown trope: {s}\n", .{target_id});
        return 2;
    }

    const a = s.arena.allocator();
    var eidx: std.ArrayListUnmanaged(usize) = .empty;
    var tids: std.ArrayListUnmanaged([]const u8) = .empty;
    s.pathInto(target_id, &eidx, &tids) catch return 3;
    const doc = emitmod.emitDocument(a, &s, tids.items, eidx.items, um, target_id) catch return 3;
    Io.File.stdout().writeStreamingAll(io, doc) catch return 3;
    return 0;
}
