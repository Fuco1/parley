# Picking a session

**The switcher is built on sallet because a session is listed by columns, and
sallet lets a source match one column at a time.** A sallet source brings its
own matcher and its own renderer, so a candidate need not be a string: here it
is the vector `parley-session-fields` returns, the matcher sends each token the
operator types to the column it names — the name, unless a sigil says
otherwise — and the renderer draws the vector as its row. A word can then be
aimed at a name without also matching every session whose working directory or
tag happens to hold it.

**A flat row cannot be aimed, and the columns of one machine's sessions share
their words.** `completing-read` completes over strings, so the columns are
baked into one and a token is matched against the whole of it. Measured on
2026-09-29 with Emacs 28.2 and sallet at `2a2d434`, over the 5 sessions
`parley-sessions` listed, every one of them working in `~/dev/orc` and running
in the tmux session `orc-orc-b3743fe3`: the token `orc` matched all 5 rows
under the `substring` and `flex` completion styles and none under `basic`,
which matches the beginning of a row and so reaches nothing but the name. The
sallet matcher, sending it to the name column, matched 1.

## sallet is optional

**Only the picker gains from sallet, so parley does not require it.** The view,
typing into a session and finding one are the same with sallet or without it,
and the picker has a frontend that needs none. Requiring sallet would make every
part of parley need a package that one command is better with. So no package
header names it, and it is the one dependency parley has that is soft.

## Without sallet the pick is the minibuffer reader

**With sallet not on the load path, `parley-switch` picks with
`parley-read-session`**, a `completing-read` over the sessions. What a row
holds and how the two frontends draw it is [discovery](discovery.md)'s. What the
fallback loses is the aim: a token is matched against the whole of a row, as
above.

The reader is in `parley.el` rather than beside the picker, and `CLAUDE.md`
says why.
