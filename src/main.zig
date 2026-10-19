//ZNAVI - Zig-written file NAvigator with VI controls
//
const std = @import("std");
const posix = std.posix;
const file_entry = @import("FileEntry.zig");
const Terminal = @import("Terminal.zig");
const input = @import("input.zig");
const Key = input.Key;
const render = @import("render.zig");
const fs = @import("fs.zig");
const cd_aliases = @import("aliases.zig");
const Alias = cd_aliases.Alias;
const handlers = @import("handlers.zig");
const rename = @import("rename.zig");
const handleKey = handlers.handleKey;
const state_zig = @import("state.zig");
const ProgramState = state_zig.ProgramState;
const View = state_zig.View;

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
        state.aliases = cd_aliases.loadAliases(io, init.arena.allocator(), home) catch &.{};
    }

    var active_error: ?anyerror = null;

    while (true) {
        const frame_allocator = one_cycle_arena.allocator();
        defer _ = one_cycle_arena.reset(.free_all);
        terminal_size = Terminal.getSize();

        if (state.dir_changed) {
            // The remembered item (refresh, :!) points into dir_contents_arena, which we are about to
            // free – copy the name into the frame arena, otherwise we would compare freed memory
            switch (state.pending_cursor) {
                .item => |*target| {
                    target.name = try frame_allocator.dupe(u8, target.name);
                    target.extension = try frame_allocator.dupe(u8, target.extension);
                },
                else => {},
            }
            // Before loading new contents, completely clear the old list and file names
            _ = dir_contents_arena.reset(.free_all);
            const dir_allocator = dir_contents_arena.allocator();
            // fill current_dir_contents with the new entries
            var skipped_error: ?anyerror = null;
            if (fs.getDirContents(io, dir_allocator, state.current_dir, &skipped_error, state.viewing.owner or state.viewing.group)) |contents| {
                // uid/gid -> names (from the cache, a new id is looked up in libc only once)
                for (contents) |*entry| {
                    entry.owner_name = try fs.lookupName(.user, &state.user_names, init.arena.allocator(), entry.owner);
                    entry.group_name = try fs.lookupName(.group, &state.group_names, init.arena.allocator(), entry.group);
                }
                state.current_dir_contents = contents;
                state.sortContents();
                state.dir_changed = false;
                // null if everything is fine, otherwise the error of an entry we had to skip
                active_error = skipped_error;
            } else |err| {
                active_error = err; // Remember the error for one draw only
                state.dir_changed = false;

                // Fallback state - e.g. an empty directory, so the app doesn't freeze
                state.current_dir_contents = &.{};
            }
        }

        // Data for this frame; lives only until the end of the loop iteration (frame arena)
        var view: View = .{ .visible = try state_zig.getVisibleItems(frame_allocator, &state) };
        state_zig.applyPendingCursor(&state, view.visible);
        state_zig.setWindow(&view, terminal_size, state.global_index);

        var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
        const display_path = try render.shortenPath(state.current_dir, terminal_size.cols, &dir_buf);

        if (state.program_mode == .help) {
            // The page count depends on the terminal height; after shrinking the window we stay on the last page
            view.help_pages = render.helpPageCount(terminal_size.rows);
            state.help_page = @min(state.help_page, view.help_pages - 1);
            try render.drawHelpScreen(stdout, state.help_page, terminal_size.rows);
        } else if (state.program_mode == .alias) {
            // Alias mode has its own screen with just the list of aliases
            view.alias_matches = try cd_aliases.getFilteredAliases(frame_allocator, state.aliases, state.alias_buffer.items);
            state.alias_index = @min(state.alias_index, view.alias_matches.len -| 1);
            try render.drawAliasScreen(stdout, &state, &view, active_error, terminal_size);
        } else {
            try render.drawScreen(stdout, display_path, &state, &view, active_error, terminal_size.cols);
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
            .open_file => |item| openFile(io, terminal, stdout, stdin, frame_allocator, &state, item) catch |err| {
                active_error = err;
            },
            // E.g. an alias to a nonexistent directory – show the error, stay in alias mode
            .jump_to_alias => |alias| jumpToAlias(alias, &state, gpa, io) catch |err| {
                active_error = err;
            },
            .run_shell => |command| {
                const shell = init.environ_map.get("SHELL") orelse "/bin/sh";
                const selected: ?file_entry = if (state.global_index < view.visible.len) view.visible[state.global_index] else null;
                const expanded = handlers.expandShellCommand(frame_allocator, command, selected) catch |err| {
                    active_error = err;
                    continue;
                };
                runShell(io, terminal, stdout, stdin, state.current_dir, &.{ shell, "-c", expanded }) catch |err| {
                    active_error = err;
                };
                // The command may have created, deleted or renamed files – reload the directory
                state.rememberSelected(&view);
                state.dir_changed = true;
            },
            .interactive_shell => {
                const shell = init.environ_map.get("SHELL") orelse "/bin/sh";
                runShell(io, terminal, stdout, stdin, state.current_dir, &.{shell}) catch |err| {
                    active_error = err;
                };
                // Anything in the directory could have changed in the shell
                state.rememberSelected(&view);
                state.dir_changed = true;
            },
            .bulk_rename => {
                const tmp_dir = init.environ_map.get("TMPDIR") orelse "/tmp";
                bulkRename(io, terminal, stdout, stdin, frame_allocator, tmp_dir, state.current_dir, view.visible) catch |err| {
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

// Opening a file: text in $VISUAL/$EDITOR, everything else via xdg-open (detached)
fn openFile(
    io: std.Io,
    terminal: Terminal,
    stdout: *std.Io.Writer,
    stdin: *std.Io.Reader,
    frame_allocator: std.mem.Allocator,
    state: *const ProgramState,
    item: file_entry,
) !void {
    const file_full_name = try std.fmt.allocPrint(frame_allocator, "{s}{s}", .{
        item.name,
        item.extension,
    });
    const full_path = try std.fs.path.join(frame_allocator, &.{ state.current_dir, file_full_name });

    // statFile follows a symlink to its target. Only open regular files – on a FIFO even the
    // open itself would hang (text sniffing and xdg-open alike) and znavi couldn't even be quit
    const stat = try std.Io.Dir.cwd().statFile(io, full_path, .{});
    if (stat.kind != .file) return error.NotARegularFile;

    if (!fs.isTextFile(io, full_path)) return openDetached(io, state.current_dir, full_path);

    // Open text in an editor in this terminal.
    // A terminal editor (vim, less...) needs a normal terminal, not our RAW mode
    terminal.leaveRaw();
    errdefer terminal.enterRaw() catch {};
    const term = try runEditor(io, state.current_dir, full_path);
    // E.g. the editor doesn't exist (127). Wait for Enter before returning to our screen,
    // otherwise the program's message would disappear immediately
    const ok = switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        switch (term) {
            .exited => |code| try stdout.print("\nopen failed: exit code {d}", .{code}),
            else => try stdout.print("\nopen failed: terminated ({t})", .{term}),
        }
        try waitForEnter(stdout, stdin);
    }
    try terminal.enterRaw();
    if (!ok) return error.OpenCommandFailed;
}

// $VISUAL, then $EDITOR, then vi – in this terminal (call outside RAW mode).
// The path goes in as $1, so it needs no escaping; $VISUAL/$EDITOR may include arguments.
fn runEditor(io: std.Io, cwd: []const u8, path: []const u8) !std.process.Child.Term {
    var child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", "exec ${VISUAL:-${EDITOR:-vi}} \"$1\"", "znavi", path },
        .cwd = .{ .path = cwd }, // vim's :! and relative paths should apply here
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    return child.wait(io);
}

// :cw – put the visible file names into a temp file, the user edits them in an editor
// and the changed lines get renamed (rename.zig). If something fails, print why and wait for Enter.
fn bulkRename(
    io: std.Io,
    terminal: Terminal,
    stdout: *std.Io.Writer,
    stdin: *std.Io.Reader,
    allocator: std.mem.Allocator,
    tmp_dir: []const u8,
    cwd: []const u8,
    visible: []const file_entry,
) !void {
    // Same order as on screen, without ".."; a name containing a newline can't be written to the file
    var sources: std.ArrayList([]const u8) = .empty;
    var list: std.ArrayList(u8) = .empty;
    for (visible) |item| {
        if (std.mem.eql(u8, item.name, "..")) continue;
        const name = try std.fmt.allocPrint(allocator, "{s}{s}", .{ item.name, item.extension });
        if (std.mem.indexOfAny(u8, name, "\r\n") != null) continue;
        try sources.append(allocator, name);
        try list.print(allocator, "{s}\n", .{name});
    }
    if (sources.items.len == 0) return error.NothingToRename;

    // Random name and exclusive, so we don't overwrite someone else's file in a shared /tmp
    var random_bytes: [8]u8 = undefined;
    io.random(&random_bytes);
    const list_path = try std.fmt.allocPrint(allocator, "{s}/znavi-cw.{x}", .{ tmp_dir, &random_bytes });
    {
        const file = try std.Io.Dir.cwd().createFile(io, list_path, .{ .exclusive = true, .permissions = .fromMode(0o600) });
        defer file.close(io);
        try file.writeStreamingAll(io, list.items);
    }
    defer std.Io.Dir.cwd().deleteFile(io, list_path) catch {};

    terminal.leaveRaw();
    defer terminal.enterRaw() catch {};

    // Editor exited with an error (vim :cq) = cancel, rename nothing
    const term = try runEditor(io, cwd, list_path);
    const ok = switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        try stdout.writeAll("\ncw: editor did not exit cleanly, nothing renamed.");
        try waitForEnter(stdout, stdin);
        return error.RenameCancelled;
    }

    const edited = try std.Io.Dir.cwd().readFileAlloc(io, list_path, allocator, .limited(64 << 20));
    var dir = try std.Io.Dir.openDirAbsolute(io, cwd, .{});
    defer dir.close(io);

    const outcome = rename.run(io, allocator, dir, sources.items, edited, stdout) catch |err| {
        try waitForEnter(stdout, stdin);
        return err;
    };
    if (outcome.failed > 0) {
        try stdout.print("cw: {d} renamed, {d} failed.", .{ outcome.renamed, outcome.failed });
        try waitForEnter(stdout, stdin);
        return error.RenameFailed;
    }
}

// Run the GUI program outside our terminal: a new session without a controlling terminal,
// stdio on /dev/null. Ctrl+Z/Ctrl+C in znavi won't hit it and znavi doesn't wait for it to close.
// Linux: setsid(1) from util-linux, FreeBSD: daemon(8) from the base system. setsid is tried
// first, because on Linux a different `daemon` may be installed, where -f means foreground.
// An error from xdg-open itself (e.g. no application found) is invisible after detaching; we at
// least check that it exists.
fn openDetached(io: std.Io, cwd: []const u8, path: []const u8) !void {
    var child = try std.process.spawn(io, .{
        .argv = &.{
            "/bin/sh",
            "-c",
            \\command -v xdg-open >/dev/null || exit 127
            \\if command -v setsid >/dev/null; then exec setsid -f xdg-open "$1"
            \\else exec daemon -f xdg-open "$1"; fi
            ,
            "znavi",
            path,
        },
        .cwd = .{ .path = cwd },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    // setsid/daemon exits right after detaching; wait for it so it doesn't stay a zombie
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| switch (code) {
            0 => {},
            127 => return error.XdgOpenNotFound,
            else => return error.OpenCommandFailed,
        },
        else => return error.OpenCommandFailed,
    }
}

// :!command (argv = shell -c command) or :sh (argv = just the shell) – runs in the current
// directory on the normal terminal (like vim); after :! waits for Enter so the output stays visible
fn runShell(
    io: std.Io,
    terminal: Terminal,
    stdout: *std.Io.Writer,
    stdin: *std.Io.Reader,
    cwd: []const u8,
    argv: []const []const u8,
) !void {
    terminal.leaveRaw();
    defer terminal.enterRaw() catch {};

    // Ctrl+C / Ctrl+\ sends SIGINT / SIGQUIT to the whole foreground process group,
    // which includes znavi. Catch them with a no-op handler while the child runs so only
    // the child dies (like system(3)). Not SIG_IGN: ignored signals are inherited
    // across exec, so the child would ignore Ctrl+C too, while a handler is reset to default.
    const noop: posix.Sigaction = .{
        .handler = .{ .handler = noopSignalHandler },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    var old_int: posix.Sigaction = undefined;
    var old_quit: posix.Sigaction = undefined;
    posix.sigaction(.INT, &noop, &old_int);
    defer posix.sigaction(.INT, &old_int, null);
    posix.sigaction(.QUIT, &noop, &old_quit);
    defer posix.sigaction(.QUIT, &old_quit, null);

    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    // wait4 is retried on EINTR, so the handler doesn't break waiting
    const term = try child.wait(io);

    // Interactive :sh – the exit code is only from the last command in it, don't wait for Enter
    if (argv.len == 1) return;
    switch (term) {
        .exited => |code| if (code != 0) try stdout.print("\nshell returned {d}", .{code}),
        else => try stdout.print("\nshell terminated: {t}", .{term}),
    }
    try waitForEnter(stdout, stdin);
}

fn noopSignalHandler(_: posix.SIG) callconv(.c) void {}

// Call outside RAW mode
fn waitForEnter(stdout: *std.Io.Writer, stdin: *std.Io.Reader) !void {
    try stdout.writeAll("\nPress Enter to continue");
    try stdout.flush();
    // The terminal is in normal (line) mode, so the first byte arrives only after Enter;
    // discard the rest of the line (enterRaw with .FLUSH also discards anything not yet read)
    _ = stdin.takeByte() catch {};
    stdin.toss(stdin.buffered().len);
}

// Goes to the alias's directory and returns to normal mode
fn jumpToAlias(alias: Alias, state: *ProgramState, gpa: std.mem.Allocator, io: std.Io) !void {
    // The real path: /home/... -> /usr/home/..., without a trailing slash
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try std.Io.Dir.realPathFileAbsolute(io, alias.path, &path_buf);
    state.setCurrentDir(gpa, try gpa.dupe(u8, path_buf[0..path_len]));

    // Jumping elsewhere – the old forward path and the search no longer apply
    state.clearForwardHistory(gpa);
    state.search_buffer.clearRetainingCapacity();
    state.resetIndices();
    state.dir_changed = true;
    state.program_mode = .normal;
}

// ===================== Tests (zig build test) =====================

// Tests from FileEntry.zig (sorting, formatting) run together with these
test {
    _ = file_entry;
    _ = render;
    _ = cd_aliases;
    _ = input;
    _ = fs;
    _ = Terminal;
    _ = state_zig;
    _ = @import("commands.zig");
    _ = @import("handlers.zig");
    _ = rename;
}
