// Príkazy pre command mód (:vd, :sn, ...)
const std = @import("std");
const state_zig = @import("state.zig");
const ProgramState = state_zig.ProgramState;
const View = state_zig.View;
const Action = state_zig.Action;
const Sorting = state_zig.Sorting;

// Príkazy pre command mód (:vd, :sn, ...). Z tej istej tabuľky sa generuje aj nápoveda,
// takže nový príkaz stačí pridať sem a v nápovede sa objaví sám
pub const Command = struct {
    name: []const u8,
    help: []const u8,
    run: *const fn (*ProgramState, *const View) Action,
};

pub const commands = [_]Command{
    .{ .name = "q", .help = "Quit program", .run = quit },
    .{ .name = "r", .help = "Refresh directory contents", .run = refresh },
    .{ .name = "h", .help = "Toggle hidden files", .run = toggleHidden },
    .{ .name = "vd", .help = "Toggle date visibility", .run = toggleView("date") },
    .{ .name = "vs", .help = "Toggle size visibility", .run = toggleView("size") },
    .{ .name = "va", .help = "Toggle alias visibility (next to directories)", .run = toggleView("aliases") },
    .{ .name = "vp", .help = "Toggle permissions visibility", .run = toggleView("permissions") },
    .{ .name = "vo", .help = "Toggle owner visibility", .run = toggleOwner },
    .{ .name = "vg", .help = "Toggle group visibility", .run = toggleGroup },
    .{ .name = "sn", .help = "Sort by name", .run = sortBy(.by_name) },
    .{ .name = "sN", .help = "Sort by name, dirs first", .run = sortBy(.by_name_dirs_first) },
    .{ .name = "sd", .help = "Sort by date", .run = sortBy(.by_date) },
    .{ .name = "sD", .help = "Sort by date, dirs first", .run = sortBy(.by_date_dirs_first) },
    .{ .name = "ss", .help = "Sort by size, smallest first", .run = sortBy(.by_size_asc) },
    .{ .name = "sS", .help = "Sort by size, largest first", .run = sortBy(.by_size_desc) },
    .{ .name = "cw", .help = "Batch rename visible files in $EDITOR", .run = bulkRename },
    .{ .name = "a", .help = "Aliases: type to filter (1 match = go), Enter = go", .run = enterAliases },
    .{ .name = "?", .help = "Show this help screen", .run = showHelp },
};

fn quit(_: *ProgramState, _: *const View) Action {
    return .quit;
}

fn refresh(state: *ProgramState, view: *const View) Action {
    state.refresh(view);
    return .none;
}

fn bulkRename(_: *ProgramState, _: *const View) Action {
    return .bulk_rename;
}

fn showHelp(state: *ProgramState, _: *const View) Action {
    state.enterHelp();
    return .none;
}

fn enterAliases(state: *ProgramState, _: *const View) Action {
    state.enterAliasMode();
    return .none;
}

fn toggleHidden(state: *ProgramState, view: *const View) Action {
    state.rememberSelected(view);
    state.viewing.hidden = !state.viewing.hidden;
    return .none;
}

// Prvý zapnutý z :vo/:vg – uid/gid ešte nemáme načítané, načítame adresár znova
fn toggleOwner(state: *ProgramState, _: *const View) Action {
    state.viewing.owner = !state.viewing.owner;
    if (state.viewing.owner and !state.viewing.group) state.dir_changed = true;
    return .none;
}

fn toggleGroup(state: *ProgramState, _: *const View) Action {
    state.viewing.group = !state.viewing.group;
    if (state.viewing.group and !state.viewing.owner) state.dir_changed = true;
    return .none;
}

// Prepne jeden stĺpec vo Viewing podľa mena poľa (vygeneruje sa funkcia pre každé pole zvlášť)
fn toggleView(comptime field: []const u8) *const fn (*ProgramState, *const View) Action {
    return struct {
        fn run(state: *ProgramState, _: *const View) Action {
            @field(state.viewing, field) = !@field(state.viewing, field);
            return .none;
        }
    }.run;
}

fn sortBy(comptime sorting: Sorting) *const fn (*ProgramState, *const View) Action {
    return struct {
        fn run(state: *ProgramState, view: *const View) Action {
            state.current_sorting = sorting;
            state.rememberSelected(view);
            state.sortContents();
            return .none;
        }
    }.run;
}
