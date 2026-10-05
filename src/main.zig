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
const handleKey = handlers.handleKey;
const state_zig = @import("state.zig");
const ProgramState = state_zig.ProgramState;
const View = state_zig.View;

pub fn main(init: std.process.Init) !void {
    const io = init.io; //vezmeme si interface io programu
    // gpa pre current_dir, históriu a buffre – tie uvoľňujeme ručne cez free/deinit
    const gpa = init.gpa;

    // arena s dlhsou zivotnostou (Vyčistí sa IBA pri zmene adresára alebo refreshu)
    var dir_contents_arena = std.heap.ArenaAllocator.init(init.gpa);
    defer dir_contents_arena.deinit();

    // arena pre dočasné stringy v rámci jedného while loopu, /napr. xdg-open cesty)
    var one_cycle_arena = std.heap.ArenaAllocator.init(init.gpa);
    defer one_cycle_arena.deinit();

    // Štartovací adresár ešte pred RAW módom, aby chybová hláška išla normálne do shellu
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const start_arg: ?[]const u8 = if (argv.len > 1) argv[1] else null;
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const start_dir = fs.getStartingDir(io, start_arg, &buffer) catch |err| {
        std.debug.print("znavi: {s}: {s}\n", .{ start_arg orelse ".", @errorName(err) });
        std.process.exit(1);
    };

    // nastavenie STDOUT pre pisanie vystupu
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.Writer.init(std.Io.File.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    // nastavenie STDIN pre citanie vstupu
    var stdin_buffer: [16]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(init.io, &stdin_buffer);
    const stdin = &stdin_reader.interface;

    // inicializujeme terminal a odovzdame mu writer aj reader
    const terminal = try Terminal.init(&stdout_writer);
    // pri odchode z main sa vsetko vrati do povodneho stavu uvolnime pamat
    defer terminal.deinit();
    // inicializacia velkosti terminalu, default UNIX terminal je 24x80
    var terminal_size: Terminal.Size = .{ .rows = 24, .cols = 80 };
    // default sorting by name dirs first
    var state = ProgramState{
        // skopírujeme z buffera na stacku do gpa, aby sa current_dir dal neskôr uvoľniť
        .current_dir = try gpa.dupe(u8, start_dir),
        .command_buffer = .empty,
        .search_buffer = .empty,
        .history_forward = .empty,
    };
    defer state.deinit(gpa);

    // cd aliasy zo ~/.aliases; ak súbor nejde prečítať, pokračujeme bez aliasov
    if (init.environ_map.get("HOME")) |home| {
        state.aliases = cd_aliases.loadAliases(io, init.arena.allocator(), home) catch &.{};
    }

    var active_error: ?anyerror = null;

    while (true) {
        const frame_allocator = one_cycle_arena.allocator();
        defer _ = one_cycle_arena.reset(.free_all);
        terminal_size = Terminal.getSize();

        if (state.dir_changed) {
            // Zapamätaná položka (refresh, :!) ukazuje do dir_contents_arena, ktorú ideme
            // uvoľniť – meno skopírujeme do frame arény, inak by sme porovnávali uvoľnenú pamäť
            switch (state.pending_cursor) {
                .item => |*target| {
                    target.name = try frame_allocator.dupe(u8, target.name);
                    target.extension = try frame_allocator.dupe(u8, target.extension);
                },
                else => {},
            }
            // Pred načítaním nového obsahu kompletne vyčistíme starý zoznam a názvy súborov
            _ = dir_contents_arena.reset(.free_all);
            const dir_allocator = dir_contents_arena.allocator();
            // current_dir_contents naplnime novymi polozkami
            var skipped_error: ?anyerror = null;
            if (fs.getDirContents(io, dir_allocator, state.current_dir, &skipped_error, state.viewing.owner or state.viewing.group)) |contents| {
                // uid/gid -> mená (z cache, nové id hľadáme v libc iba raz)
                for (contents) |*entry| {
                    entry.owner_name = try fs.lookupName(.user, &state.user_names, init.arena.allocator(), entry.owner);
                    entry.group_name = try fs.lookupName(.group, &state.group_names, init.arena.allocator(), entry.group);
                }
                state.current_dir_contents = contents;
                state.sortContents();
                state.dir_changed = false;
                // null ak je všetko v poriadku, inak chyba položky, ktorú sme museli preskočiť
                active_error = skipped_error;
            } else |err| {
                active_error = err; // Chybu si zapamätáme len na jedno vykreslenie
                state.dir_changed = false;

                // Záchranný krok pre stav - napr. prázdny adresár, aby aplikácia nezamrzla
                state.current_dir_contents = &.{};
            }
        }

        // Dáta pre tento frame; žijú iba do konca cyklu (frame aréna)
        var view: View = .{ .visible = try state_zig.getVisibleItems(frame_allocator, &state) };
        state_zig.applyPendingCursor(&state, view.visible);
        state_zig.setWindow(&view, terminal_size, state.global_index);

        var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
        const display_path = try render.shortenPath(state.current_dir, terminal_size.cols, &dir_buf);

        if (state.program_mode == .help) {
            // Počet strán závisí od výšky terminálu; po zmenšení okna ostaneme na poslednej
            view.help_pages = render.helpPageCount(terminal_size.rows);
            state.help_page = @min(state.help_page, view.help_pages - 1);
            try render.drawHelpScreen(stdout, state.help_page, terminal_size.rows);
        } else if (state.program_mode == .alias) {
            // Alias mód má vlastnú obrazovku iba so zoznamom aliasov
            view.alias_matches = try cd_aliases.getFilteredAliases(frame_allocator, state.aliases, state.alias_buffer.items);
            state.alias_index = @min(state.alias_index, view.alias_matches.len -| 1);
            try render.drawAliasScreen(stdout, &state, &view, active_error, terminal_size);
        } else {
            try render.drawScreen(stdout, display_path, &state, &view, active_error, terminal_size.cols);
        }
        try stdout_writer.flush();

        const key: Key = try input.readKey(stdin, state.program_mode != .normal);
        // Chyba sa zobrazí do najbližšieho stlačenia klávesu, potom zas uvidíme : alebo / riadok
        active_error = null;

        // Handler iba zmení stav a povie, čo treba spraviť; vedľajšie efekty sú všetky tu
        const action = handleKey(key, &state, &view, gpa) catch |err| {
            active_error = err;
            continue;
        };
        switch (action) {
            .none => {},
            .quit => break,
            // Vrátime terminál do normálu, zastavíme sa (fg nás prebudí) a znova prejdeme do RAW
            .suspend_process => {
                terminal.leaveRaw();
                try posix.raise(.TSTP);
                try terminal.enterRaw();
            },
            .open_file => |item| openFile(io, terminal, stdout, stdin, frame_allocator, &state, item) catch |err| {
                active_error = err;
            },
            // Napr. alias na neexistujúci adresár – chybu ukážeme, ostaneme v alias móde
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
                runShell(io, terminal, stdout, stdin, shell, state.current_dir, expanded) catch |err| {
                    active_error = err;
                };
                // Príkaz mohol súbory vytvoriť, zmazať či premenovať – načítame adresár znova
                state.rememberSelected(&view);
                state.dir_changed = true;
            },
        }
    }

    // cd-on-exit: ak je nastavená ZNAVI_LASTDIR, zapíšeme do toho súboru posledný adresár,
    // aby shellová funkcia vedela po skončení spraviť cd
    if (init.environ_map.get("ZNAVI_LASTDIR")) |lastdir_path| {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = lastdir_path, .data = state.current_dir });
    }
}

// Otvorenie súboru: text v $VISUAL/$EDITOR, ostatné cez xdg-open (odpojené)
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

    // statFile ide cez symlink na cieľ. Otvárame len bežné súbory – na FIFO by sa zasekol
    // už samotný open (sniff textu aj xdg-open) a znavi by sa nedalo ani ukončiť
    const stat = try std.Io.Dir.cwd().statFile(io, full_path, .{});
    if (stat.kind != .file) return error.NotARegularFile;

    if (!fs.isTextFile(io, full_path)) return openDetached(io, state.current_dir, full_path);

    // Text otvoríme v editore v tomto termináli.
    // Cesta ide ako $1, takže ju netreba escapovať; $VISUAL/$EDITOR môžu mať aj argumenty.
    const argv: []const []const u8 = &.{ "/bin/sh", "-c", "exec ${VISUAL:-${EDITOR:-vi}} \"$1\"", "znavi", full_path };

    // Terminálový editor (vim, less...) musí dostať normálny terminál, nie náš RAW mód
    terminal.leaveRaw();
    errdefer terminal.enterRaw() catch {};
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = state.current_dir }, // vim :! a relatívne cesty majú platiť tu
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(io);
    // Napr. editor neexistuje (127). Pred návratom na našu obrazovku počkáme na Enter,
    // inak by hláška programu hneď zmizla
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

// GUI program spustíme mimo nášho terminálu: nová session bez riadiaceho terminálu,
// stdio na /dev/null. Ctrl+Z/Ctrl+C v znavi ho nezasiahne a znavi nečaká na jeho zatvorenie.
// Linux: setsid(1) z util-linux, FreeBSD: daemon(8) zo základného systému. setsid skúšame
// prvý, lebo na Linuxe môže byť nainštalovaný iný `daemon`, kde -f znamená foreground.
// Chybu samotného xdg-open (napr. nenašiel aplikáciu) po odpojení už nevidíme; overíme
// aspoň, že existuje.
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
    // setsid/daemon sa po odpojení hneď ukončí; počkáme naň, aby nezostal zombie
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

// :!príkaz – spustí ho cez shell v aktuálnom adresári na normálnom termináli (ako vim),
// potom počká na Enter, aby bolo vidno výstup
fn runShell(
    io: std.Io,
    terminal: Terminal,
    stdout: *std.Io.Writer,
    stdin: *std.Io.Reader,
    shell: []const u8,
    cwd: []const u8,
    command: []const u8,
) !void {
    terminal.leaveRaw();
    defer terminal.enterRaw() catch {};

    var child = try std.process.spawn(io, .{
        .argv = &.{ shell, "-c", command },
        .cwd = .{ .path = cwd },
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(io);

    switch (term) {
        .exited => |code| if (code != 0) try stdout.print("\nshell returned {d}", .{code}),
        else => try stdout.print("\nshell terminated: {t}", .{term}),
    }
    try waitForEnter(stdout, stdin);
}

// Volať mimo RAW módu
fn waitForEnter(stdout: *std.Io.Writer, stdin: *std.Io.Reader) !void {
    try stdout.writeAll("\nPress Enter to continue");
    try stdout.flush();
    // Terminál je v normálnom (riadkovom) móde, takže prvý bajt príde až po Enter;
    // zvyšok riadku zahodíme (enterRaw s .FLUSH zahodí aj to, čo ešte nebolo prečítané)
    _ = stdin.takeByte() catch {};
    stdin.toss(stdin.buffered().len);
}

// Prejde do adresára aliasu a vráti sa do normal módu
fn jumpToAlias(alias: Alias, state: *ProgramState, gpa: std.mem.Allocator, io: std.Io) !void {
    // Skutočná cesta: /home/... -> /usr/home/..., bez lomky na konci
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try std.Io.Dir.realPathFileAbsolute(io, alias.path, &path_buf);
    state.setCurrentDir(gpa, try gpa.dupe(u8, path_buf[0..path_len]));

    // Skok inam – stará cesta vpred ani vyhľadávanie už neplatia
    state.clearForwardHistory(gpa);
    state.search_buffer.clearRetainingCapacity();
    state.resetIndices();
    state.dir_changed = true;
    state.program_mode = .normal;
}

// ===================== Testy (zig build test) =====================

// Testy z FileEntry.zig (triedenie, formátovanie) sa spustia spolu s týmito
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
}
