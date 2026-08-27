# lector.nvim

`lector.nvim` adds semantic accessibility to Neovim without changing its
visual interface or replacing its mappings. It is an independent protocol
producer, not a component of the Lector terminal screen reader. It emits the
versioned Lector application-accessibility protocol to the host terminal,
where Lector—or any other compatible terminal screen reader—can speak the
result.

The plugin is optional and fails safely. Without it, or when its required
Neovim API is unavailable, the terminal screen reader retains its ordinary
auto-reading and cursor-tracking behavior. Terminal buffers, external prompts,
terminal reset, alternate-screen exit, and an explicit protocol `end` also
return control to the screen reader.

## Requirements

- Neovim with API level 14 and `nvim_ui_send()` (currently Neovim 0.13/nightly)
- A terminal screen reader implementing the
  [Lector application-accessibility protocol](PROTOCOL.md)

Neovim 0.12 and older remain usable, but `setup()` returns `false` and the
plugin sends no terminal messages because those releases do not expose the
required TUI API. Run `:checkhealth lector` for an explicit compatibility
report.

## Installation

With Neovim's built-in package manager:

```lua
vim.pack.add({
  { src = "https://github.com/n0ot/lector.nvim" },
})

require("lector").setup()
```

With lazy.nvim:

```lua
{
  "n0ot/lector.nvim",
  opts = {},
}
```

The plugin does not define key mappings.

`setup()` is reload-safe: repeated setup and in-process Lua module reloads
replace the previous callbacks, deferred work, commands, and autocmds.

## What it announces

- Buffer names on entry, cursor destinations and unavailable provider-declared
  navigation destinations, editor modes, indentation changes, and Visual
  selections
- Character, word, or line destinations after matching deletion units, put
  summaries, numeric changes, folds, searches, spelling errors, and macro
  recording
- Diagnostics, messages, quickfix and location-list entries, command-line
  editing, native completion, and optional Blink completion details
- Informational floating windows, native context menus, otherwise silent
  window and context-menu closures, and terminal-buffer handoff

Input which may produce transient terminal output temporarily restores the
screen reader's ordinary reading. This preserves Neovim's visual presentation
for `:echo`, errors, hit-enter prompts, pagers, external commands, and similar
interfaces instead of reconstructing or repeating their screen output in Lua.

See [`:help lector.nvim`](doc/lector.txt) for the complete behavior and option
reference.

## Commands

- `:LectorSay {text}` sends application-authored speech.
- `:LectorStatus` reads buffer, cursor, fold, and Visual-selection status.
- `:LectorCompletionDocumentation` reads documentation for the selected
  completion item when available.
- `:LectorAccessibilityEnable` and `:LectorAccessibilityDisable` control the
  plugin explicitly.
- `:checkhealth lector` reports compatibility and current state.

## Configuration

All announcement categories default to `true`:

```lua
require("lector").setup({
  announce_buffers = true,
  announce_cursor = true,
  announce_deletions = true,
  announce_diagnostics = true,
  announce_modes = true,
  announce_messages = true,
  announce_floating_windows = true,
  announce_command_line = true,
  announce_value_changes = true,
  announce_puts = true,
  announce_folds = true,
  announce_search = true,
  announce_quickfix = true,
  announce_recording = true,
  announce_spelling = true,
  announce_completions = true,
  announce_popup_menus = true,
  completion_include_kind = true,
  completion_include_source = true,
  completion_include_position = true,
})
```

Other plugins can publish provider-neutral menu state through `update_menu()`
and `close_menu()`. The core does not need to know which keys or UI provider
changed the selection.

Provider-owned navigation can similarly report its semantic intent without
exposing a mapping. `observe_navigation()` runs an action and requests “no
previous item” or “no next item” only if the editor state remains unchanged:

```lua
local accessibility = require("lector")

accessibility.observe_navigation("next", function()
  provider.goto_next_item()
end)
```

`observe_search()` wraps provider-owned search navigation so match position
is announced from Neovim's resulting search state. Successful cursor and text
changes otherwise come directly from Neovim events and before/after state;
lector.nvim does not interpret normal-mode keys or mapping expansions.

## Testing

Run every headless and real-TUI test with:

```sh
./scripts/test
```

The real-TUI test uses only Python's standard library and exercises Neovim
through a PTY, including the blocking native context-menu loop, transient
command output, and terminal-buffer handoff.

## License and provenance

`lector.nvim` is MIT licensed. Its implementation was written against public
Neovim APIs and does not contain code or configuration from third-party
accessibility implementations.
