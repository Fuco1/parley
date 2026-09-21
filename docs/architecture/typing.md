# Typing into a session

**The buffer's process reads a transcript; it is not the session.** Its standard
input reaches nobody, so input submitted in the buffer has to leave by another
door.

comint has one: bound to a function, `comint-input-sender` is handed what was
submitted instead of it being written to the process. **The pane is where it
goes, and the pane is the only way into a session parley did not start.**

comint also requires a live process — `comint-send-input` errors without one —
which the pipeline satisfies whether or not anything is ever sent to it.

## The prompt holds a block, and not a line

**The input zone is a block the operator may edit before he sends it**: a line
opened inside it with `S-<return>`, a word changed on the line above, point
left wherever the editing ended.

**What makes the whole of it the input is that comint is not line oriented on
the way out.** `comint-eol-on-send` moves point to `field-end` before
`comint-send-input` reads, and unsent input after the process mark carries no
`field` property — so `field-end` is the end of the buffer however many
newlines lie between it and point, and the input is everything from the process
mark on. Measured against Emacs 28.2: three lines standing at the prompt,
`comint-send-input` called with point on the second of them, and
`comint-input-sender` handed all three as one string.

A block therefore needs no mechanism of parley's own. It reaches the sender as
one string with newlines in it, which is the paste shape below, and so reaches
the session as one message.

## The input zone is marked, and the mark is shown rather than written

**Nothing else in the buffer says where typing begins.** The pipeline emits no
prompt, so there is no prompt string in the buffer at all and the operator's
unsent text is the tail of a buffer whose tail is otherwise conversation. It
moves under him as well: the transcript is followed, so output arrives while he
types, and comint inserts it at the process mark and moves the mark past what it
inserted.

**What marks it is an overlay from the process mark to the end of the buffer.**
A text property cannot mark the zone, because the zone holds no text until
something is typed — and an empty zone is when he most needs to see where it is.
An overlay has a position whether or not there is text under it.

**Nothing the overlay shows may be buffer text.** `comint-send-input` sends
`(buffer-substring (process-mark proc) (field-end))`, so a mark written into the
buffer after that mark is a mark typed into the session. The `> ` at the head of
the zone is the overlay's `before-string`: shown at a position where the buffer
holds nothing, and it is the `> ` every turn of his is quoted with because what
he is typing is the turn it is about to be. It opens with the blank line every
block of conversation opens with, so the zone stands apart from the turn above
it the way two turns do, and that line is bare because it belongs to neither.
The band under it is a face of the zone's own, so his next turn stands apart
from the turns it will join — and the
run of lines a past turn is found by reads the face on buffer text at the head
of a line, which this mark is not, so no line of the zone is taken for a turn
already sent.

**`line-prefix` is not what shows it**, though it is the right shape — it puts
text at the head of a line on screen without putting it in the buffer. It is
read off the character at the head of the line, and an empty overlay covers no
character. Measured on Emacs 28.2 in a 191 column terminal: an empty overlay
carrying `line-prefix` and a face shows neither of them, which loses exactly the
case the mark exists for.

**The band reaches the window edge on the zone's last line by a stretched
space.** A background is a band only if the face extends it
([transcript](transcript.md)), and what `:extend` paints from is the newline
that ends a line. Every line of the zone ends in one except the last, which is
the last line of the buffer: measured the same way, the colour there stops at
the last character typed. That line is painted by a space carrying
`(space :align-to right)`, shown after the zone as the overlay's `after-string`.
Its `cursor` property is what keeps point drawn at the head of that space
rather than at the far end of it, where the operator would be watching his
cursor stand at the window edge as he typed.

**The overlay is put back after every output**, since the mark it starts at has
just moved; `comint-output-filter-functions` is where that is known, and
`comint-send-input` runs the same hook with an empty string once the sender has
returned, so the block a send leaves behind is covered by it too. It is also
placed when the process is started: a session whose transcript is still empty
renders nothing at all, and the first message of a session would be typed into a
buffer with nothing in it to type at.

**Marking the zone writes nothing into the buffer, and the line a run of tool
calls collapses to depends on that.** That line is rewritten by comparing the
two lines before the process mark against the block last written and taking
them back out only if they match ([transcript](transcript.md)); an overlay
leaves the comparison reading what it read before.

## Two send shapes, and the newline is what chooses

**A single line goes as one `send-keys -l`**, where `-l` is what stops tmux
reading the text as key names, with an `Enter` after it to submit.

**Anything with a newline in it goes through a paste buffer instead.**
`send-keys` would type the newline and the CLI would submit at it, so a
three-line message would arrive as three messages. `paste-buffer -p` wraps the
text in a bracketed paste, which the CLI takes as one paste and so as one
message however many lines it has.

The text reaches tmux on standard input, so a paste is never an argument vector
however long it is. The paste buffer is named and deleted on the way out, so the
operator's own paste stack is where he left it.

**A trailing semicolon has to be escaped.** tmux reads one at the end of an
argument as the separator between two of its own commands and drops it, leaving
a backslash before it as the way to write one. A line of SQL is a line that ends
in a semicolon. Measured against tmux 3.2a: `send-keys -l -- 'foo;'` arrives as
`foo`, and a semicolon in the middle of an argument is untouched.

**What tmux says is raised when it exits non-zero.** The usual reason is that
the pane has gone — the session was quit, or its window closed — and a message
that vanished quietly would leave the operator waiting for an answer to
something nobody received.

## A session with no pane is read only

A session started outside tmux has no pane, and so does a background agent
([discovery](discovery.md)). Neither can be typed into at all.

**The switcher marks such a session in the row it lists it by**, because the
choice of which session to open is the last moment at which the operator has
written nothing yet. Hiding them would cost him a conversation he can read, and
the transcript of one is as readable as any other.

**The mark is read from the pane being nil and not from the reported kind.** The
pane is what a send needs; a session outside tmux has none either, and `kind`
says nothing about that one.

**Submitting to a session with no pane is an error naming it**, which is what a
record reached any other way — `parley-transcript` with a record in hand — runs
into, and beats a silent no-op wherever it comes from.

## What comint echoes is rewritten into the shape the renderer emits

`comint-send-input` puts what the operator submitted into the buffer itself,
before the sender runs and without passing the render pass — so it lands with
no blank line before it, no quote, and comint's `comint-highlight-input` where
every other turn of his carries `parley-user`. **The sender replaces that text
with the block a `user` record renders to**, and one function writes both, so
his turn has one shape however it reached the buffer and the two cannot drift
apart.

**It is rewritten rather than deleted and left to the transcript to render.**
The session writes the message to its transcript seconds later, and minutes
later if it was busy when it arrived; a buffer that showed nothing until then
would leave the operator unable to tell a message he had sent from one that
went nowhere.

**The rewrite belongs in the sender and not on `comint-input-filter-functions`.**
comint puts its own properties on the input after that hook has run, so a block
written there would be highlighted as input anyway. By the time the sender runs
the text carries them, and deleting it takes them with it.

It is also where such a prompt enters the imenu index, because it is the one
prompt the render pass never sees.

## The echo has to be deduplicated

The session writes the same message to its own transcript seconds later.
Without a guard every prompt appears twice.

**The guard is every message sent from this buffer that has not come back, and
one entry of it is spent on the first user message that matches.** A second
message saying the very same thing was typed at the pane, or submitted here
twice, and is shown; so is everything else typed at the pane, which matches
nothing sent from here.

**Every send is outstanding and not only the last.** A session that is working
holds everything submitted at it until the turn it is on has finished, so the
operator can have several messages in flight and the transcript delivers them
together once that turn ends.

**There is no bound on how late the transcript's copy may be**, because there
is no bound on how late it comes — minutes, if the turn that was running was
long — and the message has to appear exactly once whenever it lands. What that
costs is a message that never reaches the transcript at all, which leaves its
entry standing: the next message of the same text typed at the pane is then
taken for it and dropped.

## A past turn is sent again as it was written

**`RET` with point on a turn the operator took sends that turn to the pane**,
with the `> ` the renderer put on each of its lines taken off, and all of it: a
prompt of four lines goes back as four lines and not as the line point stood
on.

**A turn is the run of lines whose head carries `parley-user-marker`.** One
function quotes every turn of his whichever door it reached the buffer by, so
the marked `> ` heads a turn the transcript delivered and one submitted here
alike — where `field`, which `comint-get-old-input-default` branches on, is
`output` on the first and absent on the second, and each branch gives its own
wrong answer. Measured against Emacs 28.2 over the test fixture with point in
the rendered turn `what is here`, the default returns `> what is here` on the
delivered one and `"\n> what is here\n"` on the one submitted here.

**The face and not the `> ` itself is what says whose turn it is.** An
assistant turn quoting something is markdown with `> ` at the front of a line
too, and that quote is markdown-mode's to hide rather than the renderer's to
strip.

**Anything that is not such a run is refused with a message.** An assistant
turn and the one line a run of tool calls collapsed to are what reach that
branch, and neither is the operator's to send again; a line of somebody else's
markdown typed into a live session is worse than an error saying nothing went.
