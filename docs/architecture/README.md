# The architecture

**This directory is where parley's architecture is written down.** Where a page
here and any other document disagree, this one wins.

A page carries what the code cannot say about itself: which decision lives
where, which constraint forces it, what a measurement came to, an alternative
that fails and the one reason it fails.

## The pages

| Page | Owns |
|---|---|
| `discovery.md` | what a session is, how one is found, why standard input is the discriminator, and where what it is doing now is read from |
| `transcript.md` | the pipeline that reads a transcript, the projection it is filtered through, the render pass, the index over the prompts, and the line at the top of the buffer |
| `typing.md` | the pane as the only way into a session, the input zone and what marks it, the two send shapes, the echo, and sending a past turn again |

## What may go on a page

**Architecture is not a reference. If a grep can answer it, it does not belong
here** — a function's arguments, a plist's keys, a copy of a `defcustom`'s
default. The file that holds the thing is its reference, and a copy on a page is
a second source of truth that drifts silently, because nothing checks prose
against code.

**One page owns each fact.** A rule restated on two pages is two rules the
moment one of them is edited. If the page that owns a subject is wrong, fix that
page in the same change that made it wrong.

**A measurement is quoted with what it measured.** parley's design turns on
numbers — what a pure Elisp pass costs against a jq pipeline, what a pty costs
against a pipe — and a number with no stated tree, transcript size or tool
version cannot be rechecked.

**No tombstones.** A page states what is true now; `CLAUDE.md` has the rule and
it binds here too.

## Where the rest of it is

| Fact | Owner |
|---|---|
| layout, house style, where a new thing goes | `CLAUDE.md` |
| the check commands and the role that runs each | `.orc/config.toml` |
| what the package is and how to use it | `README.md` |
