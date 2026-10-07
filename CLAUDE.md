# parley — repo conventions

parley is an Emacs package that shows the Claude Code sessions running on this
machine as conversations, and types into them. It reads each session's
append-only JSONL transcript and writes to the session's tmux pane. It never
starts a session, and ends one only by typing `/exit` into its pane.

**This file is repo conventions only** — layout, where a new thing goes, house
style. Why the package is shaped the way it is belongs to the manual,
`doc/parley.texi`.

## Where the architecture is

| fact | owner |
|---|---|
| **why the package is shaped this way, one node per subject. Read this first** | the manual, `doc/parley.texi` |
| layout, house style, where a new thing goes | this file |
| what a function or a variable does, and the reason a caller needs, for a reader in Emacs's help | its docstring, under "Docstrings and commentaries are read in Emacs's help" below |
| the check commands and the role that runs each | `.orc/config.toml` |
| what the package is and how to use it | `README.md` |

Start at the manual's `Top` node: its menu lists every node and what each owns.

**The manual is where the architecture is argued.** One node owns each
subject. When you find something architectural — which decision lives where,
which constraint forces it — put it in the node that owns that subject. A
commit body is read once and a `;;` comment only by whoever opens that file;
neither is where the next person looks, and both go stale silently because
nothing checks prose against code. Where the manual and any other document
disagree, the manual wins.

**The tie-breaker between a node and a `;;` comment is what the argument is
about.** Could the sentence have been written before the file existed, and would
it still be true if the function were rewritten from scratch? Then it is the
system's and the manual owns it. Does it name a flag, the order of two forms, or
what an external tool does at this one call? Then it is the line's, the code
owns it, and a node that repeats it has taken the fact away from the only place
it prevents the mistake.

**The tie-breaker does not reach a docstring or a `;;; Commentary:` section.**
Those are read in Emacs's help, and help reaches the manual only through an
Info node one of them names. What they owe their reader is under "Docstrings and
commentaries are read in Emacs's help" below.

### What goes in a node

**A node carries what the code cannot say about itself**: which decision lives
where, which constraint forces it, an alternative that fails and the one reason
it fails.

**Architecture is not a reference. If a grep can answer it, it does not belong
in the manual** — a function's arguments, a plist's keys, a copy of a
`defcustom`'s default. The file that holds the thing is its reference, and a
copy in a node is a second source of truth that drifts silently, because
nothing checks prose against code.

**One node owns each fact.** A rule restated in two nodes is two rules the
moment one of them is edited. If the node that owns a subject is wrong, fix that
node in the same change that made it wrong.

**No figures.** A node states a decision and the constraint that forces it, and
the number a cost came to is in the commit that made the decision; "A cost a
decision rests on is measured before the decision" below has the rule and it
binds here too.

**No tombstones.** A node states what is true now; "No tombstones" below has the
rule and it binds here too.

**The manual is Texinfo, written directly.** straight's default files directive
and MELPA's default file list both build the `.info` from a `.texi` under
`doc/` and ship it, so nothing generates the `.texi` and no `.info` is
committed. A subject of its own is a `@node` and `@chapter` with an entry in
the `Top` menu; a node names another with `@ref`, `@xref` or `@pxref`, and
`makeinfo` fails on a menu entry or a reference naming a node that does not
exist.

## Layout

| file | holds |
|---|---|
| `parley.el` | discovery: `claude agents --json`, the stdin discriminator, the pane id, the transcript path, and the tag that tells two sessions apart. What a session is doing, read from the file it writes about itself. Then listing what it found: the status order, the five columns a session is listed by, the one `completing-read` over them, and the lookup that says whether a session already has a transcript buffer. The base of the package |
| `parley-switch.el` | picking a session with sallet: the source, the matcher that keeps the columns apart, the renderer, and the fallback to the minibuffer reader when sallet is missing |
| `parley-transcript.el` | the conversation view: the `tail`/`jq` pipeline, the render pass, the conversation above the input zone being read-only, the table writer, the imenu index, the buffer and the session record it follows, the session's live status, the header line, typing into the pane, and ending the session |
| `test/` | one file per source file, named `<source>-test.el` |
| `test/parley-fixtures.el` | what more than one test file needs, and no test. A test file requires it by the test file's own directory, because the checks put only the root on the load path |
| `.orc/config.toml` | the check commands, and which role runs each |
| `doc/parley.texi` | the manual: why the package is shaped this way, one node per subject |

**The requiring goes one way only.** `parley.el` requires nothing else in the
package; the picker requires the view, and the view requires neither. Anything
both the picker and the view need goes down into `parley.el`, because the other
direction closes a cycle and `require` does not survive one.

**Every file requires each library it calls**, even one another file already
loads. A function reached through someone else's `require` is a dependency on
that file's imports, and the byte compiler cannot see it: `(require 'parley)`
loads the library at compile time, so the call compiles clean either way.

### Where a new thing goes

- **A `defcustom` goes beside what reads it** — at the top of the file when the
  whole file reads it, inside the `;;; ` section when one section does.
- **A new `;;; ` section is named for its subject**, not for the kind of code
  under it: `;;; Typing into the pane`, never `;;; Functions`.
- **A new test goes in the file mirroring its source**, under the `;;; ` section
  mirroring the source's.
- **A new source file needs no edit anywhere.** `.orc/config.toml` globs the
  tree, and the tests are found the same way.

## House style

- **`parley--` for what only its own file calls, `parley-` for what another file
  may.** Two dashes mean private, and nothing outside that file may reach it.
  Another package's double-dash names are private to that package in the same
  way: parley calls its public surface or owns the few lines itself, and reaches
  a private only where neither will do, with the reason written at the call.
- **`` `foo' `` quoting for a symbol inside a docstring**, which is what Emacs
  renders as a link.
- **Two spaces after a period**, in docstrings and in comments.
- **`;;; ` headings divide every source file into sections.**
- **A test is named `<the file's feature>-test-<the property it asserts>`**, not
  for the function it calls —
  `parley-transcript-test-drops-the-tool-payloads`, never a numbered variant of
  the function's name. A helper in a test file carries `-test--`.
- **Never shout. A run of capitals is not emphasis.** Capitals are for a token
  spelled that way: `TMUX_PANE`, `PATH`, `JSONL`. An argument or a
  metasyntactic variable written in capitals is the convention of
  `(elisp) Documentation Tips` and not shouting: `SESSION`,
  `SESSION:WINDOW.PANE`.
- **Prefer the form that can only fail.** `jq -M` where colour would be wrong
  even though a pipe would not get it anyway; a `user-error` on a session with
  no pane rather than a silent no-op.

### Docstrings and commentaries are read in Emacs's help

**A docstring and a `;;; Commentary:` section are written for a reader in
`C-h f`, `C-h v` or `finder-commentary` who has no other file open.** Help shows
them from the installed package, which is the `.el` files and the Info manual
built from `doc/parley.texi`: straight's default files directive and MELPA's
default file list both leave `*.md` out.

**A docstring carries the contract of what it documents** — what it does or
means, each argument, the return value, what it signals — **and the reason for
any behaviour a caller would not expect.** No line ceiling applies to a
docstring or to a commentary.

**It states the reason and not the evidence.** Neither a docstring nor a
commentary carries a figure, under the rule in "A cost a decision rests on is
measured before the decision" below.

**A docstring points only where help mode follows**: a symbol quoted as
`` `foo' ``, an Info node, a URL. It may say where a value comes from, such as
another package's function, but it never leaves out an explanation and names a
file to read for it. Nor does a commentary.

**Docstrings follow the Emacs Lisp manual's conventions, Info node
`(elisp) Documentation Tips`**: a first line that stands alone as a summary, the
imperative for a function, an argument named in capitals, `\\[command]` rather
than a literal key. `checkdoc` checks the mechanical half of them, and a check
profile runs it.

**A `;;` comment keeps the rule it has**: why and not what, and an argument
about the system is the manual's.

### A cost a decision rests on is measured before the decision

**Take the measurement before making the decision, and put the number in the
commit that makes it.** A number nobody took is a number nobody can check, and
"this looks expensive" is not one. The commit is where the number stays true:
it names the tree the number was taken on.

**A node of the manual, a comment, a docstring or a commentary states the
decision and the constraint that forces it, and carries no figure.** A number taken on one tree
says nothing about the tree as it stands, nobody reading it later can recheck
it, and the decision it argued for is already made. A value the code sets, such
as a timer's interval, is not a figure in this sense.

## No tombstones

**A document states what is true now.** The history is in git and git is the
only place it belongs.

No "previously", no "used to", no "renamed from", no dated note explaining why
the old thing is gone, no commented-out code left behind to mark where something
was. Deleting a rule means deleting its text, not annotating it dead. If the
reason for the current shape matters, state it as a present-tense constraint —
"jq block buffers a pipe, so `--unbuffered` is not optional" — and never as a
story about what happened.

A rewrite that leaves a file describing two eras at once is worse than no
rewrite. Read the whole file after editing it.

## Build and check

**The commands live in `.orc/config.toml`**, as named profiles with a `[roles]`
table saying which role runs which. Read them there rather than here: a copy in
this file is a second source of truth that drifts.

`orc check --role inner` is the one to run while you work. It byte-compiles the
tree under `byte-compile-error-on-warn` and runs `checkdoc` over every source
file outside `test/`, which together are the house-style gate — a warning from
either is an error — and builds the manual with `makeinfo`. `handoff` and
`merge` add the ERT suite.

Two things that will cost you a run:

- **`require` prefers a `.elc` over a newer `.el`**, saying so in one line of
  stdout. The compile deletes every `.elc` under the tree before it compiles
  anything, and `handoff` and `merge` run it before the tests, so no role loads
  a stale one. The test command run by hand after an edit does: it tests the
  package as it was last compiled. Run the compile first, or
  `rm -f *.elc test/*.elc`.
- **Most of the suite needs `jq` and `tmux` on `PATH`** and skips without them,
  so a green run that asserted almost nothing is possible.
