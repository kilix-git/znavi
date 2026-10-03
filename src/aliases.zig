// cd aliasy zo ~/.aliases: načítanie, parsovanie a filtrovanie podľa mena
// toto cele napisal claude
const std = @import("std");

// Alias zo ~/.aliases, ktorý iba mení adresár: alias rev="cd ~/cloud-local/revizie/"
pub const Alias = struct {
    name: []const u8,
    path: []const u8,
    // Skutočná cesta (/home/... -> /usr/home/..., bez lomky na konci) na porovnanie s adresármi v zozname
    real_path: []const u8,
};

// Načíta ~/.aliases a doplní skutočné cesty (realpath). Všetko ide do arény procesu –
// aliasy žijú do konca programu, netreba ich uvoľňovať.
pub fn loadAliases(io: std.Io, arena: std.mem.Allocator, home: []const u8) ![]const Alias {
    const file_path = try std.fs.path.join(arena, &.{ home, ".aliases" });
    const contents = std.Io.Dir.cwd().readFileAlloc(io, file_path, arena, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return &.{}, // bez ~/.aliases jednoducho nemáme aliasy
        else => return err,
    };

    const aliases = try parseAliases(arena, contents, home);
    for (aliases) |*alias| {
        // Ak adresár (zatiaľ) neexistuje, realpath zlyhá – ostane textová cesta z parseAliases
        var real_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (std.Io.Dir.realPathFileAbsolute(io, alias.path, &real_buf)) |len| {
            alias.real_path = try arena.dupe(u8, real_buf[0..len]);
        } else |_| {}
    }
    return aliases;
}

// Z textu ~/.aliases vyberie iba aliasy tvaru alias meno="cd cesta" (alebo 'cd cesta'), ostatné preskočí.
// Bez prístupu na disk: real_path je zatiaľ iba upravená textová cesta (bez lomky na konci)
pub fn parseAliases(arena: std.mem.Allocator, contents: []const u8, home: []const u8) ![]Alias {
    var list: std.ArrayList(Alias) = .empty;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        // Komentáre (#alias ...) a ostatné riadky preskočíme
        if (!std.mem.startsWith(u8, line, "alias ")) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const name = std.mem.trim(u8, line["alias ".len..eq], " \t");
        // Hodnotu zbavíme úvodzoviek: "cd ..." alebo 'cd ...'
        const value = std.mem.trim(u8, line[eq + 1 ..], "\"' \t");
        if (!std.mem.startsWith(u8, value, "cd ")) continue;
        const target = std.mem.trim(u8, value["cd ".len..], " \t");
        // "cd x && ls" a podobné nie sú čistá zmena adresára
        if (name.len == 0 or target.len == 0 or std.mem.indexOfAny(u8, target, " ;&|") != null) continue;

        // ~ alebo ~/... nahradíme domovským adresárom
        const path = if (std.mem.eql(u8, target, "~") or std.mem.startsWith(u8, target, "~/"))
            try std.mem.concat(arena, u8, &.{ home, target[1..] })
        else
            target;
        // Relatívne "cd foo" závisí od toho, kde práve sme – na skok sa nehodí
        if (!std.fs.path.isAbsolute(path)) continue;

        try list.append(arena, .{ .name = name, .path = path, .real_path = try std.fs.path.resolve(arena, &.{path}) });
    }
    return list.toOwnedSlice(arena);
}

// Alias zodpovedá filtru, ak jeho meno obsahuje text filtra (bez ohľadu na veľkosť písmen)
fn aliasMatchesFilter(alias: Alias, filter: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(alias.name, filter) != null;
}

// Aliasy zodpovedajúce filtru
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

// Jediný alias zodpovedajúci filtru, inak null (žiadny alebo viac) – bez alokácie
pub fn singleAliasMatch(aliases: []const Alias, filter: []const u8) ?Alias {
    var found: ?Alias = null;
    for (aliases) |alias| {
        if (!aliasMatchesFilter(alias, filter)) continue;
        if (found != null) return null;
        found = alias;
    }
    return found;
}

// ===================== Testy =====================

test "parseAliases berie iba čisté cd aliasy" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text =
        \\alias dl="cd ~/Downloads"
        \\alias proj='cd /usr/home/matej/projects'
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
    try std.testing.expectEqualStrings("/usr/home/matej/projects", aliases[1].path);
    try std.testing.expectEqualStrings("log", aliases[2].name);
    // real_path bez lomky na konci
    try std.testing.expectEqualStrings("/var/log", aliases[2].real_path);
}
