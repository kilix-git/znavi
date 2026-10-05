// Stav programu (žije medzi frame-ami), dáta pre jeden frame (View) a ich výpočet
const std = @import("std");
const file_entry = @import("FileEntry.zig");
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
    // Po h (alebo l tou istou cestou späť dole): na priečinok, z ktorého sme prišli (história forward)
    from_history,
    // Po triedení / prepnutí skrytých: na tú istú položku (index sa zmení, súbor nie)
    item: file_entry,
};

// Odvodené dáta pre jeden frame. Prepočítajú sa z ProgramState v každom cykle a žijú
// vo frame aréne, preto nie sú v ProgramState (medzi frame-ami by ukazovali do uvoľnenej pamäte)
pub const View = struct {
    // Položky po skrytí skrytých súborov a filtri vyhľadávania; global_index ukazuje sem
    visible: []const file_entry = &.{},
    // Riadky, ktoré sa zmestia na obrazovku, a index prvého z nich vo visible
    window: []const file_entry = &.{},
    window_start: usize = 0,
    // Alias mód: aliasy zodpovedajúce filtru
    alias_matches: []const Alias = &.{},
    // Nápoveda: počet strán pri aktuálnej výške terminálu
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
    current_dir_contents: []file_entry = &.{},
    // Count prefix pre j/k (5j): rozpísané číslo, 0 = žiadny count
    count: usize = 0,
    // Kam dať kurzor v najbližšom frame, keď už poznáme nový zoznam (iba raz, nie každý frame)
    pending_cursor: PendingCursor = .none,
    // cd aliasy zo ~/.aliases (načítané raz pri štarte, žijú v aréne procesu)
    aliases: []const Alias = &.{},
    // Cache uid -> meno a gid -> meno, každé id sa cez libc hľadá iba raz (žije v aréne procesu)
    user_names: std.AutoHashMapUnmanaged(u32, []const u8) = .empty,
    group_names: std.AutoHashMapUnmanaged(u32, []const u8) = .empty,
    // Alias mód (:a): čo píšeme a vybraný riadok (zodpovedajúce aliasy sú vo View)
    alias_buffer: std.ArrayList(u8) = .empty,
    alias_index: usize = 0,
    // Nápoveda (?): strana, ktorú práve ukazujeme (od 0)
    help_page: usize = 0,
    history_forward: std.ArrayList([]const u8),

    // Meno aliasu, ktorý vedie do tohto adresára (prvý nájdený), inak null
    pub fn aliasFor(self: *const ProgramState, file: file_entry) ?[]const u8 {
        if (!file.is_dir or self.aliases.len == 0) return null;
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        // Na "/" už lomka je, inde ju medzi adresár a meno pridáme
        const sep = if (std.mem.endsWith(u8, self.current_dir, "/")) "" else "/";
        const full_path = std.fmt.bufPrint(&path_buf, "{s}{s}{s}", .{ self.current_dir, sep, file.name }) catch return null;
        for (self.aliases) |alias| {
            if (std.mem.eql(u8, alias.real_path, full_path)) return alias.name;
        }
        return null;
    }

    // Prepne do alias módu s prázdnym filtrom (kláves a alebo príkaz :a)
    // Otvorí nápovedu na prvej strane (kláves ? alebo príkaz :?)
    pub fn enterHelp(self: *ProgramState) void {
        self.program_mode = .help;
        self.help_page = 0;
    }

    pub fn enterAliasMode(self: *ProgramState) void {
        self.program_mode = .alias;
        self.alias_buffer.clearRetainingCapacity();
        self.alias_index = 0;
    }

    // Zapamätá si vybranú položku; main ju po prepočítaní zoznamu znova nájde
    pub fn rememberSelected(self: *ProgramState, view: *const View) void {
        self.pending_cursor = if (self.global_index < view.visible.len)
            .{ .item = view.visible[self.global_index] }
        else
            .none;
    }

    // Načíta adresár znova (napr. súbory zmenil iný program), kurzor ostane na položke
    pub fn refresh(self: *ProgramState, view: *const View) void {
        self.rememberSelected(view);
        self.dir_changed = true;
    }

    pub fn resetIndices(self: *ProgramState) void {
        self.global_index = 0;
    }

    pub fn sortContents(self: *ProgramState) void {
        // ".." pridáva getDirContents ako prvú položku – necháme ju na indexe 0 v každom triedení
        var items = self.current_dir_contents;
        if (items.len > 0 and std.mem.eql(u8, items[0].name, "..")) items = items[1..];

        switch (self.current_sorting) {
            .by_name => std.mem.sort(file_entry, items, {}, file_entry.lessThanByName),
            .by_name_dirs_first => std.mem.sort(file_entry, items, {}, file_entry.lessThanByNameDirsFirst),
            .by_date => std.mem.sort(file_entry, items, {}, file_entry.lessThanByDate),
            .by_date_dirs_first => std.mem.sort(file_entry, items, {}, file_entry.lessThanByDateDirsFirst),
            .by_size_asc => std.mem.sort(file_entry, items, {}, file_entry.lessThanBySizeAsc),
            .by_size_desc => std.mem.sort(file_entry, items, {}, file_entry.lessThanBySizeDesc),
        }
    }

    pub fn clearForwardHistory(self: *ProgramState, allocator: std.mem.Allocator) void {
        // Prejdeme všetky uložené stringy a uvoľníme ich z pamäte
        for (self.history_forward.items) |item| {
            allocator.free(item);
        }
        // Teraz môžeme bezpečne vyčistiť samotný zoznam
        self.history_forward.clearRetainingCapacity();
    }

    // Nastaví nový current_dir (vlastníctvo prechádza na state) a uvoľní starý
    pub fn setCurrentDir(self: *ProgramState, allocator: std.mem.Allocator, new_dir: []const u8) void {
        allocator.free(self.current_dir);
        self.current_dir = new_dir;
    }

    // Uvoľní všetku pamäť, ktorú state vlastní (current_dir, buffre, históriu)
    pub fn deinit(self: *ProgramState, allocator: std.mem.Allocator) void {
        allocator.free(self.current_dir);
        self.command_buffer.deinit(allocator);
        self.search_buffer.deinit(allocator);
        self.alias_buffer.deinit(allocator);
        for (self.history_forward.items) |item| allocator.free(item);
        self.history_forward.deinit(allocator);
    }
};

// Čo má main spraviť po spracovaní klávesu – handlery samy nič nespúšťajú ani nekreslia
pub const Action = union(enum) {
    none,
    quit,
    suspend_process,
    open_file: file_entry,
    jump_to_alias: Alias,
    // :!príkaz – text za výkričníkom (ukazuje do command_buffer, main ho spustí hneď)
    run_shell: []const u8,
};

// Uloží kópiu cesty do histórie; ak append zlyhá, kópiu uvoľníme, aby neunikla
pub fn pushHistory(list: *std.ArrayList([]const u8), allocator: std.mem.Allocator, path: []const u8) !void {
    const copy = try allocator.dupe(u8, path);
    errdefer allocator.free(copy);
    try list.append(allocator, copy);
}

// Položky, ktoré používateľ vidí: bez skrytých (ak ich nezobrazujeme) a podľa vyhľadávania
pub fn getVisibleItems(allocator: std.mem.Allocator, state: *const ProgramState) ![]const file_entry {
    var items: []const file_entry = state.current_dir_contents;
    if (!state.viewing.hidden) items = try getOnlyVisibleItems(allocator, items);
    if (state.search_buffer.items.len > 0) items = try getFilteredItemsByName(allocator, items, state.search_buffer.items);
    return items;
}

fn getOnlyVisibleItems(allocator: std.mem.Allocator, items: []const file_entry) ![]const file_entry {
    // Jednoduchý filter na viditeľné veci
    var result: std.ArrayList(file_entry) = .empty;
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
    items: []const file_entry,
    search_str: []const u8,
) ![]const file_entry {
    var result: std.ArrayList(file_entry) = .empty;
    errdefer result.deinit(allocator);
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;

    for (items) |item| {
        // Spojíme meno a príponu, aby vyhľadávanie videlo celé meno súboru
        const full_name = std.fmt.bufPrint(&name_buf, "{s}{s}", .{ item.name, item.extension }) catch item.name;
        if (std.ascii.indexOfIgnoreCase(full_name, search_str) != null) {
            try result.append(allocator, item);
        }
    }
    return result.toOwnedSlice(allocator);
}

// Okno riadkov na obrazovke: kurzor držíme v strede, pri okrajoch zoznamu sa okno zastaví
pub fn setWindow(view: *View, terminal_size: Terminal.Size, global_index: usize) void {
    const total_rows_available = terminal_size.rows -| TERMINAL_PADDING;
    const half_window = total_rows_available / 2;
    var start_index: usize = global_index -| half_window;

    // Korekcia konca okna voči celkovému počtu viditeľných položiek
    var end_index = start_index + total_rows_available;
    if (end_index > view.visible.len) {
        end_index = view.visible.len;
        start_index = end_index -| total_rows_available;
    }
    view.window_start = start_index;
    view.window = view.visible[start_index..end_index];
}

// Kurzor na miesto zapamätané v predchádzajúcom kroku (pending_cursor), keď už poznáme nový zoznam
pub fn applyPendingCursor(state: *ProgramState, visible: []const file_entry) void {
    const pending = state.pending_cursor;
    state.pending_cursor = .none;
    switch (pending) {
        .none => {},
        // G, gg, Ctrl+d či :<n> potom kurzor normálne presunú, lebo toto beží iba raz
        .from_history => {
            const prev = state.history_forward.getLastOrNull() orelse return;
            for (visible, 0..) |item, idx| {
                if (item.is_dir and std.mem.eql(u8, item.name, prev)) {
                    state.global_index = idx;
                    return;
                }
            }
        },
        // Meno + prípona (foo.c vs foo.h). Ak tam už nie je (napr. sme ju práve skryli),
        // ostaneme na rovnakom riadku v rámci zoznamu
        .item => |target| {
            state.global_index = @min(state.global_index, visible.len -| 1);
            for (visible, 0..) |item, idx| {
                if (std.mem.eql(u8, item.name, target.name) and std.mem.eql(u8, item.extension, target.extension)) {
                    state.global_index = idx;
                    return;
                }
            }
        },
    }
}

// ===================== Testy =====================

// Pomocné funkcie pre testy (používajú ich aj handlers.zig a render.zig)

// Stav s vlastnou kópiou cesty (deinit ju uvoľní)
pub fn testState(dir: []const u8) !ProgramState {
    return .{
        .current_dir = try std.testing.allocator.dupe(u8, dir),
        .command_buffer = .empty,
        .search_buffer = .empty,
        .history_forward = .empty,
    };
}

pub fn testEntry(name: []const u8, is_dir: bool, size: usize) file_entry {
    return .{ .name = name, .extension = "", .is_dir = is_dir, .size = size, .permissions = @enumFromInt(0o644) };
}

test "setWindow drží kurzor v strede a zastaví sa na okrajoch" {
    var items: [100]file_entry = undefined;
    for (&items) |*item| item.* = testEntry("f", false, 0);
    const size: Terminal.Size = .{ .rows = 24, .cols = 80 }; // 20 riadkov na zoznam

    var view: View = .{ .visible = &items };
    setWindow(&view, size, 50);
    try std.testing.expectEqual(@as(usize, 40), view.window_start);
    try std.testing.expectEqual(@as(usize, 20), view.window.len);

    setWindow(&view, size, 98);
    try std.testing.expectEqual(@as(usize, 80), view.window_start);
    try std.testing.expectEqual(@as(usize, 20), view.window.len);

    // Krátky zoznam: celý na obrazovke
    view = .{ .visible = items[0..5] };
    setWindow(&view, size, 3);
    try std.testing.expectEqual(@as(usize, 0), view.window_start);
    try std.testing.expectEqual(@as(usize, 5), view.window.len);
}
