#!/usr/bin/env python3
"""Exercise lector.nvim through a real TUI and native popup loop."""

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
NVIM = os.environ.get("LECTOR_NVIM", "nvim")
TERMINAL_QUERY_RESPONSES = (
    (b"\x1b[5n", b"\x1b[0n"),  # terminal status: operating normally
)
MAX_TERMINAL_QUERY_LENGTH = max(len(query) for query, _ in TERMINAL_QUERY_RESPONSES)


class Nvim:
    def __init__(
        self,
        runtime: Path,
        state_home: Path,
        *,
        announce_spelling: bool = False,
    ) -> None:
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
            f"announce_spelling={'true' if announce_spelling else 'false'}"
            "})"
        )
        self.process = subprocess.Popen(
            [
                NVIM,
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
        self._terminal_query_tail = b""

    def pump(self, seconds: float = 0.05) -> None:
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            ready, _, _ = select.select([self.master], [], [], min(0.02, remaining))
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
            query_data = self._terminal_query_tail + chunk
            old_tail_length = len(self._terminal_query_tail)
            for query, response in TERMINAL_QUERY_RESPONSES:
                start = 0
                while True:
                    position = query_data.find(query, start)
                    if position < 0:
                        break
                    if position + len(query) > old_tail_length:
                        os.write(self.master, response)
                    start = position + len(query)
            self._terminal_query_tail = query_data[-(MAX_TERMINAL_QUERY_LENGTH - 1):]
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

    def wait_for_event_prefix(self, expected: str, timeout: float = 3.0) -> str:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            self.pump(0.05)
            for event in self.events:
                if event.startswith(expected):
                    return event
        raise AssertionError(
            f"missing event beginning with {expected!r}; events={self.events!r}"
        )

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
    if not shutil.which(NVIM):
        print("skipped: nvim is not installed")
        return 0

    runtime = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix="lector-nvim-pty-") as directory:
        session = Nvim(runtime, Path(directory))
        try:
            session.wait_for_event("unnamed buffer")

            session.send(b"i{}\x1b")
            session.pump(0.2)
            session.clear()
            session.send(b"%")
            session.wait_for_event("{")
            session.pump(0.2)
            if session.events != [
                "set;auto=1;cursor=0",
                "set;auto=0;cursor=0",
                "{",
            ]:
                raise AssertionError(
                    f"mapped percent motion yielded cursor tracking: {session.events!r}"
                )

            session.send(
                b":lua vim.keymap.set('n','Q',function() "
                b"vim.cmd('normal! %') end)\r"
            )
            session.pump(0.2)
            session.clear()
            session.send(b"Q")
            session.wait_for_event("}")
            session.pump(0.2)
            if session.events != [
                "set;auto=1;cursor=0",
                "set;auto=0;cursor=0",
                "}",
            ]:
                raise AssertionError(
                    f"Lua command motion had competing speech: {session.events!r}"
                )
            session.send(b":nunmap Q\r")
            session.send(b"dd")

            session.send(b":nnoremap Q :\r")
            session.clear()
            session.send(b"Q")
            session.wait_for_event("command")
            session.send(b"\x1b")
            session.send(b":nunmap Q\r")

            session.send(b":lua vim.keymap.set('n','Q',function() end)\r")
            session.clear()
            session.send(b"Q")
            session.pump(0.2)
            if session.events != [
                "set;auto=1;cursor=0",
                "set;auto=0;cursor=0",
            ]:
                raise AssertionError(
                    f"harmless Lua mapping enabled cursor tracking: {session.events!r}"
                )
            session.send(b":nunmap Q\r")

            session.send(
                b":lua vim.keymap.set('n','Q',function() "
                b"vim.api.nvim_echo({{'lua mapping output'}},false,{}) end)\r"
            )
            session.pump(0.2)
            session.clear()
            session.send(b"Q")
            session.wait_for_output(b"lua mapping output")
            session.pump(0.2)
            if session.events != [
                "set;auto=1;cursor=0",
                "set;auto=0;cursor=0",
            ]:
                raise AssertionError(
                    f"Lua mapping output had competing speech: {session.events!r}"
                )

            session.send(b":nnoremap Q <Cmd>echo 'Cmd mapping output'<CR>\r")
            session.pump(0.2)
            session.clear()
            session.send(b"Q")
            session.wait_for_output(b"Cmd mapping output")
            session.pump(0.2)
            if session.events != [
                "set;auto=1;cursor=0",
                "set;auto=0;cursor=0",
            ]:
                raise AssertionError(
                    f"Cmd mapping output had competing speech: {session.events!r}"
                )

            session.send(
                b":lua vim.keymap.set('n','Q',function() "
                b"vim.api.nvim_echo({{'first\\nsecond'}},false,{}) end)\r"
            )
            session.pump(0.2)
            session.clear()
            session.send(b"Q")
            session.wait_for_output(b"Press ENTER")
            session.wait_for_event("set;auto=1;cursor=0")
            session.pump(0.2)
            if session.events != ["set;auto=1;cursor=0"]:
                raise AssertionError(
                    f"Lua hit-enter prompt lost automatic reading: {session.events!r}"
                )
            session.send(b"\r")
            session.wait_for_event("set;auto=0;cursor=0")

            session.send(
                b":lua vim.keymap.set('n','Q',function() "
                b"vim.api.nvim_feedkeys(':','n',false) end)\r"
            )
            session.pump(0.2)
            session.clear()
            session.send(b"Q")
            session.wait_for_event("command")
            session.pump(0.2)
            if session.events != [
                "set;auto=1;cursor=0",
                "set;auto=0;cursor=0",
                "command",
            ]:
                raise AssertionError(
                    f"Lua mapping command line was not interactive: {session.events!r}"
                )
            session.send(b"\x1b")

            session.send(
                b":lua vim.keymap.set('n','Q',function() local lines={}; "
                b"for i=1,40 do lines[i]=tostring(i) end; "
                b"vim.api.nvim_echo({{table.concat(lines,'\\n')}},false,{}) end)\r"
            )
            session.pump(0.2)
            session.clear()
            session.send(b"Q")
            session.wait_for_output(b"-- More --")
            session.wait_for_event("set;auto=1;cursor=0")
            session.pump(0.2)
            if session.events != ["set;auto=1;cursor=0"]:
                raise AssertionError(
                    f"Lua mapping pager did not retain automatic reading: {session.events!r}"
                )
            session.send(b"q")
            session.wait_for_event("set;auto=0;cursor=0")
            session.send(b":nunmap Q\r")

            session.send(
                b":lua vim.keymap.set('n','Q',function() "
                b"require('lector').observe_navigation('next',function() end) end)\r"
            )
            session.clear()
            session.send(b"Q")
            session.wait_for_event("no next item")
            session.send(b":nunmap Q\r")

            session.send(
                b":lua vim.keymap.set('n','Q',function() "
                b"vim.ui.select({'first action','second action'},"
                b"{prompt='Code actions:'},function() end) end)\r"
            )
            session.pump(0.2)
            session.clear()
            session.send(b"Q")
            session.wait_for_output(b"Code actions:")
            session.wait_for_output(b"first action")
            session.wait_for_event("end")
            session.pump(0.2)
            if session.events != ["set;auto=1;cursor=0", "end"]:
                raise AssertionError(
                    f"selector reclaimed semantic policy before closing: {session.events!r}"
                )
            session.clear()
            session.send(b"\x1b")
            session.wait_for_event("set;auto=0;cursor=0")
            session.send(b":nunmap Q\r")

            session.send(
                b":lua vim.keymap.set('n','Q',function() "
                b"local b=vim.api.nvim_create_buf(false,true); "
                b"vim.api.nvim_buf_set_lines(b,0,-1,false,"
                b"{'custom interactive UI','second row'}); "
                b"local w=vim.api.nvim_open_win(b,true,"
                b"{relative='editor',row=2,col=4,width=30,height=2,style='minimal'}); "
                b"vim.keymap.set('n','q',function() "
                b"vim.api.nvim_win_close(w,true) end,{buffer=b}) end)\r"
            )
            session.pump(0.2)
            session.clear()
            session.send(b"Q")
            session.wait_for_output(b"custom interactive UI")
            session.wait_for_event("end")
            session.pump(0.2)
            if session.events != ["set;auto=1;cursor=0", "end"]:
                raise AssertionError(
                    f"focused Lua UI did not restore screen-reader defaults: "
                    f"{session.events!r}"
                )
            session.clear()
            session.send(b"j")
            session.pump(0.2)
            if session.events:
                raise AssertionError(
                    f"focused Lua UI did not retain screen-reader ownership: "
                    f"{session.events!r}"
                )
            session.clear()
            session.send(b"q")
            session.wait_for_event("set;auto=0;cursor=0")
            session.pump(0.2)
            if "set;auto=1;cursor=0" in session.events or "end" in session.events:
                raise AssertionError(
                    f"closing Lua UI briefly reclaimed output fallback: "
                    f"{session.events!r}"
                )
            session.send(b":nunmap Q\r")

            session.send(
                b":lua vim.keymap.set('n','Q',function() "
                b"vim.ui.input({prompt='Custom input: '},function() end) end)\r"
            )
            session.pump(0.2)
            session.clear()
            session.send(b"Q")
            session.wait_for_output(b"Custom input:")
            session.wait_for_event("end")
            session.pump(0.2)
            if session.events != ["set;auto=1;cursor=0", "end"]:
                raise AssertionError(
                    f"vim.ui.input did not retain screen-reader ownership: "
                    f"{session.events!r}"
                )
            session.clear()
            session.send(b"\x1b")
            session.wait_for_event("set;auto=0;cursor=0")
            session.send(b":nunmap Q\r")

            session.send(b":let g:lector_cmdline_history_test = 1\r")
            session.pump(0.2)
            session.send(b":\x1b[A")
            session.pump(0.2)
            session.clear()
            session.send(b"\x1b[D")
            session.wait_for_event("1")
            session.pump(0.2)
            if session.events != ["1"] or b"Error in CursorMovedC" in session.output:
                raise AssertionError(
                    f"command-line left motion failed: events={session.events!r}"
                )
            session.clear()
            session.send(b"\x1b[C")
            session.wait_for_event("blank")
            session.pump(0.2)
            if session.events != ["blank"] or b"Error in CursorMovedC" in session.output:
                raise AssertionError(
                    f"command-line right motion failed: events={session.events!r}"
                )
            session.clear()
            session.send(b"\x7f")
            session.wait_for_event("1")
            session.pump(0.2)
            if session.events != ["1"]:
                raise AssertionError(
                    f"command-line deletion did not announce removed text: {session.events!r}"
                )
            session.send(b"\x1b")

            session.send(b"a")
            session.pump(0.2)
            session.clear()
            session.send(b"test")
            session.pump(0.2)
            if session.events:
                raise AssertionError(
                    f"Insert-mode typing produced semantic speech: {session.events!r}"
                )
            session.clear()
            session.send(b"\x1b[D")
            session.wait_for_event("t")
            session.pump(0.2)
            if session.events != ["t"]:
                raise AssertionError(
                    f"Insert-mode Left did not announce the character: {session.events!r}"
                )
            session.clear()
            session.send(b"\x1b[C")
            session.wait_for_event("blank")
            session.pump(0.2)
            if session.events != ["blank"]:
                raise AssertionError(
                    f"Insert-mode Right did not announce the character: {session.events!r}"
                )
            session.clear()
            session.send(b"\x7f")
            session.wait_for_event("t")
            session.pump(0.2)
            if session.events != ["t"]:
                raise AssertionError(
                    f"Insert-mode deletion did not announce removed text: {session.events!r}"
                )
            session.send(b"t\rsecond")
            session.pump(0.2)
            session.clear()
            session.send(b"\x1b[A")
            session.wait_for_event("test")
            session.pump(0.2)
            if session.events != ["test"]:
                raise AssertionError(
                    f"Insert-mode Up did not announce the line: {session.events!r}"
                )
            session.clear()
            session.send(b"\x1b[B")
            session.wait_for_event("second")
            session.pump(0.2)
            if session.events != ["second"]:
                raise AssertionError(
                    f"Insert-mode Down did not announce the line: {session.events!r}"
                )
            session.send(b"\x1b")
            session.pump(0.2)
            session.send(b"dd")
            session.pump(0.2)
            session.clear()
            session.send(b"0")
            session.wait_for_event("t")
            session.pump(0.2)
            if session.events != ["t"]:
                raise AssertionError(
                    f"line-start motion competed with cursor tracking: {session.events!r}"
                )
            session.clear()
            session.send(b"l")
            session.wait_for_event("e")
            session.pump(0.2)
            if session.events != ["e"]:
                raise AssertionError(
                    f"character motion competed with cursor tracking: {session.events!r}"
                )
            session.send(b"dd")
            session.pump(0.2)

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
            if "set;auto=1;cursor=0" in session.events:
                raise AssertionError(
                    f"Visual entry enabled automatic reading: {session.events!r}"
                )
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
            session.send(b":setlocal spell spelllang=en_us spellsuggest=best,5\r")
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
            session.clear()
            session.send(b"z=")
            session.wait_for_output(b'Change "quik" to:')
            session.wait_for_event("set;auto=1;cursor=0")
            session.pump(0.2)
            if session.output.find(b"set;auto=1;cursor=0") > session.output.find(
                b'Change "quik" to:'
            ):
                raise AssertionError("terminal reading started after suggestions rendered")
            valid_spelling_handoffs = (
                ["set;auto=1;cursor=0"],
                ["set;auto=1;cursor=0", "end"],
            )
            if session.events not in valid_spelling_handoffs:
                raise AssertionError(
                    f"spelling suggestions were not handed to terminal reading: "
                    f"{session.events!r}"
                )
            session.send(b"q")
            session.wait_for_event("set;auto=0;cursor=0")
            session.pump(0.2)
            valid_spelling_lifecycles = (
                ["set;auto=1;cursor=0", "set;auto=0;cursor=0"],
                ["set;auto=1;cursor=0", "end", "set;auto=0;cursor=0"],
            )
            if session.events not in valid_spelling_lifecycles:
                raise AssertionError(
                    f"spelling suggestion prompt did not restore semantic reading: "
                    f"{session.events!r}"
                )

            session.send(b":nnoremap Q z=\r")
            session.clear()
            session.send(b"Q")
            session.wait_for_output(b'Change "quik" to:')
            session.wait_for_event("set;auto=1;cursor=0")
            if session.output.find(b"set;auto=1;cursor=0") > session.output.find(
                b'Change "quik" to:'
            ):
                raise AssertionError(
                    "terminal reading started after remapped suggestions rendered"
                )
            session.send(b"q")
            session.wait_for_event("set;auto=0;cursor=0")

            session.send(b":nunmap Q\r")
            session.send(b":nnoremap <Plug>(LectorSpellSuggest) z=\r")
            session.send(b":nmap Q <Plug>(LectorSpellSuggest)\r")
            session.clear()
            session.send(b"Q")
            session.wait_for_output(b'Change "quik" to:')
            session.wait_for_event("set;auto=1;cursor=0")
            if session.output.find(b"set;auto=1;cursor=0") > session.output.find(
                b'Change "quik" to:'
            ):
                raise AssertionError(
                    "terminal reading started after <Plug> suggestions rendered"
                )
            session.send(b"q")
            session.wait_for_event("set;auto=0;cursor=0")
            session.send(b":nunmap Q\r")

            session.clear()
            session.send(b"[I")
            session.wait_for_output(b"The quik fox meets zzzzword")
            session.wait_for_event("set;auto=1;cursor=0")
            session.pump(0.2)
            if session.output.find(b"set;auto=1;cursor=0") > session.output.find(
                b"The quik fox meets zzzzword"
            ):
                raise AssertionError("identifier-list reading started after output rendered")
            if session.events != ["set;auto=1;cursor=0"]:
                raise AssertionError(
                    f"identifier list did not retain terminal reading: {session.events!r}"
                )
            session.send(b"q")
            session.wait_for_event("set;auto=0;cursor=0")

            session.clear()
            session.send(b"g<")
            session.wait_for_output(b"Press ENTER or type command to continue")
            session.wait_for_event("set;auto=1;cursor=0")
            session.pump(0.2)
            if session.events != ["set;auto=1;cursor=0"]:
                raise AssertionError(
                    f"message scrollback did not retain terminal reading: {session.events!r}"
                )
            session.send(b"q")
            session.wait_for_event("set;auto=0;cursor=0")

            session.clear()
            session.send(b"1z=")
            session.pump(0.2)
            if "set;auto=1;cursor=0" in session.events:
                raise AssertionError(
                    f"counted spelling replacement enabled automatic reading: "
                    f"{session.events!r}"
                )
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
            session.clear()
            session.send(b":only\r")
            session.pump(0.2)
            if "closed" in session.events:
                raise AssertionError(f"window close was announced: {session.events!r}")

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
            session.clear()
            session.send(b"\r")
            session.pump(0.2)
            if "closed" in session.events:
                raise AssertionError(f"context menu close was announced: {session.events!r}")
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
            session.pump(0.2)
            if "closed" in session.events:
                raise AssertionError(f"submenu close was announced: {session.events!r}")

            session.clear()
            session.send(b":")
            session.wait_for_event("command")
            session.clear()
            session.send(b"echo 'pty visible output'\r")
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

        spelling_session = Nvim(
            runtime,
            Path(directory) / "semantic-spelling",
            announce_spelling=True,
        )
        try:
            spelling_session.wait_for_event("unnamed buffer")
            spelling_session.send(b":set spell spelllang=en_us spellsuggest=best,5\r")
            spelling_session.send(b"ithis is a tesst\x1b")
            spelling_session.clear()
            spelling_session.send(b"z=")
            spelling_session.wait_for_output(b'Change "tesst" to:')
            spelling_session.wait_for_event_prefix("Change tesst to. 1, test")
            spelling_session.pump(0.2)
            if any(
                event in {"set;auto=1;cursor=0", "end"}
                for event in spelling_session.events
            ):
                raise AssertionError(
                    "semantic spelling suggestions yielded terminal "
                    f"reading: {spelling_session.events!r}"
                )
            spelling_session.send(b"q")

            spelling_session.send(b":nnoremap Q z=\r")
            spelling_session.clear()
            spelling_session.send(b"Q")
            spelling_session.wait_for_output(b'Change "tesst" to:')
            spelling_session.wait_for_event_prefix("Change tesst to. 1, test")
            if any(
                event in {"set;auto=1;cursor=0", "end"}
                for event in spelling_session.events
            ):
                raise AssertionError(
                    "mapped semantic spelling suggestions yielded terminal "
                    f"automatic reading: {spelling_session.events!r}"
                )
            spelling_session.send(b"q")
        finally:
            spelling_session.close()

    print("lector.nvim PTY tests passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
