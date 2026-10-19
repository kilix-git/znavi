// Originally from Gemini: puts the terminal into RAW mode; since reworked a bit with the enterRaw and leaveRaw methods
const std = @import("std");
const posix = std.posix;
const Terminal = @This();

original_termios: posix.termios,
raw_termios: posix.termios,
stdout_writer: *std.Io.File.Writer,

// Initialization: remembers the original terminal state and switches to RAW mode
pub fn init(stdout_writer: *std.Io.File.Writer) !Terminal {
    // 1. Read and adjust the terminal attributes
    const original = try posix.tcgetattr(posix.STDIN_FILENO);
    var raw = original;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    // Ctrl+C/Ctrl+Z must not send a signal (deinit would be skipped), Ctrl+S/Ctrl+Q must not stop the output
    raw.lflag.ISIG = false;
    raw.iflag.IXON = false;

    const self = Terminal{ .original_termios = original, .raw_termios = raw, .stdout_writer = stdout_writer };
    try self.enterRaw();
    return self;
}

// RAW mode, alternate screen (the shell's scrollback stays untouched) and a hidden cursor
pub fn enterRaw(self: Terminal) !void {
    try posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, self.raw_termios);
    try self.stdout_writer.interface.writeAll("\x1B[?1049h\x1B[?25l");
    try self.stdout_writer.flush();
}

// The opposite of enterRaw: shows the cursor, restores the original screen and the original termios mode
pub fn leaveRaw(self: Terminal) void {
    self.stdout_writer.interface.writeAll("\x1B[?25h\x1B[?1049l") catch {};
    self.stdout_writer.flush() catch {};
    posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, self.original_termios) catch {};
}

// Deinitialization: called via defer in main
pub fn deinit(self: Terminal) void {
    self.leaveRaw();
}

pub const Size = struct {
    rows: u16,
    cols: u16,
};

pub fn getSize() Size {
    // Create a winsize struct as defined by POSIX
    var winsize = std.posix.winsize{
        .row = 0,
        .col = 0,
        .xpixel = 0,
        .ypixel = 0,
    };
    // STDOUT_FILENO is the standard output descriptor (1)
    const fd = std.posix.STDOUT_FILENO;
    // Call the ioctl syscall to get the window size (TIOCGWINSZ)
    const err = std.posix.system.ioctl(fd, std.posix.T.IOCGWINSZ, @intFromPtr(&winsize));
    // If the syscall succeeded, return the values it found
    if (std.posix.errno(err) == .SUCCESS) {
        return .{
            .rows = if (winsize.row == 0) 24 else winsize.row,
            .cols = if (winsize.col == 0) 80 else winsize.col,
        };
    }
    // Safe fallback on error (e.g. running in a non-standard IDE buffer)
    return .{ .rows = 24, .cols = 80 };
}
