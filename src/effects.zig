// Side effects requested by the handlers (see Action in state.zig): opening files, running
// programs in the foreground, :cw and alias jumps. main.zig only dispatches to these.
const std = @import("std");
const posix = std.posix;
const FileEntry = @import("FileEntry.zig");
const Terminal = @import("Terminal.zig");
const fs = @import("fs.zig");
const rename = @import("rename.zig");
const Alias = @import("aliases.zig").Alias;
const ProgramState = @import("state.zig").ProgramState;

// The terminal environment that every foreground child needs
pub const Ui = struct {
    io: std.Io,
    terminal: Terminal,
    stdout: *std.Io.Writer,
    stdin: *std.Io.Reader,

    // Gives the normal terminal to a child program (and to our messages after it exits).
    // Always paired with `defer ui.takeBack()`.
    fn handOff(ui: Ui) void {
        ui.terminal.leaveRaw();
    }

    fn takeBack(ui: Ui) void {
        ui.terminal.enterRaw() catch {};
    }

    // Call between handOff and takeBack
    fn waitForEnter(ui: Ui) !void {
        try ui.stdout.writeAll("\nPress Enter to continue");
        try ui.stdout.flush();
        // The terminal is in normal (line) mode, so the first byte arrives only after Enter;
        // discard the rest of the line (enterRaw with .FLUSH also discards anything not yet read)
        _ = ui.stdin.takeByte() catch {};
        ui.stdin.toss(ui.stdin.buffered().len);
    }
};

// Ctrl+C / Ctrl+\ sends SIGINT / SIGQUIT to the whole foreground process group,
// which includes znavi. Catch them with a no-op handler while the child runs so only
// the child dies (like system(3)). Not SIG_IGN: ignored signals are inherited
// across exec, so the child would ignore Ctrl+C too, while a handler is reset to default.
const SignalGuard = struct {
    old_int: posix.Sigaction,
    old_quit: posix.Sigaction,

    fn install() SignalGuard {
        const noop: posix.Sigaction = .{
            .handler = .{ .handler = noopSignalHandler },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        var guard: SignalGuard = undefined;
        posix.sigaction(.INT, &noop, &guard.old_int);
        posix.sigaction(.QUIT, &noop, &guard.old_quit);
        return guard;
    }

    fn restore(guard: *const SignalGuard) void {
        posix.sigaction(.INT, &guard.old_int, null);
        posix.sigaction(.QUIT, &guard.old_quit, null);
    }

    fn noopSignalHandler(_: posix.SIG) callconv(.c) void {}
};

// Every program that takes over our terminal runs through here, between ui.handOff and ui.takeBack.
// It runs in cwd (so vim's :! and relative paths apply there) and only it gets Ctrl+C.
fn runForeground(ui: Ui, cwd: []const u8, argv: []const []const u8) !std.process.Child.Term {
    const guard = SignalGuard.install();
    defer guard.restore();

    var child = try std.process.spawn(ui.io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    // wait4 is retried on EINTR, so the handler doesn't break waiting
    return child.wait(ui.io);
}

// $VISUAL, then $EDITOR, then vi – in this terminal.
// The path goes in as $1, so it needs no escaping; $VISUAL/$EDITOR may include arguments.
fn runEditor(ui: Ui, cwd: []const u8, path: []const u8) !std.process.Child.Term {
    return runForeground(ui, cwd, &.{ "/bin/sh", "-c", "exec ${VISUAL:-${EDITOR:-vi}} \"$1\"", "znavi", path });
}

fn exitedCleanly(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

// Opening a file: text in $VISUAL/$EDITOR, everything else via xdg-open (detached)
pub fn openFile(ui: Ui, allocator: std.mem.Allocator, cwd: []const u8, item: FileEntry) !void {
    var name_buf: [std.Io.Dir.max_name_bytes]u8 = undefined;
    const full_path = try std.fs.path.join(allocator, &.{ cwd, item.fullName(&name_buf) });

    // statFile follows a symlink to its target. Only open regular files – on a FIFO even the
    // open itself would hang (text sniffing and xdg-open alike) and znavi couldn't even be quit
    const stat = try std.Io.Dir.cwd().statFile(ui.io, full_path, .{});
    if (stat.kind != .file) return error.NotARegularFile;

    if (!fs.isTextFile(ui.io, full_path)) return openDetached(ui.io, cwd, full_path);

    // Open text in an editor in this terminal
    ui.handOff();
    defer ui.takeBack();
    const term = try runEditor(ui, cwd, full_path);
    if (exitedCleanly(term)) return;
    // E.g. the editor doesn't exist (127). Wait for Enter before returning to our screen,
    // otherwise the program's message would disappear immediately
    switch (term) {
        .exited => |code| try ui.stdout.print("\nopen failed: exit code {d}", .{code}),
        else => try ui.stdout.print("\nopen failed: terminated ({t})", .{term}),
    }
    try ui.waitForEnter();
    return error.OpenCommandFailed;
}

// :cw – put the visible file names into a temp file, the user edits them in an editor
// and the changed lines get renamed (rename.zig). If something fails, print why and wait for Enter.
pub fn bulkRename(
    ui: Ui,
    allocator: std.mem.Allocator,
    tmp_dir: []const u8,
    cwd: []const u8,
    visible: []const FileEntry,
) !void {
    const io = ui.io;
    // Same order as on screen, without ".."; a name containing a newline can't be written to the file
    var sources: std.ArrayList([]const u8) = .empty;
    var list: std.ArrayList(u8) = .empty;
    var name_buf: [std.Io.Dir.max_name_bytes]u8 = undefined;
    for (visible) |item| {
        if (item.is_parent) continue;
        const name = try allocator.dupe(u8, item.fullName(&name_buf));
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

    // Stays on the normal terminal until the end, rename.run reports to stdout
    ui.handOff();
    defer ui.takeBack();

    // Editor exited with an error (vim :cq) = cancel, rename nothing
    if (!exitedCleanly(try runEditor(ui, cwd, list_path))) {
        try ui.stdout.writeAll("\ncw: editor did not exit cleanly, nothing renamed.");
        try ui.waitForEnter();
        return error.RenameCancelled;
    }

    const edited = try std.Io.Dir.cwd().readFileAlloc(io, list_path, allocator, .limited(64 << 20));
    var dir = try std.Io.Dir.openDirAbsolute(io, cwd, .{});
    defer dir.close(io);

    const outcome = rename.run(io, allocator, dir, sources.items, edited, ui.stdout) catch |err| {
        try ui.waitForEnter();
        return err;
    };
    if (outcome.failed > 0) {
        try ui.stdout.print("cw: {d} renamed, {d} failed.", .{ outcome.renamed, outcome.failed });
        try ui.waitForEnter();
        return error.RenameFailed;
    }
}

// :!command (argv = shell -c command) or :sh (argv = just the shell) – runs in the current
// directory on the normal terminal (like vim); after :! waits for Enter so the output stays visible
pub fn runShell(ui: Ui, cwd: []const u8, argv: []const []const u8) !void {
    ui.handOff();
    defer ui.takeBack();
    const term = try runForeground(ui, cwd, argv);

    // Interactive :sh – the exit code is only from the last command in it, don't wait for Enter
    if (argv.len == 1) return;
    switch (term) {
        .exited => |code| if (code != 0) try ui.stdout.print("\nshell returned {d}", .{code}),
        else => try ui.stdout.print("\nshell terminated: {t}", .{term}),
    }
    try ui.waitForEnter();
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

// Goes to the alias's directory and returns to normal mode
pub fn jumpToAlias(alias: Alias, state: *ProgramState, gpa: std.mem.Allocator, io: std.Io) !void {
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
