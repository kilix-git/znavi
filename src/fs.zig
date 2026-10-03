// Práca so súborovým systémom: štartovací adresár, obsah adresára, vlastník a skupina
const std = @import("std");
const file_entry = @import("FileEntry.zig");

//tato funkcia sa pouziva iba raz po spusteni programu, potom sa current_dir meni a uz ju viac nepouzijeme
// arg: adresár z príkazového riadku (znavi ~/docs, znavi ..), null = aktuálny adresár
pub fn getStartingDir(io: std.Io, arg: ?[]const u8, out_buffer: []u8) ![]u8 {
    const path = arg orelse {
        const path_len = try std.process.currentPath(io, out_buffer);
        return out_buffer[0..path_len];
    };
    // Relatívnu cestu vyriešime voči aktuálnemu adresáru, výsledok je skutočná absolútna cesta
    const path_len = try std.Io.Dir.cwd().realPathFile(io, path, out_buffer);
    const real_path = out_buffer[0..path_len];
    // Overíme, že je to adresár (súbor by skončil chybou NotDir)
    var dir = try std.Io.Dir.openDirAbsolute(io, real_path, .{});
    dir.close(io);
    return real_path;
}

// Meno používateľa / skupiny pre id: najprv z cache, inak cez getpwuid / getgrgid a uložíme.
// Id bez záznamu (napr. súbory z iného počítača) zobrazíme ako číslo, rovnako ako ls.
pub fn lookupName(
    comptime kind: enum { user, group },
    map: *std.AutoHashMapUnmanaged(u32, []const u8),
    allocator: std.mem.Allocator,
    maybe_id: ?u32,
) ![]const u8 {
    const id = maybe_id orelse return "?";
    if (map.get(id)) |name| return name;

    const c_name: ?[*:0]const u8 = switch (kind) {
        .user => if (std.c.getpwuid(id)) |pw| pw.name else null,
        .group => if (std.c.getgrgid(id)) |gr| gr.name else null,
    };
    const name = if (c_name) |n|
        try allocator.dupe(u8, std.mem.span(n))
    else
        try std.fmt.allocPrint(allocator, "{d}", .{id});
    try map.put(allocator, id, name);
    return name;
}

// std.Io.File.Stat nemá vlastníka ani skupinu, tak uid/gid zistíme cez libc fstatat.
// Rovnako ako pri statFile: najprv cieľ symlinku, pri zlomenom symlinku samotná linka.
fn getOwnerGroup(dir: std.Io.Dir, name: []const u8) ?struct { uid: u32, gid: u32 } {
    var name_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const name_z = std.fmt.bufPrintZ(&name_buf, "{s}", .{name}) catch return null;
    var st: std.c.Stat = undefined;
    if (std.c.fstatat(dir.handle, name_z, &st, 0) != 0 and
        std.c.fstatat(dir.handle, name_z, &st, std.c.AT.SYMLINK_NOFOLLOW) != 0) return null;
    return .{ .uid = st.uid, .gid = st.gid };
}

// skipped_error: sem zapíšeme chybu položky, ktorú sa nepodarilo načítať (zvyšok adresára sa načíta normálne)
// with_owner: zisťovať uid/gid (extra fstatat na položku) – iba keď je zapnuté :vo alebo :vg
pub fn getDirContents(
    io: std.Io,
    arena_allocator: std.mem.Allocator,
    directory_name: []const u8,
    skipped_error: *?anyerror,
    with_owner: bool,
) ![]file_entry {
    var list: std.ArrayList(file_entry) = .empty;
    errdefer list.deinit(arena_allocator);

    var dir = try std.Io.Dir.openDirAbsolute(io, directory_name, .{ .iterate = true });
    defer dir.close(io);

    var iterator = dir.iterate();

    // Pridanie nadradeného adresára "../" (statický literál netreba duplikovať)
    // Stat "..", aby mal skutočný dátum a práva; ak zlyhá, dáme nuly namiesto undefined
    const parent_stat = dir.statFile(io, "..", .{}) catch null;
    const parent_owner = if (with_owner) getOwnerGroup(dir, "..") else null;
    try list.append(arena_allocator, .{
        .name = "..",
        .extension = "",
        .is_dir = true,
        .is_hidden = false,
        .is_symlink = false,
        .size = if (parent_stat) |ps| ps.size else 0,
        .date = if (parent_stat) |ps| ps.mtime else .zero,
        .owner = if (parent_owner) |og| og.uid else null,
        .group = if (parent_owner) |og| og.gid else null,
        .permissions = if (parent_stat) |ps| ps.permissions else .fromMode(0),
    });

    while (try iterator.next(io)) |entry| {
        // Detekcia, či ide o skrytý súbor (názov začína bodkou, ale nie je to "." ani "..")
        const is_hidden = entry.name.len > 0 and entry.name[0] == '.' and
            !std.mem.eql(u8, entry.name, ".") and !std.mem.eql(u8, entry.name, "..");

        // Zlomený symlink: stat cieľa zlyhá, tak spravíme stat samotnej linky (ako ls)
        // Ak zlyhá aj ten, položku preskočíme a chybu ukážeme v stavovom riadku
        const stat = dir.statFile(io, entry.name, .{}) catch
            dir.statFile(io, entry.name, .{ .follow_symlinks = false }) catch |err| {
            skipped_error.* = err;
            continue;
        };

        const owner_group = if (with_owner) getOwnerGroup(dir, entry.name) else null;

        const is_symlink = (entry.kind == .sym_link);
        const is_dir = if (is_symlink) (stat.kind == .directory) else (entry.kind == .directory);

        var final_name: []const u8 = undefined;
        var final_ext: []const u8 = "";

        if (entry.kind == .file) {
            final_name = try arena_allocator.dupe(u8, std.fs.path.stem(entry.name));
            final_ext = try arena_allocator.dupe(u8, std.fs.path.extension(entry.name));
        } else {
            final_name = try arena_allocator.dupe(u8, entry.name);
        }

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
        // Ostatné typy (sockety, FIFO, zariadenia) zámerne nezobrazujeme – xdg-open by sa na FIFO zasekol
    }
    return try list.toOwnedSlice(arena_allocator);
}

// Heuristika ako git/grep: nulový bajt v prvých 8 KB = binárny súbor
pub fn looksLikeText(bytes: []const u8) bool {
    return std.mem.indexOfScalar(u8, bytes, 0) == null;
}

// Volať len na bežný súbor (openFile to overí cez stat) – na FIFO by open zablokoval
pub fn isTextFile(io: std.Io, path: []const u8) bool {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    defer file.close(io);
    var sniff: [8192]u8 = undefined;
    var reader = file.reader(io, &.{});
    const n = reader.interface.readSliceShort(&sniff) catch return false;
    return looksLikeText(sniff[0..n]);
}

test "looksLikeText" {
    try std.testing.expect(looksLikeText("ahoj\nsvet"));
    try std.testing.expect(looksLikeText("")); // prázdny súbor otvoríme v editore
    try std.testing.expect(!looksLikeText("\x7fELF\x02\x01\x00\x00"));
}
