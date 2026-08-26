# Lector application-accessibility protocol, version 1

Full-screen terminal applications know semantic facts which a terminal screen
reader cannot reliably infer from cursor movement and changed cells. This
one-way protocol lets an application temporarily suppress selected automatic
heuristics and provide semantic speech without identifying itself to the
screen reader.

## Envelope

Messages use a seven-bit Application Program Command (APC) envelope:

```text
ESC _ Lector;A11y;1;<command> ESC \
```

`Lector;A11y` is the protocol namespace and `1` is the protocol version. A
consumer must claim only a complete, exact message in a version it supports.
Unknown, malformed, incomplete, and oversized messages have no protocol
effect.

## Commands

```text
set;auto=<0|1>;cursor=<0|1>
say;<hex-encoded UTF-8>
line;indent=<0..65535>;<hex-encoded UTF-8>
end
```

`set` always states both policy axes. `0` asks the terminal screen reader to
suppress that automatic behavior; `1` leaves it available. `say` and `line` do
not change policy implicitly.

`say` carries ordinary application-authored speech. `line` identifies semantic
line content and provides its indentation in display columns. The consumer
decides whether and how to report indentation according to the user's own
settings.

The text payload is lowercase or uppercase hexadecimal representing UTF-8.
Version 1 limits decoded speech to 2,000 bytes and rejects control characters.

`end` immediately restores the consumer's ordinary policy for that terminal
view.

## Consumer requirements

A compatible terminal screen reader should:

1. Scope state and speech to the exact terminal view or tmux pane which
   received the message.
2. Apply automatic-reading and cursor-tracking policy independently. Cursor
   suppression includes inferred Backspace and Delete announcements.
3. Route requested speech through normal user settings and focus policy.
4. Discard speech from hidden or inactive panes rather than replaying it after
   a pane switch.
5. Restore defaults on `end`, alternate-screen exit, RIS, DECSTR, view
   replacement, PTY teardown, or equivalent terminal-view teardown.
6. Bound incomplete control-sequence memory and queued speech.

Ordinary drawing operations are not session resets. SGR reset, erase display,
cursor addressing, and routine screen redraws must not end the session.

The protocol is intentionally one-way in version 1. It has no authentication,
heartbeat, acknowledgement, or capability query. Applications should re-send
their complete `set` policy when they regain or reinitialize the terminal.

## Producer guidance

Send a complete `set` before semantic speech. Reassert it after resume, focus
regain, shell return, UI attachment, or any operation which may have reset the
terminal. Send `end` before yielding to a nested terminal application and while
leaving or suspending the full-screen interface.

Applications must remain useful when the consumer ignores every protocol
message. Protocol output must not replace or remove visual information.

APC is used because these messages are private application-to-terminal control
data. Version 1 does not assign meanings to OSC 200, 201, or 202.
