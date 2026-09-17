# The transcript

A session's transcript is an append-only JSONL file. The buffer that shows the
session is a comint buffer whose process reads it.

## One process, not two

`tail -c +1 -F FILE` starts at byte zero and then follows, so the history and
every later append come down the same pipe.

**Reading the file and then starting a `tail -n0` loses whatever is appended
between the read finishing and the tail starting, and there is no way to notice
that it did.** That is the whole argument for the shape: a gap in a conversation
view is invisible, so the design has to make one impossible rather than make one
detectable.

`-F` rather than `-f` because a session that has not spoken yet has no
transcript to open. tail says so on stderr, which shares the buffer, and picks
the file up when it appears — so a line in the buffer is not always JSON, and
the render pass has to survive one that is not.

## jq does the filtering, because Emacs is single threaded

Measured on a 26 MB transcript: 23502 lines in, 8651 of them a message, and a
pure Elisp pass over all of them costs 2.72 s of blocked UI. The same transcript
through the pipeline projects to 5300 lines and 1.3 MB, which settle in the
buffer in 5.2 s — and the tool payloads, which are the bulk of those 26 MB,
never enter the Emacs process at all.

**The projection is built from scratch rather than pruned.** A tool result lives
in a `tool_result` block and again in a top-level `toolUseResult` field;
emitting only the fields parley renders means neither is ever read, where a
filter that deleted the payloads would have to know every place one can hide.

**A message that renders to nothing is dropped rather than emitted empty**,
which is what becomes of a `tool_result` turn and of an assistant turn that was
only thinking.

**jq block buffers a pipe**, and a live session whose output waits for a buffer
to fill looks frozen. Which flags hold that off, and what each of them costs,
is the business of the call that builds the pipeline; the docstring of
`parley-transcript--command` carries them.

**The pipeline runs on a pipe and not a pty**, bound at the call rather than
inherited, for two measured reasons. To a terminal jq line buffers on its own,
so on a pty the flag that stops it block buffering is dead and its absence could
not be noticed until something else changed. And a pipe is much the faster of
the two: the 26 MB transcript settles in 4.5 s against 10.1 s, which is the cost
of a terminal line discipline between jq and Emacs.

Killing the buffer stops the pipeline either way. Emacs puts the process in a
group of its own whichever it allocates and signals the group, so `sh`, `tail`
and `jq` go together.

## The objects become conversation on the way in

The render pass runs on `comint-preoutput-filter-functions`, so a projected
object is replaced by the text it renders to before comint inserts anything —
rather than inserted and then rewritten in place.

What arrives holds whole lines only by luck, so the tail of a chunk after the
last newline is held until the rest of that line arrives.

**An assistant turn is markdown and is fontified as markdown. The operator's own
turn is quoted and otherwise left alone** — what he typed at a terminal is not
markdown, and fontifying it as though it were would invent emphasis he never
wrote.

### A turn of the operator's is found by its background

His own turn is what he looks for in a buffer that is markdown from top to
bottom, and a weight is not something the eye lands on among prose. So a turn
carries a background — and **a background is a band only if the face extends
it**. `:extend` is unspecified on a face that sets `:background` alone, and the
colour then stops at the last character of each line; what it is painted from
past that character is the newline ending the line, so the newline that closes
a turn's block carries the face as well as the text before it.

**The `> ` at the head of each line takes a face of its own**, so a theme can
dim the mark the renderer added without dimming the words the operator wrote.
It inherits the turn's face before anything else, so the band under it is
unbroken.

### Fontification happens in another buffer, twice over

Markdown fontification is not a set of keywords that can be lifted out of
markdown-mode: fences and inline code are found by its syntax table and its
`syntax-propertize-function`, so the keywords alone would give a broken subset.
Font lock in the transcript buffer itself would refontify the whole conversation
on every append.

**One reused buffer, not a temporary one per message.** Turning markdown-mode on
costs about as much as fontifying a paragraph does. Measured over 300 messages
of a paragraph each: 0.84 s with a temporary buffer per message against 0.44 s
with one buffer reused.

**The markdown is rendered with its markup hidden.** The operator wants to read
the answer and not the asterisks around a bold word or the markers around a
fence, so markdown-mode's markup hiding is on in the fontify buffer. Two
properties carry it: `invisible markdown-markup`, which the emphasis, code,
fence and link markers get, and `display`, which hides a heading's `#` and turns
a blockquote's `>`, a list bullet and a horizontal rule into a glyph. Hiding is
the reading buffer's decision and not the property's, so the transcript buffer
names `markdown-markup` in its invisibility spec.

**Three properties are copied onto a clean string and nothing else is:
`font-lock-face`, `invisible` and `display`.** A selected set rather than the
buffer string taken whole, because markdown-mode leaves `markdown-heading`,
`font-lock-multiline` and a `syntax-table` property behind in the buffer it
fontifies in, and the transcript buffer has business with none of them — a
`syntax-table` property in a comint buffer least of all.

**A `face` property must not survive.** comint sets `font-lock-defaults` to
`(nil t)`, which is not nil, so global font lock turns font lock on in the
transcript buffer with no keywords at all — where the only thing it can do is
strip, and `face` is exactly what it removes. `font-lock-face` survives it, and
is what comint itself puts on its prompt and its input. So do `invisible` and
`display`, neither of which is in `font-lock-extra-managed-props` — which is
what the hiding rests on, and is asserted in a live transcript buffer.

`ansi-color-process-output` is taken out of the buffer's output filters for the
same reason the pipeline refuses colour at the source: measured over the 26 MB
transcript not one escape byte reaches the buffer, and scanning the 1.3 MB for
them costs 2.4 s of the 6.9 s that history takes to settle.

## A run of tool calls is one line

The operator wants the conversation. The calls an agent made on its way to an
answer are worth one line however many there were, and the pane is still there
for anyone who wants to watch the work.

**The count cannot be held back until the run ends.** A line that waited for the
final count would appear only once the agent had stopped working, which is
exactly the frozen session the pipeline's buffering flags exist to prevent. So
the line is written as soon as the run starts and rewritten as the run grows:
the old one is taken back out and a new one put in.

**Only if it is still there to take.** The operator can type into this buffer,
and comint moves the process mark past what he typed, so what sits at the end
may not be that line at all. Text that is not the block the run emitted is left
alone and the count starts over, which is the truth about the buffer — something
else is now between the calls.

Anything a turn said ends the run before it, and the calls that turn went on to
make carry into the next one. A turn that said nothing and only called tools is
therefore not a break in a run.

## The index over the prompts is recorded, never parsed

Navigating a long conversation means jumping between its prompts, which is what
imenu is for.

**The index is built as messages are inserted, because that is where a message's
position is already known.** The render pass has the record in hand and the
offset of the block it made; going back over the finished buffer would mean
parsing rendered text into the structure that was in hand a moment earlier.

**Positions are markers, not the numbers they were.** This buffer is deleted
from as well as appended to — the run line at the end goes whenever its run
grows — and the operator can edit in it himself. An entry has to keep pointing
at its prompt through all of that, or say that its prompt is gone, which is what
a second marker at the end of the label's line is for: deleting that line is
what brings the two together and nothing else does.

**A label is the prompt's first line that says anything.** How many messages ago
it was is no help to the operator, so no counter goes in one. The prompt is
trimmed before its first line is taken, so that the line the label names is the
line the entry points at.

**Two prompts with one first line are told apart in the label, because imenu
looks nowhere else.** A choice is carried back to an entry by its name — `assoc`
on the string `completing-read` returned — so a second entry under a name the
first already has cannot be reached: it is offered once and answers with the
earlier prompt. It gets `<2>` on the end instead, the way Emacs tells two
buffers of one name apart, and the number says which of the entries in front of
the operator this is rather than how many messages came before the prompt.

**A label no entry in the index already carries comes out of that untouched.**
It is already the string the operator searches for, and suffixing every entry to
make the collision case uniform would cost the common case for nothing.

**The number is read off the index as it is built, in one pass in buffer
order**, which is also all `generate-new-buffer-name` takes: a prompt whose own
first line is `foo<2>` collides with the `foo<2>` an earlier duplicate of `foo`
was handed, and is renamed `foo<2><2>` as a buffer of that name would be.
Reserving the distinct first lines in a pass of their own would leave that one
bare — a different rule from the one Emacs has, and a second rule for the
operator to learn.

**`imenu-create-index-function` is the whole of the interface, and parley ships
no jump command of its own.** `M-x imenu` is always there and `sallet-imenu` is
another front end over the same index; a third would be parley's to keep working
against both. That is also what forces the disambiguation into the label: imenu
offers no seam at which a choice could be resolved any other way.

## One buffer per session, found by id

**A session's buffer is found by the session id it records and never by its
name.** `claude agents` gives two sessions in sibling worktrees one name, and a
lookup by name would hand the second session the first one's buffer.

A buffer's name still has to be unique to a session, so it carries the tag
[discovery](discovery.md) describes.

**Switching to a session again shows the buffer as it stands**, process and
history and all, and refreshes the record in it: what `claude agents` says about
a session goes stale.
