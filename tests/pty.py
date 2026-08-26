#!/usr/bin/env python3
"""Exercise Lector's Neovim client through a real TUI and native popup loop."""

from __future__ import annotations

import fcntl
import os
import re
import select
import shutil
import struct
import subprocess
import sys
import tempfile
import termios
import time
from pathlib import Path


APC = re.compile(
    rb"\x1b_Lector;A11y;1;(?:say;([0-9a-f]+)|line;indent=\d+;([0-9a-f]+)|"
    rb"(set;auto=[01];cursor=[01]|end))\x1b\\"
)


class Nvim:
    def __init__(self, runtime: Path, state_home: Path) -> None:
        master, slave = os.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
        env = os.environ.copy()
        env.update({
            "TERM": "xterm-256color",
            "XDG_STATE_HOME": str(state_home),
        })
        setup = (
            "lua require('lector').setup({"
            "announce_diagnostics=false,announce_floating_windows=false,"
            "announce_spelling=false})"
        )
        self.process = subprocess.Popen(
            [
                "nvim",
                "--clean",
                "-n",
                "-i",
                "NONE",
                "--cmd",
                f"set runtimepath^={runtime}",
                "--cmd",
                "set mouse=a mousemodel=popup_setpos",
                "--cmd",
                setup,
            ],
            stdin=slave,
            stdout=slave,
            stderr=slave,
            env=env,
            close_fds=True,
        )
        os.close(slave)
        self.master = master
        os.set_blocking(master, False)
        self.output = bytearray()
        self.events: list[str] = []
        self._parsed = 0

    def pump(self, seconds: float = 0.05) -> None:
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            ready, _, _ = select.select([self.master], [], [], min(0.02, deadline - time.monotonic()))
            if not ready:
                continue
            try:
                chunk = os.read(self.master, 65536)
            except BlockingIOError:
                continue
            except OSError:
                break
            if not chunk:
                break
            self.output.extend(chunk)
        self._parse_events()

    def _parse_events(self) -> None:
        data = bytes(self.output)
        for match in APC.finditer(data, self._parsed):
            encoded = match.group(1) or match.group(2)
            if encoded:
                self.events.append(bytes.fromhex(encoded.decode()).decode("utf-8"))
            else:
                self.events.append(match.group(3).decode())
            self._parsed = match.end()

    def send(self, value: bytes) -> None:
        os.write(self.master, value)
        self.pump()

    def wait_for_event(self, expected: str, timeout: float = 3.0) -> None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            self.pump(0.05)
            if expected in self.events:
                return
        raise AssertionError(f"missing event {expected!r}; events={self.events!r}")

    def wait_for_output(self, expected: bytes, timeout: float = 3.0) -> None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            self.pump(0.05)
            if expected in self.output:
                return
        raise AssertionError(f"missing terminal output {expected!r}")

    def clear(self) -> None:
        self.output.clear()
        self.events.clear()
        self._parsed = 0

    def close(self) -> None:
        if self.process.poll() is None:
            try:
                self.send(b"\x1b:qall!\r")
                self.process.wait(timeout=2)
            except (OSError, subprocess.TimeoutExpired):
                self.process.terminate()
                try:
                    self.process.wait(timeout=1)
                except subprocess.TimeoutExpired:
                    self.process.kill()
        os.close(self.master)


def main() -> int:
    if not shutil.which("nvim"):
        print("skipped: nvim is not installed")
        return 0

    runtime = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix="lector-nvim-pty-") as directory:
        session = Nvim(runtime, Path(directory))
        try:
            session.wait_for_event("unnamed buffer")

            session.clear()
            session.send(b"ione\rone\rone\x1b")
            session.clear()
            session.send(b"ggdd")
            session.wait_for_event("one")
            if any(event.startswith("deleted") for event in session.events):
                raise AssertionError(f"deletion contents were announced: {session.events!r}")

            session.clear()
            session.send(b"u")
            session.pump(0.2)
            if any(event.startswith("deleted") for event in session.events):
                raise AssertionError(f"undo was misreported as deletion: {session.events!r}")

            session.send(b"gg0")
            session.clear()
            session.send(b"v")
            session.wait_for_event("visual")
            session.pump(0.2)
            if "o" in session.events:
                raise AssertionError(
                    f"Visual entry repeated the cursor character: {session.events!r}"
                )
            session.send(b"\x1b")

            session.send(b"gg0")
            session.send(b"vl")
            session.clear()
            session.send(b"d")
            session.wait_for_event("e")
            semantic = [event for event in session.events if event not in {
                "end", "set;auto=0;cursor=0"
            }]
            if semantic != ["e"]:
                raise AssertionError(
                    f"Visual deletion had competing speech: {session.events!r}"
                )
            session.send(b"u")

            session.send(b"GoThe quik fox meets zzzzword\x1b")
            session.send(b":setlocal spell spelllang=en_us\r")
            session.send(b"0")
            session.send(b":nnoremap s ]s\r")
            session.clear()
            session.send(b"s")
            session.wait_for_event("quik")
            session.send(b":nunmap s\r")
            session.clear()
            session.send(b"]s")
            session.wait_for_event("zzzzword")
            session.clear()
            session.send(b"[s")
            session.wait_for_event("quik")
            session.send(b":setlocal nospell\rdd")

            session.send(b"Goalpha beta gamma\x1b")
            session.send(b"0w")
            session.send(b":nnoremap Q daw\r")
            session.clear()
            session.send(b"Q")
            session.wait_for_event("gamma")
            if "g" in session.events:
                raise AssertionError(f"word deletion announced only a character: {session.events!r}")
            session.send(b":nunmap Q\r")
            session.send(b":nnoremap Q s\r")
            session.clear()
            session.send(b"Q")
            session.wait_for_event("a")
            session.send(b"\x1bu:nunmap Q\r")
            session.clear()
            session.send(b"x")
            session.wait_for_event("a")
            session.send(b"uudd")

            session.send(b"gg0")
            session.clear()
            session.send(b"dw")
            session.wait_for_event("blank")
            if session.events.count("blank") != 1:
                raise AssertionError(f"deletion destination repeated: {session.events!r}")
            if any(event.startswith("deleted") for event in session.events):
                raise AssertionError(f"word contents were announced after deletion: {session.events!r}")

            session.clear()
            session.send(b"p")
            session.wait_for_event("pasted one")
            semantic = [event for event in session.events if event not in {
                "end", "set;auto=0;cursor=0"
            }]
            if semantic != ["pasted one"]:
                raise AssertionError(f"put had competing announcements: {session.events!r}")

            session.send(b":vsplit\r")
            session.pump(0.2)
            session.clear()
            session.send(b"\x17w")
            session.pump(0.2)
            if any(event in {"one", "blank"} for event in session.events):
                raise AssertionError(f"CTRL-W was interpreted as cursor motion: {session.events!r}")
            session.send(b":only\r")
            session.pump(0.2)

            session.clear()
            session.send(b"gg/one\r")
            session.wait_for_event("2 of 3")

            session.send(b":nnoremenu 10.10 PopUp.PTY <Cmd>let g:lector_pty_menu=1<CR>\r")
            session.clear()
            session.send(b"\x1b[<2;1;1M\x1b[<2;1;1m")
            session.wait_for_event("context menu")
            for _ in range(20):
                session.send(b"\x1b[B")
                if any(event.startswith("PTY, ") for event in session.events):
                    break
            else:
                raise AssertionError(f"PTY menu item was not reachable: {session.events!r}")
            session.send(b"\r")
            session.pump(0.2)
            session.send(
                b":lua require('lector').say(tostring(vim.g.lector_pty_menu))\r"
            )
            session.wait_for_event("1")

            session.send(b":nnoremenu 90.10 PopUp.Parent.Child <Nop>\r")
            session.clear()
            session.send(b"\x1b[<2;1;1M\x1b[<2;1;1m")
            session.wait_for_event("context menu")
            for _ in range(20):
                session.send(b"\x1b[B")
                if any(event.startswith("Parent, submenu, ") for event in session.events):
                    break
            else:
                raise AssertionError(f"Parent submenu was not reachable: {session.events!r}")
            session.clear()
            session.send(b"\r")
            session.wait_for_event("end")
            session.send(b"\x1b\x1b")
            session.wait_for_event("set;auto=0;cursor=0")

            session.clear()
            session.send(b":echo 'pty visible output'\r")
            session.wait_for_output(b"pty visible output")
            if "end" not in session.events:
                raise AssertionError(f"command output did not enter ordinary reading: {session.events!r}")

            session.clear()
            session.send(b":terminal\r")
            session.wait_for_event("end")
            session.send(b"exit\r")
            session.pump(0.3)
            session.send(b"\x1c\x0e:bd!\r")
            session.wait_for_event("set;auto=0;cursor=0")
        finally:
            session.close()

    print("lector Neovim PTY tests passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
