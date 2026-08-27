#!/usr/bin/env python3
"""Deterministic LSP server for lector.nvim integration tests."""

from __future__ import annotations

import json
import sys


def read_message():
    headers = {}
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            return None
        if line == b"\r\n":
            break
        name, value = line.decode("ascii").split(":", 1)
        headers[name.lower()] = value.strip()
    length = int(headers["content-length"])
    return json.loads(sys.stdin.buffer.read(length))


def send(message):
    payload = json.dumps(message, separators=(",", ":")).encode("utf-8")
    header = f"Content-Length: {len(payload)}\r\n\r\n".encode("ascii")
    sys.stdout.buffer.write(header + payload)
    sys.stdout.buffer.flush()


uri = None
while True:
    message = read_message()
    if message is None:
        break
    method = message.get("method")
    request_id = message.get("id")
    if method == "initialize":
        send({
            "jsonrpc": "2.0",
            "id": request_id,
            "result": {
                "capabilities": {
                    "textDocumentSync": 1,
                    "hoverProvider": True,
                    "definitionProvider": True,
                    "referencesProvider": True,
                    "signatureHelpProvider": {"triggerCharacters": ["("]},
                    "completionProvider": {},
                },
                "serverInfo": {"name": "lector-fixture", "version": "1"},
            },
        })
    elif method == "textDocument/didOpen":
        uri = message["params"]["textDocument"]["uri"]
        send({
            "jsonrpc": "2.0",
            "method": "textDocument/publishDiagnostics",
            "params": {
                "uri": uri,
                "diagnostics": [
                    {
                        "range": {
                            "start": {"line": 0, "character": 6},
                            "end": {"line": 0, "character": 11},
                        },
                        "severity": 1,
                        "source": "fixture",
                        "code": "E001",
                        "message": "undefined name",
                    },
                    {
                        "range": {
                            "start": {"line": 0, "character": 14},
                            "end": {"line": 0, "character": 21},
                        },
                        "severity": 2,
                        "source": "fixture",
                        "code": "W003",
                        "message": "unresolved target",
                    },
                    {
                        "range": {
                            "start": {"line": 1, "character": 0},
                            "end": {"line": 1, "character": 5},
                        },
                        "severity": 2,
                        "source": "fixture",
                        "code": "W002",
                        "message": "demonstration warning",
                    },
                ],
            },
        })
    elif method == "textDocument/hover":
        send({
            "jsonrpc": "2.0",
            "id": request_id,
            "result": {"contents": {"kind": "markdown", "value": "**fixture hover**"}},
        })
    elif method == "textDocument/signatureHelp":
        send({
            "jsonrpc": "2.0",
            "id": request_id,
            "result": {
                "signatures": [{
                    "label": "print(value)",
                    "documentation": "fixture signature",
                }],
                "activeSignature": 0,
                "activeParameter": 0,
            },
        })
    elif method == "textDocument/definition":
        send({
            "jsonrpc": "2.0",
            "id": request_id,
            "result": {
                "uri": uri,
                "range": {
                    "start": {"line": 1, "character": 0},
                    "end": {"line": 1, "character": 5},
                },
            },
        })
    elif method == "textDocument/references":
        send({
            "jsonrpc": "2.0",
            "id": request_id,
            "result": [
                {
                    "uri": uri,
                    "range": {
                        "start": {"line": 0, "character": 6},
                        "end": {"line": 0, "character": 11},
                    },
                },
                {
                    "uri": uri,
                    "range": {
                        "start": {"line": 1, "character": 6},
                        "end": {"line": 1, "character": 11},
                    },
                },
            ],
        })
    elif method == "textDocument/completion":
        send({
            "jsonrpc": "2.0",
            "id": request_id,
            "result": [{
                "label": "print",
                "kind": 3,
                "detail": "Prints a value",
                "documentation": {"kind": "markdown", "value": "Print docs"},
            }],
        })
    elif method == "shutdown":
        send({"jsonrpc": "2.0", "id": request_id, "result": None})
    elif method == "exit":
        break
    elif request_id is not None:
        send({"jsonrpc": "2.0", "id": request_id, "result": None})
