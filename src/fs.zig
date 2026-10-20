// this file does things with the filesystem, opens a dir, then reads the contents and fills up the []FileEntry struct with data if it is possible
const std = @import("std");
const FileEntry = @import("FileEntry.zig");

// this function is used precisely once after starting the program, then current_dir is changed and this function never gets called again
// arg is an argument from the command line, we can run znavi with a path as an argument, so it opens there
pub fn getStartingDir(io: std.Io, arg: ?[]const u8, out_buffer: []u8) ![]u8 {
    const path = arg orelse {
        const path_len = try std.process.currentPath(io, out_buffer);
        return out_buffer[0..path_len];
    };
    // we must repair the relative path (if the program was started with relative path as an arg) to get real path
    const path_len = try std.Io.Dir.cwd().realPathFile(io, path, out_buffer);
    const real_path = out_buffer[0..path_len];
    // and we must also check if the arg is a dir and not a file
    var dir = try std.Io.Dir.openDirAbsolute(io, real_path, .{});
    dir.close(io);
    return real_path;
}

// lookupName, getOwnerGroup written by claude, tried to comprehend and comment by me
pub fn lookupName(
    comptime kind: enum { user, group },
    map: *std.AutoHashMapUnmanaged(u32, []const u8),
    allocator: std.mem.Allocator,
    maybe_id: ?u32,
) ![]const u8 {
    // return "?" instead of null if there is not an optional maybe_id in the argument
    const id = maybe_id orelse return "?";
    // this is the most common return, a cache hit
    if (map.get(id)) |name| return name;

    // this is the comptime switch by kind
    // we call libc functions as required by kind
    const c_name: ?[*:0]const u8 = switch (kind) {
        .user => if (std.c.getpwuid(id)) |pw| pw.name else null,
        .group => if (std.c.getgrgid(id)) |gr| gr.name else null,
    };
    // make an owned copy, if name was found, std.mem.span walks the C-style string to it's '\0' terminator and returns a Zig slice
    const name = if (c_name) |n|
        try allocator.dupe(u8, std.mem.span(n))
    else
        // if the name was not found, put in the id itself
        try std.fmt.allocPrint(allocator, "{d}", .{id});
    try map.put(allocator, id, name);
    return name;
}

// Zig's std.Io.File.Stat does not have owner and group, so let's use libc's function fstatat().
fn getOwnerGroup(dir: std.Io.Dir, name: []const u8) ?struct { uid: u32, gid: u32 } {
    // prepare a new buffer, +1 size for the terminating '\0' (we are creating a C-style string)
    var name_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    // name_z will contain a C-style string which we can then feed to fstatat
    const name_z = std.fmt.bufPrintZ(&name_buf, "{s}", .{name}) catch return null;
    var st: std.c.Stat = undefined;
    // if the first call does not end in zero, it failed (broken symlink) and we try to stat the symlink itself
    // the function returns null, if both calls fail
    if (std.c.fstatat(dir.handle, name_z, &st, 0) != 0 and
        std.c.fstatat(dir.handle, name_z, &st, std.c.AT.SYMLINK_NOFOLLOW) != 0) return null;
    return .{ .uid = st.uid, .gid = st.gid };
}

// skipped_error: arg is meant to contain an error if it occurs while reading an entry
// with_owner: argument says if we should check the entries' owner/group, if set to false, we do not do those checks (:vo or :vg turned ON)
pub fn getDirContents(
    io: std.Io,
    arena_allocator: std.mem.Allocator,
    directory_name: []const u8,
    skipped_error: *?anyerror,
    with_owner: bool,
) ![]FileEntry {
    var list: std.ArrayList(FileEntry) = .empty;
    errdefer list.deinit(arena_allocator);

    var dir = try std.Io.Dir.openDirAbsolute(io, directory_name, .{ .iterate = true });
    defer dir.close(io);

    var iterator = dir.iterate();

    // as a first entry, we must add the path to the parent directory "../"
    // stat() the ".." directory, to get real dates and perms; if the stat() fails,
    // we will fill those variables with zeroes instead of 'undefined'
    // only do this if we are not in the '/' root directory, as it has no parent
    if (!std.mem.eql(u8, directory_name, "/")) {
        const parent_stat = dir.statFile(io, "..", .{}) catch null;
        const parent_owner = if (with_owner) getOwnerGroup(dir, "..") else null;
        try list.append(arena_allocator, .{
            .name = "..",
            .extension = "",
            .is_dir = true,
            .is_parent = true,
            .is_hidden = false,
            .is_symlink = false,
            .size = if (parent_stat) |ps| ps.size else 0,
            .date = if (parent_stat) |ps| ps.mtime else .zero,
            .owner = if (parent_owner) |og| og.uid else null,
            .group = if (parent_owner) |og| og.gid else null,
            .permissions = if (parent_stat) |ps| ps.permissions else .fromMode(0),
        });
    }
    //
    // next we iterate the actual entries:
    while (try iterator.next(io)) |entry| {
        // detect if it is a hidden file (the name starts with a '.', but it is not "./" nor "../")
        const is_hidden = entry.name.len > 0 and entry.name[0] == '.' and
            !std.mem.eql(u8, entry.name, ".") and !std.mem.eql(u8, entry.name, "..");

        // broken symlink: stat of the target fails, so let's stat the symlink itself
        // if that fails as well, we skip the entry and write the error and continue onto the next entry
        const stat = dir.statFile(io, entry.name, .{}) catch
            dir.statFile(io, entry.name, .{ .follow_symlinks = false }) catch |err| {
            skipped_error.* = err;
            continue;
        };

        // remember the function argument? Let's not do unnecessary operations
        const owner_group = if (with_owner) getOwnerGroup(dir, entry.name) else null;

        const is_symlink = (entry.kind == .sym_link);
        const is_dir = if (is_symlink) (stat.kind == .directory) else (entry.kind == .directory);

        // we prepare the final string vars
        var final_name: []const u8 = undefined;
        var final_ext: []const u8 = "";

        // and fill them by duping on the arena
        if (entry.kind == .file) {
            final_name = try arena_allocator.dupe(u8, std.fs.path.stem(entry.name));
            final_ext = try arena_allocator.dupe(u8, std.fs.path.extension(entry.name));
        } else {
            final_name = try arena_allocator.dupe(u8, entry.name);
        }

        // finally, we have everything to add to the []FileEntries list
        // we only add files, dirs and symlinks
        if (entry.kind == .directory or entry.kind == .file or is_symlink) {
            try list.append(arena_allocator, .{
                .name = final_name,
                .extension = final_ext,
                .is_dir = is_dir,
                .is_hidden = is_hidden,
                .is_symlink = is_symlink,
                .size = stat.size,
                .date = stat.mtime,
                .owner = if (owner_group) |og| og.uid else null,
                .group = if (owner_group) |og| og.gid else null,
                .permissions = stat.permissions,
            });
        }
        // other types of files (sockets, FIFO, devices) are not getting shown - xdg-open would be blocked on those
    }
    return try list.toOwnedSlice(arena_allocator);
}

// checks if it is a normal file, if it is a FIFO, openFile would block
pub fn isTextFile(io: std.Io, path: []const u8) bool {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    defer file.close(io);
    var sniff: [8192]u8 = undefined;
    var reader = file.reader(io, &.{});
    const n = reader.interface.readSliceShort(&sniff) catch return false;
    return looksLikeText(sniff[0..n]);
}
//
// similar check as in grep: zero byte in the first 8KB means it is a binary file
pub fn looksLikeText(bytes: []const u8) bool {
    return std.mem.indexOfScalar(u8, bytes, 0) == null;
}

test "looksLikeText" {
    try std.testing.expect(looksLikeText("ahoj\nsvet"));
    try std.testing.expect(looksLikeText("")); //
    try std.testing.expect(!looksLikeText("\x7fELF\x02\x01\x00\x00"));
}
