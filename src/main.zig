//ZNAVI - Zig-written file NAvigator with VI controls
//
const std = @import("std");
const posix = std.posix;
const FileEntry = @import("FileEntry.zig");
const Terminal = @import("Terminal.zig");
const input = @import("input.zig");
const Key = input.Key;
const render = @import("render.zig");
const fs = @import("fs.zig");
const aliases = @import("aliases.zig");
const handlers = @import("handlers.zig");
const effects = @import("effects.zig");
const handleKey = handlers.handleKey;
const getVisibleItems = @import("state.zig").getVisibleItems;
const applyPendingCursor = @import("state.zig").applyPendingCursor;
const setWindow = @import("state.zig").setWindow;
const ProgramState = @import("state.zig").ProgramState;
const View = @import("state.zig").View;

pub fn main(init: std.process.Init) !void {
    const io = init.io; // take the program's io interface
    // gpa for current_dir, history and buffers – we free those by hand with free/deinit
    const gpa = init.gpa;

    // long-lived arena (cleared ONLY on a directory change or refresh)
    var dir_contents_arena = std.heap.ArenaAllocator.init(init.gpa);
    defer dir_contents_arena.deinit();

    // arena for temporary strings within one loop iteration (e.g. xdg-open paths)
    var one_cycle_arena = std.heap.ArenaAllocator.init(init.gpa);
    defer one_cycle_arena.deinit();

    // Starting directory before RAW mode, so an error message goes to the shell normally
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const start_arg: ?[]const u8 = if (argv.len > 1) argv[1] else null;
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const start_dir = fs.getStartingDir(io, start_arg, &buffer) catch |err| {
        std.debug.print("znavi: {s}: {s}\n", .{ start_arg orelse ".", @errorName(err) });
        std.process.exit(1);
    };

    // set up STDOUT for writing output
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.Writer.init(std.Io.File.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    // set up STDIN for reading input
    var stdin_buffer: [16]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(init.io, &stdin_buffer);
    const stdin = &stdin_reader.interface;

    // initialize the terminal and hand it the writer
    const terminal = try Terminal.init(&stdout_writer);
    // on leaving main everything is restored to its original state
    defer terminal.deinit();
    // Everything a foreground child (editor, :!, :sh, :cw) needs to borrow the terminal
    const ui: effects.Ui = .{ .io = io, .terminal = terminal, .stdout = stdout, .stdin = stdin };
    // initial terminal size, the default UNIX terminal is 24x80
    var terminal_size: Terminal.Size = .{ .rows = 24, .cols = 80 };
    // default sorting by name dirs first
    var state = ProgramState{
        // copy from the stack buffer into gpa so current_dir can be freed later
        .current_dir = try gpa.dupe(u8, start_dir),
        .command_buffer = .empty,
        .search_buffer = .empty,
        .history_forward = .empty,
    };
    defer state.deinit(gpa);

    // cd aliases from ~/.aliases; if the file can't be read, we continue without aliases
    if (init.environ_map.get("HOME")) |home| {
        state.aliases = aliases.loadAliases(io, init.arena.allocator(), home) catch &.{};
    }

    // file name colors like ls -G
    if (init.environ_map.get("LSCOLORS")) |lscolors| state.palette = .parse(lscolors);

    var active_error: ?anyerror = null;

    while (true) {
        const frame_allocator = one_cycle_arena.allocator();
        defer _ = one_cycle_arena.reset(.free_all);
        terminal_size = Terminal.getSize();

        if (state.dir_changed) {
            active_error = try reloadDir(io, &state, &dir_contents_arena, frame_allocator, init.arena.allocator());
        }

        // Data for this frame; lives only until the end of the loop iteration (frame arena)
        var view: View = .{ .visible = try getVisibleItems(frame_allocator, &state) };
        applyPendingCursor(&state, view.visible);
        setWindow(&view, terminal_size, state.global_index);

        var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
        const display_path = try render.shortenPath(state.current_dir, terminal_size.cols, &dir_buf);

        if (state.program_mode == .help) {
            // The page count depends on the terminal height; after shrinking the window we stay on the last page
            view.help_pages = render.helpPageCount(terminal_size.rows);
            state.help_page = @min(state.help_page, view.help_pages - 1);
            try render.drawHelpScreen(stdout, state.help_page, terminal_size.rows);
        } else if (state.program_mode == .alias) {
            // Alias mode has its own screen with just the list of aliases
            view.alias_matches = try aliases.getFilteredAliases(frame_allocator, state.aliases, state.alias_buffer.items);
            state.alias_index = @min(state.alias_index, view.alias_matches.len -| 1);
            try render.drawAliasScreen(stdout, &state, &view, active_error, terminal_size);
        } else {
            // the current time colors the date column by age
            const now = std.Io.Clock.real.now(io);
            try render.drawScreen(stdout, display_path, &state, &view, active_error, terminal_size.cols, now);
        }
        try stdout_writer.flush();

        const key: Key = try input.readKey(stdin, state.program_mode != .normal);
        // The error is shown until the next key press, then we see the : or / line again
        active_error = null;

        // The handler only changes state and says what to do; all side effects happen here
        const action = handleKey(key, &state, &view, gpa) catch |err| {
            active_error = err;
            continue;
        };
        switch (action) {
            .none => {},
            .quit => break,
            // Return the terminal to normal, stop (fg wakes us up) and go back to RAW
            .suspend_process => {
                terminal.leaveRaw();
                try posix.raise(.TSTP);
                try terminal.enterRaw();
            },
            .open_file => |item| effects.openFile(ui, frame_allocator, state.current_dir, item) catch |err| {
                active_error = err;
            },
            // E.g. an alias to a nonexistent directory – show the error, stay in alias mode
            .jump_to_alias => |alias| effects.jumpToAlias(alias, &state, gpa, io) catch |err| {
                active_error = err;
            },
            .run_shell => |command| {
                const shell = init.environ_map.get("SHELL") orelse "/bin/sh";
                const selected: ?FileEntry = if (state.global_index < view.visible.len) view.visible[state.global_index] else null;
                const expanded = handlers.expandShellCommand(frame_allocator, command, selected) catch |err| {
                    active_error = err;
                    continue;
                };
                effects.runShell(ui, state.current_dir, &.{ shell, "-c", expanded }) catch |err| {
                    active_error = err;
                };
                // The command may have created, deleted or renamed files – reload the directory
                state.rememberSelected(&view);
                state.dir_changed = true;
            },
            .interactive_shell => {
                const shell = init.environ_map.get("SHELL") orelse "/bin/sh";
                effects.runShell(ui, state.current_dir, &.{shell}) catch |err| {
                    active_error = err;
                };
                // Anything in the directory could have changed in the shell
                state.rememberSelected(&view);
                state.dir_changed = true;
            },
            .bulk_rename => {
                const tmp_dir = init.environ_map.get("TMPDIR") orelse "/tmp";
                effects.bulkRename(ui, frame_allocator, tmp_dir, state.current_dir, view.visible) catch |err| {
                    active_error = err;
                };
                // Even after an error some files may have been renamed
                state.rememberSelected(&view);
                state.dir_changed = true;
            },
        }
    }

    // cd-on-exit: if ZNAVI_LASTDIR is set, write the last directory into that file,
    // so a shell function can cd there after we exit
    if (init.environ_map.get("ZNAVI_LASTDIR")) |lastdir_path| {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = lastdir_path, .data = state.current_dir });
    }
}

// Loads state.current_dir into a freshly reset dir_arena. Returns the error to show for one
// draw (the directory couldn't be read, or an entry had to be skipped), or null.
// Only allocation failures are returned as errors.
fn reloadDir(
    io: std.Io,
    state: *ProgramState,
    dir_arena: *std.heap.ArenaAllocator,
    frame_allocator: std.mem.Allocator,
    names_allocator: std.mem.Allocator,
) !?anyerror {
    // The remembered item (refresh, :!) points into dir_arena, which we are about to
    // free – copy the name into the frame arena, otherwise we would compare freed memory
    switch (state.pending_cursor) {
        .item => |*target| {
            target.name = try frame_allocator.dupe(u8, target.name);
            target.extension = try frame_allocator.dupe(u8, target.extension);
        },
        else => {},
    }
    // Before loading new contents, completely clear the old list and file names
    _ = dir_arena.reset(.free_all);
    state.dir_changed = false;
    // Fallback state - e.g. an empty directory, so the app doesn't freeze
    state.current_dir_contents = &.{};

    // null if everything is fine, otherwise the error of an entry we had to skip
    var skipped_error: ?anyerror = null;
    const contents = fs.getDirContents(io, dir_arena.allocator(), state.current_dir, &skipped_error, state.viewing.owner or state.viewing.group) catch |err| {
        const shown: ?anyerror = err;
        return shown;
    };
    // uid/gid -> names (from the cache, a new id is looked up in libc only once)
    for (contents) |*entry| {
        entry.owner_name = try fs.lookupName(.user, &state.user_names, names_allocator, entry.owner);
        entry.group_name = try fs.lookupName(.group, &state.group_names, names_allocator, entry.group);
    }
    state.current_dir_contents = contents;
    state.sortContents();
    return skipped_error;
}

// ===================== Tests (zig build test) =====================

// Tests from FileEntry.zig (sorting, formatting) run together with these
test {
    _ = FileEntry;
    _ = render;
    _ = aliases;
    _ = input;
    _ = fs;
    _ = Terminal;
    _ = @import("state.zig");
    _ = @import("commands.zig");
    _ = @import("handlers.zig");
    _ = @import("rename.zig");
    _ = effects;
    _ = @import("colors.zig");
}
