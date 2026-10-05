// Kreslenie obrazoviek (zoznam súborov, aliasy, nápoveda) a pomocné funkcie na šírku textu
const std = @import("std");
const file_entry = @import("FileEntry.zig");
const Terminal = @import("Terminal.zig");
const state_zig = @import("state.zig");
const ProgramState = state_zig.ProgramState;
const View = state_zig.View;
const commands = @import("commands.zig").commands;

pub fn drawScreen(
    stdout: *std.Io.Writer,
    display_path: []const u8,
    state: *const ProgramState,
    view: *const View,
    active_error: ?anyerror,
    cols: u16,
) !void {
    const mode_string = switch (state.program_mode) {
        .normal => "[N]",
        .command => "[C]",
        .search => "[S]",
        .alias => "[A]",
        .help => "[?]",
    };
    // Lokálny buffer na minimalizáciu syscallov
    var raw_buf: [131_072]u8 = undefined;
    var stream_writer = std.Io.Writer.fixed(&raw_buf);

    // Napísanie aktuálneho adresára (skrátenej verzie)
    try stream_writer.print("{s}:\n", .{display_path});

    // Šírky stĺpcov meriame cez celý (filtrovaný) adresár, nie iba riadky na obrazovke,
    // aby sa stĺpce pri scrollovaní neposúvali
    const longestFileNameLength = getLongestNameLength(view.visible);

    // Začiatok okna vo visible, aby čísla riadkov zodpovedali príkazu :<číslo>
    const window_start = view.window_start;
    // Šírka čísla podľa najväčšieho indexu (minimálne 2 znaky)
    var index_width: usize = 2;
    var max_index = view.visible.len -| 1;
    while (max_index >= 100) : (max_index /= 10) index_width += 1;

    // Šírka stĺpca s menom: najdlhšie meno, ale najviac toľko, koľko ostane z riadku
    // po ukazovateli, čísle a zapnutých stĺpcoch ("   " + šírka hodnoty), aby sa riadok nezalomil
    // Stĺpce vlastníka a skupiny sú široké ako najdlhšie meno na obrazovke
    var owner_width: usize = 0;
    var group_width: usize = 0;
    for (view.visible) |file| {
        owner_width = @max(owner_width, displayWidth(file.owner_name));
        group_width = @max(group_width, displayWidth(file.group_name));
    }
    var reserved: usize = 1 + index_width + 1;
    if (state.viewing.permissions) reserved += 3 + 10;
    if (state.viewing.owner) reserved += 3 + owner_width;
    if (state.viewing.group) reserved += 3 + group_width;
    if (state.viewing.date) reserved += 3 + 19;
    if (state.viewing.size) reserved += 3 + 10;
    // Stĺpec aliasov je široký ako najdlhšie meno aliasu
    var alias_width: usize = 0;
    if (state.viewing.aliases) {
        for (state.aliases) |alias| alias_width = @max(alias_width, displayWidth(alias.name));
        if (alias_width > 0) reserved += 3 + alias_width;
    }
    const name_col = @max(@min(longestFileNameLength, @as(usize, cols) -| reserved), 1);

    for (view.window, window_start..) |file, idx| {
        const file_is_selected = (idx == state.global_index);

        if (file_is_selected) {
            try stream_writer.writeAll("\x1B[48;5;236m");
        }

        const pointer = if (file_is_selected) ">" else " ";
        const italic_start = if (file.is_symlink) "\x1b[3m" else "";
        const italic_end = if (file.is_symlink) "\x1b[23m" else "";
        const slash = if (file.is_dir) "/" else "";

        // Vytlačíme základný riadok súboru
        try stream_writer.writeAll(pointer);
        try stream_writer.print("{[value]d:>[width]} ", .{ .value = idx, .width = index_width });

        // Celé meno (meno + prípona + lomka); ak je dlhšie ako stĺpec, odrežeme ho a dáme "…"
        var full_name_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
        const full_name = std.fmt.bufPrint(&full_name_buf, "{s}{s}{s}", .{ file.name, file.extension, slash }) catch file.name;
        var shown_name = full_name;
        var ellipsis: []const u8 = "";
        if (displayWidth(full_name) > name_col) {
            shown_name = truncateToWidth(full_name, name_col - 1);
            ellipsis = "…";
        }
        try stream_writer.print("{s}{s}{s}{s}", .{ italic_start, shown_name, ellipsis, italic_end });

        // Efektívny padding
        const current_len = displayWidth(shown_name) + @as(usize, if (ellipsis.len > 0) 1 else 0);
        const show_aliases = state.viewing.aliases and alias_width > 0;
        if (show_aliases or state.viewing.size or state.viewing.date or state.viewing.permissions or
            state.viewing.owner or state.viewing.group)
        {
            if (name_col > current_len) {
                const padding = name_col - current_len;
                try stream_writer.print("{[value]s:<[width]}", .{ .value = "", .width = padding });
            }
        }

        // Alias, ktorý vedie do tohto adresára (prázdne miesto, ak žiadny nie je)
        if (show_aliases) {
            try stream_writer.writeAll("   ");
            try writePadded(&stream_writer, state.aliasFor(file) orelse "", alias_width);
        }

        // Fixné medzery a volania formátovania prístupom cez state.viewing
        if (state.viewing.permissions) {
            var perm_buf: [10]u8 = undefined;
            const formatted_perms = file.getFormattedPermissions(&perm_buf);
            try stream_writer.writeAll("   ");
            try stream_writer.writeAll(formatted_perms);
        }

        // Vlastník a skupina zarovnané doľava, ako v ls -l
        if (state.viewing.owner) {
            try stream_writer.writeAll("   ");
            try writePadded(&stream_writer, file.owner_name, owner_width);
        }
        if (state.viewing.group) {
            try stream_writer.writeAll("   ");
            try writePadded(&stream_writer, file.group_name, group_width);
        }

        if (state.viewing.date) {
            var date_buf: [20]u8 = undefined;
            const formatted_date = file.getFormattedDateTime(&date_buf);
            try stream_writer.writeAll("   ");
            try stream_writer.writeAll(formatted_date);
        }

        if (state.viewing.size) {
            var size_buf: [12]u8 = undefined;
            const formatted_size = file.getFormattedSize(&size_buf);
            try stream_writer.writeAll("   ");
            try stream_writer.writeAll(formatted_size);
        }
        if (file_is_selected) {
            try stream_writer.writeAll("\x1B[0m");
        }
        try stream_writer.writeAll("\n");
    }

    try stream_writer.writeAll("\n");

    // Vykreslenie stavového riadku na základe módu
    if (active_error) |err| {
        try stream_writer.print("\x1B[31mError: {s}\x1B[0m\n", .{@errorName(err)});
    } else if (state.program_mode == .command) {
        try stream_writer.print("{s}:{s}\n", .{ mode_string, state.command_buffer.items });
    } else if (state.program_mode == .search) {
        try stream_writer.print("{s}/{s}\n", .{ mode_string, state.search_buffer.items });
    } else if (state.count > 0) {
        try stream_writer.print("{s} {d}\n", .{ mode_string, state.count });
    } else {
        try stream_writer.print("{s}\n", .{mode_string});
    }

    // Finálny zápis na obrazovku
    try writeFrame(stdout, stream_writer.buffered());
}

pub fn drawAliasScreen(
    stdout: *std.Io.Writer,
    state: *const ProgramState,
    view: *const View,
    active_error: ?anyerror,
    terminal_size: Terminal.Size,
) !void {
    var raw_buf: [65_536]u8 = undefined;
    var stream_writer = std.Io.Writer.fixed(&raw_buf);

    try stream_writer.writeAll("Aliases:\n");

    const matches = view.alias_matches;
    if (matches.len == 0) {
        try stream_writer.writeAll(if (state.aliases.len == 0) "  (no cd aliases in ~/.aliases)\n" else "  (no match)\n");
    }

    // Riadky na zoznam: bez hlavičky, prázdneho riadku a stavového riadku
    const rows_available = @max(@as(usize, terminal_size.rows) -| 3, 1);
    // Okno posúvame tak, aby vybraný alias bol vždy vidieť
    const start = if (state.alias_index >= rows_available) state.alias_index - rows_available + 1 else 0;
    const end = @min(start + rows_available, matches.len);

    var name_width: usize = 0;
    for (matches) |alias| name_width = @max(name_width, displayWidth(alias.name));

    for (matches[start..end], start..) |alias, i| {
        const selected = (i == state.alias_index);
        if (selected) try stream_writer.writeAll("\x1B[48;5;236m");
        try stream_writer.writeAll(if (selected) ">" else " ");
        try writePadded(&stream_writer, alias.name, name_width);
        try stream_writer.writeAll("  ");

        // Cestu odrežeme, aby sa riadok nezalomil (rovnako ako dlhé mená súborov)
        const room = @max(@as(usize, terminal_size.cols) -| (1 + name_width + 2), 1);
        if (displayWidth(alias.path) > room) {
            try stream_writer.print("{s}…", .{truncateToWidth(alias.path, room - 1)});
        } else {
            try stream_writer.writeAll(alias.path);
        }
        if (selected) try stream_writer.writeAll("\x1B[0m");
        try stream_writer.writeAll("\n");
    }

    try stream_writer.writeAll("\n");
    if (active_error) |err| {
        try stream_writer.print("\x1B[31mError: {s}\x1B[0m", .{@errorName(err)});
    } else {
        try stream_writer.print("[A]/{s}", .{state.alias_buffer.items});
    }

    try writeFrame(stdout, stream_writer.buffered());
}

// Riadky na jednu stranu nápovedy: posledný riadok necháme na pätičku
fn helpPageRows(rows: u16) usize {
    return @max(rows, 2) - 1;
}

// Počet strán nápovedy pri danej výške terminálu
pub fn helpPageCount(rows: u16) usize {
    const page_rows = helpPageRows(rows);
    const total_lines = std.mem.count(u8, help_text, "\n") + 1;
    return (total_lines + page_rows - 1) / page_rows;
}

// Jedna strana nápovedy (page od 0); listovanie rieši handleHelpMode
pub fn drawHelpScreen(stdout: *std.Io.Writer, page: usize, rows: u16) !void {
    const page_rows = helpPageRows(rows);
    const total_pages = helpPageCount(rows);

    var raw_buf: [4096]u8 = undefined;
    var stream_writer: std.Io.Writer = .fixed(&raw_buf);

    var lines = std.mem.splitScalar(u8, help_text, '\n');
    // Preskočíme riadky predchádzajúcich strán
    for (0..page * page_rows) |_| _ = lines.next();
    var row: usize = 0;
    while (row < page_rows) : (row += 1) {
        const line = lines.next() orelse break;
        try stream_writer.print("{s}\n", .{line});
    }
    // Pätička bez \n na konci, aby terminál neodroloval prvý riadok
    if (page + 1 < total_pages) {
        try stream_writer.print("-- {d}/{d}: any key = next page, q = close --", .{ page + 1, total_pages });
    } else {
        try stream_writer.writeAll("Press ANY key to return...");
    }
    try writeFrame(stdout, stream_writer.buffered());
}

// Text nápovedy; drawHelpScreen ho rozdelí na strany podľa výšky terminálu
const help_text =
    \\=== ZNAVI FILE BROWSER HELP ===
    \\
    \\[ Normal Mode ]
    \\  j / Down  - Move selection down (5j = 5 rows)
    \\  k / Up    - Move selection up   (5k = 5 rows)
    \\  l / Right - Enter directory / Open file (also Enter)
    \\  h / Left  - Go to parent directory
    \\  Backspace - Toggle hidden files
    \\  Ctrl+h    - Toggle hidden files
    \\  Ctrl+d    - Jump down 20 items
    \\  Ctrl+u    - Jump up 20 items
    \\  gg        - Jump to top
    \\  G         - Jump to bottom
    \\  :         - Enter Command Mode
    \\  /         - Search (Enter keeps filter, Esc clears it)
    \\  a         - Aliases (same as :a)
    \\  r         - Refresh directory contents (same as :r)
    \\  ?         - Show this help screen
    \\  q         - Quit program (also Ctrl+c)
    \\  Ctrl+z    - Suspend (resume with fg)
    \\
    \\[ Command Mode ]
    \\
++ command_help ++
    \\  :<number> - Jump to specific index
    \\  :!<cmd>   - Run shell command in current directory
    \\              (% = selected file, \% = literal %)
    \\  Esc       - Return to Normal Mode
;

// Riadky nápovedy pre príkazy, vygenerované pri kompilácii z tabuľky commands
const command_help = blk: {
    var text: []const u8 = "";
    for (commands) |cmd| {
        text = text ++ std.fmt.comptimePrint("  :{s:<8} - {s}\n", .{ cmd.name, cmd.help });
    }
    break :blk text;
};

// Počet stĺpcov na obrazovke: jeden znak = jeden stĺpec (široké CJK/emoji ignorujeme)
// Pošle hotový frame na terminál bez mazania celej obrazovky (\x1B[2J pri rýchlom scrollovaní bliká):
// kurzor domov, každý riadok zmažeme (\x1B[K) a hneď prepíšeme, na konci zmažeme zvyšok obrazovky (\x1B[J).
// \x1B[K dávame na začiatok riadku, nie na koniec: riadok presne na šírku terminálu nechá kurzor
// v poslednom stĺpci a \x1B[K by tam zmazal posledný znak
fn writeFrame(stdout: *std.Io.Writer, frame: []const u8) !void {
    try stdout.writeAll("\x1B[H");
    var lines = std.mem.splitScalar(u8, frame, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try stdout.writeAll("\n");
        first = false;
        try stdout.writeAll("\x1B[K");
        try stdout.writeAll(line);
    }
    try stdout.writeAll("\x1B[J");
}

// Fish-style skracovanie: /usr/home/matej/dlhy/src -> /u/h/m/dlhy/src
// Adresáre zľava skracujeme na prvé písmeno (skryté na ".c"), iba kým sa cesta nezmestí.
// Posledný adresár ostáva celý; ak sa nezmestí ani tak, ukážeme koniec cesty.
pub fn shortenPath(path: []const u8, cols: u16, buf: []u8) ![]const u8 {
    // Rezerva pre dvojbodku a nový riadok na konci riadku
    const max_allowed: usize = if (cols > 2) cols - 2 else cols;
    if (displayWidth(path) <= max_allowed) return path;

    // 1. Koľko adresárov zľava treba skrátiť (posledný nikdy)
    const component_count = std.mem.count(u8, std.mem.trim(u8, path, "/"), "/") + 1;
    var abbreviate_count: usize = 0;
    var shown_len = displayWidth(path);
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |component| {
        if (shown_len <= max_allowed or abbreviate_count + 1 >= component_count) break;
        shown_len -= displayWidth(component) - displayWidth(abbreviateComponent(component));
        abbreviate_count += 1;
    }

    // 2. Poskladáme cestu: prvých abbreviate_count adresárov skrátených, zvyšok celý
    var w: std.Io.Writer = .fixed(buf);
    it.reset();
    var index: usize = 0;
    while (it.next()) |component| : (index += 1) {
        try w.writeByte('/');
        try w.writeAll(if (index < abbreviate_count) abbreviateComponent(component) else component);
    }
    const shortened = w.buffered();
    const shortened_width = displayWidth(shortened);
    if (shortened_width <= max_allowed) return shortened;

    // 3. Extrémne úzky terminál – vrátime len koniec cesty: preskočíme toľko znakov
    // zo začiatku, koľko je navyše (celé znaky, nie bajty)
    const skip = truncateToWidth(shortened, shortened_width - max_allowed);
    return shortened[skip.len..];
}

// "matej" -> "m", ".config" -> ".c"; celý prvý UTF-8 znak (napr. "š"), nie iba jeho prvý bajt
fn abbreviateComponent(component: []const u8) []const u8 {
    const first = if (component.len > 1 and component[0] == '.') @as(usize, 1) else 0;
    const char_len = std.unicode.utf8ByteSequenceLength(component[first]) catch 1;
    return component[0..@min(first + char_len, component.len)];
}

pub fn displayWidth(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch s.len; // neplatné UTF-8: bajty
}

// Najdlhší začiatok s, ktorý sa zmestí do max_cols stĺpcov (nereže v strede znaku)
pub fn truncateToWidth(s: []const u8, max_cols: usize) []const u8 {
    var i: usize = 0;
    var used: usize = 0;
    while (i < s.len and used < max_cols) : (used += 1) {
        i += std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
    }
    return s[0..@min(i, s.len)];
}

// Vypíše s a doplní medzerami na width stĺpcov. Zigové {s:<width} počíta bajty,
// takže meno s diakritikou by dostalo menej medzier a ďalší stĺpec by sa posunul
fn writePadded(writer: *std.Io.Writer, s: []const u8, width: usize) !void {
    try writer.writeAll(s);
    try writer.splatByteAll(' ', width -| displayWidth(s));
}

fn getLongestNameLength(files: []const file_entry) usize {
    var longest_len: usize = 0;

    for (files) |file| {
        const slash_len: usize = if (file.is_dir) 1 else 0;
        const current_len = displayWidth(file.name) + displayWidth(file.extension) + slash_len;
        // std.math.max vráti vyššiu z dvoch hodnôt
        longest_len = @max(longest_len, current_len);
    }
    return longest_len;
}

// ===================== Testy =====================

test "displayWidth počíta znaky, nie bajty" {
    try std.testing.expectEqual(@as(usize, 5), displayWidth("škola"));
    try std.testing.expectEqual(@as(usize, 5), displayWidth("hello"));
    try std.testing.expectEqual(@as(usize, 0), displayWidth(""));
    // Neplatné UTF-8: počítame bajty
    try std.testing.expectEqual(@as(usize, 2), displayWidth("\xff\xfe"));
}

test "truncateToWidth nereže v strede znaku" {
    try std.testing.expectEqualStrings("šk", truncateToWidth("škola", 2));
    try std.testing.expectEqualStrings("škola", truncateToWidth("škola", 10));
    try std.testing.expectEqualStrings("", truncateToWidth("škola", 0));
    try std.testing.expectEqualStrings("ab", truncateToWidth("abc", 2));
}

test "writeFrame maže každý riadok na začiatku a zvyšok obrazovky na konci" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeFrame(&w, "ab\ncd\n");
    try std.testing.expectEqualStrings("\x1B[H\x1B[Kab\n\x1B[Kcd\n\x1B[K\x1B[J", w.buffered());
}

fn expectShortened(dir: []const u8, cols: u16, expected: []const u8) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(expected, try shortenPath(dir, cols, &buf));
}

test "shortenPath skracuje fish-style" {
    const long = "/usr/home/matej/frikkinlongdirectoryname/src/zig/zig-out";
    // Zmestí sa – bez zmeny
    try expectShortened(long, 80, long);
    // Skracujeme zľava, iba kým to treba
    try expectShortened(long, 30, "/u/h/m/f/src/zig/zig-out");
    // Posledný adresár nikdy neskracujeme; ak sa nezmestí ani tak, ostane koniec cesty
    try expectShortened(long, 10, "/zig-out");
    // Bodka na začiatku ostáva (.config -> .c)
    try expectShortened("/home/.config/very_long_directory_name", 32, "/h/.c/very_long_directory_name");
    // Celý prvý UTF-8 znak, nie iba jeho prvý bajt
    try expectShortened("/školské/dokumenty_dlhé", 20, "/š/dokumenty_dlhé");
}

test "nápoveda: strany pokryjú celý text" {
    // Vysoký terminál: všetko na jednej strane
    try std.testing.expectEqual(@as(usize, 1), helpPageCount(1000));

    // 10 riadkov = 9 riadkov textu + pätička na stranu
    const total_lines = std.mem.count(u8, help_text, "\n") + 1;
    try std.testing.expectEqual((total_lines + 8) / 9, helpPageCount(10));

    // Druhá strana začína 10. riadkom textu
    var buf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try drawHelpScreen(&w, 1, 10);
    var lines = std.mem.splitScalar(u8, help_text, '\n');
    for (0..9) |_| _ = lines.next();
    const expected_first = try std.fmt.allocPrint(std.testing.allocator, "\x1B[H\x1B[K{s}\n", .{lines.next().?});
    defer std.testing.allocator.free(expected_first);
    try std.testing.expect(std.mem.startsWith(u8, w.buffered(), expected_first));
}
