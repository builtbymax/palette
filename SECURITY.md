# Security

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub: open the repository's **Security** tab and choose
**Report a vulnerability**. Don't open a public issue. Include the Palette version (menu-bar menu header or
`Palette --version`), your macOS version and the steps to reproduce.

Only the latest release gets fixes. Installed copies receive them through the built-in updater.

## What Palette trusts

Palette runs with your user's permissions and treats your own shell setup as trusted.

- **Completion code runs.** To find candidates, Palette starts a private `zsh -f -i` per shell and loads
  zsh's completion system with your `fpath` and a snapshot of your aliases, completion functions,
  `compdef`s and `zstyle`s. Completion functions are shell code and run as you type, exactly as if you
  had pressed Tab. Some run other programs, in the current directory: `git`, `make` (which can read a
  project's Makefile), `docker`, `brew` and so on. Completing inside a directory you don't trust carries
  the same risk as pressing Tab there.
- **Network.** Palette itself contacts only GitHub, for Sparkle's update feed and downloads. Updates are
  verified with an EdDSA signature and Apple's Developer ID signature before they install. Completion
  functions may use the network on their own, as they do in your shell.
- **Local connections.** Shells talk to Palette over a Unix socket in `~/.local/state/palette/`. The
  directory is private to your user (mode 700), so other users can't connect. Snapshots of your shell
  are written there and readable only by you.
- **Accessibility.** Palette reads only the position and size of the focused terminal pane. It doesn't
  read window contents or type for you; inserting a suggestion is done by the shell plugin.

See [Privacy and data](README.md#privacy-and-data) for what is stored and how to remove it.
