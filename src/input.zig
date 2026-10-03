// Čítanie klávesov: bajty zo stdin (vrátane escape sekvencií šípok) -> Key
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

// typing: v command / search / alias móde chceme písmená ako čisté znaky, nie príkazy
pub fn readKey(stdin: anytype, typing: bool) !Key {
    const byte = try stdin.takeByte();

    if (byte == 27) { // Začiatok escape sekvencie
        // Šípky prídu naraz (ESC [ A), samotný Esc príde sám.
        // Pozrieme sa do buffera bez blokovania.
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
                    // Neznáma sekvencia (napr. Delete = ESC [ 3 ~), zahodíme zvyšok
                    stdin.toss(stdin.buffered().len);
                    break :blk Key{ .char = 27 };
                },
            };
        }
        return Key{ .char = 27 }; // Samostatný Esc
    }

    // Ctrl+C ukončí program v každom režime (ISIG je vypnutý, takže príde ako bajt 3)
    if (byte == 3) return .quit;
    // Ctrl+Z (bajt 26) – suspend rieši main, tiež v každom režime
    if (byte == 26) return .ctrl_z;

    // Ak píšeme príkaz, chceme klávesy ako 'q', 'j', 'k' posielať ako čisté znaky!
    if (typing) {
        return switch (byte) {
            8, 127 => .backspace, // Backspace ale chceme mazať aj v príkazovom riadku
            else => Key{ .char = byte },
        };
    }
    // Mapovanie bežných kláves na akcie
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
        'g' => { // Začiatok sekvencie gg
            // Pokúsime sa okamžite prečítať druhý znak
            const next = stdin.takeByte() catch return Key{ .char = byte };
            if (next == 'g') {
                return .go_top;
            }
            // Ak to nebolo 'g', vrátime pôvodný znak (alebo implementuj switch na iné g-príkazy)
            return Key{ .char = next };
        },
        ':' => .command,
        '/' => .search,
        'a' => .alias,
        'q' => .quit,
        else => Key{ .char = byte },
    };
}
