# znavi

A small, fast and not very feature-rich (by design!) vim-style terminal file navigator written in Zig.

Navigate your files almost like in vim's own netrw.
Move with `hjkl`, you can add a multiplier as well: `10j`, `5k` works as expected.
Enter a directory or open a file with `enter` or `l`.
Go up a level with `h`.
Filter files in search mode with `/`.
Enter command mode with `:` and you can use `:<number>` to fast jump to a file, do `:sS` to sort files by size, `:vp` is used to view permissions and more (see below).

The program is able to use your ~/.aliases file, it parses any alias that does some kind of `cd` operation and those aliases appear in alias mode, which you can enter by pressing `:a` or just `a` in normal mode.
I know using ~/.aliases is not an industry standard, people have aliases in ~/.profile, or maybe somewhere else, but that's what I do and works for me. The source is easy enough to change it if needed.
The program is able to cd into the directory in which you exited the program, by using a simple shell function with a properly set ZNAVI\_LASTDIR environment variable (see example below).
You can also start the program with an argument - a directory in which you wish to start.

## Building

Requires Zig 0.16.

```sh
zig build             # binary ends up in zig-out/bin/znavi
zig build test        # run the tests
```

Developed and used on FreeBSD; it should work on Linux and other Unix-like systems too.

## Usage

```sh
znavi           # start in the current directory
znavi ~/docs    # start in another directory
```

Press `?` in normal mode or `:?` in command mode inside znavi for the full list of keys and commands.

### Normal mode

| Key                | Action                                      |
|--------------------|---------------------------------------------|
| `j` / `k`, arrows  | Move down / up (`5j` = 5 rows)              |
| `l`, Right, Enter  | Enter directory / open file                 |
| `h`, Left          | Go to parent directory                      |
| `Ctrl+d` / `Ctrl+u`| Jump 20 items down / up                     |
| `gg` / `G`         | Jump to top / bottom                        |
| `/`                | Search (Enter keeps the filter, Esc clears) |
| Backspace, `Ctrl+h`| Toggle hidden files                         |
| `a`                | Alias mode                                  |
| `r`                | Refresh directory contents                  |
| `:`                | Command mode                                |
| `?`                | Help                                        |
| `q`, `Ctrl+c`      | Quit                                        |
| `Ctrl+z`           | Suspend (resume with `fg`)                  |

### Command mode

| Command     | Action                                         |
|-------------|------------------------------------------------|
| `:q`        | Quit                                           |
| `:r`        | Refresh directory contents                     |
| `:h`        | Toggle hidden files                            |
| `:vd` `:vs` `:vp` `:vo` `:vg` `:va` | Toggle date, size, permissions, owner, group, alias columns |
| `:sn` / `:sN` | Sort by name / name with directories first   |
| `:sd` / `:sD` | Sort by date / date with directories first   |
| `:ss` / `:sS` | Sort by size, smallest / largest first       |
| `:a`        | Aliases                                        |
| `:<number>` | Jump to that index                             |
| `:!<cmd>`   | Run a shell command in the current directory (`%` = selected file, `\%` = literal `%`) |
| `:?`        | Help                                           |

## Opening files

Text files (no NUL byte in the first 8 KB) open in `$VISUAL`, then `$EDITOR`,
then `vi`, in the same terminal. Everything else goes to `xdg-open`. Only
regular files are opened, so a symlink pointing to a FIFO or device is refused
instead of hanging. If the program fails (for example, the editor isn't
installed), znavi shows its error and waits for ENTER.

## Aliases

znavi reads `~/.aliases` and parses aliases that only change directory:

```sh
alias dl="cd ~/Downloads"
alias logs='cd /var/log'
```

Press `a` in normal mode, you'll pop into alias mode, which is a new clean standalone screen and you immediately filter available items by typing.
In this mode, you can move with arrows and use ENTER to cd into the aliased directory.
If you keep typing so that only one item remains, it automatically jumps there.
Relative paths and aliases present in ~/.aliases that do something other than `cd` are skipped.

## cd on exit

If `ZNAVI_LASTDIR` is set, znavi writes its last directory when you quit. A small shell function can then be used to `cd` into it.

fish (`~/.config/fish/functions/zn.fish`):

```fish
function zn
    set -l tmp (mktemp)
    ZNAVI_LASTDIR=$tmp znavi $argv
    if test -s $tmp
        cd (cat $tmp)
    end
    rm -f $tmp
end
```

sh / bash / zsh:

```sh
zn() {
    tmp=$(mktemp)
    ZNAVI_LASTDIR=$tmp znavi "$@"
    [ -s "$tmp" ] && cd "$(cat "$tmp")"
    rm -f "$tmp"
}
```
## comment on development process 
I am by no means a programmer. I did study computer science about 20 years ago and haven't touched programming since. I was able to start this project at first by writing by hand, then with help from free gemini and then I paid for claude code, which did all the more advanced features and refactored the code and split it into multiple files and wrote tests. The overall architecture and use of structs and program states may be weird, doing it all in a while(true) loop may be weird as well, I don't know. Suggestions are ofc welcome, but I may be hesitant to add features.
I may add more features as I use the program and find something lacking, I don't know, you are free to use it however you desire.
