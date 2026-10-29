#!/usr/bin/env python3
"""End-to-end check: real zsh + palette.zsh + `Palette --headless`.

Drives an interactive zsh in a pseudo-terminal, answers its cursor-position
queries like a terminal would, and checks the panel events printed by the
headless app and the buffer after accepting suggestions.

    swift build && python3 Tests/e2e.py
"""
import os
import pty
import select
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BINARY = os.path.join(ROOT, ".build", "debug", "Palette")


class Shell:
    def __init__(self, env):
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.chdir(ROOT)
            os.execve("/bin/zsh", ["zsh", "-i"], env)
        self.output = b""

    def pump(self, seconds):
        end = time.time() + seconds
        while time.time() < end:
            ready, _, _ = select.select([self.fd], [], [], 0.02)
            if not ready:
                continue
            try:
                data = os.read(self.fd, 65536)
            except OSError:
                return
            self.output += data
            # Answer cursor-position requests: pretend the prompt is on row 5.
            for _ in range(data.count(b"\x1b[6n")):
                os.write(self.fd, b"\x1b[5;3R")

    def type(self, text, settle=0.6):
        for ch in text:
            os.write(self.fd, ch.encode())
            self.pump(0.03)
        self.pump(settle)

    def close(self):
        try:
            os.kill(self.pid, 9)
        except ProcessLookupError:
            pass


class App:
    def __init__(self, env):
        self.proc = subprocess.Popen([BINARY, "--headless"], env=env, stdout=subprocess.PIPE, text=True)
        assert self.proc.stdout.readline().strip() == "ready"
        os.set_blocking(self.proc.stdout.fileno(), False)
        self.events = []

    def read(self):
        while True:
            line = self.proc.stdout.readline()
            if not line:
                break
            self.events.append(line.strip())
        return self.events

    def last_show(self):
        shows = [e for e in self.read() if e.startswith("show")]
        return shows[-1] if shows else ""

    def close(self):
        self.proc.terminate()


def main():
    tmp = tempfile.mkdtemp(prefix="palette-e2e-")
    sock = os.path.join(tmp, "palette.sock")
    dump = os.path.join(tmp, "buffer")
    env = dict(os.environ, PALETTE_SOCKET=sock, PALETTE_AUTOSTART="0", TERM="xterm-256color",
               HOME=tmp, LANG="en_US.UTF-8")
    zshrc = os.path.join(tmp, ".zshrc")
    with open(zshrc, "w") as f:
        f.write(f"""
PS1='> '
autoload -Uz compinit && compinit -C -d {tmp}/zcompdump
alias gco='git checkout'
myfunc() {{ :; }}
_mytool_words() {{ compadd -d '(first second)' alpha beta; }}
_mytool() {{ _mytool_words; }}
compdef _mytool mytool
_t() {{ print -rn -- "$BUFFER" > {dump}; }}
zle -N _t
bindkey '^T' _t
source {ROOT}/shell/palette.zsh
""")
    env["ZDOTDIR"] = tmp

    app = App(env)
    shell = None
    failures = []

    def check(name, condition, detail=""):
        print(("ok   " if condition else "FAIL ") + name + (f"  ({detail})" if detail and not condition else ""))
        if not condition:
            failures.append(name)

    def buffer():
        shell.type("\x14", 0.3)
        with open(dump) as f:
            return f.read()

    try:
        shell = Shell(env)
        shell.pump(1.0)
        shell.type("\n", 0.5)  # first prompt connects in precmd

        shell.type("git ch", 1.5)
        show = app.last_show()
        check("suggests git subcommands", "items=checkout" in show, show)
        check("reports cursor cell", "row=4 col=8" in show, show)
        check("aligns with the typed word", "align=2" in show, show)

        shell.type("\t")
        check("tab inserts the top suggestion", buffer() == "git checkout ", repr(buffer()))

        shell.type("\x15", 0.3)  # kill line
        shell.type("ls Sou", 1.0)
        check("completes paths", "items=Sources/" in app.last_show(), app.last_show())
        shell.type("\t")
        check("directory insertion keeps going", buffer() == "ls Sources/", repr(buffer()))
        shell.type("", 1.0)
        check("lists the next level", "PaletteCore/" in app.last_show(), app.last_show())

        shell.type("\x15", 0.3)
        shell.type("git commit --am", 1.5)
        check("matches options fuzzily", "items=--amend" in app.last_show(), app.last_show())
        shell.type("\x1b[B", 0.3)
        check("arrow moves the selection", "select 1" in app.read(), app.events[-3:])
        shell.type("\x1b[A\x1b", 1.0)
        check("escape dismisses", app.read()[-1] == "hide", app.events[-3:])

        shell.type("\x15", 0.3)
        shell.type("gco ", 1.5)
        check("aliases complete like their command", "main" in app.last_show(), app.last_show())
        shell.type("\x15", 0.3)
        shell.type("mytool ", 1.0)
        check("completion functions from .zshrc", "items=alpha,beta" in app.last_show(), app.last_show())
        shell.type("\x15", 0.3)
        shell.type("myfu", 1.0)
        check("user functions are commands", "items=myfunc" in app.last_show(), app.last_show())

        shell.type("\x15", 0.3)
        shell.type("echo hi", 0.6)
        shell.type("\x1b[A", 0.4)  # dropdown closed or not, up must not break
        shell.type("\x15", 0.3)
        shell.type("cd zzzz-not-there", 1.0)
        check("hides without matches", app.read()[-1] == "hide", app.events[-3:])
    finally:
        if shell:
            shell.close()
        app.close()

    if failures:
        print(f"\n{len(failures)} failed")
        sys.exit(1)
    print("\nall passed")


if __name__ == "__main__":
    main()
