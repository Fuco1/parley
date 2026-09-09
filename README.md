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

## How it works

- `claude agents --json` lists live sessions. Headless `claude -p` children are
  filtered out by checking whether `/proc/<pid>/fd/0` is a tty.
- `TMUX_PANE` from `/proc/<pid>/environ` is the pane id, which is exactly what
  `tmux send-keys -t` takes. No naming convention, no cooperation from whatever
  launched the session.
- The buffer is a comint buffer whose process is
  `tail -c +1 -F <transcript> | jq -c --unbuffered '…'`. Starting at byte zero
  means the same process delivers history and then follows, with no gap. jq
  drops the tool payloads before they ever reach Emacs.
- Assistant text is fontified by markdown-mode in a side buffer and inserted
  with `font-lock-face`. A plain `face` property does not survive comint's
  font-lock pass.

## Status

Early. Nothing works yet.

## Requirements

- Emacs 28.1, `markdown-mode`, `jq`, `tmux`, Linux (`/proc`)
- [sallet](https://github.com/Fuco1/sallet) is optional; without it the session
  switcher falls back to `completing-read`.
