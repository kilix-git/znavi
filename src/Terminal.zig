//toto mi dal gemini, nastavi to terminal do RAW modu, trocha sa to prerobilo s metodami enterRaw a leaveRaw
const std = @import("std");
const posix = std.posix;
const Terminal = @This();

original_termios: posix.termios,
raw_termios: posix.termios,
stdout_writer: *std.Io.File.Writer,

// Inicializácia: zapamätá si pôvodný stav terminálu a prepne do RAW módu
pub fn init(stdout_writer: *std.Io.File.Writer) !Terminal {
    // 1. Načítanie a úprava vlastností terminálu
    const original = try posix.tcgetattr(posix.STDIN_FILENO);
    var raw = original;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    // Ctrl+C/Ctrl+Z nesmú poslať signál (preskočil by sa deinit), Ctrl+S/Ctrl+Q nesmú zastaviť výstup
    raw.lflag.ISIG = false;
    raw.iflag.IXON = false;

    const self = Terminal{ .original_termios = original, .raw_termios = raw, .stdout_writer = stdout_writer };
    try self.enterRaw();
    return self;
}

// RAW mód, alternatívna obrazovka (scrollback shellu zostane nedotknutý) a skrytý kurzor
pub fn enterRaw(self: Terminal) !void {
    try posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, self.raw_termios);
    try self.stdout_writer.interface.writeAll("\x1B[?1049h\x1B[?25l");
    try self.stdout_writer.flush();
}

// Opak enterRaw: zobrazí kurzor, vráti pôvodnú obrazovku a pôvodný režim termios
pub fn leaveRaw(self: Terminal) void {
    self.stdout_writer.interface.writeAll("\x1B[?25h\x1B[?1049l") catch {};
    self.stdout_writer.flush() catch {};
    posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, self.original_termios) catch {};
}

// Deinicializácia: volá sa cez defer v main
pub fn deinit(self: Terminal) void {
    self.leaveRaw();
}

pub const Size = struct {
    rows: u16,
    cols: u16,
};

pub fn getSize() Size {
    // Vytvoríme štruktúru winsize podľa POSIX štandardu
    var winsize = std.posix.winsize{
        .row = 0,
        .col = 0,
        .xpixel = 0,
        .ypixel = 0,
    };
    // STDOUT_FILENO je štandardný deskriptor pre výstup (1)
    const fd = std.posix.STDOUT_FILENO;
    // Zavoláme ioctl systémové volanie pre získanie veľkosti okna (TIOCGWINSZ)
    const err = std.posix.system.ioctl(fd, std.posix.T.IOCGWINSZ, @intFromPtr(&winsize));
    // Ak systémové volanie prebehlo úspešne, vrátime zistené hodnoty
    if (std.posix.errno(err) == .SUCCESS) {
        return .{
            .rows = if (winsize.row == 0) 24 else winsize.row,
            .cols = if (winsize.col == 0) 80 else winsize.col,
        };
    }
    // Bezpečný fallback v prípade chyby (napr. beh v neštandardnom IDE bufferi)
    return .{ .rows = 24, .cols = 80 };
}
