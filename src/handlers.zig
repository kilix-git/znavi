// Spracovanie klávesov v jednotlivých módoch: iba menia stav a vracajú Action,
// vedľajšie efekty (otvorenie súboru, nápoveda, skok na alias...) robí main
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
    // Ctrl+Z funguje v každom režime
    if (key == .ctrl_z) return .suspend_process;
    return switch (state.program_mode) {
        .normal => handleNormalMode(key, state, view, gpa),
        .command => handleCommandMode(key, state, view, gpa),
        .search => handleSearchMode(key, state, gpa),
        .alias => handleAliasMode(key, state, view, gpa),
        .help => handleHelpMode(key, state, view),
    };
}

// Vstup do priečinka
fn enterDir(state: *ProgramState, gpa: std.mem.Allocator, item: file_entry) !void {
    state.setCurrentDir(gpa, try std.fs.path.resolve(gpa, &.{
        state.current_dir,
        item.name,
    }));
    state.resetIndices();
    state.dir_changed = true;
}

fn handleNormalMode(key: Key, state: *ProgramState, view: *const View, gpa: std.mem.Allocator) anyerror!Action {
    // Číslice zbierame do count (0 iba ak už nejaké číslo rozpisujeme), strop 9999
    if (key == .char) {
        const c = key.char;
        if ((c >= '1' and c <= '9') or (c == '0' and state.count > 0)) {
            if (state.count < 1000) state.count = state.count * 10 + (c - '0');
            return .none;
        }
    }
    // Akýkoľvek iný kláves count spotrebuje (použijú ho iba j/k)
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
                // 5k: o count riadkov hore, najďalej na prvú položku
                state.global_index -|= count;
            }
        },
        .down => {
            if (view.visible.len > 0 and state.global_index + 1 < view.visible.len) {
                // 5j: o count riadkov dole, najďalej na poslednú položku
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
                        // Ideme tou istou cestou späť dole – kurzor dáme na ďalšiu úroveň
                        gpa.free(state.history_forward.pop().?);
                        state.pending_cursor = .from_history;
                    } else {
                        // Nová vetva, stará cesta vpred už neplatí
                        state.clearForwardHistory(gpa);
                    }
                } else {
                    return .{ .open_file = item };
                }
            }
        },
        .left => {
            // Vypočítame rodičovský adresár
            const parent_dir = try std.fs.path.resolve(gpa, &.{
                state.current_dir,
                "..",
            });
            // Na "/" je rodič zas "/" – nie je kam ísť, nič neukladáme ani nenačítavame
            if (std.mem.eql(u8, parent_dir, state.current_dir)) {
                gpa.free(parent_dir);
                return .none;
            }
            errdefer gpa.free(parent_dir);

            // Ak ideme hore, zistíme názov priečinka, z ktorého sme prišli,
            // a uložíme ho do histórie FORWARD, aby sme vedeli ísť znova dole
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
                    // AK JE TO ADRESÁR: Umelo vyvoláme vetvu .right (šípku vpravo)
                    // Tým zaistíme, že Enter prevezme celú logiku, históriu aj správu pamäte z klávesy 'l'
                    if (view.visible[state.global_index].is_dir) {
                        return handleNormalMode(.right, state, view, gpa);
                    } else {
                        // Ak je to súbor, iba ho otvoríme (editor alebo xdg-open)
                        return .{ .open_file = view.visible[state.global_index] };
                    }
                }
            },
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
                // Po Enter sa vraciame do normal módu (príkaz :a ho prepne ďalej na alias mód)
                state.program_mode = .normal;

                for (commands) |cmd| {
                    if (std.mem.eql(u8, command, cmd.name)) return cmd.run(state, view);
                }
                // :!ls – shellový príkaz spustí main (prázdne :! nerobí nič)
                if (command.len > 1 and command[0] == '!') return .{ .run_shell = command[1..] };
                // :<number> – skok na index
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
                // Ostal jediný alias – skočíme hneď, bez Enter
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

// Nápoveda: q alebo Esc ju zatvorí, iný kláves = ďalšia strana (na poslednej zatvorí).
// Ctrl+C (.quit) a Ctrl+Z fungujú ako všade inde
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

// :!príkaz: % nahradí menom vybraného súboru (v apostrofoch, aby prežili medzery
// aj špeciálne znaky), \% je obyčajné %. Bez vybraného súboru je % chyba.
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
            // 'meno' – apostrof v mene zapíšeme ako '\'' (ukončí, escapuje, znova otvorí)
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

// ===================== Testy =====================

// Pošle klávesy postupne do handleKey, vráti akciu posledného
fn feedKeys(state: *ProgramState, view: *const View, keys: []const Key) !Action {
    var action: Action = .none;
    for (keys) |key| action = try handleKey(key, state, view, std.testing.allocator);
    return action;
}

test "count prefix: 5j a 3k" {
    var state = try testState("/tmp");
    defer state.deinit(std.testing.allocator);
    var items: [10]file_entry = undefined;
    for (&items) |*item| item.* = testEntry("f", false, 0);
    const view: View = .{ .visible = &items };

    _ = try feedKeys(&state, &view, &.{ .{ .char = '5' }, .down });
    try std.testing.expectEqual(@as(usize, 5), state.global_index);
    _ = try feedKeys(&state, &view, &.{ .{ .char = '3' }, .up });
    try std.testing.expectEqual(@as(usize, 2), state.global_index);
    // Ďalej ako na koniec nejdeme
    _ = try feedKeys(&state, &view, &.{ .{ .char = '9' }, .{ .char = '9' }, .down });
    try std.testing.expectEqual(@as(usize, 9), state.global_index);
    // Count sa minul, ďalšie j je o jeden riadok
    _ = try feedKeys(&state, &view, &.{.up});
    try std.testing.expectEqual(@as(usize, 8), state.global_index);
}

test "Enter: súbor vráti open_file, priečinok zmení adresár" {
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

test "h a potom l vráti kurzor na priečinok, z ktorého sme prišli" {
    var state = try testState("/tmp/sub");
    defer state.deinit(std.testing.allocator);

    _ = try feedKeys(&state, &.{}, &.{.left});
    try std.testing.expectEqualStrings("/tmp", state.current_dir);

    // Nový frame: obsah /tmp, kurzor na "sub"
    const parent = [_]file_entry{ testEntry("a", true, 0), testEntry("b", true, 0), testEntry("sub", true, 0) };
    const view: View = .{ .visible = &parent };
    applyPendingCursor(&state, view.visible);
    try std.testing.expectEqual(@as(usize, 2), state.global_index);

    // l na ten istý priečinok: späť dole a história sa spotrebuje
    _ = try feedKeys(&state, &view, &.{.right});
    try std.testing.expectEqualStrings("/tmp/sub", state.current_dir);
    try std.testing.expectEqual(@as(usize, 0), state.history_forward.items.len);
}

test "príkazy :sS, :q a :<číslo>" {
    var state = try testState("/tmp");
    defer state.deinit(std.testing.allocator);
    var items: [10]file_entry = undefined;
    for (&items) |*item| item.* = testEntry("f", false, 0);
    const view: View = .{ .visible = &items };

    _ = try feedKeys(&state, &view, &.{ .command, .{ .char = 's' }, .{ .char = 'S' }, .{ .char = '\r' } });
    try std.testing.expectEqual(Sorting.by_size_desc, state.current_sorting);
    try std.testing.expectEqual(Mode.normal, state.program_mode);

    // Číslo za koncom zoznamu: posledná položka
    _ = try feedKeys(&state, &view, &.{ .command, .{ .char = '4' }, .{ .char = '2' }, .{ .char = '\r' } });
    try std.testing.expectEqual(@as(usize, 9), state.global_index);

    // Neznámy príkaz nič nespraví
    try std.testing.expectEqual(Action.none, try feedKeys(&state, &view, &.{ .command, .{ .char = 'x' }, .{ .char = '\r' } }));

    try std.testing.expectEqual(Action.quit, try feedKeys(&state, &view, &.{ .command, .{ .char = 'q' }, .{ .char = '\r' } }));
}

test "alias mód skočí sám, keď ostane jediný alias" {
    var state = try testState("/tmp");
    defer state.deinit(std.testing.allocator);
    const aliases = [_]Alias{
        .{ .name = "docs", .path = "/d", .real_path = "/d" },
        .{ .name = "downloads", .path = "/dl", .real_path = "/dl" },
    };
    state.aliases = &aliases;
    state.enterAliasMode();
    const view: View = .{};

    // "do" sedí na oba
    try std.testing.expectEqual(Action.none, try feedKeys(&state, &view, &.{ .{ .char = 'd' }, .{ .char = 'o' } }));
    // "doc" už iba na docs
    const action = try feedKeys(&state, &view, &.{.{ .char = 'c' }});
    try std.testing.expectEqualStrings("docs", action.jump_to_alias.name);
}

test "nápoveda: listovanie, q zatvorí, Ctrl+C ukončí" {
    var state = try testState("/tmp");
    defer state.deinit(std.testing.allocator);
    const view: View = .{ .help_pages = 2 };

    _ = try feedKeys(&state, &view, &.{.help});
    try std.testing.expectEqual(Mode.help, state.program_mode);
    try std.testing.expectEqual(@as(usize, 0), state.help_page);
    // Ľubovoľný kláves = ďalšia strana, na poslednej zatvorí
    _ = try feedKeys(&state, &view, &.{.{ .char = 'x' }});
    try std.testing.expectEqual(@as(usize, 1), state.help_page);
    _ = try feedKeys(&state, &view, &.{.down});
    try std.testing.expectEqual(Mode.normal, state.program_mode);

    // :? otvorí nápovedu znova od prvej strany, q ju hneď zatvorí
    _ = try feedKeys(&state, &view, &.{ .command, .{ .char = '?' }, .{ .char = '\r' } });
    try std.testing.expectEqual(Mode.help, state.program_mode);
    try std.testing.expectEqual(@as(usize, 0), state.help_page);
    _ = try feedKeys(&state, &view, &.{.{ .char = 'q' }});
    try std.testing.expectEqual(Mode.normal, state.program_mode);

    // Ctrl+C v nápovede ukončí program, Ctrl+Z ho uspí
    _ = try feedKeys(&state, &view, &.{.help});
    try std.testing.expectEqual(Action.quit, try feedKeys(&state, &view, &.{.quit}));
    try std.testing.expectEqual(Action.suspend_process, try feedKeys(&state, &view, &.{.ctrl_z}));
}

test ":! vráti shellový príkaz, prázdne :! nič" {
    var state = try state_zig.testState("/tmp");
    defer state.deinit(std.testing.allocator);
    const view: View = .{};

    const action = try feedKeys(&state, &view, &.{ .command, .{ .char = '!' }, .{ .char = 'l' }, .{ .char = 's' }, .{ .char = '\r' } });
    try std.testing.expectEqualStrings("ls", action.run_shell);
    try std.testing.expectEqual(Mode.normal, state.program_mode);

    try std.testing.expectEqual(Action.none, try feedKeys(&state, &view, &.{ .command, .{ .char = '!' }, .{ .char = '\r' } }));
}

test ":! nahradí % menom vybraného súboru" {
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
