// aliases parsed from ~/.aliases
// written entirely by claude
const std = @import("std");

// An alias from ~/.aliases that only changes directory: alias dl="cd ~/Downloads"
pub const Alias = struct {
    name: []const u8,
    path: []const u8,
    // Real path (/home/... -> /usr/home/..., no trailing '/'), used to match
    // aliases against directories in the listing
    real_path: []const u8,
};

// Loads ~/.aliases and resolves real paths (realpath). Everything goes into the arena
// aliases have the same lifetime as the entire program, there's no need to free them
pub fn loadAliases(io: std.Io, arena: std.mem.Allocator, home: []const u8) ![]const Alias {
    const file_path = try std.fs.path.join(arena, &.{ home, ".aliases" });
    const contents = std.Io.Dir.cwd().readFileAlloc(io, file_path, arena, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return &.{}, // no file = no aliases
        else => return err,
    };

    const aliases = try parseAliases(arena, contents, home);
    for (aliases) |*alias| {
        // If the directory does not (yet) exist, realpath fails – the text-only path from parseAliases remains
        var real_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (std.Io.Dir.realPathFileAbsolute(io, alias.path, &real_buf)) |len| {
            alias.real_path = try arena.dupe(u8, real_buf[0..len]);
        } else |_| {}
    }
    return aliases;
}

// Takes only lines of the form alias name="cd path" (or 'cd path'), the rest is skipped.
// real_path here is just the cleaned-up text path; loadAliases replaces it with the real one if the directory exists
pub fn parseAliases(arena: std.mem.Allocator, contents: []const u8, home: []const u8) ![]Alias {
    var list: std.ArrayList(Alias) = .empty;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        // Comments (#alias ...) and the other lines are skipped
        if (!std.mem.startsWith(u8, line, "alias ")) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const name = std.mem.trim(u8, line["alias ".len..eq], " \t");
        // we trim the quotes " " or ' '
        const value = std.mem.trim(u8, line[eq + 1 ..], "\"' \t");
        if (!std.mem.startsWith(u8, value, "cd ")) continue;
        const target = std.mem.trim(u8, value["cd ".len..], " \t");
        // "cd x && ls" is not a pure directory change, so it is ignored
        if (name.len == 0 or target.len == 0 or std.mem.indexOfAny(u8, target, " ;&|") != null) continue;

        // ~ or ~/... is replaced by home directory
        const path = if (std.mem.eql(u8, target, "~") or std.mem.startsWith(u8, target, "~/"))
            try std.mem.concat(arena, u8, &.{ home, target[1..] })
        else
            target;
        // the relative "cd foo" (not absolute) depends on our current directory and therefore is not suitable for use in our program
        if (!std.fs.path.isAbsolute(path)) continue;

        try list.append(arena, .{ .name = name, .path = path, .real_path = try std.fs.path.resolve(arena, &.{path}) });
    }
    return list.toOwnedSlice(arena);
}

// Alias matches the filter if its name contains the text of the filter (case insensitive)
fn aliasMatchesFilter(alias: Alias, filter: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(alias.name, filter) != null;
}

// Aliases which match the filter
pub fn getFilteredAliases(allocator: std.mem.Allocator, aliases: []const Alias, filter: []const u8) ![]const Alias {
    var result: std.ArrayList(Alias) = .empty;
    errdefer result.deinit(allocator);
    for (aliases) |alias| {
        if (aliasMatchesFilter(alias, filter)) {
            try result.append(allocator, alias);
        }
    }
    return result.toOwnedSlice(allocator);
}

// the only alias which matches the filter, otherwise null – no allocation
pub fn singleAliasMatch(aliases: []const Alias, filter: []const u8) ?Alias {
    var found: ?Alias = null;
    for (aliases) |alias| {
        if (!aliasMatchesFilter(alias, filter)) continue;
        if (found != null) return null;
        found = alias;
    }
    return found;
}

// ===================== Test =====================

test "parseAliases takes only clean `cd somewhere` types of aliases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text =
        \\alias dl="cd ~/Downloads"
        \\alias proj='cd /usr/home/foouser/projects'
        \\#alias old="cd /old"
        \\alias ll="ls -la"
        \\alias both="cd /tmp && ls"
        \\alias rel="cd foo"
        \\alias empty="cd "
        \\  alias log = "cd /var/log/"
        \\export PATH=/bin
    ;
    const aliases = try parseAliases(arena.allocator(), text, "/home/test");
    try std.testing.expectEqual(@as(usize, 3), aliases.len);

    try std.testing.expectEqualStrings("dl", aliases[0].name);
    try std.testing.expectEqualStrings("/home/test/Downloads", aliases[0].path);
    try std.testing.expectEqualStrings("proj", aliases[1].name);
    try std.testing.expectEqualStrings("/usr/home/foouser/projects", aliases[1].path);
    try std.testing.expectEqualStrings("log", aliases[2].name);
    // real_path without '/' at the end
    try std.testing.expectEqualStrings("/var/log", aliases[2].real_path);
}
