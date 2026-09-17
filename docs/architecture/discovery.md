# Discovery

**parley talks to sessions it did not start, and needs no cooperation from
whatever did.** A session launched by hand and one launched by a fleet runner
are indistinguishable at this level, which is why this is its own package.

Two facts make that possible, and everything here rests on them:

- every Claude Code session appends its transcript to
  `~/.claude/projects/<cwd-slug>/<session-id>.jsonl`, and
- every session started inside tmux inherits `TMUX_PANE`, which is exactly what
  `tmux send-keys -t` takes.

parley reads the first and writes to the second. It never starts or stops a
session — tmux owns that.

## Standard input is the discriminator, not the reported kind

`claude agents --json` needs no terminal and prints one entry per live session.
Its `kind` field does not say what parley needs to know: a headless lane running
`claude -p --input-format stream-json` is reported as interactive too, so a list
built on `kind` would offer the operator sessions that no one is typing at and
that will never read what he sends.

**What holds is `/proc/<pid>/fd/0`.** A session someone is typing at has a
terminal there — a `/dev/pts/N`. A headless child has a pipe. That is a property
of how the process was started rather than a claim the process makes about
itself, which is why it is the one parley trusts.

**The reported kind is carried on the record and not believed.** It costs
nothing to pass through and it is there for whoever wants to make a decision
that `kind` really does answer.

The discriminator does not exclude everything it might be expected to. A
background agent dispatched from the agent view keeps the dispatching terminal
on `fd 0`, so it passes, and it carries no `TMUX_PANE` — it is readable and
cannot be typed into.

## The pane comes from the environment, not from a naming convention

tmux exports `TMUX_PANE` into the pane and every descendant inherits it, so the
value is there whoever started the session, in the `%N` form `send-keys -t`
takes. `/proc/<pid>/environ` is a NUL-separated block and the entry is read out
of it directly.

**A session outside tmux has no pane and is read only.** So is a background
agent. The record carries nil there rather than pretending, and what that costs
the operator belongs to [typing](typing.md).

## The transcript path is derived, not searched for

Claude Code names the project directory after the session's working directory
with every character outside `[A-Za-z0-9]` replaced by a dash, so `/home/me/a.b`
keeps its transcripts in `-home-me-a-b`. Building the path is one substitution
and needs no directory scan.

Nothing here reads the file. What the path is for belongs to
[transcript](transcript.md).

## Nothing in a record is guaranteed

`claude agents` reports a name for most sessions and not for all, and a status
for most and not for all. **The placeholders are chosen once, where the record
is turned into columns, rather than by each thing that displays one** — two
frontends that each invent their own would disagree about a session neither of
them can describe.

**A name is not unique.** Two sessions in sibling worktrees come back under one,
and a background agent is named after its prompt. So a switcher row and a buffer
name both carry a tag instead, and the tag is the session id with the pane
before it when there is one.

**The pane alone is not enough**, though it is what the operator recognises a
session by and what he searches the switcher with: suspend the session running
in a pane, start another there, and `claude agents` reports two live sessions in
one pane.

**The id goes in whole and never as a prefix.** Two ids can share one, and two
sessions sharing a name, a pane and a prefix would be two the tag could not tell
apart at all — which is the one thing it exists to do. A long tag is the price,
and it is the last column of a row and the tail of a buffer name.
