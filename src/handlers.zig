// Key handling in the individual modes: handlers only change state and return an Action,
// side effects (opening a file, help, jumping to an alias...) are done by main
const std = @import("std");
const file_entry = @import("FileEntry.zig");
const Key = @import("input.zig").Key;
const cd_aliases = @import("aliases.zig");
const Alias = cd_aliases.Alias;
const commands = @import("commands.zig").commands;
const state_zig = @import("state.zig");
const ProgramState = state_zig.ProgramState;
const View = state_zig.View;
const Action = state_zig.Action;
const Mode = state_zig.Mode;
const Sorting = state_zig.Sorting;
const pushHistory = state_zig.pushHistory;
const applyPendingCursor = state_zig.applyPendingCursor;
const testState = state_zig.testState;
const testEntry = state_zig.testEntry;

pub fn handleKey(key: Key, state: *ProgramState, view: *const View, gpa: std.mem.Allocator) !Action {
    // Ctrl+Z works in every mode
    if (key == .ctrl_z) return .suspend_process;
    return switch (state.program_mode) {
        .normal => handleNormalMode(key, state, view, gpa),
        .command => handleCommandMode(key, state, view, gpa),
        .search => handleSearchMode(key, state, gpa),
        .alias => handleAliasMode(key, state, view, gpa),
        .help => handleHelpMode(key, state, view),
    };
}

// Entering a directory
fn enterDir(state: *ProgramState, gpa: std.mem.Allocator, item: file_entry) !void {
    state.setCurrentDir(gpa, try std.fs.path.resolve(gpa, &.{
        state.current_dir,
        item.name,
    }));
    state.resetIndices();
    state.dir_changed = true;
}

fn handleNormalMode(key: Key, state: *ProgramState, view: *const View, gpa: std.mem.Allocator) anyerror!Action {
    // Collect digits into count (0 only if we're already typing a number), capped at 9999
    if (key == .char) {
        const c = key.char;
        if ((c >= '1' and c <= '9') or (c == '0' and state.count > 0)) {
            if (state.count < 1000) state.count = state.count * 10 + (c - '0');
            return .none;
        }
    }
    // Any other key consumes count (only j/k use it)
    const count = @max(state.count, 1);
    state.count = 0;

    switch (key) {
        .help => state.enterHelp(),
        .ctrl_z => return .suspend_process,
        .backspace => {
            state.rememberSelected(view);
            state.viewing.hidden = !state.viewing.hidden;
        },
        .command => {
            state.program_mode = .command;
            state.command_buffer.clearRetainingCapacity();
        },
        .search => {
            state.program_mode = .search;
            state.search_buffer.clearRetainingCapacity();
        },
        .alias => {
            state.enterAliasMode();
        },
        .up => {
            if (state.global_index > 0) {
                // 5k: count rows up, at most to the first item
                state.global_index -|= count;
            }
        },
        .down => {
            if (view.visible.len > 0 and state.global_index + 1 < view.visible.len) {
                // 5j: count rows down, at most to the last item
                state.global_index = @min(state.global_index + count, view.visible.len - 1);
            }
        },
        .right => {
            if (view.visible.len > 0) {
                const item = view.visible[state.global_index];
                if (item.is_dir) {
                    state.search_buffer.clearRetainingCapacity();
                    try enterDir(state, gpa, item);

                    const fwd = state.history_forward.items;
                    if (fwd.len > 0 and std.mem.eql(u8, fwd[fwd.len - 1], item.name)) {
                        // Going back down the same path – put the cursor on the next level
                        gpa.free(state.history_forward.pop().?);
                        state.pending_cursor = .from_history;
                    } else {
                        // A new branch, the old forward path no longer applies
                        state.clearForwardHistory(gpa);
                    }
                } else {
                    return .{ .open_file = item };
                }
            }
        },
        .left => {
            // Compute the parent directory
            const parent_dir = try std.fs.path.resolve(gpa, &.{
                state.current_dir,
                "..",
            });
            // On "/" the parent is "/" again – nowhere to go, nothing to save or reload
            if (std.mem.eql(u8, parent_dir, state.current_dir)) {
                gpa.free(parent_dir);
                return .none;
            }
            errdefer gpa.free(parent_dir);

            // When going up, find out the name of the directory we came from
            // and save it to the FORWARD history, so we can go back down again
            try pushHistory(&state.history_forward, gpa, std.fs.path.basename(state.current_dir));

            state.setCurrentDir(gpa, parent_dir);
            state.resetIndices();
            state.pending_cursor = .from_history;
            state.dir_changed = true;
            state.search_buffer.clearRetainingCapacity();
        },
        .ctrl_d => {
            if (state.global_index + 20 < view.visible.len) {
                state.global_index += 20;
            } else if (view.visible.len > 0) {
                state.global_index = view.visible.len - 1;
            }
        },
        .ctrl_u => {
            if (state.global_index >= 20) {
                state.global_index -= 20;
            } else {
                state.global_index = 0;
            }
        },
        .go_top => {
            state.global_index = 0;
        },
        .go_bottom => {
            if (view.visible.len > 0) {
                state.global_index = view.visible.len - 1;
            }
        },
        .quit => return .quit,
        .char => |c| switch (c) {
            27 => {
                if (state.search_buffer.items.len > 0) {
                    state.rememberSelected(view);
                    state.search_buffer.clearRetainingCapacity();
                }
            },
            '\r', '\n' => {
                if (view.visible.len > 0) {
                    // IF IT'S A DIRECTORY: artificially trigger the .right branch (right arrow)
                    // That way Enter takes over all the logic, history and memory management of the 'l' key
                    if (view.visible[state.global_index].is_dir) {
                        return handleNormalMode(.right, state, view, gpa);
                    } else {
                        // If it's a file, just open it (editor or xdg-open)
                        return .{ .open_file = view.visible[state.global_index] };
                    }
                }
            },
            'r' => state.refresh(view),
            else => {},
        },
    }
    return .none;
}

fn handleCommandMode(key: Key, state: *ProgramState, view: *const View, gpa: std.mem.Allocator) !Action {
    switch (key) {
        .char => |c| switch (c) {
            '\r', '\n' => {
                const command = state.command_buffer.items;
                // After Enter we return to normal mode (the :a command switches on to alias mode)
                state.program_mode = .normal;

                for (commands) |cmd| {
                    if (std.mem.eql(u8, command, cmd.name)) return cmd.run(state, view);
                }
                // :!ls – the shell command is run by main (an empty :! does nothing)
                if (command.len > 1 and command[0] == '!') return .{ .run_shell = command[1..] };
                // :<number> – jump to an index
                if (std.fmt.parseInt(usize, command, 10) catch null) |target_index| {
                    if (target_index < view.visible.len) {
                        state.global_index = target_index;
                    } else if (view.visible.len > 0) {
                        state.global_index = view.visible.len - 1;
                    }
                }
            },
            27 => {
                state.program_mode = .normal;
            },
            32...126 => {
                try state.command_buffer.append(gpa, c);
            },
            else => {},
        },
        .backspace => {
            if (state.command_buffer.items.len > 0) {
                _ = state.command_buffer.pop();
            }
        },
        .quit => return .quit,
        else => {},
    }
    return .none;
}

fn handleSearchMode(key: Key, state: *ProgramState, gpa: std.mem.Allocator) !Action {
    switch (key) {
        .char => |c| switch (c) {
            '\r', '\n' => {
                state.program_mode = .normal;
            },
            27 => {
                state.search_buffer.clearRetainingCapacity();
                state.resetIndices();
                state.program_mode = .normal;
            },
            32...126 => {
                try state.search_buffer.append(gpa, c);
                state.resetIndices();
            },
            else => {},
        },
        .backspace => {
            if (state.search_buffer.items.len > 0) {
                _ = state.search_buffer.pop();
                state.resetIndices();
            }
        },
        .quit => return .quit,
        else => {},
    }
    return .none;
}

fn handleAliasMode(key: Key, state: *ProgramState, view: *const View, gpa: std.mem.Allocator) !Action {
    switch (key) {
        .char => |c| switch (c) {
            '\r', '\n' => {
                if (view.alias_matches.len == 0) return .none;
                return .{ .jump_to_alias = view.alias_matches[state.alias_index] };
            },
            27 => {
                state.program_mode = .normal;
            },
            32...126 => {
                try state.alias_buffer.append(gpa, c);
                state.alias_index = 0;
                // Only one alias left – jump right away, without Enter
                if (cd_aliases.singleAliasMatch(state.aliases, state.alias_buffer.items)) |alias| return .{ .jump_to_alias = alias };
            },
            else => {},
        },
        .backspace => {
            if (state.alias_buffer.items.len > 0) {
                _ = state.alias_buffer.pop();
                state.alias_index = 0;
                if (cd_aliases.singleAliasMatch(state.aliases, state.alias_buffer.items)) |alias| return .{ .jump_to_alias = alias };
            }
        },
        .up => {
            state.alias_index -|= 1;
        },
        .down => {
            if (state.alias_index + 1 < view.alias_matches.len) state.alias_index += 1;
        },
        .quit => return .quit,
        else => {},
    }
    return .none;
}

// Help: q or Esc closes it, any other key = next page (closes on the last one).
// Ctrl+C (.quit) and Ctrl+Z work like everywhere else
fn handleHelpMode(key: Key, state: *ProgramState, view: *const View) Action {
    switch (key) {
        .quit => return .quit,
        .char => |c| if (c == 'q' or c == 27) {
            state.program_mode = .normal;
            return .none;
        },
        else => {},
    }
    if (state.help_page + 1 < view.help_pages) {
        state.help_page += 1;
    } else {
        state.program_mode = .normal;
    }
    return .none;
}

// :!command: % is replaced with the selected file's name (in single quotes, so spaces
// and special characters survive), \% is a plain %. Without a selected file % is an error.
pub fn expandShellCommand(allocator: std.mem.Allocator, command: []const u8, selected: ?file_entry) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < command.len) : (i += 1) {
        const c = command[i];
        if (c == '\\' and i + 1 < command.len and command[i + 1] == '%') {
            try out.append(allocator, '%');
            i += 1;
        } else if (c == '%') {
            const file = selected orelse return error.NoFileSelected;
            // 'name' – a single quote in the name is written as '\'' (closes, escapes, reopens)
            try out.append(allocator, '\'');
            for ([_][]const u8{ file.name, file.extension }) |part| {
                for (part) |ch| {
                    if (ch == '\'') try out.appendSlice(allocator, "'\\''") else try out.append(allocator, ch);
                }
            }
            try out.append(allocator, '\'');
        } else {
            try out.append(allocator, c);
        }
    }
    return out.toOwnedSlice(allocator);
}

// ===================== Tests =====================

// Feeds keys to handleKey one by one, returns the action of the last one
fn feedKeys(state: *ProgramState, view: *const View, keys: []const Key) !Action {
    var action: Action = .none;
    for (keys) |key| action = try handleKey(key, state, view, std.testing.allocator);
    return action;
}

test "count prefix: 5j and 3k" {
    var state = try testState("/tmp");
    defer state.deinit(std.testing.allocator);
    var items: [10]file_entry = undefined;
    for (&items) |*item| item.* = testEntry("f", false, 0);
    const view: View = .{ .visible = &items };

    _ = try feedKeys(&state, &view, &.{ .{ .char = '5' }, .down });
    try std.testing.expectEqual(@as(usize, 5), state.global_index);
    _ = try feedKeys(&state, &view, &.{ .{ .char = '3' }, .up });
    try std.testing.expectEqual(@as(usize, 2), state.global_index);
    // We don't go past the end
    _ = try feedKeys(&state, &view, &.{ .{ .char = '9' }, .{ .char = '9' }, .down });
    try std.testing.expectEqual(@as(usize, 9), state.global_index);
    // The count is used up, the next j moves one row
    _ = try feedKeys(&state, &view, &.{.up});
    try std.testing.expectEqual(@as(usize, 8), state.global_index);
}

test "Enter: a file returns open_file, a directory changes the directory" {
    var state = try testState("/tmp");
    defer state.deinit(std.testing.allocator);
    const items = [_]file_entry{ testEntry("sub", true, 0), testEntry("notes.txt", false, 10) };
    const view: View = .{ .visible = &items };

    state.global_index = 1;
    const action = try feedKeys(&state, &view, &.{.{ .char = '\r' }});
    try std.testing.expectEqualStrings("notes.txt", action.open_file.name);
    try std.testing.expectEqualStrings("/tmp", state.current_dir);

    state.global_index = 0;
    try std.testing.expectEqual(Action.none, try feedKeys(&state, &view, &.{.{ .char = '\r' }}));
    try std.testing.expectEqualStrings("/tmp/sub", state.current_dir);
    try std.testing.expect(state.dir_changed);
}

test "h and then l puts the cursor back on the directory we came from" {
    var state = try testState("/tmp/sub");
    defer state.deinit(std.testing.allocator);

    _ = try feedKeys(&state, &.{}, &.{.left});
    try std.testing.expectEqualStrings("/tmp", state.current_dir);

    // New frame: contents of /tmp, cursor on "sub"
    const parent = [_]file_entry{ testEntry("a", true, 0), testEntry("b", true, 0), testEntry("sub", true, 0) };
    const view: View = .{ .visible = &parent };
    applyPendingCursor(&state, view.visible);
    try std.testing.expectEqual(@as(usize, 2), state.global_index);

    // l on the same directory: back down, and the history entry is consumed
    _ = try feedKeys(&state, &view, &.{.right});
    try std.testing.expectEqualStrings("/tmp/sub", state.current_dir);
    try std.testing.expectEqual(@as(usize, 0), state.history_forward.items.len);
}

test "commands :sS, :q and :<number>" {
    var state = try testState("/tmp");
    defer state.deinit(std.testing.allocator);
    var items: [10]file_entry = undefined;
    for (&items) |*item| item.* = testEntry("f", false, 0);
    const view: View = .{ .visible = &items };

    _ = try feedKeys(&state, &view, &.{ .command, .{ .char = 's' }, .{ .char = 'S' }, .{ .char = '\r' } });
    try std.testing.expectEqual(Sorting.by_size_desc, state.current_sorting);
    try std.testing.expectEqual(Mode.normal, state.program_mode);

    // A number past the end of the list: the last item
    _ = try feedKeys(&state, &view, &.{ .command, .{ .char = '4' }, .{ .char = '2' }, .{ .char = '\r' } });
    try std.testing.expectEqual(@as(usize, 9), state.global_index);

    // An unknown command does nothing
    try std.testing.expectEqual(Action.none, try feedKeys(&state, &view, &.{ .command, .{ .char = 'x' }, .{ .char = '\r' } }));

    try std.testing.expectEqual(Action.quit, try feedKeys(&state, &view, &.{ .command, .{ .char = 'q' }, .{ .char = '\r' } }));
}

test "alias mode jumps by itself when only one alias is left" {
    var state = try testState("/tmp");
    defer state.deinit(std.testing.allocator);
    const aliases = [_]Alias{
        .{ .name = "docs", .path = "/d", .real_path = "/d" },
        .{ .name = "downloads", .path = "/dl", .real_path = "/dl" },
    };
    state.aliases = &aliases;
    state.enterAliasMode();
    const view: View = .{};

    // "do" matches both
    try std.testing.expectEqual(Action.none, try feedKeys(&state, &view, &.{ .{ .char = 'd' }, .{ .char = 'o' } }));
    // "doc" matches only docs
    const action = try feedKeys(&state, &view, &.{.{ .char = 'c' }});
    try std.testing.expectEqualStrings("docs", action.jump_to_alias.name);
}

test "help: paging, q closes, Ctrl+C quits" {
    var state = try testState("/tmp");
    defer state.deinit(std.testing.allocator);
    const view: View = .{ .help_pages = 2 };

    _ = try feedKeys(&state, &view, &.{.help});
    try std.testing.expectEqual(Mode.help, state.program_mode);
    try std.testing.expectEqual(@as(usize, 0), state.help_page);
    // Any key = next page, closes on the last one
    _ = try feedKeys(&state, &view, &.{.{ .char = 'x' }});
    try std.testing.expectEqual(@as(usize, 1), state.help_page);
    _ = try feedKeys(&state, &view, &.{.down});
    try std.testing.expectEqual(Mode.normal, state.program_mode);

    // :? opens help again from the first page, q closes it right away
    _ = try feedKeys(&state, &view, &.{ .command, .{ .char = '?' }, .{ .char = '\r' } });
    try std.testing.expectEqual(Mode.help, state.program_mode);
    try std.testing.expectEqual(@as(usize, 0), state.help_page);
    _ = try feedKeys(&state, &view, &.{.{ .char = 'q' }});
    try std.testing.expectEqual(Mode.normal, state.program_mode);

    // Ctrl+C in help quits the program, Ctrl+Z suspends it
    _ = try feedKeys(&state, &view, &.{.help});
    try std.testing.expectEqual(Action.quit, try feedKeys(&state, &view, &.{.quit}));
    try std.testing.expectEqual(Action.suspend_process, try feedKeys(&state, &view, &.{.ctrl_z}));
}

test ":! returns the shell command, an empty :! does nothing" {
    var state = try state_zig.testState("/tmp");
    defer state.deinit(std.testing.allocator);
    const view: View = .{};

    const action = try feedKeys(&state, &view, &.{ .command, .{ .char = '!' }, .{ .char = 'l' }, .{ .char = 's' }, .{ .char = '\r' } });
    try std.testing.expectEqualStrings("ls", action.run_shell);
    try std.testing.expectEqual(Mode.normal, state.program_mode);

    try std.testing.expectEqual(Action.none, try feedKeys(&state, &view, &.{ .command, .{ .char = '!' }, .{ .char = '\r' } }));
}

test ":sh returns an interactive shell" {
    var state = try state_zig.testState("/tmp");
    defer state.deinit(std.testing.allocator);
    const view: View = .{};

    try std.testing.expectEqual(Action.interactive_shell, try feedKeys(&state, &view, &.{ .command, .{ .char = 's' }, .{ .char = 'h' }, .{ .char = '\r' } }));
    try std.testing.expectEqual(Mode.normal, state.program_mode);
}

test ":! replaces % with the selected file name" {
    const allocator = std.testing.allocator;
    var file = state_zig.testEntry("my file", false, 0);
    file.extension = ".txt";

    const expanded = try expandShellCommand(allocator, "wc -l % && echo 100\\%", file);
    defer allocator.free(expanded);
    try std.testing.expectEqualStrings("wc -l 'my file.txt' && echo 100%", expanded);

    const quoted = try expandShellCommand(allocator, "cat %", state_zig.testEntry("it's", false, 0));
    defer allocator.free(quoted);
    try std.testing.expectEqualStrings("cat 'it'\\''s'", quoted);

    try std.testing.expectError(error.NoFileSelected, expandShellCommand(allocator, "cat %", null));
}
