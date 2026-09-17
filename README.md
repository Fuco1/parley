# parley

A conversation view for the Claude Code sessions running on this machine.

Every session writes an append-only JSONL transcript under
`~/.claude/projects/<cwd-slug>/<session-id>.jsonl`, and every session started
inside tmux inherits `TMUX_PANE`. Parley reads the first and types into the
second. It never starts or stops a session — tmux owns those, whether they were
launched by hand or by a fleet runner like [orc](https://github.com/Fuco1/orc).

## What it shows

The conversation, and nothing else. A run of tool calls collapses to one line
saying how many there were. If you want to watch an agent work, read its pane;
parley is for reading what it said.

## Using it

- `M-x parley-switch` picks a live session and opens its conversation. With
  sallet it matches the columns one at a time: `orc` for the name, `/worker-2`
  for the working directory, `%14` for the pane, `:idle` for the status.
- `M-x parley-transcript` opens the same buffer for a session you already have
  in hand. Either way the buffer delivers the transcript from its first byte and
  then follows the file.
- Submitting at the prompt types the message into the session's tmux pane. A
  session outside tmux has no pane and is read only.
- `M-x imenu` in a transcript buffer jumps between the prompts.

## How it works

`docs/architecture/` — one page per subject, starting at
[the page table](docs/architecture/README.md).

## Requirements

- Emacs 28.1, `markdown-mode`, `jq`, `tmux`, Linux (`/proc`)
- [sallet](https://github.com/Fuco1/sallet) is optional; without it the session
  switcher falls back to `completing-read`.
