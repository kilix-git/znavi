// Key reading: bytes from stdin (including arrow escape sequences) -> Key
const std = @import("std");

pub const Key = union(enum) {
    help,
    up,
    down,
    left,
    right,
    command,
    search,
    alias,
    quit,
    backspace,
    ctrl_d,
    ctrl_u,
    ctrl_z,
    go_top,
    go_bottom,
    char: u8,
};

// typing: in command / search / alias mode we want letters as plain characters, not commands
pub fn readKey(stdin: anytype, typing: bool) !Key {
    const byte = try stdin.takeByte();

    if (byte == 27) { // Start of an escape sequence
        // Arrows arrive all at once (ESC [ A), a lone Esc arrives by itself.
        // Peek into the buffer without blocking.
        const pending = stdin.buffered();
        if (pending.len >= 2 and pending[0] == '[') {
            const code = pending[1];
            stdin.toss(2);
            return switch (code) {
                'A' => .up,
                'B' => .down,
                'C' => .right,
                'D' => .left,
                else => blk: {
                    // Unknown sequence (e.g. Delete = ESC [ 3 ~), discard the rest
                    stdin.toss(stdin.buffered().len);
                    break :blk Key{ .char = 27 };
                },
            };
        }
        return Key{ .char = 27 }; // Lone Esc
    }

    // Ctrl+C quits the program in every mode (ISIG is off, so it arrives as byte 3)
    if (byte == 3) return .quit;
    // Ctrl+Z (byte 26) – suspending is handled by main, also in every mode
    if (byte == 26) return .ctrl_z;

    // While typing a command we want keys like 'q', 'j', 'k' sent as plain characters!
    if (typing) {
        return switch (byte) {
            8, 127 => .backspace, // But Backspace should still delete in the command line
            else => Key{ .char = byte },
        };
    }
    // Map ordinary keys to actions
    return switch (byte) {
        '?' => .help,
        'k' => .up,
        'j' => .down,
        'h' => .left,
        'l' => .right,
        8, 127 => .backspace,
        4 => .ctrl_d,
        21 => .ctrl_u,
        'G' => .go_bottom,
        'g' => { // Start of the gg sequence
            // Try to read the second character right away
            const next = stdin.takeByte() catch return Key{ .char = byte };
            if (next == 'g') {
                return .go_top;
            }
            // If it wasn't 'g', return the character (or implement a switch for other g-commands)
            return Key{ .char = next };
        },
        ':' => .command,
        '/' => .search,
        'a' => .alias,
        'q' => .quit,
        else => Key{ .char = byte },
    };
}
