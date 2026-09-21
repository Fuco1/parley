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

## The pane id is for typing, and where the pane is for showing

**A pane id resolves to nothing the operator can act on.** `%15` says nothing
about where that pane is, and its `%` reads as a stray format directive wherever
it is displayed. What locates a session is its tmux session, window and pane
index — `orc-orc-b3743fe3:3.1` — so that is what the displayed forms of a
session carry, and `tmux list-panes` is what maps a pane id to it. **The pane id
stays on the record** for `send-keys -t`, which is the only thing that takes it.

**One `list-panes -a` resolves the whole list.** It prints every pane on the
server, so the alternative — a `display-message -t <pane>` per session — would
cost a dozen subprocesses to discover a dozen sessions instead of one. The map
is asked for when the first tag needs it and dropped whenever the session list
is discovered again, so what is shown beside a list is no older than the list.

**A pane tmux does not report has no location**, which a session can outlive its
window by, and a session with no pane never had one. Neither is an error: what
is lost is where to show the session, not the transcript it is read from.

## The transcript path is derived, not searched for

Claude Code names the project directory after the session's working directory
with every character outside `[A-Za-z0-9]` replaced by a dash, so `/home/me/a.b`
keeps its transcripts in `-home-me-a-b`. Building the path is one substitution
and needs no directory scan.

Nothing here reads the file. What the path is for belongs to
[transcript](transcript.md).

## A live status is read from the session's own file

**Every session writes what it is doing to `~/.claude/sessions/<pid>.json`**,
beside the `sessionId` it is running, its `cwd` and a `procStart`. The pid is
what a record already carries, so nothing has to be searched for, and one read
of some 600 bytes answers every question parley asks about that session.

**The status is four-valued: working, waiting, idle and unknown.** The file says
`busy`, `waiting` or `idle`, and **waiting is not a slower kind of idle**: an
idle session has finished and will read what is typed at it next, a waiting one
has stopped and cannot go on until the operator answers it. Collapsing the two
would draw the state that most needs him as the state that needs nothing from
him. A waiting session's file carries a `waitingFor` as well, and the one
observed on this machine reads `input needed`; one sample is no vocabulary, so
that field is not read and the state is the whole of what is held.

**Unknown is never working.** A status parley does not know, a file that is not
there, a file whose `sessionId` is not the one being asked about and a session
whose process is gone all read as unknown. Everything downstream draws working
as motion, and motion that never stops is worse than no indicator at all.

**The file alone does not say the session died**, and a session killed while
busy leaves one saying `busy` with nothing in it to say otherwise. Two
comparisons settle it on the same read, and both are needed. The `sessionId` has
to be the one being asked about, a pane being reused and the next session in it
being a different conversation. And the `procStart` has to equal the start time
`/proc` reports for that pid — field 22 of `/proc/<pid>/stat`, equal on all 14
of the live pids the directory held when it was checked — because `/proc/<pid>`
existing on its own reads `busy` forever the moment an unrelated process
inherits the pid. A stale file is not hypothetical: a session with no process
left sat on disk saying `idle`.

### The file rather than `claude agents --json`

`claude agents --json` reads these same files, and the liveness filter is the
whole of what it adds. Measured on this machine on 2026-09-21, over a directory
of 14 session files: it costs **0.38 s a call** over three calls, and it
reported **13 live sessions** against those 14 files. Emacs has one thread, so a
second of reading a conversation that shelled out for a status would be a third
of a second not drawing anything — for a filter the two comparisons above make
anyway.

### A tick, and no watch

**The file carries no heartbeat.** It is written in place when a session changes
what it is doing and not otherwise: `inotifywait` over the directory for 75 s
saw six `MODIFY` events across two of its fourteen files, each an
`OPEN`/`MODIFY`/`CLOSE_WRITE` on the file itself, and no create, no rename and
no replacement. One session sat at `busy` with a status **2.5 hours** old while
its transcript had been appended to 8 minutes earlier, and another with one
452 s old while its transcript was being appended to as the measurement was
taken. **So the file is what a session says about itself until it says
otherwise**, and a reader of it is never behind the session by more than its own
interval.

**Nothing but a buffer someone is looking at consumes a status.** The switcher
is current by construction — `parley-sessions` runs `claude agents --json` on
every invocation and every row is built from what it returned — and nothing else
in the package reads one. So what a file watch would buy over a tick is the
status of a buffer no window is showing, which is worth nothing to anybody. The
buffer reads the file itself, about once a second and only while a window is
showing it, on a tick of its own — so killing the buffer is the whole of
stopping it.

## Sessions are listed waiting first, then idle, then busy

**The order is what each status asks of the operator.** A waiting session is
stopped and cannot go on until he answers it; an idle one is not stopped — it
has finished and will read what he types next. Both are open to him and only
one of them is blocked on him, so waiting leads and idle follows. A busy
session needs nothing from him at all and comes last, and a status parley does
not name sorts after every status it does — including the nil `claude agents`
reports for a session it knows no status for.

**The order is over the values a status is read as**, not over a second list of
the strings a session writes. `claude agents` reports the status out of the
same file the status reader reads, so a record's status is spelled the way that
file spells it and is mapped through the reader's table before it is ranked —
otherwise `waiting` is written in two places in one file that have to agree
about how Claude Code spells it.

**One sorted list is what both frontends list**, the switcher's rows and the
minibuffer reader alike, so neither can put a session where the other does not.

## Nothing in a record is guaranteed

`claude agents` reports a name for most sessions and not for all, and a status
for most and not for all. **The placeholders are chosen once, where the record
is turned into columns, rather than by each thing that displays one** — two
frontends that each invent their own would disagree about a session neither of
them can describe.

**A name is not unique.** Two sessions in sibling worktrees come back under one,
and a background agent is named after its prompt. So a switcher row and a buffer
name both carry a tag instead, and the tag is the session id with its pane's
location before it when there is one. A session with no location is tagged by
its id alone.

**The location alone is not enough**, though it is what the operator recognises
a session by and what he searches the switcher with: suspend the session running
in a pane, start another there, and `claude agents` reports two live sessions in
one location.

**The id goes in whole and never as a prefix.** Two ids can share one, and two
sessions sharing a name, a location and a prefix would be two the tag could not
tell apart at all — which is the one thing it exists to do. A long tag is the
price, and it is the last column of a row and the tail of a buffer name.

## A row is coloured where it is built, and the status by its value

**The faces go on the row itself, beside the columns.** Both frontends draw
that one string — sallet renders it, and `completing-read` completes over it —
and `completing-read` displays a face on a candidate as readily as a sallet
buffer does. A face the picker owned would leave the minibuffer fallback plain,
which is the frontend a machine without sallet has.

**The status is coloured by what it says**, and the three the operator scans a
dozen rows for — idle, busy, waiting — are three colours rather than one. A
single colour for "status" tells him a row has one, which he knew; picking the
busy session out then costs him a read of every row, which is what colour was
for.

**The read only mark has no column of its own.** A column for it is blank on
every session that has a pane, which is nearly all of them, and what it says is
about the status: a session that cannot be typed into is idle in a way that
matters. So it is drawn after the status, inside that column.

**A name past its column's width is drawn whole.** It pushes the columns after
it along that one row, and the alternative cuts the handle the operator picks a
session by — two sessions in sibling worktrees come back under one name, and a
background agent is named after its prompt, so the tail of a name is where the
difference often is.

**The status is the one column cut to its width.** It holds one of a handful of
values — parley names three and `claude agents` may report a fourth tomorrow —
so a cut there loses nothing anyone picks a session by, while a status running
long would carry every column after it out of line on that row. The name and
the working directory are the handles, and neither is ever cut.

**A column is measured as it is drawn.** A width in characters is not a width
on screen: a name in a script drawn two columns to the glyph would put that
row's status past every other row's, and the columns exist to be read down.

**A column's face covers the column and not only the value in it**, so a face
given a background colours a column rather than a stripe as long as whatever
happens to be in it.
