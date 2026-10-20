// Drawing the screens (file list, aliases, help) and helpers for text width
const std = @import("std");
const FileEntry = @import("FileEntry.zig");
const Terminal = @import("Terminal.zig");
const ProgramState = @import("state.zig").ProgramState;
const View = @import("state.zig").View;
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
    // Local buffer to minimize syscalls
    var raw_buf: [131_072]u8 = undefined;
    var stream_writer = std.Io.Writer.fixed(&raw_buf);

    // Write the current directory (shortened version)
    try stream_writer.print("{s}:\n", .{display_path});

    // Column widths are measured over the whole (filtered) directory, not just the rows on screen,
    // so the columns don't shift while scrolling
    const longest_name_len = getLongestNameLength(view.visible);

    // Start of the window in visible, so the row numbers match the :<number> command
    const window_start = view.window_start;
    // Width of the number based on the largest index (at least 2 characters)
    var index_width: usize = 2;
    var max_index = view.visible.len -| 1;
    while (max_index >= 100) : (max_index /= 10) index_width += 1;

    // Width of the name column: the longest name, but at most what's left of the row
    // after the pointer, the number and the enabled columns ("   " + value width), so the row doesn't wrap
    // The owner and group columns are as wide as the longest name on screen
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
    // The alias column is as wide as the longest alias name
    var alias_width: usize = 0;
    if (state.viewing.aliases) {
        for (state.aliases) |alias| alias_width = @max(alias_width, displayWidth(alias.name));
        if (alias_width > 0) reserved += 3 + alias_width;
    }
    const name_col = @max(@min(longest_name_len, @as(usize, cols) -| reserved), 1);

    for (view.window, window_start..) |file, idx| {
        const file_is_selected = (idx == state.global_index);

        if (file_is_selected) {
            try stream_writer.writeAll("\x1B[48;5;236m");
        }

        const pointer = if (file_is_selected) ">" else " ";
        const italic_start = if (file.is_symlink) "\x1b[3m" else "";
        const italic_end = if (file.is_symlink) "\x1b[23m" else "";
        const slash = if (file.is_dir) "/" else "";

        // Print the basic file row
        try stream_writer.writeAll(pointer);
        try stream_writer.print("{[value]d:>[width]} ", .{ .value = idx, .width = index_width });

        // The full name (name + extension + slash); if it's longer than the column, cut it and add "…"
        var name_buf: [std.Io.Dir.max_name_bytes]u8 = undefined;
        var full_name_buf: [std.Io.Dir.max_name_bytes + 1]u8 = undefined;
        const full_name: []const u8 = std.fmt.bufPrint(&full_name_buf, "{s}{s}", .{ file.fullName(&name_buf), slash }) catch unreachable;
        var shown_name = full_name;
        var ellipsis: []const u8 = "";
        if (displayWidth(full_name) > name_col) {
            shown_name = truncateToWidth(full_name, name_col - 1);
            ellipsis = "…";
        }
        try stream_writer.print("{s}{s}{s}{s}", .{ italic_start, shown_name, ellipsis, italic_end });

        // Effective padding
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

        // The alias that leads to this directory (blank if there is none)
        if (show_aliases) {
            try stream_writer.writeAll("   ");
            try writePadded(&stream_writer, state.aliasFor(file) orelse "", alias_width);
        }

        // Fixed spacing and formatting calls, toggled via state.viewing
        if (state.viewing.permissions) {
            var perm_buf: [10]u8 = undefined;
            const formatted_perms = file.getFormattedPermissions(&perm_buf);
            try stream_writer.writeAll("   ");
            try stream_writer.writeAll(formatted_perms);
        }

        // Owner and group aligned left, like in ls -l
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

    // Draw the status line depending on the mode
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

    // Final write to the screen
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

    // Rows for the list: without the header, the blank line and the status line
    const rows_available = @max(@as(usize, terminal_size.rows) -| 3, 1);
    // Move the window so the selected alias is always visible
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

        // Cut the path so the row doesn't wrap (just like long file names)
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

// Rows per help page: the last row is left for the footer
fn helpPageRows(rows: u16) usize {
    return @max(rows, 2) - 1;
}

// Number of help pages at the given terminal height
pub fn helpPageCount(rows: u16) usize {
    const page_rows = helpPageRows(rows);
    const total_lines = std.mem.count(u8, help_text, "\n") + 1;
    return (total_lines + page_rows - 1) / page_rows;
}

// One help page (page from 0); paging is handled by handleHelpMode
pub fn drawHelpScreen(stdout: *std.Io.Writer, page: usize, rows: u16) !void {
    const page_rows = helpPageRows(rows);
    const total_pages = helpPageCount(rows);

    var raw_buf: [4096]u8 = undefined;
    var stream_writer: std.Io.Writer = .fixed(&raw_buf);

    var lines = std.mem.splitScalar(u8, help_text, '\n');
    // Skip the rows of the previous pages
    for (0..page * page_rows) |_| _ = lines.next();
    var row: usize = 0;
    while (row < page_rows) : (row += 1) {
        const line = lines.next() orelse break;
        try stream_writer.print("{s}\n", .{line});
    }
    // Footer without a trailing \n, so the terminal doesn't scroll off the first row
    if (page + 1 < total_pages) {
        try stream_writer.print("-- {d}/{d}: any key = next page, q = close --", .{ page + 1, total_pages });
    } else {
        try stream_writer.writeAll("Press ANY key to return...");
    }
    try writeFrame(stdout, stream_writer.buffered());
}

// Help text; drawHelpScreen splits it into pages based on the terminal height
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

// Help rows for the commands, generated at compile time from the commands table
const command_help = blk: {
    var text: []const u8 = "";
    for (commands) |cmd| {
        text = text ++ std.fmt.comptimePrint("  :{s:<8} - {s}\n", .{ cmd.name, cmd.help });
    }
    break :blk text;
};

// Sends a finished frame to the terminal without clearing the whole screen (\x1B[2J flickers when scrolling fast):
// cursor home, each line is cleared (\x1B[K) and rewritten right away, at the end the rest of the screen is cleared (\x1B[J).
// \x1B[K goes at the start of a line, not the end: a line exactly as wide as the terminal leaves the cursor
// in the last column and \x1B[K there would erase the last character
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

// Fish-style shortening: /usr/home/matej/long/src -> /u/h/m/long/src
// Directories are shortened from the left to their first letter (hidden ones to ".c"), only until the path fits.
// The last directory stays whole; if it still doesn't fit, we show the end of the path.
pub fn shortenPath(path: []const u8, cols: u16, buf: []u8) ![]const u8 {
    // Room for the colon and the newline at the end of the row
    const max_allowed: usize = if (cols > 2) cols - 2 else cols;
    if (displayWidth(path) <= max_allowed) return path;

    // 1. How many directories from the left need shortening (never the last one)
    const component_count = std.mem.count(u8, std.mem.trim(u8, path, "/"), "/") + 1;
    var abbreviate_count: usize = 0;
    var shown_len = displayWidth(path);
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |component| {
        if (shown_len <= max_allowed or abbreviate_count + 1 >= component_count) break;
        shown_len -= displayWidth(component) - displayWidth(abbreviateComponent(component));
        abbreviate_count += 1;
    }

    // 2. Build the path: the first abbreviate_count directories shortened, the rest whole
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

    // 3. Extremely narrow terminal – return just the end of the path: skip as many characters
    // from the start as there are too many (whole characters, not bytes)
    const skip = truncateToWidth(shortened, shortened_width - max_allowed);
    return shortened[skip.len..];
}

// "matej" -> "m", ".config" -> ".c"; the whole first UTF-8 character (e.g. "š"), not just its first byte
fn abbreviateComponent(component: []const u8) []const u8 {
    const first = if (component.len > 1 and component[0] == '.') @as(usize, 1) else 0;
    const char_len = std.unicode.utf8ByteSequenceLength(component[first]) catch 1;
    return component[0..@min(first + char_len, component.len)];
}

// Number of columns on screen: one character = one column (wide CJK/emoji are ignored)
pub fn displayWidth(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch s.len; // invalid UTF-8: bytes
}

// The longest prefix of s that fits into max_cols columns (doesn't cut in the middle of a character)
pub fn truncateToWidth(s: []const u8, max_cols: usize) []const u8 {
    var i: usize = 0;
    var used: usize = 0;
    while (i < s.len and used < max_cols) : (used += 1) {
        i += std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
    }
    return s[0..@min(i, s.len)];
}

// Prints s and pads it with spaces to width columns. Zig's {s:<width} counts bytes,
// so a name with diacritics would get fewer spaces and the next column would shift
fn writePadded(writer: *std.Io.Writer, s: []const u8, width: usize) !void {
    try writer.writeAll(s);
    try writer.splatByteAll(' ', width -| displayWidth(s));
}

fn getLongestNameLength(files: []const FileEntry) usize {
    var longest_len: usize = 0;

    var name_buf: [std.Io.Dir.max_name_bytes]u8 = undefined;
    for (files) |file| {
        const slash_len: usize = if (file.is_dir) 1 else 0;
        const current_len = displayWidth(file.fullName(&name_buf)) + slash_len;
        // std.math.max returns the larger of two values
        longest_len = @max(longest_len, current_len);
    }
    return longest_len;
}

// ===================== Testy =====================

test "displayWidth counts characters, not bytes" {
    try std.testing.expectEqual(@as(usize, 5), displayWidth("johny"));
    try std.testing.expectEqual(@as(usize, 5), displayWidth("hello"));
    try std.testing.expectEqual(@as(usize, 0), displayWidth(""));
    // invalid UTF-8: counting bytes
    try std.testing.expectEqual(@as(usize, 2), displayWidth("\xff\xfe"));
}

test "truncateToWidth does not cut in the middle" {
    try std.testing.expectEqualStrings("sc", truncateToWidth("school", 2));
    try std.testing.expectEqualStrings("school", truncateToWidth("school", 10));
    try std.testing.expectEqualStrings("", truncateToWidth("school", 0));
    try std.testing.expectEqualStrings("ab", truncateToWidth("abc", 2));
}

test "writeFrame clears each line at its start and the rest of the screen at the end" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeFrame(&w, "ab\ncd\n");
    try std.testing.expectEqualStrings("\x1B[H\x1B[Kab\n\x1B[Kcd\n\x1B[K\x1B[J", w.buffered());
}

fn expectShortened(dir: []const u8, cols: u16, expected: []const u8) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(expected, try shortenPath(dir, cols, &buf));
}

test "shortenPath shortens fish-style" {
    const long = "/usr/home/matej/frikkinlongdirectoryname/src/zig/zig-out";
    // It fits – no change
    try expectShortened(long, 80, long);
    // Shorten from the left, only as much as needed
    try expectShortened(long, 30, "/u/h/m/f/src/zig/zig-out");
    // The last directory is never shortened; if it still doesn't fit, the end of the path stays
    try expectShortened(long, 10, "/zig-out");
    // A leading dot is kept (.config -> .c)
    try expectShortened("/home/.config/very_long_directory_name", 32, "/h/.c/very_long_directory_name");
    // The whole first UTF-8 character, not just its first byte
    try expectShortened("/školské/dokumenty_dlhé", 20, "/š/dokumenty_dlhé");
}

test "help: the pages cover the whole text" {
    // Tall terminal: everything on one page
    try std.testing.expectEqual(@as(usize, 1), helpPageCount(1000));

    // 10 rows = 9 lines of text + a footer per page
    const total_lines = std.mem.count(u8, help_text, "\n") + 1;
    try std.testing.expectEqual((total_lines + 8) / 9, helpPageCount(10));

    // The second page starts with the 10th line of text
    var buf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try drawHelpScreen(&w, 1, 10);
    var lines = std.mem.splitScalar(u8, help_text, '\n');
    for (0..9) |_| _ = lines.next();
    const expected_first = try std.fmt.allocPrint(std.testing.allocator, "\x1B[H\x1B[K{s}\n", .{lines.next().?});
    defer std.testing.allocator.free(expected_first);
    try std.testing.expect(std.mem.startsWith(u8, w.buffered(), expected_first));
}
