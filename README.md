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

- Neovim 0.12 or newer, with API level 14 and `nvim_ui_send()`
- A terminal screen reader implementing the
  [Lector application-accessibility protocol](PROTOCOL.md)

Neovim 0.11 and older remain usable, but `setup()` returns `false` and the
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
  summaries, numeric changes, folds, searches, spelling errors and suggestion
  lists, and macro recording
- Diagnostics, messages, quickfix and location-list entries, command-line
  editing, native completion, and optional Blink completion details
- Informational floating windows, native context menus, and terminal-buffer
  handoff

Lector suppresses terminal heuristics only while it owns a predictable editor
context: Normal, operator-pending, Insert, Replace, Visual, Select, and
semantic command-line editing. Native output such as `z=`, `[I`, `g<`, tag
selection, keyword lookup, hit-enter output, and pagers enables automatic
reading before it renders while leaving cursor tracking suppressed. Focused
floating UIs, prompt buffers, `vim.ui.select()`, `vim.ui.input()`, terminal
jobs, and unknown future modes instead restore the screen reader's complete
ordinary policy. Informational non-focused floats are announced semantically.
Ordinary movement, editing, and entry into Visual mode never enable automatic
reading.

See [`:help lector.nvim`](doc/lector.txt) for the complete behavior and option
reference.

## Commands

- `:LectorSay {text}` sends application-authored speech.
- `:LectorStatus` reads buffer, cursor, fold, and Visual-selection status.
- `:LectorCompletionDocumentation` reads documentation for the selected
  completion item when available.
- `:LectorDiagnostic` reads the diagnostic at the cursor, or the most severe
  diagnostic on the current line when the cursor is outside every diagnostic
  range. Its Lua equivalent is
  `require("lector").announce_current_diagnostic()`.
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
A command line which remains open beyond its input transaction is announced
as interactive editor state. One which enters and leaves within the same
transaction is treated as an implementation detail. Opaque Lua mapping
callbacks temporarily allow automatic output reading while keeping cursor
tracking suppressed; semantic policy resumes when the callback returns, or
remains yielded if Neovim stops at a pager or hit-enter prompt. If the callback
instead enters a focused floating or prompt UI, lector.nvim sends protocol
`end` and leaves both terminal reading features available until editor focus
returns.

The plugin yields its complete policy while `vim.ui.select()` or
`vim.ui.input()` is active. This keeps default and third-party providers—and
LSP workflows such as code actions which use them—readable without replacing
their visual UI.

## Testing

Run every headless and real-TUI test with:

```sh
./scripts/test
```

The real-TUI tests use only Python's standard library and exercise Neovim
through a PTY, including a deterministic LSP server, the blocking native
context-menu loop, selectors, transient command output, and terminal-buffer
handoff.

## Architecture

`lua/lector/init.lua` coordinates setup, teardown, autocmds, and cross-feature
policy. Cohesive behavior lives in smaller modules:

- `protocol.lua` owns APC framing and speech sanitization.
- `policy.lua` decides whether the editor or an external interactive UI owns
  screen-reader policy.
- `transient_output.lua` recognizes native commands which render output
  without passing through an Ex-command boundary.
- `editor.lua` provides stateless editor snapshots, text inspection, and diffs.
- `edits.lua` classifies text effects and owns edit-observation state.
- `providers.lua` owns provider navigation and search transactions.
- `menus.lua`, `completion.lua`, and `context_menu.lua` separate menu state,
  completion adapters, and the native context-menu interaction loop.

Stateful modules are factories. Every loaded lector.nvim instance receives new
feature objects, while cached module definitions remain safe across in-process
reloads.

## License and provenance

`lector.nvim` is MIT licensed. Its implementation was written against public
Neovim APIs and does not contain code or configuration from third-party
accessibility implementations.
