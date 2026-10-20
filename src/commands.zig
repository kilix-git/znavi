// command mode commands (like: :vd, :sn, ...)
const std = @import("std");
const ProgramState = @import("state.zig").ProgramState;
const View = @import("state.zig").View;
const Action = @import("state.zig").Action;
const Sorting = @import("state.zig").Sorting;

// commands for command mode (:vd, :sn, ...). the same table is used to generate :h or --help text,
// so it's sufficient to add new commands here and it will appear in --help automagically
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
    .{ .name = "ve", .help = "Toggle file extension visibility", .run = toggleView("extension") },
    .{ .name = "sn", .help = "Sort by name", .run = sortBy(.by_name) },
    .{ .name = "sN", .help = "Sort by name, dirs first", .run = sortBy(.by_name_dirs_first) },
    .{ .name = "sd", .help = "Sort by date", .run = sortBy(.by_date) },
    .{ .name = "sD", .help = "Sort by date, dirs first", .run = sortBy(.by_date_dirs_first) },
    .{ .name = "ss", .help = "Sort by size, smallest first", .run = sortBy(.by_size_asc) },
    .{ .name = "sS", .help = "Sort by size, largest first", .run = sortBy(.by_size_desc) },
    .{ .name = "se", .help = "Sort by extension, A to Z", .run = sortBy(.by_ext_asc) },
    .{ .name = "sE", .help = "Sort by extension, Z to A", .run = sortBy(.by_ext_desc) },
    .{ .name = "cw", .help = "Batch rename visible files in $EDITOR", .run = bulkRename },
    .{ .name = "sh", .help = "Open $SHELL here, exit it to return", .run = interactiveShell },
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

fn interactiveShell(_: *ProgramState, _: *const View) Action {
    return .interactive_shell;
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

// if we changed :vo or :vg, we need to re-read the contents
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
