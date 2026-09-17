;;; parley-transcript.el --- A comint buffer over a session transcript -*- lexical-binding: t -*-

;; Copyright (C) 2026 Matúš Goljer <matus.goljer@gmail.com>

;; Author: Matúš Goljer <matus.goljer@gmail.com>
;; Maintainer: Matúš Goljer <matus.goljer@gmail.com>

;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License
;; as published by the Free Software Foundation; either version 3
;; of the License, or (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; A session's transcript is an append-only JSONL file, so the buffer
;; that shows the session is a comint buffer whose process reads it.
;;
;; One process, not two.  `tail -c +1 -F FILE' starts at byte zero and
;; then follows, so the history and every later append come down the
;; same pipe.  Reading the file and then starting a `tail -n0' loses
;; whatever is appended between the read finishing and the tail
;; starting, and there is no way to notice that it did.
;;
;; jq does the filtering, because Emacs is single threaded.  Measured
;; on a 26 MB transcript: 23502 lines in, 8651 of them a message, and a
;; pure elisp pass over all of them costs 2.72 s of blocked UI.  The
;; same transcript through this pipeline projects to 5300 lines and
;; 1.3 MB, which settle in the buffer in 5.2 s -- and the tool
;; payloads, which are the bulk of those 26 MB, never enter the Emacs
;; process at all.
;;
;; What arrives is one object per line, and the render pass turns each
;; into buffer text: markdown for what the agent said, a quote for what
;; the operator said, and a single line for a run of tool calls however
;; many calls went into it.
;;
;; comint requires a live process, since `comint-send-input' errors
;; without one, and this pipeline is it.  Nothing is ever written to
;; its stdin: `comint-input-sender' takes what the operator submitted
;; and types it into the session's tmux pane instead, which is the only
;; door into a session parley did not start.

;;; Code:

(require 'comint)
(require 'imenu)
(require 'subr-x)
(require 'markdown-mode)
(require 'parley)

(defconst parley-transcript-projection
  (concat
   "select(.type == \"user\" or .type == \"assistant\")"
   " | { role: .type,"
   "     text: ((.message.content // \"\")"
   "            | if type == \"string\" then ."
   "              else [.[] | select(.type == \"text\") | .text] | join(\"\\n\") end),"
   "     tools: ((.message.content // \"\")"
   "             | if type == \"array\""
   "               then [.[] | select(.type == \"tool_use\")] | length"
   "               else 0 end) }"
   " | select(.text != \"\" or .tools > 0)")
  "The jq program every line of a transcript is passed through.

It emits what parley renders and no more: the role, the text and
how many tool calls the message made.  A tool result never
reaches Emacs, because the object is built from scratch rather
than pruned -- the payload lives in a `tool_result' block and in
a top-level `toolUseResult' field, and neither is read.

A message that renders to nothing is dropped rather than emitted
empty, which is what becomes of a `tool_result' turn and of an
assistant turn that was only thinking.

The count is per message and the run is not collapsed here.  A
run cannot be counted until it ends, so collapsing it would hold
back the line saying the agent is working until the agent had
stopped working -- exactly the frozen session `--unbuffered'
exists to prevent.  Consecutive tool-only objects are the run,
and joining them is the renderer's job.")

(defun parley-transcript--command (file)
  "Return the shell pipeline that projects the transcript FILE.

`-F' rather than `-f' because a session that has not spoken yet
has no transcript to open; tail says so on stderr, which shares
the buffer, and picks the file up when it appears.  A line in the
buffer is therefore not always JSON.

`--unbuffered' is not optional: jq block buffers a pipe, and
without the flag nothing arrives until the buffer fills, so a
live session looks frozen.  `-c' keeps one object to one line,
and a newline inside a JSON string stays escaped, so one message
stays one line too.

`-M' costs three characters and closes a trap.  jq colourises
when its stdout is a terminal and this one is a pipe, so it would
not colourise anyway -- but `parley-transcript-mode' has taken
the escape stripping out of the buffer, and `-M' is what keeps
that safe if the pipeline ever ran on a terminal again.  Measured
over the 26 MB transcript it leaves no escape byte in the stream
at all: a control character inside a JSON string is written as
the six characters \\u001b."
  (concat "tail -c +1 -F " (shell-quote-argument file)
          " | jq -M -c --unbuffered "
          (shell-quote-argument parley-transcript-projection)))

;;; Rendering

(defface parley-user
  '((((background light)) :inherit bold :background "#e6e6e6" :extend t)
    (((background dark)) :inherit bold :background "#2e2e2e" :extend t)
    (t :inherit bold :extend t))
  "Face for a turn the operator took.
`:extend' is what carries the background past the last character
of a line to the window edge, and a face that sets only
`:background' leaves it unspecified -- measured on Emacs 28.2,
`(face-attribute f :extend nil t)' is `unspecified' for such a
face and `t' only when the face says so."
  :group 'parley)

(defface parley-user-marker '((t :inherit (parley-user shadow)))
  "Face for the `> ' at the head of each line of a turn the operator took.
It inherits `parley-user' first, so the marker stands on the same
background as the turn it marks, and takes only what that face
leaves unspecified -- the foreground -- from `shadow'.  The
marker is the renderer's and the words after it are the
operator's, and the two are worth telling apart."
  :group 'parley)

(defface parley-tool-run '((t :inherit shadow))
  "Face for the one line a run of tool calls collapses to."
  :group 'parley)

(defvar parley-transcript--markdown-buffer nil
  "The buffer assistant text is fontified in, nil before there is one.")

(defun parley-transcript--fontify-buffer ()
  "Return the buffer assistant text is fontified in, creating it if there is none.

One buffer for every message of every session, because turning
markdown-mode on costs about as much as fontifying the paragraph
does and a fresh temporary buffer per message pays it thousands
of times over a long conversation.  Measured over 300 messages of
a paragraph each: 0.84 s with a temporary buffer per message
against 0.44 s with one buffer reused.

`delay-mode-hooks' keeps the operator's `markdown-mode-hook' out
of a buffer he will never see.  With the leading space in the
name it keeps font lock out too: `font-lock-mode' refuses a
buffer whose name starts with a space, and nothing here runs
`after-change-major-mode-hook' for `global-font-lock-mode' to act
on -- so there is no jit-lock here and `font-lock-ensure' is the
plain fontify-region it looks like.

`markdown-toggle-markup-hiding' is on because the markup that is
hidden with a `display' property -- a heading's `#', a
blockquote's `>', a list bullet, a horizontal rule -- is the
markup markdown-mode only marks when `markdown-hide-markup' is
non-nil.  What it marks `invisible' it marks either way."
  (unless (buffer-live-p parley-transcript--markdown-buffer)
    (setq parley-transcript--markdown-buffer
          (get-buffer-create " *parley-markdown*"))
    (with-current-buffer parley-transcript--markdown-buffer
      (delay-mode-hooks (markdown-mode))
      (markdown-toggle-markup-hiding 1)))
  parley-transcript--markdown-buffer)

(defconst parley-transcript--fontified-properties
  '((face . font-lock-face) (invisible . invisible) (display . display))
  "The properties copied out of the fontify buffer, and what each becomes.
`face' becomes `font-lock-face' because font lock runs in the
transcript buffer and strips `face'.  `invisible' and `display'
are what markdown-mode hides markup with, and neither is in
`font-lock-extra-managed-props', so both come through it.")

(defvar parley-transcript--fontified-tables nil
  "The tables the last `parley-transcript--fontify' found, newest call only.
A list of (START . END) offsets into the text that call was
given.  It is set on every call and read by the render pass right
after it, which is the whole of its life: a table's place in the
buffer is the overlay's business from then on.

Not buffer local, because the buffer it is written in is the
fontify buffer and the buffer it is read in is the transcript.")

(defun parley-transcript--tables ()
  "Return the tables in this buffer, as (START . END) offsets from `point-min'.

A table is what markdown-mode calls one, and a table inside a
fenced code block is not one: `markdown-table-at-point-p' asks
`markdown-code-block-at-point-p', which reads the syntax
markdown-mode propertized the fence with.  Here is the only
place that is known -- the transcript buffer is a comint buffer
and holds no markdown syntax at all, so a pass over the finished
text could not tell a table an agent wrote from one it was
quoting.

END of a table is the end of its last line and not the newline
after it, so that the overlay laid over one covers the table and
nothing else."
  (let ((start (point-min))
        (tables nil))
    (save-excursion
      (goto-char start)
      (while (not (eobp))
        (if (not (markdown-table-at-point-p))
            (forward-line 1)
          (let ((begin (markdown-table-begin))
                (end (markdown-table-end)))
            (goto-char end)
            (when (eq (char-before end) ?\n)
              (setq end (1- end)))
            (push (cons (- begin start) (- end start)) tables)))))
    (nreverse tables)))

(defun parley-transcript--fontify (text)
  "Return TEXT as markdown-mode fontifies it, in `font-lock-face' properties.

The fontification happens in `parley-transcript--fontify-buffer'
and not in the transcript buffer, because markdown fontification
is not a set of keywords that can be lifted out of markdown-mode:
fences and inline code are found by its syntax table and its
`syntax-propertize-function', so the keywords alone would give a
broken subset -- and font lock in the transcript buffer would
refontify the whole conversation on every append.

`parley-transcript--fontified-properties' is copied onto a clean
string rather than the buffer string being taken whole, because
markdown-mode also leaves `markdown-heading', `font-lock-multiline'
and, over an HTML comment, a `syntax-table' property behind, and
the transcript buffer has business with none of them -- a
`syntax-table' property in a comint buffer least of all.  `face'
in particular has to go: comint sets `font-lock-defaults' to
`(nil t)', which is not nil, so global font lock turns font lock
on in that buffer with no keywords at all, where the only thing
it can do is strip -- and `face' is exactly what
`font-lock-default-unfontify-region' removes.  `font-lock-face'
survives it, and is what comint itself puts on its prompt and its
input.  Both were measured.

Each property is walked over its own runs and not over the face
runs, because `markdown-fontify-sub-superscripts' puts `display'
on text that carries no face at all.

The tables TEXT holds are left in
`parley-transcript--fontified-tables' on the way past, because
this is the one buffer that knows where they are."
  (with-current-buffer (parley-transcript--fontify-buffer)
    (erase-buffer)
    (insert text)
    (font-lock-ensure)
    (setq parley-transcript--fontified-tables (parley-transcript--tables))
    (let ((string (substring-no-properties (buffer-string)))
          (start (point-min)))
      (dolist (copy parley-transcript--fontified-properties)
        (let ((property (car copy))
              (position start))
          (while (< position (point-max))
            (let ((next (next-single-property-change
                         position property nil (point-max)))
                  (value (get-text-property position property)))
              (when value
                (put-text-property (- position start) (- next start)
                                   (cdr copy) value string))
              (setq position next)))))
      string)))

(defun parley-transcript--record (line)
  "Return the projected object LINE holds, nil if it holds none.
A line in this buffer is not always JSON: `tail -F' reports a
transcript that does not exist yet on stderr, which shares the
buffer, and a pipeline that died mid-object left half of one."
  (and (string-prefix-p "{" line)
       (ignore-errors (json-parse-string line :object-type 'alist))))

(defun parley-transcript--block (string)
  "Return STRING as one block of buffer text, or nothing if it says nothing.
A block is a blank line, then STRING, then a newline.  So turns
stand apart, and the last line of the buffer is always the last
line of the last block -- which is what
`parley-transcript--take-back-run' stands on."
  (let ((trimmed (string-trim-right string)))
    (if (string= trimmed "") "" (concat "\n" trimmed "\n"))))

(defun parley-transcript--quote (text)
  "Return the block of buffer text the operator's turn TEXT renders to.
It is quoted and otherwise left alone: what he typed at a
terminal is not markdown, and fontifying it as though it were
would invent emphasis he never wrote.  The `> ' the quoting adds
carries `parley-user-marker' and the words it stands in front of
carry `parley-user', so the renderer's mark and the operator's
text can be coloured apart.

It is trimmed at both ends, and not only on the right.  The first
character of the block is where the imenu index points and the
first line of it is what the entry is labelled with, so a prompt
that opened with a blank line would put a quoted blank line under
both.

Every turn of his comes through here, the one the transcript
delivered and the one he submitted at the prompt alike, so that
the two cannot come out looking different."
  (let ((trimmed (string-trim text)))
    (if (string= trimmed "")
        ""
      (let ((block (parley-transcript--block
                    (propertize (replace-regexp-in-string "^" "> " trimmed)
                                'font-lock-face 'parley-user)))
            (position 0))
        ;; The newline ending a line is what its background is painted
        ;; from, so the one the block closes with carries the face
        ;; too: without it the last line of a turn stops at its last
        ;; character while every line above it runs to the edge.  The
        ;; newline the block opens with is left bare, because that
        ;; blank line is between two turns and belongs to neither.
        (put-text-property (1- (length block)) (length block)
                           'font-lock-face 'parley-user block)
        (while (string-match "^> " block position)
          (put-text-property (match-beginning 0) (match-end 0)
                             'font-lock-face 'parley-user-marker block)
          (setq position (match-end 0)))
        block))))

(defun parley-transcript--speech (record)
  "Return the block of buffer text RECORD said, nothing if it said nothing.
An assistant turn is markdown and is fontified as markdown, and
the operator's own is quoted by `parley-transcript--quote'."
  (let ((text (string-trim-right (or (alist-get 'text record) ""))))
    (cond
     ((string= text "") "")
     ((equal (alist-get 'role record) "assistant")
      (parley-transcript--block (parley-transcript--fontify text)))
     (t (parley-transcript--quote text)))))

(defun parley-transcript--tool-run (count)
  "Return the block of buffer text a run of COUNT tool calls collapses to.
The operator wants the conversation, so the calls an agent made
on its way to an answer are worth exactly one line however many
of them there were.  The pane is still there for anyone who wants
to watch the work."
  (parley-transcript--block
   (propertize (format "%d tool call%s" count (if (= count 1) "" "s"))
               'font-lock-face 'parley-tool-run)))

(defvar-local parley-transcript--partial ""
  "Output that has arrived without the newline that would end it.")

(defvar-local parley-transcript--run 0
  "How many tool calls the run of them at the end of the buffer made.
Zero when the buffer does not end in a run.")

(defvar-local parley-transcript--pending nil
  "The prompts the last render pass produced, as a list of (TEXT . OFFSET).
OFFSET counts from the first character of the string that pass
returned.  It is an offset and not a buffer position because the
string has not been inserted yet, which is also why the list
outlives the pass: `parley-transcript--index-output' turns each
into a position once comint has inserted it, and empties this.")

(defvar-local parley-transcript--pending-tables nil
  "The tables the last render pass produced, as a list of (START . END).
Offsets into the string that pass returned, for the reason
`parley-transcript--pending' holds offsets, and turned into the
overlay over each table by `parley-transcript--align-output' once
comint has inserted that string.")

(defun parley-transcript--take-back-run ()
  "Delete the tool run block at the end of the buffer, and say if it went.

A run cannot be counted until it has ended, so a line that waited
for the count would appear only once the agent had stopped
working -- which is the frozen session `--unbuffered' exists to
prevent.  The line is written as soon as the run starts and
rewritten as the run grows instead, and taking the old one back
out is how it is rewritten.

Only if it is still there to take.  The operator can type into
this buffer, and comint moves the process mark past what he
typed, so what sits at the end may not be this line at all.  Text
that is not the block this run emitted is left alone and the
caller starts the count over, which is the truth about the
buffer: something else is now between the calls."
  (let* ((end (marker-position
               (process-mark (get-buffer-process (current-buffer)))))
         (start (save-excursion (goto-char end) (forward-line -2) (point)))
         (block (parley-transcript--tool-run parley-transcript--run)))
    (when (equal (buffer-substring-no-properties start end)
                 (substring-no-properties block))
      (let ((inhibit-read-only t))
        ;; comint binds this around its own insertion but not around
        ;; the preoutput filters, which is where this runs.
        (delete-region start end))
      t)))

(defun parley-transcript--filter (string)
  "Return the buffer text the newly arrived STRING renders to.

STRING is whatever the pipeline has written since the last time,
and it holds whole lines only by luck, so the tail of it after
the last newline is held in `parley-transcript--partial' until
the rest of that line arrives.

This runs on `comint-preoutput-filter-functions' rather than on
`comint-output-filter-functions': the projected objects are
replaced by what they render to on the way in, instead of being
inserted and then rewritten in place."
  (let* ((lines (split-string (concat parley-transcript--partial string) "\n"))
         (complete (butlast lines)))
    (setq parley-transcript--partial (car (last lines)))
    (if (null complete)
        ;; Nothing to render, and in particular no reason to take the
        ;; run line at the end of the buffer back out and put the very
        ;; same one back.
        ""
      (let ((run parley-transcript--run)
            (blocks nil)
            (offset 0))
        (when (and (> run 0) (not (parley-transcript--take-back-run)))
          (setq run 0))
        (dolist (line complete)
          (let* ((record (parley-transcript--record line))
                 (speech (cond
                          ((null record) (parley-transcript--block line))
                          ;; comint has already put this one in the
                          ;; buffer; the transcript is only agreeing.
                          ((parley-transcript--echoed-p record) "")
                          (t (parley-transcript--speech record)))))
            ;; Anything the turn said ends the run that came before it,
            ;; and the calls it went on to make carry into the next
            ;; turn.  A turn that said nothing and only called tools is
            ;; therefore not a break in the run.
            (unless (string= speech "")
              (when (> run 0)
                (push (parley-transcript--tool-run run) blocks)
                (setq offset (+ offset (length (car blocks))))
                (setq run 0))
              ;; A prompt is an imenu entry, and here is where its
              ;; position is known: one character into the block it is
              ;; about to be, past the blank line every block opens
              ;; with.  Nothing an agent said or did is indexed, so
              ;; only this branch records anything.
              (when (equal (alist-get 'role record) "user")
                (push (cons (alist-get 'text record) (1+ offset))
                      parley-transcript--pending))
              ;; A table is recorded here for the same reason, and the
              ;; same one character in: `parley-transcript--fontify'
              ;; found it in the fontify buffer, which is the only
              ;; buffer that can tell a table from a table inside a
              ;; fence, and left where it was behind it.  Only what
              ;; that call rendered, so the branch has to be the one
              ;; that called it.
              (when (equal (alist-get 'role record) "assistant")
                (dolist (table parley-transcript--fontified-tables)
                  (push (cons (+ offset 1 (car table))
                              (+ offset 1 (cdr table)))
                        parley-transcript--pending-tables)))
              (push speech blocks)
              (setq offset (+ offset (length speech))))
            (setq run (+ run (or (alist-get 'tools record) 0)))))
        (setq parley-transcript--run run)
        (when (> run 0)
          (push (parley-transcript--tool-run run) blocks))
        (mapconcat #'identity (nreverse blocks) "")))))


;;; Aligning the tables

;; A table lines up only if the agent lined it up, and a table whose
;; columns do not line up is a table nobody reads.  The alignment is a
;; rendering and not an edit: an overlay over the table carries the
;; aligned form in a `display' property, and the text under it is the
;; text the transcript delivered.
;;
;; That is what lets the rendering be recomputed when the window
;; changes width.  Nothing refontifies or rewrites this buffer after
;; an insertion, by design, so text written once on the way in could
;; never answer a resize -- and what the rendering is computed from is
;; the text under the overlay, so recomputing it needs no record of
;; anything.

(defvar-local parley-transcript--aligned-width nil
  "The window width this buffer's tables were last aligned to, nil for none.
`parley-transcript--realign-tables' runs on a hook that a resize
is only one of the reasons for, and this is what tells the resize
from the rest.")

(defun parley-transcript--width ()
  "Return the columns a table in this buffer has to fit in.

The body of a window showing the buffer, and the selected
window's when none does -- which is what an alignment computed
before the buffer was ever displayed has to stand on.

An overlay is the buffer's and not a window's, so a buffer shown
in two windows of different widths is aligned to whichever of
them changed last."
  (window-body-width (get-buffer-window (current-buffer) t)))

(defun parley-transcript--aligned (text width)
  "Return TEXT with its columns aligned, nil if the result needs more than WIDTH.

Aligned by markdown-mode's own `markdown-table-align', in the
buffer `parley-transcript--fontify' renders in: what the operator
would get by aligning the table himself is what he should get
from reading it.

Nil if the aligned form is wider than WIDTH, because alignment
only ever adds padding -- so a table that has to be wrapped to
fit is one alignment has pushed further past the edge, and the
columns it would have lined up are broken by the wrap anyway.
The text the agent wrote is shown instead, which is the narrower
of the two.

Nil, too, if TEXT is no longer a table: the operator can edit in
this buffer, and what is under the overlay is what the aligned
form is computed from.

Nil as well for a table of nothing but delimiter rows, which has
nothing in it to line up: `markdown-table-align' formats from the
cells, a delimiter row carries none, and with no row of data left
it raises `Empty table' rather than saying so.  Whether a row is
one is asked with markdown-mode's own
`markdown--is-delimiter-row', because that is the predicate the
caller which raises sorts the rows with -- `| --- | --- |' is a
delimiter row, and anything reading the character after the bar
takes it for a row of data.

Nil, last, when the aligned form does not say what TEXT says.  A
row with no bar at the end of it loses its last cell to
`markdown--table-line-to-columns' -- measured against the
repository's markdown-mode, the three lines of `| a', `|---' and
`| 1' align to three bare bars -- and a `display' property showing
that is a cell of the agent's the operator cannot read at all.
The text as he wrote it is shown instead.

The face is on the string and not on the text under it.  What a
`display' property shows is the string's own properties, and the
`font-lock-face' markdown-mode left on the buffer text never
reaches the screen through one."
  (with-current-buffer (parley-transcript--fontify-buffer)
    (erase-buffer)
    (insert text)
    (goto-char (point-min))
    (when (and (markdown-table-at-point-p)
               (not (seq-every-p #'markdown--is-delimiter-row
                                 (split-string text "\n"))))
      (markdown-table-align)
      (let ((aligned (string-trim-right
                      (buffer-substring-no-properties (point-min) (point-max))
                      "\n")))
        (when (and (equal (parley-transcript--table-content aligned)
                          (parley-transcript--table-content text))
                   (<= (parley-transcript--columns aligned) width))
          (propertize aligned 'face 'markdown-table-face))))))

(defun parley-transcript--table-content (text)
  "Return what TEXT says, with everything the alignment may move taken out.

The spaces a cell is padded with, the bars between two of them
and the dashes and colons a delimiter row is written from -- so
two forms of one table answer this the same way exactly when they
hold the same cells, whatever either does with the width of a
column.

A cell's own dashes and colons go with them, which can only make
two forms agree and never make them differ: what this is asked is
whether the alignment dropped anything, and the answer may not be
yes when it did not."
  (replace-regexp-in-string "[ \t|:-]" "" text))

(defun parley-transcript--columns (text)
  "Return how many columns the widest line of TEXT takes up on screen.
`string-width' and not `length', because a table of CJK text is
aligned in columns and lines up in none."
  (apply #'max 0 (mapcar #'string-width (split-string text "\n"))))

(defun parley-transcript--align-overlay (overlay width)
  "Show the table under OVERLAY aligned to WIDTH columns.

An overlay left empty is dropped rather than realigned.  Nothing
brings its ends together but the deletion of every line of its
table -- `comint-truncate-buffer' taking the top of the
conversation away, or the operator killing a stretch of it -- and
an overlay over no text is an overlay nothing can bring back."
  (if (= (overlay-start overlay) (overlay-end overlay))
      (delete-overlay overlay)
    (overlay-put overlay 'display
                 (parley-transcript--aligned
                  (buffer-substring-no-properties (overlay-start overlay)
                                                  (overlay-end overlay))
                  width))))

(defun parley-transcript--align-output (_string)
  "Lay an overlay over each table the last render pass produced, and align it.

On `comint-output-filter-functions', for the reason
`parley-transcript--index-output' is: the render pass ran before
the insertion and could only say how far into its string each
table was, and comint has just inserted that string at
`comint-last-output-start'.

The overlay takes in neither what is inserted at its start nor
what is inserted at its end, because a table's own text is all it
may show in place of.

STRING is what the hook is called with and is not looked at: what
arrived is already in the buffer."
  (when parley-transcript--pending-tables
    (let ((width (parley-transcript--width)))
      (dolist (table parley-transcript--pending-tables)
        (let ((overlay (make-overlay (+ comint-last-output-start (car table))
                                     (+ comint-last-output-start (cdr table))
                                     nil t)))
          (overlay-put overlay 'parley-table t)
          (parley-transcript--align-overlay overlay width))))
    (setq parley-transcript--pending-tables nil)))

(defun parley-transcript--realign-tables ()
  "Align this buffer's tables to the width of the window showing it.

On `window-configuration-change-hook', whose buffer-local value
Emacs runs for each window showing the buffer once that window
has changed its body size -- with the window selected, so the
width read here is that window's.

It runs on a window being added, deleted or given another buffer
as well, and the tables are recomputed on none of those: the
aligned form follows from the text and the width alone, so
nothing but a width that has changed can change it."
  (let ((width (parley-transcript--width)))
    (unless (eq width parley-transcript--aligned-width)
      (setq parley-transcript--aligned-width width)
      (dolist (overlay (overlays-in (point-min) (point-max)))
        (when (overlay-get overlay 'parley-table)
          (parley-transcript--align-overlay overlay width))))))


;;; The imenu index

;; Navigating a long conversation means jumping between the prompts in
;; it, which is what imenu is for.  The index is recorded as the
;; messages are inserted, because that is where the position of a
;; message is already known: the render pass has the record in hand
;; and the offset of the block it made of it, and going back over the
;; finished buffer instead would mean parsing rendered text into the
;; structure that was in hand a moment earlier.

(defvar-local parley-transcript--index nil
  "The prompts in this buffer as (LABEL START END), newest first.
START is where the prompt begins, and is what the imenu entry
made of this points at.  END is the end of the line START is on,
which is the line LABEL names: it is there to say whether that
line is still in the buffer, because deleting it is what brings
the two markers together and nothing else does.")

(defun parley-transcript--index-truncate (string limit)
  "Return STRING cut to LIMIT, in characters as well as in columns.

`truncate-string-to-width' counts the columns a string displays
in, and `imenu--truncate-items' cuts with `substring', which
counts characters -- and a combining mark is a character that
displays in no column at all.  A label cut to the limit in
columns is therefore not always inside it in characters, and
imenu would cut what is over a second time, taking the end off a
label this file had already made as long as it may be.

Cutting both ways leaves imenu nothing to cut: the columns first,
which is what puts the ellipsis on the end, and the characters
after."
  (let ((short (truncate-string-to-width string limit nil nil t)))
    (if (> (length short) limit) (substring short 0 limit) short)))

(defun parley-transcript--index-label (text)
  "Return the imenu label for the prompt TEXT, nil if it has nothing to say.

The first line of the prompt that says anything, which is what
the operator will look for; how many messages ago it was is no
help to him.  The
prompt is trimmed first and its first line taken after that, so
that the line this names is the line the entry points at --
`parley-transcript--speech' trims it the same way before quoting
it, and the two would otherwise disagree about where a prompt
that opened with a blank line begins.  A prompt that says nothing
at all has no label, and so gets no entry.

Truncated to `imenu-max-item-length', imenu's own variable for
this length and the reason there is not a second one here.  Doing
it here is what puts an ellipsis on the end, where
`imenu--truncate-items' cuts with `substring' -- and it leaves
that function nothing left to do."
  (let ((line (car (split-string (string-trim text) "\n"))))
    (cond ((string= line "") nil)
          ((numberp imenu-max-item-length)
           (parley-transcript--index-truncate line imenu-max-item-length))
          (t line))))

(defun parley-transcript--index-numbered (label n)
  "Return LABEL with `<N>' on the end, short enough for imenu to keep whole.

`imenu--truncate-items' cuts a label to `imenu-max-item-length'
with `substring', and it does so after
`imenu-create-index-function' has returned -- so a suffix hung
off a label already that long would be cut straight back off, and
the two entries it is there to tell apart would be under one name
again.  The label gives up the characters the suffix needs
instead, counted the way imenu counts them -- which is what
`parley-transcript--index-truncate' is for.  What comes back is
inside the limit already, so imenu leaves it alone.

All of them, when the suffix needs the whole of the limit: a
label that kept so much as its first character there would lose
the suffix in exchange, which is the one part of the name that
tells the two entries apart.  The number alone is what is left,
and it is still a name no other entry has.

A limit narrower than the number itself is where that stops, and
it is a limit too short to name anything by: the suffix is
returned whole, `imenu--truncate-items' cuts the number, and two
prompts numbered far enough apart can come back under one name
again -- at a limit of 3, `<100>' is cut to `<10' and lands on
the tenth.  Cutting it here instead would hand the entry a number
that is not its own, which is no better and no longer a number."
  (let* ((suffix (format "<%d>" n))
         (room (and (numberp imenu-max-item-length)
                    (- imenu-max-item-length (length suffix)))))
    (concat (cond ((null room) label)
                  ((<= room 0) "")
                  (t (parley-transcript--index-truncate label room)))
            suffix)))

(defun parley-transcript--index-prompt (text position)
  "Record the prompt TEXT, whose quote begins at POSITION, in the imenu index.

POSITION is the first character of the quote and not the blank
line the block around it opens with, because the line POSITION is
on is the line the label names.  `parley-transcript--quote' trims
the prompt before quoting it, so those are the same line whatever
the prompt opened with.

Positions are kept as markers and not as the numbers they are
now, because this buffer is deleted from as well as appended to
-- the tool run line at the end is taken back out whenever its
run grows -- and the operator can edit in it himself.  An entry
has to go on pointing at its prompt through all of that, or say
that its prompt is gone."
  (let ((label (parley-transcript--index-label text)))
    (when label
      (save-excursion
        (goto-char position)
        (push (list label (point-marker) (copy-marker (line-end-position)))
              parley-transcript--index)))))

(defun parley-transcript--index-output (_string)
  "Place the prompts the last render pass produced in the imenu index.

On `comint-output-filter-functions', which is the first moment
the text exists: `parley-transcript--filter' ran before the
insertion and could only say how far into its string each prompt
was, and comint has just inserted that string at
`comint-last-output-start'."
  (dolist (prompt (nreverse parley-transcript--pending))
    (parley-transcript--index-prompt
     (car prompt) (+ comint-last-output-start (cdr prompt))))
  (setq parley-transcript--pending nil))

(defun parley-transcript--imenu-index ()
  "Return this buffer's prompts as an imenu index, in buffer order.

The buffer's `imenu-create-index-function', and it parses
nothing: every entry was recorded as its prompt was inserted, so
all this does is hand over what is already there.

All but the prompts that have since been deleted, which is the
one thing the recording cannot know.  `comint-truncate-buffer' is
how a comint buffer is kept from growing without end and it
deletes from the top, as does an operator killing a stretch of
conversation he is done with.  A marker in what went does not die
with it -- it survives at the boundary of the deletion, where it
points at whatever text is there now -- so an entry is dropped
once its two markers have met, which is to say once the line its
label names has been deleted out from between them.  Dropping it
from the list is also what lets those two markers go.

Two prompts whose first line is the same have one label, and
`imenu' resolves what the operator picked back to an entry with
`assoc' -- so the second of them would be in the index, would be
offered once, and would answer with the first.  A label an entry
here already carries therefore gets `<2>' on the end and the one
after that `<3>', the way Emacs tells two buffers of one name
apart.  The number is read off the entries already placed here,
because those are what the operator is choosing between: how many
messages came before a prompt is no more help in telling two of
them apart than it was in naming one.

One pass over the prompts in buffer order, which is also all
`generate-new-buffer-name' takes: a prompt whose own first line
is `foo<2>' collides with the `foo<2>' an earlier duplicate of
`foo' was handed, and is renamed `foo<2><2>' as a buffer of that
name would be."
  (setq parley-transcript--index
        (seq-filter (lambda (entry) (< (nth 1 entry) (nth 2 entry)))
                    parley-transcript--index))
  ;; Two tables and not a walk over the list being built, because
  ;; this runs on every `M-x imenu' -- `imenu-auto-rescan' is on in
  ;; this buffer -- and the conversation it is here for is the one
  ;; with hundreds of prompts in it.  `names' answers what `assoc'
  ;; over that list would: 5000 prompts no two of which share a label
  ;; cost 459 ms that way against 61 ms here.  `counts' holds the
  ;; number the last prompt of a label took, so the next of them
  ;; builds one candidate instead of every candidate from 2 up: 200
  ;; prompts under one label cost 321 ms without it, and 1000 of
  ;; them 6.8 s.
  (let ((index nil)
        (names (make-hash-table :test 'equal))
        (counts (make-hash-table :test 'equal)))
    (dolist (entry (reverse parley-transcript--index) (nreverse index))
      (let ((label (car entry))
            (n (gethash (car entry) counts 1)))
        (while (gethash label names)
          (setq n (1+ n))
          (setq label (parley-transcript--index-numbered (car entry) n)))
        (puthash (car entry) n counts)
        (puthash label t names)
        (push (cons label (nth 1 entry)) index)))))

;;; The buffer

(defvar-local parley-transcript-session nil
  "The session record this buffer follows, nil in a buffer that follows none.
It is the plist `parley-sessions' returned for that session.")

(define-derived-mode parley-transcript-mode comint-mode "Parley"
  "Major mode for the transcript of a Claude Code session.

The process writes one projected JSON object per message and
`parley-transcript--filter' renders each into the buffer text
that stands for it, so what the buffer holds is the conversation
and never the objects."
  ;; `ansi-color-process-output' is in the default value of
  ;; `comint-output-filter-functions' as of Emacs 28, and `jq -M'
  ;; leaves it nothing to find: measured over the 26 MB transcript, not
  ;; one escape byte reaches the buffer.  Scanning the 1.3 MB for them
  ;; anyway costs 2.4 s of the 6.9 s that history takes to settle, and
  ;; not spending Emacs's one thread on a search that cannot succeed is
  ;; the whole reason jq is in this pipeline.
  (setq-local comint-output-filter-functions
              (remq 'ansi-color-process-output comint-output-filter-functions))
  ;; The markup markdown-mode marked `invisible markdown-markup' is
  ;; hidden by the reading buffer's spec and not by the property, and
  ;; the default spec of t would hide it without this -- but it is one
  ;; `add-to-invisibility-spec' from anywhere else away from being a
  ;; list this value is not in.
  (add-to-invisibility-spec 'markdown-markup)
  ;; A preoutput filter, so the objects are turned into conversation on
  ;; the way in rather than inserted and rewritten in place.
  (add-hook 'comint-preoutput-filter-functions #'parley-transcript--filter
            nil t)
  ;; The pipeline reads a file and nothing else, so its stdin is not a
  ;; way to reach the session.  What the operator submits goes to the
  ;; session's tmux pane instead, which is the door that does reach it.
  (setq-local comint-input-sender #'parley-transcript--send-input)
  ;; What RET on a past turn sends.  comint's default reads the `field'
  ;; property, which stands for something else in this buffer.
  (setq-local comint-get-old-input #'parley-transcript--old-input)
  (setq-local imenu-create-index-function #'parley-transcript--imenu-index)
  ;; imenu remembers the index it built for a buffer and, left at its
  ;; default, never builds it again; switched on, it gives up again
  ;; above `imenu-auto-rescan-maxout'.  Both guards are there to keep
  ;; imenu from re-parsing a large buffer, and there is nothing here to
  ;; parse -- the index is recorded as the conversation arrives and the
  ;; function above only hands it over.  A transcript grows for as long
  ;; as its session runs, and the 26 MB one renders to 1.3 MB of buffer
  ;; against a 600 KB default, so the operator would be reading a
  ;; conversation whose index stopped at the message he opened it on.
  (setq-local imenu-auto-rescan t)
  (setq-local imenu-auto-rescan-maxout most-positive-fixnum)
  ;; After `comint-output-filter-functions' has been given its local
  ;; value above, and not before: `add-hook' would otherwise create
  ;; that binding itself, with the t in it that runs the global value
  ;; as well -- and the global value is where
  ;; `ansi-color-process-output' is, which this mode has just taken
  ;; pains to drop.
  (add-hook 'comint-output-filter-functions
            #'parley-transcript--index-output nil t)
  ;; Where the tables the render pass found are is known here and not
  ;; afterwards, for the reason the index is.
  (add-hook 'comint-output-filter-functions
            #'parley-transcript--align-output nil t)
  ;; The aligned form of a table is what fits the window, so it is
  ;; computed again when the window changes width.  Buffer locally,
  ;; which is what has Emacs run it for each window showing this
  ;; buffer with that window selected.
  (add-hook 'window-configuration-change-hook
            #'parley-transcript--realign-tables nil t)
  ;; The zone the operator types in starts at the process mark, and
  ;; comint has just moved that mark past what it inserted, so the
  ;; overlay that marks the zone is put back after every output.
  (add-hook 'comint-output-filter-functions
            #'parley-transcript--mark-input-zone nil t))

(defun parley-transcript-buffer-name (session)
  "Return the name of the buffer that follows SESSION.
The name carries the session's name and its tag, which is the two
the switcher lists it under.  The name `claude agents' gives a
session is not unique -- two in sibling worktrees come back under
one, and two live sessions can even share a pane -- so what makes
this name one session's own is `parley-session-tag'."
  (format "*parley: %s %s*"
          (or (plist-get session :name) "unnamed")
          (parley-session-tag session)))

(defun parley-transcript--buffer (session)
  "Return the buffer to show SESSION in, creating it if there is none.

The buffer is found by the session id it records and not by its
name.  The name tells two live sessions apart, but a session that
has ended leaves its buffer behind with its name still on it, and
the next session in that pane would be handed it.

`generate-new-buffer' is therefore what creates it: a name taken
by such a leftover is not a name this session can have."
  (or (seq-find (lambda (buffer)
                  (equal (plist-get (buffer-local-value 'parley-transcript-session
                                                        buffer)
                                    :session-id)
                         (plist-get session :session-id)))
                (buffer-list))
      (generate-new-buffer (parley-transcript-buffer-name session))))

;;;###autoload
(defun parley-transcript (session)
  "Show the transcript of SESSION in a comint buffer.
SESSION is a record as `parley-sessions' returns them.
Interactively, one is read in the minibuffer with
`parley-read-session', which is the reader the switcher falls
back to when sallet is missing: the same rows, in the same order.

The buffer's process delivers the transcript from its first byte
and then follows the file, so nothing appended while the history
was arriving is missed.  It is stopped when the buffer is killed.

A buffer already following SESSION is shown as it stands, process
and history and all."
  (interactive (list (parley-read-session)))
  (let ((buffer (parley-transcript--buffer session)))
    (unless (comint-check-proc buffer)
      (with-current-buffer buffer
        (parley-transcript-mode)
        ;; The session's own working directory, so that what the
        ;; operator does in this buffer happens where the session he is
        ;; reading is working.  Only if it is still there: a worktree
        ;; can be removed out from under a session that is still
        ;; running, and a process cannot be started in a directory that
        ;; is gone -- which would leave the conversation unreadable
        ;; over a directory nothing here needs.
        (let ((cwd (plist-get session :cwd)))
          (when (and cwd (file-directory-p cwd))
            (setq default-directory (file-name-as-directory cwd))))
        ;; `sh' by name and not `shell-file-name', which is whatever
        ;; the operator's SHELL is: `shell-quote-argument' quotes for
        ;; POSIX sh, so a login shell with other quoting rules -- fish,
        ;; say -- would be handed a command quoted for a shell it is
        ;; not.
        ;;
        ;; A pipe, and bound here rather than inherited:
        ;; `comint-exec-1' calls `start-file-process' without binding
        ;; `process-connection-type', so whatever it happens to be is
        ;; what parley would get.
        ;;
        ;; A pipe rather than a pty for two measured reasons.  It is
        ;; what makes `--unbuffered' mean anything: to a terminal jq
        ;; line buffers on its own, so on a pty the flag is dead and
        ;; its absence cannot be noticed until the day something else
        ;; changes.  And it is much the faster of the two -- the 26 MB
        ;; transcript settles in 4.5 s over a pipe against 10.1 s over
        ;; a pty, which is the cost of a terminal line discipline
        ;; between jq and Emacs.
        ;;
        ;; Killing the buffer stops the pipeline either way: Emacs puts
        ;; the process in a group of its own whichever it allocates,
        ;; and signals the group, so `sh', `tail' and `jq' go together.
        (let ((process-connection-type nil))
          (make-comint-in-buffer
           (buffer-name) buffer "sh" nil "-c"
           (parley-transcript--command (plist-get session :transcript))))
        ;; The pipeline has no state to lose, so there is nothing to
        ;; stop and ask the operator about.
        (set-process-query-on-exit-flag (get-buffer-process buffer) nil)
        ;; Before anything has arrived, because a session whose
        ;; transcript is still empty renders nothing at all: no output
        ;; means no output filter, and the operator would be typing
        ;; into a buffer with nothing in it to type at.
        (parley-transcript--mark-input-zone)))
    ;; After the mode, which is what `kill-all-local-variables' would
    ;; otherwise clear this out of -- and outside the guard above,
    ;; because a buffer already following this session is following the
    ;; record it was opened with, and what `claude agents' says about a
    ;; session goes stale.
    (with-current-buffer buffer (setq parley-transcript-session session))
    (pop-to-buffer buffer)))


;;; Typing into the pane

;; `comint-accumulate' opens a line in the input zone and submits
;; nothing, which is the whole of what a block needs.  comint binds it
;; to `C-c SPC', which nobody guesses, and `S-<return>' is where every
;; chat program puts it.
(define-key parley-transcript-mode-map (kbd "S-<return>") #'comint-accumulate)

;; Everything past the process mark is what the operator has typed and
;; not yet sent, and nothing in the buffer says so: the pipeline emits
;; no prompt, so his text is the tail of a buffer whose tail is
;; otherwise conversation.  What says it is an overlay from the mark to
;; the end of the buffer -- an overlay, because the zone holds no text
;; until something is typed and an empty zone is when he most needs to
;; see where it is.
;;
;; Nothing it shows may be buffer text.  `comint-send-input' sends
;; (buffer-substring (process-mark proc) (field-end)), so anything
;; written into the buffer to mark the zone is typed into the session
;; along with the message.

(defface parley-input
  '((((background light)) :background "#e3ebf6" :extend t)
    (((background dark)) :background "#232b38" :extend t)
    (t :extend t))
  "Face for the zone at the end of the buffer holding what is not yet sent.
It is worn by an overlay and not by the text, which is what lets
an empty zone carry it.  `:extend' is what carries the background
past the last character of a line to the window edge."
  :group 'parley)

(defface parley-input-marker '((t :inherit (parley-input shadow)))
  "Face for the mark at the head of the input zone.
It inherits `parley-input' first, so the mark stands on the same
band as the zone it marks, and takes only what that face leaves
unspecified -- the foreground -- from `shadow'."
  :group 'parley)

(defconst parley-transcript--input-marker
  (propertize "> " 'face 'parley-input-marker)
  "What stands at the head of the input zone.
The zone's overlay shows it as its `before-string', which is
displayed and is not in the buffer -- and what
`comint-send-input' sends is buffer text from the process mark
on.  It is the `> ' every turn of the operator's is quoted with,
because what he is typing is the turn it is about to be.")

(defconst parley-transcript--input-fill
  (propertize " " 'display '(space :align-to right)
              'face 'parley-input 'cursor t)
  "What carries the band across the last line of the input zone.
The zone's overlay shows it as its `after-string'.  `:extend'
paints from the newline that ends a line, and the last line of
the zone is the last line of the buffer and ends in none, so that
one line is painted by a space stretched to the right edge
instead -- measured on Emacs 28.2 in a 191 column terminal, the
background under a face with `:extend t' stops at the last
character of a line with no newline after it and runs to the edge
of the window on every line that has one.

`cursor' is what keeps point drawn at the head of that stretched
space rather than at the far end of it, where the operator would
be watching a cursor at the window edge as he typed: measured the
same way, point at the end of the buffer is drawn in column 190,
the last column of the window, without it.")

(defvar-local parley-transcript--input-overlay nil
  "The overlay marking the input zone, nil in a buffer that has none.")

(defun parley-transcript--mark-input-zone (&optional _string)
  "Put the overlay that marks the input zone over the end of the buffer.

The zone runs from the process mark, which is where
`comint-send-input' reads what it sends from, to the end of the
buffer.  The overlay takes text in at its end and not at its
start, so that what the operator types joins the zone and what
the render pass inserts at the mark does not.

It is put back and not merely made, because the mark it starts at
moves: comint inserts output at that mark and moves the mark past
what it inserted, so the zone is pushed down the buffer every
time the session says anything.  That is what
`comint-output-filter-functions' runs after, and
`comint-send-input' runs the same hook with an empty string once
the sender has returned, so a send is covered by it too -- the
block `parley-transcript--render-input' leaves behind has moved
the mark by then.

Nothing here writes to the buffer, so the two lines before the
mark that `parley-transcript--take-back-run' compares against the
block it last wrote read as they read before.

STRING is what that hook is called with and is not looked at: the
zone is wherever the mark is now."
  (let* ((process (get-buffer-process (current-buffer)))
         (start (and process (marker-position (process-mark process)))))
    (when start
      (if (overlayp parley-transcript--input-overlay)
          (move-overlay parley-transcript--input-overlay start (point-max))
        (setq parley-transcript--input-overlay
              (make-overlay start (point-max) nil nil t))
        (overlay-put parley-transcript--input-overlay 'face 'parley-input)
        (overlay-put parley-transcript--input-overlay 'before-string
                     parley-transcript--input-marker)
        (overlay-put parley-transcript--input-overlay 'after-string
                     parley-transcript--input-fill)))))

(defvar-local parley-transcript--sent nil
  "What has been sent from this buffer and not yet come back, as a list of texts.
Every send is outstanding until the transcript delivers it, and
not only the last one: a session that is working holds everything
submitted at it until the turn it is on has finished, so the
operator can have several messages in flight at once.

What order the list is in does not matter, since what is looked
up in it is the text.  Two entries saying the same thing stand
for two messages, and the one that arrives may be taken for
either.")

(defun parley-transcript--echoed-p (record)
  "Non-nil if RECORD is the transcript delivering what was sent from here.

`parley-transcript--render-input' has already put what the
operator submitted in the buffer, and the session writes the same
message to its transcript seconds later, so without this every
prompt appears twice.

One entry is spent on the first user message that matches it, and
not every entry of that text: a second message saying the very
same thing was typed at the pane, or submitted here twice, and is
shown.  So is everything else the operator typed at the pane,
which matches nothing that was sent from here.

There is no bound on how late the transcript's copy may be,
because there is no bound on how late it comes: a session that
was busy when the message arrived holds the input until the turn
it was working on has finished, and writes it minutes later if
that turn was long -- and the message has to appear once whenever
it lands.  What that costs is a message that never reaches the
transcript at all, which leaves its entry standing: the next
message of the same text typed at the pane is then taken for it
and dropped."
  (and (equal (alist-get 'role record) "user")
       (let ((rest (member (string-trim (or (alist-get 'text record) ""))
                           parley-transcript--sent)))
         (when rest
           (setq parley-transcript--sent
                 (nconc (butlast parley-transcript--sent (length rest))
                        (cdr rest)))
           t))))

(defun parley-transcript--render-input (string)
  "Rewrite STRING, which comint has just inserted at the prompt, as a block.

`comint-send-input' puts what the operator submitted into the
buffer itself before the sender runs, and that insertion goes
nowhere near the render pass: it lands with no blank line before
it, no quote, and comint's `comint-highlight-input' where every
other turn of his carries `parley-user'.  What comint inserted is
replaced here by what `parley-transcript--quote' makes of the
same text, so his turn has one shape however it reached the
buffer.

Here, in the sender, and not on `comint-input-filter-functions':
`comint-send-input' puts its own properties on the input after
that hook has run and before this, so a block written there would
be highlighted as input anyway.  By this point the text carries
them, and deleting it takes them with it.

The markers `comint-send-input' just set over the input are moved
onto the block.  The process mark in particular, because it is
where the next output is inserted and the block is what the
buffer ends with now.

The prompt is indexed here for the reason the render pass indexes
its own: this is where its position is known.  It is also the
only place, since the transcript's copy of this message is
dropped by `parley-transcript--echoed-p' when it arrives."
  (let ((start (marker-position comint-last-input-start))
        (process (get-buffer-process (current-buffer))))
    (delete-region start comint-last-input-end)
    (goto-char start)
    (insert (parley-transcript--quote string))
    (set-marker comint-last-input-end (point))
    (set-marker (process-mark process) (point))
    ;; One character into the block, past the blank line it opens
    ;; with, which is where the render pass indexes a prompt too.  A
    ;; prompt that says nothing renders to no block at all, and has no
    ;; label either, so nothing is looked up at a position past the
    ;; end of the buffer.
    (parley-transcript--index-prompt string (1+ start))))

(defun parley-transcript--tmux (input &rest arguments)
  "Run tmux with ARGUMENTS, INPUT on its standard input if it is a string.

What tmux said is signalled if it exited non-zero, because the
usual reason is that the pane has gone -- the session was quit,
or its window closed -- and a message that vanished quietly would
leave the operator waiting for an answer to something nobody
received."
  (with-temp-buffer
    (let ((status (if input
                      (progn
                        (insert input)
                        (apply #'call-process-region
                               (point-min) (point-max) "tmux" t t nil
                               arguments))
                    (apply #'call-process "tmux" nil t nil arguments))))
      (unless (eq status 0)
        (user-error "tmux %s: %s" (car arguments)
                    (string-trim (buffer-string)))))))

(defun parley-transcript--send-input (_process string)
  "Type STRING into the pane of this buffer's session and submit it.

This is the buffer's `comint-input-sender', which comint calls
with what was submitted instead of writing it to the process.  It
has to be: the process is a `tail' over a file, and its standard
input reaches nobody.  The pane is the session's own terminal and
is the only way in.

A single line goes as one `send-keys -l', where `-l' is what
stops tmux reading the text as key names, and an `Enter' after it
is what submits it.

Anything with a newline in it goes through a paste buffer
instead.  `send-keys' would type the newline and the CLI would
submit at it, so a three line message would arrive as three
messages; `paste-buffer -p' wraps the text in a bracketed paste,
which the CLI takes as one paste and so as one message however
many lines it has.  The text goes to tmux on standard input, so a
paste is never an argument vector however long it is.

A session started outside tmux has no pane and cannot be typed
into at all, and this is where the operator finds that out."
  (let ((pane (plist-get parley-transcript-session :pane)))
    (unless pane
      (user-error "Session %s is outside tmux and has no pane: read only"
                  (or (plist-get parley-transcript-session :name)
                      (plist-get parley-transcript-session :session-id))))
    (if (string-match-p "\n" string)
        (progn
          (parley-transcript--tmux string "load-buffer" "-b" "parley" "-")
          ;; Named and deleted on the way out, so the operator's own
          ;; paste buffer stack is where he left it.
          (parley-transcript--tmux nil "paste-buffer" "-d" "-p"
                                   "-b" "parley" "-t" pane))
      (parley-transcript--tmux
       nil "send-keys" "-t" pane "-l" "--"
       ;; tmux reads a trailing semicolon in an argument as the
       ;; separator between two of its own commands and drops it,
       ;; leaving a backslash before it as the way to write one.  A
       ;; line of SQL is a line that ends in a semicolon.  Measured
       ;; against tmux 3.2a: `foo;' arrives as `foo'.
       (replace-regexp-in-string ";\\'" "\\\\;" string)))
    (parley-transcript--tmux nil "send-keys" "-t" pane "Enter")
    (push (string-trim string) parley-transcript--sent)
    ;; Last, so that a send that raised leaves the operator his text
    ;; where he typed it rather than quoted into the conversation as
    ;; though it had gone.
    (parley-transcript--render-input string)))

(defun parley-transcript--turn-line-p ()
  "Non-nil if the line point is on is one line of a turn of the operator's.
Read at the beginning of the line, which is where
`parley-transcript--quote' puts the `> ' it marks every line of a
turn with -- and reading there rather than under point is what
leaves point at the end of a line still on it."
  (eq (get-text-property (line-beginning-position) 'font-lock-face)
      'parley-user-marker))

(defun parley-transcript--old-input ()
  "Return the turn point stands in, with the quote the renderer put on it taken off.

This is the buffer's `comint-get-old-input', which is what RET on
a past turn resubmits.  comint's default reads the `field'
property and is wrong here in two ways at once.  A turn the
transcript delivered carries `field output', because
`comint-output-filter' puts that on everything it inserts, so the
default takes the line under point whole -- measured on Emacs
28.2 over the rendered turn `what is here', it returns \"> what
is here\", and the session is asked a question opening with a
quote mark.  A turn submitted here carries no `field' at all,
because `parley-transcript--render-input' deleted the text comint
had just put `field input' on and inserted a block that inherits
nothing, so the default returns the whole unfielded run around
it: \"\\n> what is here\\n\" over the same buffer.  Both are one
line where the turn may be four.

A turn is the run of lines whose head carries
`parley-user-marker', the face `parley-transcript--quote' puts on
the `> ' it writes in front of every line of every turn of the
operator's whichever door it came in by.  The face rather than the
`> ' itself, because an assistant turn quoting something is
markdown with `> ' at the front of a line too, and that quote is
markdown-mode's to hide rather than this one's to strip.

Anything else -- an assistant turn, the line a run of tool calls
collapsed to, a blank line between two blocks -- is nobody's turn
for the operator to send again, and a `user-error' naming that
beats typing a line of somebody else's markdown into a live
session."
  (unless (parley-transcript--turn-line-p)
    (user-error "Only a turn of yours can be sent again, and point is not on one"))
  (save-excursion
    (beginning-of-line)
    (while (and (not (bobp))
                (save-excursion (forward-line -1)
                                (parley-transcript--turn-line-p)))
      (forward-line -1))
    (let ((start (point)))
      (end-of-line)
      (while (and (not (eobp))
                  (save-excursion (forward-line 1)
                                  (parley-transcript--turn-line-p)))
        (forward-line 1)
        (end-of-line))
      (replace-regexp-in-string
       "^> " "" (buffer-substring-no-properties start (point))))))

(provide 'parley-transcript)
;;; parley-transcript.el ends here
