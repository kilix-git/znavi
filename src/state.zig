// Program state (lives across frames), data for a single frame (View) and how it is computed
const std = @import("std");
const FileEntry = @import("FileEntry.zig");
const Terminal = @import("Terminal.zig");
const Alias = @import("aliases.zig").Alias;

pub const TERMINAL_PADDING: u4 = 4;

pub const Mode = enum { normal, command, search, alias, help };

pub const Sorting = enum {
    by_name,
    by_name_dirs_first,
    by_date,
    by_date_dirs_first,
    by_size_asc,
    by_size_desc,
};

pub const Viewing = struct {
    hidden: bool = false,
    permissions: bool = false,
    size: bool = true,
    date: bool = false,
    owner: bool = false,
    group: bool = false,
    aliases: bool = false,
};

pub const PendingCursor = union(enum) {
    none,
    // After h (or l going back down the same path): on the directory we came from (forward history)
    from_history,
    // After sorting / toggling hidden files: on the same item (the index changes, the file doesn't)
    item: FileEntry,
};

// Derived data for a single frame. Recomputed from ProgramState on every iteration and lives
// in the frame arena, which is why it isn't in ProgramState (across frames it would point to freed memory)
pub const View = struct {
    // Items after hiding hidden files and applying the search filter; global_index points here
    visible: []const FileEntry = &.{},
    // Rows that fit on the screen, and the index of the first of them in visible
    window: []const FileEntry = &.{},
    window_start: usize = 0,
    // Alias mode: aliases matching the filter
    alias_matches: []const Alias = &.{},
    // Help: number of pages at the current terminal height
    help_pages: usize = 1,
};

pub const ProgramState = struct {
    program_mode: Mode = .normal,
    current_dir: []const u8,
    global_index: usize = 0,
    dir_changed: bool = true,
    viewing: Viewing = .{},
    current_sorting: Sorting = .by_name_dirs_first,
    command_buffer: std.ArrayList(u8),
    search_buffer: std.ArrayList(u8),
    current_dir_contents: []FileEntry = &.{},
    // Count prefix for j/k (5j): the number being typed, 0 = no count
    count: usize = 0,
    // Where to put the cursor in the next frame, once we know the new list (only once, not every frame)
    pending_cursor: PendingCursor = .none,
    // cd aliases from ~/.aliases (loaded once at startup, live in the process arena)
    aliases: []const Alias = &.{},
    // Cache uid -> name and gid -> name, each id is looked up via libc only once (lives in the process arena)
    user_names: std.AutoHashMapUnmanaged(u32, []const u8) = .empty,
    group_names: std.AutoHashMapUnmanaged(u32, []const u8) = .empty,
    // Alias mode (:a): what we're typing and the selected row (the matching aliases are in View)
    alias_buffer: std.ArrayList(u8) = .empty,
    alias_index: usize = 0,
    // Help (?): the page currently shown (from 0)
    help_page: usize = 0,
    history_forward: std.ArrayList([]const u8),

    // Name of the alias that leads to this directory (the first one found), otherwise null
    pub fn aliasFor(self: *const ProgramState, file: FileEntry) ?[]const u8 {
        if (!file.is_dir or self.aliases.len == 0) return null;
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        // On "/" the slash is already there, elsewhere we add one between the directory and the name
        const sep = if (std.mem.endsWith(u8, self.current_dir, "/")) "" else "/";
        const full_path = std.fmt.bufPrint(&path_buf, "{s}{s}{s}", .{ self.current_dir, sep, file.name }) catch return null;
        for (self.aliases) |alias| {
            if (std.mem.eql(u8, alias.real_path, full_path)) return alias.name;
        }
        return null;
    }

    // Opens help on the first page (key ? or command :?)
    pub fn enterHelp(self: *ProgramState) void {
        self.program_mode = .help;
        self.help_page = 0;
    }

    // Switches to alias mode with an empty filter (key a or command :a)
    pub fn enterAliasMode(self: *ProgramState) void {
        self.program_mode = .alias;
        self.alias_buffer.clearRetainingCapacity();
        self.alias_index = 0;
    }

    // Remembers the selected item; main finds it again after the list is recomputed
    pub fn rememberSelected(self: *ProgramState, view: *const View) void {
        self.pending_cursor = if (self.global_index < view.visible.len)
            .{ .item = view.visible[self.global_index] }
        else
            .none;
    }

    // Reloads the directory (e.g. another program changed the files), the cursor stays on the item
    pub fn refresh(self: *ProgramState, view: *const View) void {
        self.rememberSelected(view);
        self.dir_changed = true;
    }

    pub fn resetIndices(self: *ProgramState) void {
        self.global_index = 0;
    }

    pub fn sortContents(self: *ProgramState) void {
        // The ".." entry stays at index 0 in every sort
        var items = self.current_dir_contents;
        if (items.len > 0 and items[0].is_parent) items = items[1..];

        switch (self.current_sorting) {
            .by_name => std.mem.sort(FileEntry, items, {}, FileEntry.lessThanByName),
            .by_name_dirs_first => std.mem.sort(FileEntry, items, {}, FileEntry.lessThanByNameDirsFirst),
            .by_date => std.mem.sort(FileEntry, items, {}, FileEntry.lessThanByDate),
            .by_date_dirs_first => std.mem.sort(FileEntry, items, {}, FileEntry.lessThanByDateDirsFirst),
            .by_size_asc => std.mem.sort(FileEntry, items, {}, FileEntry.lessThanBySizeAsc),
            .by_size_desc => std.mem.sort(FileEntry, items, {}, FileEntry.lessThanBySizeDesc),
        }
    }

    pub fn clearForwardHistory(self: *ProgramState, allocator: std.mem.Allocator) void {
        // Go through all stored strings and free them
        for (self.history_forward.items) |item| {
            allocator.free(item);
        }
        // Now we can safely clear the list itself
        self.history_forward.clearRetainingCapacity();
    }

    // Sets a new current_dir (ownership passes to state) and frees the old one
    pub fn setCurrentDir(self: *ProgramState, allocator: std.mem.Allocator, new_dir: []const u8) void {
        allocator.free(self.current_dir);
        self.current_dir = new_dir;
    }

    // Frees all memory owned by state (current_dir, buffers, history)
    pub fn deinit(self: *ProgramState, allocator: std.mem.Allocator) void {
        allocator.free(self.current_dir);
        self.command_buffer.deinit(allocator);
        self.search_buffer.deinit(allocator);
        self.alias_buffer.deinit(allocator);
        for (self.history_forward.items) |item| allocator.free(item);
        self.history_forward.deinit(allocator);
    }
};

// What main should do after handling a key – handlers themselves neither run nor draw anything
pub const Action = union(enum) {
    none,
    quit,
    suspend_process,
    open_file: FileEntry,
    jump_to_alias: Alias,
    // :!command – the text after the exclamation mark (points into command_buffer, main runs it right away)
    run_shell: []const u8,
    // :cw – batch rename of the visible files in $EDITOR (main runs it, see rename.zig)
    bulk_rename,
    // :sh – interactive $SHELL in the current directory, back to znavi when it exits
    interactive_shell,
};

// Saves a copy of the path to the history; if append fails, the copy is freed so it doesn't leak
pub fn pushHistory(list: *std.ArrayList([]const u8), allocator: std.mem.Allocator, path: []const u8) !void {
    const copy = try allocator.dupe(u8, path);
    errdefer allocator.free(copy);
    try list.append(allocator, copy);
}

// Items the user sees: without hidden ones (if we don't show them) and filtered by the search
pub fn getVisibleItems(allocator: std.mem.Allocator, state: *const ProgramState) ![]const FileEntry {
    var items: []const FileEntry = state.current_dir_contents;
    if (!state.viewing.hidden) items = try getOnlyVisibleItems(allocator, items);
    if (state.search_buffer.items.len > 0) items = try getFilteredItemsByName(allocator, items, state.search_buffer.items);
    return items;
}

fn getOnlyVisibleItems(allocator: std.mem.Allocator, items: []const FileEntry) ![]const FileEntry {
    // A simple filter for visible things
    var result: std.ArrayList(FileEntry) = .empty;
    errdefer result.deinit(allocator);

    for (items) |item| {
        if (!item.is_hidden) {
            try result.append(allocator, item);
        }
    }
    return try result.toOwnedSlice(allocator);
}

fn getFilteredItemsByName(
    allocator: std.mem.Allocator,
    items: []const FileEntry,
    search_str: []const u8,
) ![]const FileEntry {
    var result: std.ArrayList(FileEntry) = .empty;
    errdefer result.deinit(allocator);
    var name_buf: [std.Io.Dir.max_name_bytes]u8 = undefined;

    for (items) |item| {
        // The search sees the whole file name, extension included
        if (std.ascii.indexOfIgnoreCase(item.fullName(&name_buf), search_str) != null) {
            try result.append(allocator, item);
        }
    }
    return result.toOwnedSlice(allocator);
}

// Window of rows on the screen: the cursor is kept in the middle, the window stops at the list's edges
pub fn setWindow(view: *View, terminal_size: Terminal.Size, global_index: usize) void {
    const total_rows_available = terminal_size.rows -| TERMINAL_PADDING;
    const half_window = total_rows_available / 2;
    var start_index: usize = global_index -| half_window;

    // Correct the end of the window against the total number of visible items
    var end_index = start_index + total_rows_available;
    if (end_index > view.visible.len) {
        end_index = view.visible.len;
        start_index = end_index -| total_rows_available;
    }
    view.window_start = start_index;
    view.window = view.visible[start_index..end_index];
}

// Cursor to the place remembered in the previous step (pending_cursor), once we know the new list
pub fn applyPendingCursor(state: *ProgramState, visible: []const FileEntry) void {
    const pending = state.pending_cursor;
    state.pending_cursor = .none;
    switch (pending) {
        .none => {},
        // G, gg, Ctrl+d or :<n> then move the cursor normally, because this runs only once
        .from_history => {
            const prev = state.history_forward.getLastOrNull() orelse return;
            for (visible, 0..) |item, idx| {
                if (item.is_dir and std.mem.eql(u8, item.name, prev)) {
                    state.global_index = idx;
                    return;
                }
            }
        },
        // The same file name (foo.c vs foo.h). If it's no longer there (e.g. we just hid it),
        // we stay on the same row in the list
        .item => |target| {
            state.global_index = @min(state.global_index, visible.len -| 1);
            for (visible, 0..) |item, idx| {
                if (item.sameName(target)) {
                    state.global_index = idx;
                    return;
                }
            }
        },
    }
}

// ===================== Tests =====================

// Test helpers (also used by handlers.zig and render.zig)

// State with its own copy of the path (deinit frees it)
pub fn testState(dir: []const u8) !ProgramState {
    return .{
        .current_dir = try std.testing.allocator.dupe(u8, dir),
        .command_buffer = .empty,
        .search_buffer = .empty,
        .history_forward = .empty,
    };
}

pub fn testEntry(name: []const u8, is_dir: bool, size: usize) FileEntry {
    return .{ .name = name, .extension = "", .is_dir = is_dir, .size = size, .permissions = @enumFromInt(0o644) };
}

test "setWindow keeps the cursor in the middle and stops at the edges" {
    var items: [100]FileEntry = undefined;
    for (&items) |*item| item.* = testEntry("f", false, 0);
    const size: Terminal.Size = .{ .rows = 24, .cols = 80 }; // 20 rows for the list

    var view: View = .{ .visible = &items };
    setWindow(&view, size, 50);
    try std.testing.expectEqual(@as(usize, 40), view.window_start);
    try std.testing.expectEqual(@as(usize, 20), view.window.len);

    setWindow(&view, size, 98);
    try std.testing.expectEqual(@as(usize, 80), view.window_start);
    try std.testing.expectEqual(@as(usize, 20), view.window.len);

    // Short list: all of it on screen
    view = .{ .visible = items[0..5] };
    setWindow(&view, size, 3);
    try std.testing.expectEqual(@as(usize, 0), view.window_start);
    try std.testing.expectEqual(@as(usize, 5), view.window.len);
}
