#!/usr/bin/env python3
"""Exercise live LSP diagnostics and UI through a real Neovim TUI."""

from __future__ import annotations

import tempfile
import time
from pathlib import Path

from pty import Nvim


def wait_for_event_containing(session, fragment, timeout=3.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        session.pump(0.05)
        if any(fragment in event for event in session.events):
            return
    raise AssertionError(f"missing event containing {fragment!r}; events={session.events!r}")


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix="lector-lsp-pty-") as directory:
        session = Nvim(root, Path(directory))
        try:
            session.wait_for_event("unnamed buffer")
            session.send(
                b":lua require('lector').setup({announce_buffers=false,"
                b"announce_diagnostics=true,announce_floating_windows=true,"
                b"announce_messages=false,announce_command_line=false,"
                b"announce_spelling=false,announce_modes=false})\r"
            )
            server = str(root / "tests" / "lsp_fixture.py").encode()
            command = (
                b":lua vim.api.nvim_buf_set_name(0,'/tmp/lector-lsp-pty.lua');"
                b"vim.api.nvim_buf_set_lines(0,0,-1,false,"
                b"{'local value = missing','print(value)'});"
                b"vim.api.nvim_win_set_cursor(0,{1,6});vim.bo.filetype='lua';"
                b"vim.lsp.start({name='lector-fixture',cmd={'python3','"
                + server
                + b"'},root_dir='"
                + str(root).encode()
                + b"'})\r"
            )
            session.clear()
            session.send(command)
            session.wait_for_event("error, undefined name, 1 more")

            session.clear()
            session.send(b":LectorDiagnostic\r")
            session.wait_for_event(
                "error, undefined name, fixture, code E001, 1 more"
            )

            session.send(
                b":lua vim.keymap.set('n','Q',function() "
                b"vim.diagnostic.jump({count=1,float=false,wrap=false}) end)\r"
            )
            session.pump(0.2)
            session.clear()
            session.send(b"Q")
            session.wait_for_event("warning, unresolved target, 1 more")
            session.pump(0.2)
            if session.events != ["missing", "warning, unresolved target, 1 more"]:
                raise AssertionError(
                    f"same-line diagnostic jump was announced out of order: {session.events!r}"
                )
            session.send(b":nunmap Q\r")

            session.clear()
            session.send(b":lua vim.lsp.buf.hover()\r")
            session.wait_for_event("**fixture hover**")
            session.send(
                b":lua for _,w in ipairs(vim.api.nvim_list_wins()) do "
                b"if w~=vim.api.nvim_get_current_win() "
                b"and vim.api.nvim_win_get_config(w).relative~='' "
                b"then vim.api.nvim_win_close(w,true) end end\r"
            )

            session.clear()
            session.send(b":lua vim.lsp.buf.signature_help()\r")
            wait_for_event_containing(session, "fixture signature")
            session.send(
                b":lua for _,w in ipairs(vim.api.nvim_list_wins()) do "
                b"if w~=vim.api.nvim_get_current_win() "
                b"and vim.api.nvim_win_get_config(w).relative~='' "
                b"then vim.api.nvim_win_close(w,true) end end\r"
            )

            session.clear()
            session.send(b":lua vim.lsp.buf.definition()\r")
            wait_for_event_containing(session, "print(value)")
            definition_list_suffix = (
                "print(value), lector-lsp-pty.lua, line 2, column 1, 1 of 1"
            )
            if not any(
                event == "print(value)" or definition_list_suffix in event
                for event in session.events
            ):
                raise AssertionError(
                    "definition did not announce its destination; "
                    f"events={session.events!r}"
                )

            session.send(b"gg")
            session.pump(0.2)
            session.clear()
            session.send(b":lua vim.lsp.buf.references()\r")
            wait_for_event_containing(
                session,
                "local value = missing, lector-lsp-pty.lua, "
                "line 1, column 7, 1 of 2",
            )
            session.clear()
            session.send(b"j")
            wait_for_event_containing(
                session,
                "print(value), lector-lsp-pty.lua, line 2, column 7, 2 of 2",
            )
        finally:
            session.close()

    print("lector.nvim LSP PTY tests passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
