const std = @import("std");
const Self = @This();

name: []const u8,
extension: []const u8,
is_dir: bool = false,
is_hidden: bool = false,
is_symlink: bool = false,
size: usize = 0,
date: std.Io.Timestamp = .zero,
// uid / gid; null initialize to null if we are unable to get the real values (will be shown as "?")
owner: ?u32 = null,
group: ?u32 = null,
// owner and group will be filled by main() after reading the directory
owner_name: []const u8 = "?",
group_name: []const u8 = "?",
permissions: std.Io.File.Permissions,

pub fn lessThanByName(context: void, a: Self, b: Self) bool {
    _ = context;
    return std.mem.lessThan(u8, a.name, b.name);
}

pub fn lessThanByNameDirsFirst(context: void, a: Self, b: Self) bool {
    _ = context;
    // if a is dir and b is a file, a is first
    if (a.is_dir != b.is_dir) {
        return a.is_dir;
    }
    // if they are both of the same type, sort by name
    return std.mem.lessThan(u8, a.name, b.name);
}

pub fn lessThanByDate(context: void, a: Self, b: Self) bool {
    _ = context;
    // turn the dates of both items to nanoseconds
    const a_ns = a.date.toNanoseconds();
    const b_ns = b.date.toNanoseconds();

    // if we want the newest item on top, the nanosecond count of 'a' must be bigger (newer) than 'b'
    if (a_ns != b_ns) {
        return a_ns > b_ns;
    }

    // if their nanosecond time is exactly the same, sort by name
    return std.mem.lessThan(u8, a.name, b.name);
}

pub fn lessThanByDateDirsFirst(context: void, a: Self, b: Self) bool {
    _ = context;

    // directories go first, the same principle as above
    if (a.is_dir != b.is_dir) {
        return a.is_dir;
    }
    //again, the same principle
    const a_ns = a.date.toNanoseconds();
    const b_ns = b.date.toNanoseconds();

    if (a_ns != b_ns) {
        return a_ns > b_ns;
    }
    return std.mem.lessThan(u8, a.name, b.name);
}

// sorting by size: directories (size is shown as "-") go first by name,
// then files starting from the smallest file, files of the same size will be sorted by name
pub fn lessThanBySizeAsc(context: void, a: Self, b: Self) bool {
    _ = context;
    if (a.is_dir != b.is_dir) return a.is_dir;
    if (a.is_dir or a.size == b.size) return std.mem.lessThan(u8, a.name, b.name);
    return a.size < b.size;
}

// the same, but from the biggest one
pub fn lessThanBySizeDesc(context: void, a: Self, b: Self) bool {
    _ = context;
    if (a.is_dir != b.is_dir) return a.is_dir;
    if (a.is_dir or a.size == b.size) return std.mem.lessThan(u8, a.name, b.name);
    return a.size > b.size;
}

pub fn getFormattedDateTime(self: Self, buf: []u8) []const u8 {
    // turn nanoseconds to seconds
    const total_seconds = @divTrunc(self.date.toNanoseconds(), std.time.ns_per_s);

    // initialize EpochSeconds struct
    const epoch_secs = std.time.epoch.EpochSeconds{ .secs = @intCast(total_seconds) };

    // calculate calendar day, month, year
    const epoch_day = epoch_secs.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    // calculate time in the relevant day
    const day_seconds = epoch_secs.getDaySeconds();

    // write into buffer in the format of YYYY-MM-DD HH:MM:SS
    // note: day_index starts from 0, therefore we add + 1
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    }) catch "0000-00-00 00:00:00";
}

pub fn getFormattedSize(self: Self, buf: []u8) []const u8 {
    // directories usually don't have a meaningful size in bytes, so we return "-"
    if (self.is_dir) return "-";

    const bytes = @as(f64, @floatFromInt(self.size));

    //  I opted for KiBytes, MiBytes, GiBytes, if you want KBytes, change the 1024's into 1000's
    if (bytes < 1024) {
        return std.fmt.bufPrint(buf, "{d}B", .{self.size}) catch "0B";
    }

    const kilo = bytes / 1024.0;
    if (kilo < 1024) {
        return std.fmt.bufPrint(buf, "{d:.1}KiB", .{kilo}) catch "0KiB";
    }

    const mega = kilo / 1024.0;
    if (mega < 1024) {
        return std.fmt.bufPrint(buf, "{d:.1}MiB", .{mega}) catch "0MiB";
    }

    const giga = mega / 1024.0;
    return std.fmt.bufPrint(buf, "{d:.1}GiB", .{giga}) catch "0GiB";
}

pub fn getFormattedPermissions(self: Self, buf: []u8) []const u8 {
    const perms = @intFromEnum(self.permissions) & 0o777;

    buf[0] = if (self.is_dir) 'd' else if (self.is_symlink) 'l' else '-';
    buf[1] = if ((perms & 0o400) != 0) 'r' else '-';
    buf[2] = if ((perms & 0o200) != 0) 'w' else '-';
    buf[3] = if ((perms & 0o100) != 0) 'x' else '-';
    buf[4] = if ((perms & 0o040) != 0) 'r' else '-';
    buf[5] = if ((perms & 0o020) != 0) 'w' else '-';
    buf[6] = if ((perms & 0o010) != 0) 'x' else '-';
    buf[7] = if ((perms & 0o004) != 0) 'r' else '-';
    buf[8] = if ((perms & 0o002) != 0) 'w' else '-';
    buf[9] = if ((perms & 0o001) != 0) 'x' else '-';

    return buf[0..10];
}

// ===================== Tests =====================

fn testEntry(name: []const u8, is_dir: bool, size: usize) Self {
    return .{ .name = name, .extension = "", .is_dir = is_dir, .size = size, .permissions = @enumFromInt(0o644) };
}

fn expectOrder(comptime lessThan: fn (void, Self, Self) bool, expected: []const []const u8) !void {
    var items = [_]Self{
        testEntry("b.txt", false, 300),
        testEntry("zdir", true, 0),
        testEntry("a.txt", false, 300),
        testEntry("c.txt", false, 5),
        testEntry("adir", true, 0),
    };
    std.mem.sort(Self, &items, {}, lessThan);
    for (expected, items) |name, item| try std.testing.expectEqualStrings(name, item.name);
}

test "sorting by name" {
    try expectOrder(lessThanByName, &.{ "a.txt", "adir", "b.txt", "c.txt", "zdir" });
    try expectOrder(lessThanByNameDirsFirst, &.{ "adir", "zdir", "a.txt", "b.txt", "c.txt" });
}

test "sorting by size: dirs first, the same size then by name" {
    try expectOrder(lessThanBySizeAsc, &.{ "adir", "zdir", "c.txt", "a.txt", "b.txt" });
    try expectOrder(lessThanBySizeDesc, &.{ "adir", "zdir", "a.txt", "b.txt", "c.txt" });
}

test "sorting by date: newest first" {
    var items = [_]Self{ testEntry("old", false, 0), testEntry("new", false, 0), testEntry("dir", true, 0) };
    items[0].date = .fromNanoseconds(1 * std.time.ns_per_s);
    items[1].date = .fromNanoseconds(2 * std.time.ns_per_s);
    items[2].date = .fromNanoseconds(0);
    std.mem.sort(Self, &items, {}, lessThanByDate);
    try std.testing.expectEqualStrings("new", items[0].name);
    std.mem.sort(Self, &items, {}, lessThanByDateDirsFirst);
    try std.testing.expectEqualStrings("dir", items[0].name);
    try std.testing.expectEqualStrings("new", items[1].name);
}

test "getFormattedSize" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("512B", testEntry("f", false, 512).getFormattedSize(&buf));
    try std.testing.expectEqualStrings("1.5KiB", testEntry("f", false, 1536).getFormattedSize(&buf));
    try std.testing.expectEqualStrings("2.0MiB", testEntry("f", false, 2 * 1024 * 1024).getFormattedSize(&buf));
    try std.testing.expectEqualStrings("-", testEntry("d", true, 4096).getFormattedSize(&buf));
}

test "getFormattedPermissions" {
    var buf: [10]u8 = undefined;
    try std.testing.expectEqualStrings("-rw-r--r--", testEntry("f", false, 0).getFormattedPermissions(&buf));
    var dir = testEntry("d", true, 0);
    dir.permissions = @enumFromInt(0o755);
    try std.testing.expectEqualStrings("drwxr-xr-x", dir.getFormattedPermissions(&buf));
}

test "getFormattedDateTime" {
    var buf: [32]u8 = undefined;
    var entry = testEntry("f", false, 0);
    // 2001-09-09 01:46:40 UTC
    entry.date = .fromNanoseconds(1_000_000_000 * std.time.ns_per_s);
    try std.testing.expectEqualStrings("2001-09-09 01:46:40", entry.getFormattedDateTime(&buf));
}
