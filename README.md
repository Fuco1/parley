# parley

A conversation view for the Claude Code and Codex sessions running on this
machine.

Every Claude Code session writes an append-only JSONL transcript under
`~/.claude/projects/<cwd-slug>/<session-id>.jsonl`, and every session started
inside tmux inherits `TMUX_PANE`. Parley reads the first and types into the
second. A Codex session running in tmux is found by the thread id its TUI
writes into the pane's title, and read from that thread's rollout under
`~/.codex/sessions`. It never starts a session, which is the job of whatever
launched it in tmux — a hand or a fleet runner like
[orc](https://github.com/Fuco1/orc) — and it ends one only by typing `/exit`
into its pane.

## What it shows

The conversation, and nothing else. A run of tool calls collapses to one line
saying how many there were. If you want to watch an agent work, read its pane;
parley is for reading what it said.

## Using it

- `M-x parley-switch` picks a live session and opens its conversation. The
  sessions waiting on you are listed first, then the idle ones, then the busy.
  With sallet it matches the columns one at a time: `orc` for the name,
  `@3.1` for the window and pane a session is in, `:idle` for the status. Every column is coloured apart and
  the status by what it says, so the busy session and the one waiting on you
  are seen rather than read for. A session you already have a buffer for has
  its name in a colour of its own.
- `M-x parley-transcript` opens the same buffer for a session you already have
  in hand. Either way the buffer delivers the transcript from its first byte and
  then follows the file.
- Submitting at the prompt types the message into the session's tmux pane.
  `S-<return>` opens another line at the prompt without submitting anything, and
  the whole block goes as one message wherever point stands in it. A session
  outside tmux has no pane and is read only, and the switcher marks it `[RO]`
  beside the status.
- `RET` on a turn you took earlier sends that turn again, all of it and without
  the quote the view draws it with. On anything else — an agent's turn, the
  line a run of tool calls collapsed to — it sends nothing and says so.
- `(parley-transcript-follow-pane PANE)` opens the conversation of the session
  a program has just started in tmux pane `PANE`, once it appears there.
  orc-mode calls it for a crew session it starts in a tmux window.
- `M-x imenu` in a transcript buffer jumps between the prompts, and `C-c C-p`
  and `C-c C-n` step to the previous and the next one.
- `M-x parley-transcript-exit` in a transcript buffer ends its session by
  typing `/exit` into the pane. `M-x parley-transcript-exit-and-archive` does
  the same and then, once the session's process has ended, archives it: a
  Claude Code session with `ccarchive archive`, and a Codex session with
  `codex archive`. Both refuse a session that is not idle, and both leave the
  buffer open.

## How it works

The Info manual `parley`, one node per subject, which the package manager
builds from [`doc/parley.texi`](doc/parley.texi). Once the package is installed
`C-h i` lists it, and `M-x info-display-manual RET parley` opens it.

## Requirements

- Emacs 28.1, `markdown-mode`, `jq`, `tmux`, Linux (`/proc`)
- For Codex sessions, this under `[tui]` in `~/.codex/config.toml`, which puts
  the thread id in the pane's title; without it no Codex session is listed:

  ```toml
  terminal_title = ["run-state", "spinner", "thread-id"]
  ```
- [sallet](https://github.com/Fuco1/sallet) is optional; without it the session
  switcher falls back to `completing-read`.
- `ccarchive` is optional, and only `parley-transcript-exit-and-archive` needs
  it, to archive a Claude Code session. It archives a Codex session with
  `codex`.
