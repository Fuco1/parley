# parley — repo conventions

parley is an Emacs package that shows the Claude Code sessions running on this
machine as conversations, and types into them. It reads each session's
append-only JSONL transcript and writes to the session's tmux pane. It never
starts or stops a session.

**This file is repo conventions only** — layout, where a new thing goes, house
style. Why the package is shaped the way it is belongs to `docs/architecture/`.

## Where the architecture is

| | |
|---|---|
| `docs/architecture/` | **why the package is shaped this way, one page per subject. Read this first** |

Start at `docs/architecture/README.md`: it carries the page table and the rule
every page is held to.

**`docs/architecture/` is where architecture goes, and it is the only place it
goes.** One page owns each subject. When you find something architectural —
which decision lives where, which constraint forces it, what a measurement came
to — put it on the page that owns that subject. A commit body is read once and
a code comment only by whoever opens that file; neither is where the next person
looks, and both go stale silently because nothing checks prose against code.

**The tie-breaker between a page and a comment is what the argument is about.**
Could the sentence have been written before the file existed, and would it still
be true if the function were rewritten from scratch? Then it is the system's and
the page owns it. Does it name a flag, the order of two forms, or what an
external tool does at this one call? Then it is the line's, the code owns it,
and a page that repeats it has taken the fact away from the only place it
prevents the mistake.

## Layout

| file | holds |
|---|---|
| `parley.el` | discovery: `claude agents --json`, the stdin discriminator, the pane id, the transcript path, and the tag that tells two sessions apart. The base of the package |
| `parley-switch.el` | picking a session: the status order, the four columns a session is listed by, the sallet source and the `completing-read` fallback |
| `parley-transcript.el` | the conversation view: the `tail`/`jq` pipeline, the render pass, the imenu index, and typing into the pane |
| `test/` | one file per source file, named `<source>-test.el` |
| `.orc/config.toml` | the check commands, and which role runs each |
| `docs/architecture/` | why the package is shaped this way |

**The requiring goes one way only.** `parley.el` requires nothing else in the
package and nothing in it knows the other two files exist; the picker requires
the view, and the view requires neither. Anything both the picker and the view
need goes down into `parley.el`, because the other direction closes a cycle and
`require` does not survive one.

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
- **`` `foo' `` quoting for a symbol inside a docstring**, which is what Emacs
  renders as a link.
- **Two spaces after a period**, in docstrings and in comments.
- **`;;; ` headings divide every source file into sections.**
- **A test is named `<the file's feature>-test-<the property it asserts>`**, not
  for the function it calls —
  `parley-transcript-test-drops-the-tool-payloads`, never a numbered variant of
  the function's name. A helper in a test file carries `-test--`.
- **Never shout. A run of capitals is not emphasis.** Capitals are for a token
  spelled that way: `TMUX_PANE`, `PATH`, `JSONL`.
- **Prefer the form that can only fail.** `jq -M` where colour would be wrong
  even though a pipe would not get it anyway; a `user-error` on a session with
  no pane rather than a silent no-op.

### A claim about cost or about another tool is measured

The comments in this tree carry numbers because the numbers are the argument:
2.72 s of blocked UI against 0.44 s, 26 MB in and 1.3 MB out, 4.5 s over a pipe
against 10.1 s over a pty, `send-keys -l -- 'foo;'` arriving as `foo` under tmux
3.2a. **Take the measurement or do not make the claim.** A number nobody took is
a number nobody can check, and "this looks expensive" is not one.

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
tree under `byte-compile-error-on-warn`, which is the house-style gate — a
warning is an error. `handoff` and `merge` add the ERT suite.

Two things that will cost you a run:

- **`require` prefers a `.elc` over a newer `.el`**, saying so in one line of
  stdout. Running the test command by hand straight after a compile therefore
  tests the *previous* source. `rm -f *.elc test/*.elc` first; the `handoff` and
  `merge` roles are safe because they compile before they load.
- **Most of the suite needs `jq` and `tmux` on `PATH`** and skips without them,
  so a green run that asserted almost nothing is possible.
