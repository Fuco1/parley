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
It carries `isMeta` for the same reason from the other side: the render pass
cannot ask for a field the projection did not emit, and that field is what marks
a harness injection.

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

### A harness injection is marked, and is not his turn

A skill load reaches a transcript as a `user` message carrying the whole of the
skill, and so does the caveat a local command prepends, the expansion of a
personal command, and the notice the `Agent` tool writes about a fork. Quoted as
the operator's speech, a skill load is a thousand lines of instructions behind a
`>` marker in a buffer whose whole subject is the conversation.

**`isMeta` is what marks one, and it is the whole of the test.** The transcript
puts that field on every turn the harness injected and on nothing the operator
typed — so the `<command-name>` turn Claude Code writes when he invokes a skill
by typing its slash command carries no mark, and is quoted, marked and indexed
as any turn of his is. A pattern in the text would decide the opposite, and
would be deciding it about his own words.

**A skill load is the one injection the buffer shows, and it is worth one
line.** Both ways into a skill — the `Skill` tool and the slash command typed
for it — open with the same `Base directory for this skill: PATH` line, which is
what identifies the load, and the line the buffer shows is named from the
skill's own first `# ` heading: that heading is the name because it is what the
skill calls itself. A skill whose body opens with no heading is named by the
last segment of `PATH`. The name is quoted in the line, so a heading of several
words cannot read as prose an agent wrote.

**Every other injection renders nothing at all.** A constant line saying an
injection happened carries no information, and the caveat and the command
expansion each stand under a turn of the operator's that already says what he
did. Rendering nothing is the empty string a turn that said nothing renders to,
so such an injection is no break in a run of tool calls either.

**An injected turn is not a prompt, so it takes no imenu entry** however it
renders — the operator jumping through that index is looking for what he typed.

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

## A table is aligned by an overlay, not by an edit

A table lines up only if the agent lined it up, and a table whose columns do not
line up is a table nobody reads. What the operator sees is the table aligned;
what the buffer holds under it is the text the transcript delivered, character
for character, because the aligned form is carried by an overlay in a `display`
property.

**The alignment is a rendering and not an edit**, and both halves of that are
the reason for it:

- the rendering can be recomputed when the window changes width, which text
  written once on the way in never could — nothing refontifies or rewrites this
  buffer after an insertion, by design; and
- what it is computed from is the text under the overlay, so recomputing it
  needs no record of anything.

**Alignment only ever makes a table wider**, so a table it takes past the edge
of the window is wrapped into it: each cell over as many lines as it needs, and
the row as tall as its tallest cell. The width to wrap to is the width the
rendering is already computed for, which is what makes the width of the window
the thing the rendering is recomputed on. It costs nothing to undo — the columns
are recomputed from the text under the overlay every time, so a wrap is never
something a later render has to unpick.

**A wrap never breaks a construct a bar stands in.** A cell can hold a bar that
is no column boundary — the one inside a wiki link, which markdown-mode's own
cell reader passes over — and it is read over only while the link is whole. A
line carrying `[[target|link` alone is that construct left open, and its bar is
a boundary again: the row reads as a column more than the table has, to anything
parsing the wrapped form back and to the operator, whose grid goes with it. So a
link holding a bar is one piece of the wrap however many spaces stand inside it,
and the column it is in is floored by it exactly as a long word floors one.

**The wrapped grid is written from the cells, not handed back to the aligner.**
The widths are settled by the wrap and the padding follows from them, so a
second pass through the aligner would only read back text just written. The
cells are read once, from the table as the agent wrote it, where every construct
in them is whole, and what is written out of them is the layout the aligner
would have written.

**A cell nothing can narrow sets a floor under its column.** Wrapping packs the
pieces of a cell — its words, and a wiki link holding a bar entire — and breaks
none of them across two lines: a table past the edge of the window is one the
operator can still read back, where a broken word costs him the word and a
broken link costs him the grid. So a column holding a piece longer than the room
the grid leaves it gives nothing, and the table settles wider than the window.
That is the honest outcome. The floor is not what keeps a piece whole, which the
packing does at any width; it is what stops the columns beside an incompressible
one being packed tighter than the table they share will ever be.

**The aligned form closes a row the agent left open.** The outer bar at the end
of a row is optional, and a table written by hand leaves it off; the aligned
form always carries it, because what is aligned is a copy of the table with
those bars put back. Without them the aligner reads such a row as a row with one
cell fewer, and a `display` property is all the operator has — a cell dropped
there is a cell of the agent's he cannot read at all, where a ragged table is
merely ragged. The row stays open in the buffer text, which is what the overlay
covers.

**A table is what markdown-mode calls one**, which is narrower than what the
agent may have meant. A line that does not open with a bar is not a table line
to it, and a block of delimiter rows with no header row is a table it will not
align — both are shown as the agent wrote them. The alignment is markdown-mode's
own, so what it calls a table is the only thing parley can hand it.

**A table inside a fenced code block is not a table**, it is text the agent is
showing, and aligning it would rewrite what he quoted. The difference is
markdown-mode's syntax over the fence, which is known in the buffer the
fontification happens in and nowhere after it: the transcript buffer holds no
markdown syntax at all, so a pass over the finished text could not tell a table
an agent wrote from one it was quoting.

**Where a table is comes from the render pass.** That pass returns a string
comint has not inserted yet, so what it can say is how far into that string each
table begins — the same offsets the index over the prompts is recorded from, and
turned into buffer positions by the same output filter, because that is the
first moment the text exists.

**The faces the aligned form carries are on the display string itself.** What is
under a `display` property is not what is shown, and the `font-lock-face`
markdown-mode left on the buffer text does not reach the screen through one. The
string carries the face markdown-mode paints a table with and nothing finer, so
markup inside a cell stands in the aligned form as the agent wrote it.

**What a realignment costs.** Measured on Emacs 28.2 in batch, byte-compiled,
counted in CPU time and taken as the best of twenty runs of two hundred
alignments, over a table of seven rows and four columns whose aligned form is 73
columns wide: 2.8 ms for one that fits, nearly all of it markdown-mode's own
aligner, and 5.0 ms for one wrapped into 50 columns — the aligner is run first
either way, because whether the aligned form fits is what says a wrap is needed
at all. A conversation holding forty tables therefore costs 0.11 s of blocked
redisplay on a resize, and 0.20 s if every one of them has to be wrapped. The
hook this runs on is called for a window added, deleted or given another buffer
as well, and the width the tables were last aligned to is what tells a resize
from the rest — 3.3 µs when it has not changed, which is what keeps every other
window change free.

An overlay is the buffer's and not a window's, so a buffer shown in two windows
of different widths is aligned to whichever of them changed last.

## A run of tool calls is one line

The operator wants the conversation. The calls an agent made on its way to an
answer are worth one line however many there were, and the pane is still there
for anyone who wants to watch the work.

**A `●` heads every line the renderer wrote rather than anyone in the
conversation**, the run of tool calls and the skill load alike, and they stand
in one face — so a line the renderer is telling the operator something on
cannot be read as one an agent typed.

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
