// :cw – batch rename (like vimv): the visible names go into a temp file, one per line,
// the user edits them in $EDITOR and every changed line becomes a rename.
// Planning (pure) and applying (filesystem) are separate so the planning can be unit tested.
const std = @import("std");
const Io = std.Io;

pub const Move = struct {
    from: []const u8,
    to: []const u8,
    // Hidden name the file waits under between the two passes
    tmp: []const u8 = "",
};

pub const Outcome = struct {
    renamed: usize = 0,
    failed: usize = 0,
};

// Canonical spelling of a path, so that "x", "./x", "x/" and "a//x" count as the same name
pub fn normalize(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const absolute = path.len > 0 and path[0] == '/';
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (out.items.len > 0 or absolute) try out.append(allocator, '/');
        try out.appendSlice(allocator, part);
    }
    if (out.items.len == 0) try out.appendSlice(allocator, if (absolute) "/" else ".");
    return out.toOwnedSlice(allocator);
}

// Lines of the edited file; blank lines are ignored (a deleted line is caught by the count check)
pub fn parseLines(allocator: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    errdefer lines.deinit(allocator);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len > 0) try lines.append(allocator, line);
    }
    return lines.toOwnedSlice(allocator);
}

// Pairs old names with edited lines and keeps only the ones that change.
// Mistakes that need no filesystem (deleted line, two files to one name) are refused here.
pub fn planMoves(
    allocator: std.mem.Allocator,
    sources: []const []const u8,
    lines: []const []const u8,
    msg: *Io.Writer,
) ![]Move {
    if (lines.len != sources.len) {
        try msg.print("cw: {d} files but {d} lines. Did you delete a line by accident? Nothing renamed.\n", .{ sources.len, lines.len });
        return error.LineCountChanged;
    }
    var moves: std.ArrayList(Move) = .empty;
    errdefer moves.deinit(allocator);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);

    for (sources, lines) |from, line| {
        const to = try normalize(allocator, line);
        if (std.mem.eql(u8, from, to)) continue;
        if (try seen.fetchPut(allocator, to, {}) != null) {
            try msg.print("cw: '{s}' is the destination of more than one file. Nothing renamed.\n", .{to});
            return error.DuplicateDestination;
        }
        try moves.append(allocator, .{ .from = from, .to = to });
    }
    return moves.toOwnedSlice(allocator);
}

// Like `[ -e p ] || [ -L p ]`: a broken symlink exists too.
// A path under a regular file (NotDir) simply does not exist.
fn exists(io: Io, dir: Io.Dir, path: []const u8) !bool {
    _ = dir.statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return false,
        else => return err,
    };
    return true;
}

// Checks against the filesystem before anything moves, and picks the temporary names
pub fn checkMoves(io: Io, allocator: std.mem.Allocator, dir: Io.Dir, moves: []Move, msg: *Io.Writer) !void {
    var moving: std.StringHashMapUnmanaged(void) = .empty;
    defer moving.deinit(allocator);
    for (moves) |m| try moving.put(allocator, m.from, {});

    for (moves) |m| {
        // E.g. a name over 255 bytes – better to find out now than halfway through renaming
        const taken = exists(io, dir, m.to) catch |err| {
            try msg.print("cw: can't use '{s}': {t}. Nothing renamed.\n", .{ m.to, err });
            return err;
        };
        // Overwriting is fine only if the current owner of the name is itself moving away
        if (taken and !moving.contains(m.to)) {
            try msg.print("cw: '{s}' already exists and would be overwritten. Nothing renamed.\n", .{m.to});
            return error.DestinationExists;
        }
        // The nearest existing ancestor must be a directory (or be moving away, freeing its name)
        var parent = std.fs.path.dirname(m.to) orelse ".";
        while (!try exists(io, dir, parent)) parent = std.fs.path.dirname(parent) orelse ".";
        const parent_is_dir = if (dir.statFile(io, parent, .{})) |st| st.kind == .directory else |_| false;
        if (!parent_is_dir and !moving.contains(parent)) {
            try msg.print("cw: '{s}' is inside something that is not a directory. Nothing renamed.\n", .{m.to});
            return error.NotADirectory;
        }
    }

    const pid = std.c.getpid();
    for (moves, 0..) |*m, i| {
        m.tmp = try std.fmt.allocPrint(allocator, ".znavi-cw.{d}.{d}", .{ pid, i });
        if (try exists(io, dir, m.tmp)) {
            try msg.print("cw: temporary name '{s}' already exists. Nothing renamed.\n", .{m.tmp});
            return error.TempNameTaken;
        }
    }
}

// Two passes, so chains (a->b, b->c) and swaps (a<->b) work in any order:
// 1. every source goes to its temporary name, freeing all the original names,
// 2. every temporary name goes to its destination.
pub fn applyMoves(io: Io, dir: Io.Dir, moves: []const Move, msg: *Io.Writer) !Outcome {
    for (moves, 0..) |m, i| {
        dir.rename(m.from, dir, m.tmp, io) catch |err| {
            try msg.print("cw: could not move '{s}': {t}. Undoing, nothing renamed.\n", .{ m.from, err });
            // Put back the ones already moved so nothing is left half-renamed
            var j = i;
            while (j > 0) {
                j -= 1;
                dir.rename(moves[j].tmp, dir, moves[j].from, io) catch
                    try msg.print("cw: could not restore '{s}'; it is left as '{s}'.\n", .{ moves[j].from, moves[j].tmp });
            }
            return error.RenameFailed;
        };
    }

    // A failure here is reported and skipped, the other files still get renamed
    var outcome: Outcome = .{};
    for (moves) |m| {
        if (secondPass(io, dir, m)) |_| {
            outcome.renamed += 1;
            continue;
        } else |err| {
            outcome.failed += 1;
            // Back to the original name if it is still free, otherwise it stays hidden
            if (!(exists(io, dir, m.from) catch true)) {
                if (dir.rename(m.tmp, dir, m.from, io)) |_| {
                    try msg.print("cw: could not rename to '{s}': {t}; '{s}' was left unchanged.\n", .{ m.to, err, m.from });
                    continue;
                } else |_| {}
            }
            try msg.print("cw: could not rename to '{s}': {t}; '{s}' is left as '{s}'.\n", .{ m.to, err, m.from, m.tmp });
        }
    }
    return outcome;
}

fn secondPass(io: Io, dir: Io.Dir, m: Move) !void {
    // Someone else created the name while we were renaming (or "x" and "/abs/x" are the same file)
    if (try exists(io, dir, m.to)) return error.PathAlreadyExists;
    if (std.fs.path.dirname(m.to)) |parent| try dir.createDirPath(io, parent);
    try dir.rename(m.tmp, dir, m.to, io);
}

// Whole :cw after the editor: sources are the names written to the file, edited is its new content.
// Problems are described on msg (the user reads them before going back to znavi).
pub fn run(
    io: Io,
    allocator: std.mem.Allocator,
    dir: Io.Dir,
    sources: []const []const u8,
    edited: []const u8,
    msg: *Io.Writer,
) !Outcome {
    const lines = try parseLines(allocator, edited);
    const moves = try planMoves(allocator, sources, lines, msg);
    if (moves.len == 0) return .{};
    try checkMoves(io, allocator, dir, moves, msg);
    return applyMoves(io, dir, moves, msg);
}

// ===================== Tests =====================

test "normalize" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("x", try normalize(a, "./x"));
    try std.testing.expectEqualStrings("x", try normalize(a, "x/"));
    try std.testing.expectEqualStrings("a/x", try normalize(a, "a//./x/."));
    try std.testing.expectEqualStrings("/tmp/x", try normalize(a, "//tmp/x"));
    try std.testing.expectEqualStrings(".", try normalize(a, "./"));
    try std.testing.expectEqualStrings("/", try normalize(a, "/"));
    try std.testing.expectEqualStrings("../x", try normalize(a, "../x"));
    try std.testing.expectEqualStrings(" spaced ", try normalize(a, " spaced "));
}

test "planMoves: unchanged lines are skipped, deleted lines and duplicates refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: [256]u8 = undefined;
    var msg: Io.Writer = .fixed(&buf);

    const sources = [_][]const u8{ "a", "b", "c" };
    const moves = try planMoves(a, &sources, try parseLines(a, "a\r\n./B\n\nc/\n"), &msg);
    try std.testing.expectEqual(@as(usize, 1), moves.len);
    try std.testing.expectEqualStrings("b", moves[0].from);
    try std.testing.expectEqualStrings("B", moves[0].to);

    try std.testing.expectError(error.LineCountChanged, planMoves(a, &sources, &.{ "a", "b" }, &msg));
    try std.testing.expectError(error.DuplicateDestination, planMoves(a, &sources, &.{ "x", "./x", "c" }, &msg));
}

fn testFile(dir: Io.Dir, name: []const u8, data: []const u8) !void {
    try dir.writeFile(std.testing.io, .{ .sub_path = name, .data = data });
}

fn expectContent(dir: Io.Dir, name: []const u8, data: []const u8) !void {
    const got = try dir.readFileAlloc(std.testing.io, name, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(data, got);
}

test "run: swap, chain and move into a new subdirectory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf: [512]u8 = undefined;
    var msg: Io.Writer = .fixed(&buf);

    try testFile(tmp.dir, "a", "A");
    try testFile(tmp.dir, "b", "B");
    try testFile(tmp.dir, "c", "C");
    try testFile(tmp.dir, "d", "D");
    // a<->b swap, and a chain: c takes d's name while d moves into a directory that doesn't exist yet
    const outcome = try run(std.testing.io, arena.allocator(), tmp.dir, &.{ "a", "b", "c", "d" }, "b\na\nd\nsub/dir/e\n", &msg);
    try std.testing.expectEqual(Outcome{ .renamed = 4 }, outcome);
    try expectContent(tmp.dir, "a", "B");
    try expectContent(tmp.dir, "b", "A");
    try expectContent(tmp.dir, "d", "C");
    try expectContent(tmp.dir, "sub/dir/e", "D");
    try std.testing.expectEqual(@as(usize, 0), msg.end);
}

test "run: refuses to overwrite or to go under a regular file, touching nothing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf: [512]u8 = undefined;
    var msg: Io.Writer = .fixed(&buf);

    try testFile(tmp.dir, "a", "A");
    try testFile(tmp.dir, "f", "F");
    try std.testing.expectError(error.DestinationExists, run(std.testing.io, arena.allocator(), tmp.dir, &.{"a"}, "f\n", &msg));
    try std.testing.expectError(error.NotADirectory, run(std.testing.io, arena.allocator(), tmp.dir, &.{"a"}, "f/a\n", &msg));
    try expectContent(tmp.dir, "a", "A");

    // ...but going under "f" is fine when "f" itself moves away
    const outcome = try run(std.testing.io, arena.allocator(), tmp.dir, &.{ "a", "f" }, "f/a\ng\n", &msg);
    try std.testing.expectEqual(Outcome{ .renamed = 2 }, outcome);
    try expectContent(tmp.dir, "f/a", "A");
    try expectContent(tmp.dir, "g", "F");
}

test "run: a name that is too long is refused up front" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf: [1024]u8 = undefined;
    var msg: Io.Writer = .fixed(&buf);

    try testFile(tmp.dir, "a", "A");
    try testFile(tmp.dir, "b", "B");
    try std.testing.expectError(error.NameTooLong, run(std.testing.io, arena.allocator(), tmp.dir, &.{ "a", "b" }, "c\n" ++ "x" ** 300 ++ "\n", &msg));
    try expectContent(tmp.dir, "a", "A");
    try expectContent(tmp.dir, "b", "B");
}

test "run: a failed rename in the second pass puts the file back" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf: [1024]u8 = undefined;
    var msg: Io.Writer = .fixed(&buf);

    // Moving into a read-only directory passes the checks but the rename itself fails
    try testFile(tmp.dir, "a", "A");
    try testFile(tmp.dir, "b", "B");
    try tmp.dir.createDir(std.testing.io, "ro", .fromMode(0o555));
    defer tmp.dir.setFilePermissions(std.testing.io, "ro", .fromMode(0o755), .{}) catch {};
    const outcome = try run(std.testing.io, arena.allocator(), tmp.dir, &.{ "a", "b" }, "ro/a\nc\n", &msg);
    try std.testing.expectEqual(Outcome{ .renamed = 1, .failed = 1 }, outcome);
    try expectContent(tmp.dir, "a", "A");
    try expectContent(tmp.dir, "c", "B");
    try std.testing.expect(std.mem.indexOf(u8, msg.buffered(), "left unchanged") != null);
}
