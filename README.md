# Palette

Fig-style autocomplete for zsh on macOS. A native dropdown appears at your
cursor as you type, with fuzzy matching, descriptions and icons. It works in
Ghostty and Rex.

Palette doesn't ship completion specs. It asks **zsh's own completion
system** for candidates, so everything your shell can complete is available:
git subcommands, branches and options, paths, `brew`, `docker`, `ssh` hosts,
processes and every `_command` function on your `fpath`. Palette ranks the
results, learns what you pick and shows them.

## Install

Download `Palette-x.y.z.zip` from the latest release, or build it:

```sh
make install
```

This builds `Palette.app`, signs it with your Developer ID (or Apple
Development) identity, copies it to `/Applications` and opens it. On first
launch:

1. **Grant Accessibility access** when macOS asks. Palette uses it only to
   read the frame of the focused terminal pane. A stable signing identity
   keeps the grant across rebuilds.
2. **Install shell integration** when Palette offers it. This adds one
   `source` line at the end of `~/.zshrc`. The menu-bar item has the same
   option and can copy the line instead.

Open a new terminal tab and type `git `.

The shell plugin starts Palette in the background if it isn't running.
**Open at Login** is in the menu-bar menu.

## Keys

| Key | While the dropdown is open |
| --- | --- |
| ↑ ↓, Ctrl-P Ctrl-N | Move the selection |
| Tab | Insert the selection |
| Enter | Insert the selection if you moved it, otherwise run the command |
| Esc | Close until the next word |
| Click | Insert that row |

When the dropdown is closed, every key does what it did before. Source
Palette **last** in `~/.zshrc` so its key bindings wrap those of other
plugins.

## How it works

```
 zsh + palette.zsh ──(unix socket)──▶ Palette.app ──(pty)──▶ zsh -f -i + worker.zsh
   buffer, cursor cell,                 fuzzy rank,             compinit with your fpath,
   cwd, key handling                    learning, panel         compadd captured
```

- **`shell/palette.zsh`** sends the text left of the cursor, the cursor's
  terminal cell and the working directory on every edit. It finds the cell
  by asking the terminal for the cursor position at each prompt and again
  after a pause in typing. While the dropdown is open it owns ↑ ↓ Tab Enter
  Esc.
- **Snapshot:** when your aliases, functions or `compdef`s change,
  `palette.zsh` writes them to a private file
  (`~/.local/state/palette/shell-<pid>.zsh`, removed when the shell exits).
  The worker loads it, so `gco ` completes like `git checkout ` and
  completions sourced from `.zshrc` work.
- **`shell/worker.zsh`** runs inside a private `zsh -f -i` per shell.
  Palette asks it to complete the line up to the start of the current word,
  overriding `compadd` to capture every match with its description and tag.
- **Palette.app** caches those candidates for the current position and
  fuzzy-matches the rest of the word as you type, without asking zsh again.
  Exact and prefix matches always rank first, and your aliases come before
  other commands. Your accepted picks (per command, decaying over two weeks)
  reorder results within a tier. Turn this off with **Learn From Picks** in
  the menu.
- **Placement:** neither Ghostty nor Rex expose the caret position through
  Accessibility. Palette combines the focused pane's frame (Accessibility),
  the tty's grid and pixel size (`TIOCGWINSZ`), and Ghostty's
  `window-padding-*` settings to compute the cell's position on screen.

## Privacy and data

Palette works offline. The only network request it makes is Sparkle's
update check against this repository's GitHub releases (once a day unless
you turn off **Check Automatically**). Completion functions are another
matter: they run inside the worker like they would in your shell, so a
completion that contacts a server (Homebrew, Docker, `kubectl`, `ssh` hosts)
still does. See [SECURITY.md](SECURITY.md) for what the worker runs.

Everything Palette stores is local and readable only by you:

| What | Where | Kept |
| --- | --- | --- |
| Socket and shell snapshots (your aliases, functions, `compdef`s, `zstyle`s) | `~/.local/state/palette/` | Snapshot removed when its shell exits |
| Learned picks (command and chosen word, with count and date) | `~/Library/Application Support/Palette/learning.json` | 90 days after the last pick, at most 5,000 entries |
| zsh completion cache and dump | `~/Library/Caches/Palette/` | Until macOS or you clear caches |
| Log | `~/Library/Logs/Palette.log` | Rotated to `Palette.log.1` at 512 KB |
| Settings (Learn From Picks, update checks) | `defaults read dev.builtbymax.palette` | Until removed |

Learning can be turned off with **Learn From Picks**; **Troubleshooting →
Forget Learned Suggestions** deletes what was learned. The log holds
connections, errors and setup events, never what you type.
**Troubleshooting → Debug Logging** adds completion timings, the command
lines being completed and the computed terminal geometry. It is off again at
the next launch.

## Uninstall

1. Quit Palette from the menu-bar menu, and turn off **Open at Login** first
   if you turned it on.
2. Delete the block between `# >>> palette >>>` and `# <<< palette <<<` from
   `~/.zshrc`.
3. Delete `/Applications/Palette.app`.
4. Delete local data and reset the Accessibility permission:

   ```sh
   rm -rf ~/.local/state/palette ~/Library/Application\ Support/Palette \
     ~/Library/Caches/Palette ~/Library/Logs/Palette.log*
   defaults delete dev.builtbymax.palette
   tccutil reset Accessibility dev.builtbymax.palette
   ```

## Develop

```sh
swift test                      # unit tests, including a live zsh worker test
swift build && Tests/e2e.py     # real zsh + plugin + headless app in a pty
.build/debug/Palette --render /tmp/panel.png [--dark]   # render the dropdown
PALETTE_DEBUG=1 swift run Palette                       # run from source
```

`Palette --headless` serves completions without UI and prints panel events,
which `Tests/e2e.py` uses. Set `PALETTE_SOCKET` to run it beside an installed
copy.

## Versions and releases

`VERSION` holds the version. Releases are signed with a Developer ID,
notarized and published on GitHub Releases. Installed copies update
themselves with [Sparkle](https://sparkle-project.org): **Check for Updates…**
in the menu, plus automatic checks. Updating the app also updates the shell
plugin, because `~/.zshrc` sources it from inside `Palette.app`.

```sh
make release VERSION=0.0.2   # build origin/main, notarize, write the appcast
make publish VERSION=0.0.2   # tag that commit and create the GitHub release
```

See [the release checklist](release-checklist.md) for the steps and the
one-time setup. CI (`.github/workflows/ci.yml`) runs the unit and end-to-end
tests and builds the app on every push to `main` and every pull request.

The update feed is `releases/latest/download/appcast.xml` in this repository.
GitHub only serves it without signing in once the repository is public. For
a separate public releases repository instead, change `SUFeedURL` in
`Resources/Info.plist` and the URLs in `scripts/release.sh`.

## Security

Report vulnerabilities privately as described in [SECURITY.md](SECURITY.md).

## Limits

- zsh only. The worker is a clean `zsh -f` that receives a snapshot of your
  shell: aliases, `compdef`s, `zstyle`s, completion functions defined
  outside `fpath` (like bun's) and the names of your functions. Shell
  options and variables your completion functions read aren't copied.
- Multi-line buffers and words inside quotes aren't completed.
- Placement assumes one cell per character in the buffer. Wide characters
  before the cursor can shift the dropdown by a few cells.
