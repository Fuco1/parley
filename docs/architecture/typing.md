# Typing into a session

**The buffer's process reads a transcript; it is not the session.** Its standard
input reaches nobody, so input submitted in the buffer has to leave by another
door.

comint has one: bound to a function, `comint-input-sender` is handed what was
submitted instead of it being written to the process. **The pane is where it
goes, and the pane is the only way into a session parley did not start.**

comint also requires a live process — `comint-send-input` errors without one —
which the pipeline satisfies whether or not anything is ever sent to it.

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
