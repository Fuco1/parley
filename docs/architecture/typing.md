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
([discovery](discovery.md)). Neither can be typed into at all, and **submitting
is where the operator finds that out**: an error naming the session beats a
silent no-op.

## The echo has to be deduplicated

comint puts what the operator submitted into the buffer itself, and the session
writes the same message to its transcript seconds later. Without a guard every
prompt appears twice.

**The guard is the last string sent from this buffer, and it is spent on the
first user message that matches it.** A second message saying the very same
thing was typed at the pane and is shown; so is everything else typed at the
pane, which matches nothing sent from here.

**The window is a bound on how late the transcript's copy may be.** A session
that was busy when the message arrived holds the input until the turn it was
working on has finished and only then writes it, minutes later if the turn was
long. Widening the window makes that case rarer at the cost of swallowing a
message genuinely typed twice — which is why it is the operator's to set rather
than a constant.

**What comint inserted is not what the render pass would have inserted.** It
carries comint's own input face, no blank line and no quote, so the operator's
line reads as neither of the two things the renderer emits — and because the
transcript's properly rendered copy is the one being dropped, that is the only
form his line ever takes.
