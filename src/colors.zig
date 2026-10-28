// File name colors like FreeBSD's ls -G (LSCOLORS) and date colors by age like lsd
const std = @import("std");
const FileEntry = @import("FileEntry.zig");

// The grey background of the selected row (render.zig uses it too)
pub const selected_bg = "\x1B[48;5;238m";

// The order of the color pairs in LSCOLORS (see man ls)
pub const Type = enum {
    dir,
    symlink,
    socket,
    pipe,
    executable,
    block_device,
    char_device,
    setuid,
    setgid,
    // writable by others, with the sticky bit (like /tmp)
    dir_others_sticky,
    // writable by others, without the sticky bit
    dir_others,
};

// One color pair: foreground and background 0-7 (null = the terminal's default), uppercase letter = bold
pub const Color = struct {
    fg: ?u3 = null,
    bg: ?u3 = null,
    bold: bool = false,
};

// ls's default when LSCOLORS is not set
pub const default_lscolors = "exfxcxdxbxegedabagacad";

pub const Palette = struct {
    colors: [@typeInfo(Type).@"enum".fields.len]Color,

    // Same rules as ls: a-h = black, red, green, brown, blue, magenta, cyan, light grey,
    // A-H = the same in bold, x = default color, legacy 0-7 also work; a pair that is
    // missing (too short a string) gets ls's default and an invalid letter means default color
    pub fn parse(lscolors: []const u8) Palette {
        var palette: Palette = undefined;
        for (&palette.colors, 0..) |*color, i| {
            const pair = if (lscolors.len >= 2 * i + 2) lscolors[2 * i ..][0..2] else default_lscolors[2 * i ..][0..2];
            color.* = .{};
            for (pair, 0..) |c, j| {
                const value: ?u3 = switch (c) {
                    'a'...'h' => @intCast(c - 'a'),
                    'A'...'H' => blk: {
                        color.bold = true;
                        break :blk @intCast(c - 'A');
                    },
                    '0'...'7' => @intCast(c - '0'),
                    else => null,
                };
                if (j == 0) color.fg = value else color.bg = value;
            }
        }
        return palette;
    }

    pub const default: Palette = parse(default_lscolors);

    // The color of a file, or null for a plain file (ls doesn't color those)
    pub fn colorFor(self: *const Palette, file: FileEntry) ?Color {
        const t = typeOf(file) orelse return null;
        return self.colors[@intFromEnum(t)];
    }
};

// Which LSCOLORS type a file is, in the same order of checks as ls (print.c colortype)
pub fn typeOf(file: FileEntry) ?Type {
    const mode = file.permissions.toMode();
    // the symlink itself, no matter where it points to
    if (file.is_symlink) return .symlink;
    if (file.is_dir) {
        if (mode & 0o002 == 0) return .dir;
        return if (mode & 0o1000 != 0) .dir_others_sticky else .dir_others;
    }
    // for future use: getDirContents skips sockets, pipes and devices for now
    switch (file.kind) {
        .unix_domain_socket => return .socket,
        .named_pipe => return .pipe,
        .block_device => return .block_device,
        .character_device => return .char_device,
        else => {},
    }
    if (mode & 0o111 != 0) {
        if (mode & 0o4000 != 0) return .setuid;
        if (mode & 0o2000 != 0) return .setgid;
        return .executable;
    }
    return null;
}

// Start of the color, written right before the name
pub fn writeStart(w: *std.Io.Writer, color: Color) !void {
    if (color.fg == null and color.bg == null and !color.bold) return;
    try w.writeAll("\x1B[");
    var sep: []const u8 = "";
    if (color.bold) {
        try w.writeAll("1");
        sep = ";";
    }
    if (color.fg) |fg| {
        try w.print("{s}3{d}", .{ sep, fg });
        sep = ";";
    }
    if (color.bg) |bg| try w.print("{s}4{d}", .{ sep, bg });
    try w.writeAll("m");
}

// End of the color: only bold and the colors are turned off (not \x1B[0m), so the italics stay;
// a color with its own background gives the selected row its grey background back
pub fn writeEnd(w: *std.Io.Writer, color: Color, selected: bool) !void {
    if (color.fg == null and color.bg == null and !color.bold) return;
    try w.writeAll("\x1B[22;39m");
    if (color.bg != null) try w.writeAll(if (selected) selected_bg else "\x1B[49m");
}

// Date column colors like lsd's default theme (256-color palette):
// changed within the last hour, within the last day, older
pub const Age = enum { hour, day, older };

pub fn ageOf(date: std.Io.Timestamp, now: std.Io.Timestamp) Age {
    const age_ns = now.toNanoseconds() - date.toNanoseconds();
    if (age_ns < std.time.ns_per_hour) return .hour;
    if (age_ns < std.time.ns_per_day) return .day;
    return .older;
}

pub fn ageColor(age: Age) []const u8 {
    return switch (age) {
        .hour => "\x1B[38;5;40m",
        .day => "\x1B[38;5;42m",
        .older => "\x1B[38;5;36m",
    };
}

// ===================== Tests =====================

fn testFile(mode: std.posix.mode_t, is_dir: bool, is_symlink: bool) FileEntry {
    return .{ .name = "x", .extension = "", .is_dir = is_dir, .is_symlink = is_symlink, .permissions = .fromMode(mode) };
}

test "parse the default LSCOLORS" {
    const p = Palette.default;
    try std.testing.expectEqual(Color{ .fg = 4 }, p.colors[@intFromEnum(Type.dir)]);
    try std.testing.expectEqual(Color{ .fg = 5 }, p.colors[@intFromEnum(Type.symlink)]);
    try std.testing.expectEqual(Color{ .fg = 1 }, p.colors[@intFromEnum(Type.executable)]);
    try std.testing.expectEqual(Color{ .fg = 4, .bg = 6 }, p.colors[@intFromEnum(Type.block_device)]);
    try std.testing.expectEqual(Color{ .fg = 0, .bg = 3 }, p.colors[@intFromEnum(Type.dir_others)]);
}

test "parse: bold, default color, legacy digits, invalid letters and a short string" {
    const p = Palette.parse("ExxA1z");
    try std.testing.expectEqual(Color{ .fg = 4, .bold = true }, p.colors[0]);
    try std.testing.expectEqual(Color{ .fg = null, .bg = 0, .bold = true }, p.colors[1]);
    try std.testing.expectEqual(Color{ .fg = 1, .bg = null }, p.colors[2]);
    // the rest is ls's default
    try std.testing.expectEqual(Palette.default.colors[3], p.colors[3]);
    try std.testing.expectEqual(Palette.default.colors[10], p.colors[10]);
}

test "typeOf follows the order of ls" {
    try std.testing.expectEqual(@as(?Type, null), typeOf(testFile(0o644, false, false)));
    try std.testing.expectEqual(@as(?Type, .executable), typeOf(testFile(0o755, false, false)));
    try std.testing.expectEqual(@as(?Type, .setuid), typeOf(testFile(0o4755, false, false)));
    try std.testing.expectEqual(@as(?Type, .setgid), typeOf(testFile(0o2755, false, false)));
    // setuid without any x bit is not colored
    try std.testing.expectEqual(@as(?Type, null), typeOf(testFile(0o4644, false, false)));
    try std.testing.expectEqual(@as(?Type, .dir), typeOf(testFile(0o755, true, false)));
    try std.testing.expectEqual(@as(?Type, .dir_others_sticky), typeOf(testFile(0o1777, true, false)));
    try std.testing.expectEqual(@as(?Type, .dir_others), typeOf(testFile(0o777, true, false)));
    // a symlink to a directory or an executable is still a symlink
    try std.testing.expectEqual(@as(?Type, .symlink), typeOf(testFile(0o755, true, true)));
    try std.testing.expectEqual(@as(?Type, .symlink), typeOf(testFile(0o755, false, true)));
    var fifo = testFile(0o644, false, false);
    fifo.kind = .named_pipe;
    try std.testing.expectEqual(@as(?Type, .pipe), typeOf(fifo));
}

test "writeStart and writeEnd" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeStart(&w, .{ .fg = 4 });
    try writeStart(&w, .{ .fg = 0, .bg = 3, .bold = true });
    try writeStart(&w, .{ .bg = 2 });
    try writeStart(&w, .{});
    try std.testing.expectEqualStrings("\x1B[34m\x1B[1;30;43m\x1B[42m", w.buffered());

    w = .fixed(&buf);
    try writeEnd(&w, .{ .fg = 4 }, true);
    try writeEnd(&w, .{ .fg = 0, .bg = 3 }, false);
    try writeEnd(&w, .{ .fg = 0, .bg = 3 }, true);
    try std.testing.expectEqualStrings("\x1B[22;39m\x1B[22;39m\x1B[49m\x1B[22;39m" ++ selected_bg, w.buffered());
}

test "ageOf" {
    const now: std.Io.Timestamp = .fromNanoseconds(10 * std.time.ns_per_day);
    const ago = struct {
        fn f(n: std.Io.Timestamp, ns: i96) std.Io.Timestamp {
            return .fromNanoseconds(n.toNanoseconds() - ns);
        }
    }.f;
    try std.testing.expectEqual(Age.hour, ageOf(ago(now, 5 * std.time.ns_per_min), now));
    try std.testing.expectEqual(Age.day, ageOf(ago(now, 3 * std.time.ns_per_hour), now));
    try std.testing.expectEqual(Age.older, ageOf(ago(now, 2 * std.time.ns_per_day), now));
    // a date in the future (wrong clock) counts as new
    try std.testing.expectEqual(Age.hour, ageOf(ago(now, -std.time.ns_per_hour), now));
}
