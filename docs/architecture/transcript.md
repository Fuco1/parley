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

**The `❯ ` at the head of each line takes a face of its own**, so a theme can
dim the mark the renderer added without dimming the words the operator wrote.
It inherits the turn's face before anything else, so the band under it is
unbroken.

### A harness injection is marked, and is not his turn

A skill load reaches a transcript as a `user` message carrying the whole of the
skill, and so does the caveat a local command prepends, the expansion of a
personal command, and the notice the `Agent` tool writes about a fork. Quoted as
the operator's speech, a skill load is a thousand lines of instructions behind a
`>` marker in a buffer whose whole subject is the conversation.

**`isMeta` is what marks one, and the mark is not read off the body of a
record.** The transcript puts that field on every turn the harness injected and
on nothing the operator typed — so the turn Claude Code writes when he invokes a
skill by typing its slash command carries no mark, and is quoted, marked and
indexed as any turn of his is. A pattern in the body would decide the opposite,
and would be deciding it about his own words. The one injection the harness
leaves unmarked says what it is in the first characters of its text, and the
section below is where that is read.

**A skill load is worth one line, and the skill's own name is that line.** Both
ways into a skill — the `Skill` tool and the slash command typed for it — open
with the same `Base directory for this skill: PATH` line, which is what
identifies the load, and the line the buffer shows is named from the skill's own
first `# ` heading: that heading is the name because it is what the
skill calls itself. A skill whose body opens with no heading is named by the
last segment of `PATH`. The name is quoted in the line, so a heading of several
words cannot read as prose an agent wrote.

**A task notification is worth one line too, and the line is its `<summary>`.**
Claude Code writes one when a background shell finishes, a `Monitor` fires or a
subagent returns: a `<task-notification>` wrapping a task id, a tool-use id, the
path the output was left at, a status, and a summary on one line. The summary is
the whole of what such a record says the operator can act on — the two ids and
the path are addressed to the agent, and `<status>` says nothing the summary does
not already say in its own words — so the line is the summary and nothing else. A
notification carrying no summary renders nothing at all, having nothing to say.
Measured over the 1622 notifications in the transcripts on this machine: 1619
carry a `<summary>` and every one of those sits on one line, `<status>` is on 384
of them, and the 3 with no summary are `<fork-source>` notices.

**Every other injection renders nothing at all.** A constant line saying an
injection happened carries no information, and the caveat and the command
expansion each stand under a turn of the operator's that already says what he
did. Rendering nothing is the empty string a turn that said nothing renders to,
so such an injection is no break in a run of tool calls either.

**An injected turn is not a prompt, so it takes no imenu entry** however it
renders — the operator jumping through that index is looking for what he typed.

### Three `user` records are a wrapper the harness wrote, not speech

None of them carries `isMeta`, so none is an injection the transcript marked,
and quoted as it stands each puts tags in front of the operator as his own
words. **What the harness wrapped around the record is dealt with before the
record is read for anything.**

**A slash command reaches the transcript as three tags, and renders to the one
line he typed** — the `<command-name>` and the `<command-args>` on one line, and
the name alone when the argument is empty, as it is under `/plugin`.
`<command-message>` is the name a second time without its slash and says nothing
`<command-name>` does not. An argument he pasted over several lines keeps them,
each quoted as the first is.

**A local command's own output renders nothing at all.** A
`<local-command-stdout>` record is the terminal answering a command rather than
a turn of the conversation, and his own turn invoking that command stands right
above it saying what he did. It is also the one place an escape byte could enter
this buffer — a compaction notice arrives inside a real `ESC[2m`, and nothing
strips one out here — so rendering nothing settles that as well.

**A task notification is marked as the injection it is, and its text is left
alone.** What it renders to is above, with the injections the harness does mark;
the mark is what puts it there. An injection is already what the render pass
turns into a renderer line or into nothing, and already what the index passes
over, so marking a notification is the whole of the rule and it needs no third
path through the pass. The summary is read out of the text where every
injection's line is made.

**The unwrapping has to happen before the echo guard and before the index.**
The guard [typing.md](typing.md) describes recognises parley's own copy of a
message by the text that was sent, so a slash command submitted at parley's
prompt matches nothing while it is still three tags, and stands in the buffer
twice. The imenu entry is recorded from the record's text in the render pass, so
a turn indexed before it is unwrapped is labelled
`<command-message>one</command-message>` — one label for every slash command of
that name, and two of them told apart by a number rather than by what he asked.

**What the text decides, it decides from the head of the record.**
`<task-notification>` is matched at the very first character of the text, with
no whitespace tolerated in front of it — a space would be nothing the harness
writes, and a newline would make the second line of a turn of his decide that
the first one was never his. So a turn of the operator's that quotes the tag on
any line but the first is his own words: quoted whole, tag and all, and indexed
under its first line. He writes one: of the 1624 records holding the tag on this
machine, 1622 are notifications opening with it at character zero, and the 2 that
do not are prose quoting one. Anywhere but the head, the text would be deciding
about his words instead of the harness's, which is what `isMeta` is for and what
it stays for.

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

## A table is rendered into the buffer, and the overlay keeps its source

A table lines up only if the agent lined it up, and a table whose columns do not
line up is a table nobody reads. What stands in the buffer is the grid parley
writes, put there as text — this buffer is a rendering throughout, and a table
is the same kind of rendering as the quote around the operator's turn and the
one line a run of tool calls collapses to.

**The grid is drawn, and the source behind it is the agent's bars and dashes.**
Every column boundary in a rendered table is `│`, at each end of a line as well
as between two cells; the row between the header and the body is `├─┼─┤`, with
none of his dashes or colons left in it; and a rule of `┌─┬─┐` opens the grid
with `└─┴─┘` to close, each junction standing in the column a boundary stands
in. What the overlay carries is the `|` and the `---` he typed, which is what
every render is computed from.

**The writer emits those characters, and nothing substitutes them into a
finished form.** parley writes every grid itself, so the writer is what puts
each boundary where it is and the only thing that knows where one is. A pass
over the finished form could not: a cell can hold a bar of its own —
`[[target|link words]]` is one cell to markdown-mode's reader — and that bar
stands where no column ends, so a substitution would draw a boundary inside the
cell. Nothing scans a cell for a bar, and a bar inside one reaches the buffer
exactly as the agent wrote it.

**The `:---:` of a delimiter row is said by the padding.** How a column is
aligned is not something anyone reads off a drawn table, and it is not lost:
the marks are read off his delimiter row once and every line the writer puts out
is padded by them. The row itself becomes `├───┼───┤`.

**The drawing costs the grid no width.** Each of those characters takes the one
column the character it stands for took. Under Emacs's default width table that
is already so: measured with `char-width` on Emacs 28.2, `│`, `─` and every
junction and corner are one column, as `|` and `-` are. Under the CJK one,
which a Chinese, Japanese or Korean language environment installs, each of them
is two and `|` and `-` are still one — measured on the same Emacs, `│ a │ b │`
is 12 columns and the `┌───┬───┐` over it 18. So the transcript buffer, and the
buffer every cell is measured in, carry a `char-width-table` of their own: a
child of the environment's, which counts the drawn characters one column each
and leaves every other width to its parent, so a CJK character in a cell is
still the two columns it is. The parent is the table in force when the buffer
is set up, and a buffer set up before a switch of language environment keeps
the widths of the one it was set up under.

**The form is text and not something shown through a `display` property.** What
a `display` property shows is not text: the buffer's own machinery never looks
inside it, so nothing in such a table could be a button — `button-at` and
`next-button` find one by walking buffer positions — and a node id in a cell
could never be made clickable. Text is what the rest of the rendering can be
grown past, and a form shown through a property is where it stops.

**The overlay stays, carrying the table the agent wrote.** That is what a resize
is rendered from. The buffer holds a grid this package wrote, and reading the
cells back out of one would render the last render rather than the table: every
line of a wrapped row parses back as a row of its own. The overlay is also what
says where a table is, and what tracks a deletion — `comint-truncate-buffer`
taking the top of the conversation away brings its ends together, where a text
property would survive in both halves of what was cut.

**A region that no longer holds what parley wrote there is not rendered again.**
Truncation can take the first lines of a table away and the operator can edit in
this buffer, and rendering from the source over either would put back text that
is not there any more. The overlay is dropped instead and what is left stands as
it stands. It is dropped at the next render and not when the deletion happens,
because nothing watches this buffer for changes — by design, since watching it
means a pass over the conversation on every append.

**What this costs the operator is the source in the buffer.** A kill over a
table copies the form he is reading and not the table the agent typed. The
source is on the overlay, and no command hands it back.

**A render takes nothing of the operator's.** It goes in under
`with-silent-modifications`, so the undo list carries no entry for it and `undo`
reaches past a table to his own last change; point is put back where it stood,
which comint reads back off the buffer once its output filters have run; and the
process mark is a marker past the end of a table — a table ends before the
newline that closes the block around it — so it follows the replacement as the
overlay over every other table does.

**Point inside a table is put back by hand, the same distance into the form.** A
marker is what carries point over a replacement and the deletion takes the text
this one is in, so nothing carries it: it would come back at the head of the
grid. The distance is the most a grid laid out again can promise — the cell that
was under point may not exist at the new width — and the form is as far as it
goes, so a table point stood in is a table it stays in.

**One writer for every table, parley's own.** A table that fits the window is
the grid with no column narrowed; a table that does not is the same grid with
its cells wrapped, each over as many lines as it needs and the row as tall as
its tallest cell. There is no second path: the only other writer is
`markdown-table-align`, and it cannot write a grid around markup that is hidden.

**The reason is the markup in a cell.** Everywhere else in a message `**bold**`
shows as bold and inline code as code: the fontification has markup hiding on
and the render pass copies what markdown-mode marked `invisible`. A cell is no
exception, and what it takes is a writer that knows a hidden character costs
no column. The aligner cannot: it measures a column with
`markdown--string-width`, which does discount `invisible markdown-markup`, but
it reads its cells with `buffer-substring-no-properties`, so nothing that hides
a character ever reaches that measurement — and it pads with `%-Ns`, which
counts characters either way. Measured against this repository's markdown-mode
with hiding on, a column holding `**bold**` and `plainlonger` comes out padded
to thirteen characters on every line of the table, and the line the bold is on
then stands in eleven columns where every other line stands in fifteen.

**Every width the grid is written to is measured on what the rendering shows.**
`markdown--string-width` is markdown-mode's own answer for that width, and it is
what a column's width, the floor under it, the room a wrapped line is packed
into and the padding that fills a cell out are all taken with. It reads
`buffer-invisibility-spec` to know what is hidden, which is the other reason the
grid is written in the buffer the fontification happens in: that spec is the one
`markdown-toggle-markup-hiding` put `markdown-markup` into.

**A `display` property is a width the grid cannot measure, so it stays out of
one.** A cell comes away from the fontification with what markdown-mode painted
it and what markdown-mode hid, and without the `display` properties it also
leaves behind: the `2` of `x^2^` is one character and one column to every
measurement of it, where the property that raises and shrinks it puts it on
screen as less than one. A grid is characters standing in columns, and a hidden
character is the one thing done to a cell that the measurement and the screen
agree the width of.

**The cells reach the writer with what the fontification marked still on them.**
Where a cell begins and ends is markdown-mode's own cell reader, because that is
what reads over the bar inside a wiki link and the escaped bar — and it hands
back text with nothing on it. A cell is a verbatim substring of the line it was
read from, so what the fontification marked is taken back off that line by
position, each cell searched for from where the last one ended.

**A column the delimiter row marks is padded the way it is marked.** Right puts
the padding in front of the cell and centred splits it either side; a column
nobody marked takes it behind. The marks are read once, with markdown-mode's own
`markdown-table-colfmt`, and every line the writer puts out is padded by them —
so the lines a cell was packed over stand in the same column as the line its row
began on, and the padding is the whole of what says how a column is aligned.

**A cell already inside its column is not packed.** Packing puts one space
between two pieces, which is what a wrap has to do to a cell it spreads over
lines; a cell nothing has to be moved in is the cell the agent typed, two spaces
and all. That is every cell of every table that fits the window, and it is the
cheaper answer as well.

**A wrap never breaks a construct a bar stands in.** A cell can hold a bar that
is no column boundary — the one inside a wiki link, which markdown-mode's own
cell reader passes over — and it is read over only while the link is whole. A
line carrying `[[target|link` alone is that construct left open, and what the
break costs is the link: nothing reading the form back has one there any more.
So a link holding a bar is one piece of the wrap however many spaces stand
inside it, and the column it is in is floored by it exactly as a long word
floors one.

**A cell nothing can narrow sets a floor under its column.** Wrapping packs the
pieces of a cell — its words, and a wiki link holding a bar entire — and breaks
none of them across two lines: a table past the edge of the window is one the
operator can still read back, where a broken word costs him the word and a
broken link costs him the link. So a column holding a piece longer than the room
the grid leaves it gives nothing, and the table settles wider than the window.
That is the honest outcome. The floor is not what keeps a piece whole, which the
packing does at any width; it is what stops the columns beside an incompressible
one being packed tighter than the table they share will ever be.

**The rendered form closes a row the agent left open.** The outer bar at the end
of a row is optional, and a table written by hand leaves it off; the grid always
draws that boundary, because what the cells are read out of is a copy of the
table with those bars put back. Without them the reader takes such a row as a row with one
cell fewer, and a cell dropped on the way into the buffer is a cell of the
agent's the operator cannot read at all, where a ragged table is merely ragged.
The row stays open in the table the overlay carries, which is what every later
render reads.

**The cells are held to the table, and the grid written from them is not.** The
cell reader is markdown-mode's, and which markdown-mode is under the buffer is
the operator's business: a version of it that dropped a cell would put that
cell's row in the buffer without it. So what it handed back is compared with
what the agent typed, with everything either may space or bar or break
differently taken out, before anything is written. It is the cells that are
compared and not the grid, because a wrap takes a cell down the lines its row
spreads over: read back across a line the grid says the head of every cell where
the table says the whole of the first before the second begins.

**A table is what markdown-mode calls one**, which is narrower than what the
agent may have meant. A line that does not open with a bar is not a table line
to it, and a block of delimiter rows with no row of data has nothing in it to
line up — both are left in the buffer as the agent wrote them, and the overlay
over them is dropped: what is refused is refused at every width, so there is no
width to come back for.

**A table inside a fenced code block is not a table**, it is text the agent is
showing, and lining it up would rewrite what he quoted. The difference is
markdown-mode's syntax over the fence, which is known in the buffer the
fontification happens in and nowhere after it: the transcript buffer holds no
markdown syntax at all, so a pass over the finished text could not tell a table
an agent wrote from one it was quoting.

**Where a table is comes from the render pass.** That pass returns a string
comint has not inserted yet, so what it can say is how far into that string each
table begins — the same offsets the index over the prompts is recorded from, and
turned into buffer positions by the same output filter, because that is the
first moment the text exists. Every overlay is laid before any table is rendered,
because rendering one replaces buffer text and moves everything after it: an
overlay follows that move and an offset into the inserted string does not.

**The faces the rendered form carries are in `font-lock-face`.** `face` is what
global font lock strips in this buffer, for the reason the render pass maps it
away. A cell carries the faces markdown-mode painted it with, which is
`markdown-table-face` over the whole of a table line and the face of a construct
over the construct; what comes out of the writer with no face at all is the grid
itself — the boundaries, the rules and the padding — and that is what the table
face is filled into.

A form is never the table it came from, whatever the agent lined up himself: the
grid is drawn and his table is bars and dashes, so the first render of one
always writes.

`equal-including-properties` compares two property values with `eq` and a face
markdown-mode painted a cell with is a fresh list every fontification, so two
computations of one form do not compare equal either: a resize that leaves a
table's grid unchanged still writes it into the buffer. What that costs is the
write and never the render, which has happened by the time the comparison is
made — 87 µs against 4.5 ms, so the saving a comparison could win back is 2% of
the resize.

**What a render costs.** Measured on Emacs 28.2 in batch, byte-compiled, counted
in CPU time from `get-internal-run-time` and taken as the best of twenty runs of
two hundred renders, over a table of seven rows and four columns whose grid is
71 columns wide: 4.5 ms to write the grid for one that fits, 6.0 ms for one
wrapped into 50 columns, and 87 µs on top of either to put it in the buffer.
That last is nearly all properties — inserting the form costs 76 µs where
inserting the same characters with nothing on them costs 1.2 µs, because a form
carrying markup carries 49 runs of text properties over those seven rows and
each run is an interval the insertion has to build. A conversation holding forty tables therefore costs
0.18 s of blocked redisplay on a resize, and 0.24 s if every one of them has to
be wrapped.

That is around 1.6 times what handing a table that fits to `markdown-table-align`
costs, measured the same way on the same table: 2.7 ms and a 3 µs write. The
difference is the markup — the fontification the cells are read out of, and the
property runs the form is written with — and it buys every table the rendering
the rest of a message gets.

The hook this runs on is called for a window added, deleted or given another
buffer as well, and the width the tables were last rendered to is what tells a
resize from the rest — 0.7 µs when it has not changed, which is what keeps every
other window change free.

A table is the buffer's text and not a window's, so a buffer shown in two
windows of different widths is rendered to whichever of them changed last.

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

**The buffer replaces what the selected window is showing, and is never put in
another window.** Every way in means the same thing by picking a session — go to
it: the sallet action, the `completing-read` fallback behind it and the command
called by hand all reach the one call that shows the buffer. Displaying it
instead spends a window the request never named, because the transcript lands in
the window the operator was not in, over whatever he had open there, and takes
his selection with it.

## The header line says whose buffer this is, and what it is doing now

**The buffer name is a snapshot and the header line is not.** The name is built
once, when the buffer is made, and nothing renames it afterwards — so the
operator scrolled back through a long conversation has nothing in front of him
saying which session he is reading or what it is doing. A header line is rebuilt
on every redisplay, which is what lets it say what is true now. It is also
parley's own line: a mode line is configured by whoever owns the Emacs and may
show none of this.

**It carries the session's name, what it is doing, where its pane is and the
mark saying it cannot be typed into.** The status is the buffer's live one
([discovery](discovery.md)) and never the one the record carried when the buffer
was opened; all four states are told apart in words, and waiting is a word of
its own, because it is the state that wants the operator.

**The working directory is not on it.** A switcher row carries it because the
operator is choosing between sessions; inside the buffer it is
`default-directory`, and a line repeating what the buffer already is spends a
line on nothing.

**The line and the cell in front of the prompt are not abbreviations of each
other.** The cell says that something is working, in one column, where the
operator is typing ([typing](typing.md)); the line says which session and what
it is doing, wherever in the buffer he is.

**Where the pane is is a bare lookup in the map, never the accessor over it.**
That accessor fills the map when it has not been asked, and filling it runs
`tmux list-panes -a` — which from a header line is a subprocess per open
transcript on screen, every time the session list is discovered again and drops
the map. The tag is no way round it, reaching the same accessor. A pane the map
holds nothing for shows no location at all, and never the pane id in its place.

**The bare lookup is also what keeps the location current.** The map is refilled
whenever the sessions are listed, so a pane the operator moved shows where it is
now while the buffer name still carries where it was.
