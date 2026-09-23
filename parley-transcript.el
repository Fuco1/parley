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
;; many calls went into it.  A turn the harness injected under the
;; operator's role is marked as such in the transcript, and of those
;; only a skill load reaches the buffer -- as one line naming the skill.
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


;;; The pipeline

(defconst parley-transcript--projection
  (concat
   "select(.type == \"user\" or .type == \"assistant\")"
   " | { role: .type,"
   "     meta: (.isMeta == true),"
   "     text: ((.message.content // \"\")"
   "            | if type == \"string\" then ."
   "              else [.[] | select(.type == \"text\") | .text] | join(\"\\n\") end),"
   "     tools: ((.message.content // \"\")"
   "             | if type == \"array\""
   "               then [.[] | select(.type == \"tool_use\")] | length"
   "               else 0 end) }"
   " | select(.text != \"\" or .tools > 0)")
  "The jq program every line of a transcript is passed through.

It emits what parley renders and no more: the role, whether the
harness injected the turn, the text and how many tool calls the
message made.  A tool result never reaches Emacs, because the
object is built from scratch rather than pruned -- the payload
lives in a `tool_result' block and in a top-level
`toolUseResult' field, and neither is read.

`meta' is the transcript's own `isMeta', which every turn the
harness injected carries and no turn the operator typed does.  It
is compared against true rather than emitted as it stands,
because the field is absent far more often than it is written and
an absent one would come through as null: measured over the 917
transcripts on this machine, `isMeta' is true on 929 `user'
records, absent from the other 215405 messages, and written false
only on `system' lines, which this projection drops.

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
          (shell-quote-argument parley-transcript--projection)))

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
  "Face for the `❯ ' at the head of each line of a turn the operator took.
It inherits `parley-user' first, so the marker stands on the same
background as the turn it marks, and takes only what that face
leaves unspecified -- the foreground -- from `shadow'.  The
marker is the renderer's and the words after it are the
operator's, and the two are worth telling apart."
  :group 'parley)

(defconst parley-transcript--quote-marker "❯ "
  "What stands at the head of every line of a turn the operator took.
`parley-transcript--quote' writes it in front of every line of
every turn of his, and `parley-transcript--input-marker' heads
the zone he types in with the same string: what he is typing is
the turn it is about to be, so the two are one constant and
cannot come out looking different.")

(defface parley-tool-run '((t :inherit shadow))
  "Face for a line the renderer wrote rather than anyone in the conversation.
The one line a run of tool calls collapses to, and the one a
skill load collapses to."
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
  ;; Every cell is measured here, and a cell may hold a `│' of the
  ;; agent's, so this buffer counts one as the transcript does.  This
  ;; buffer outlives every transcript buffer, so its table is rebuilt
  ;; whenever the environment's is no longer the one it is a child of:
  ;; a transcript buffer set up after a switch measures under the new one.
  (with-current-buffer parley-transcript--markdown-buffer
    (unless (and (local-variable-p 'char-width-table)
                 (eq (char-table-parent char-width-table)
                     (default-value 'char-width-table)))
      (setq-local char-width-table (parley-transcript--drawn-width-table))))
  parley-transcript--markdown-buffer)

(defconst parley-transcript--fontified-properties
  '((face . font-lock-face) (invisible . invisible) (display . display))
  "The properties copied out of the fontify buffer, and what each becomes.
`face' becomes `font-lock-face' because font lock runs in the
transcript buffer and strips `face'.  `invisible' and `display'
are what markdown-mode hides markup with, and neither is in
`font-lock-extra-managed-props', so both come through it.")

(defconst parley-transcript--cell-properties
  '((face . font-lock-face) (invisible . invisible))
  "The properties a table cell carries out of the fontify buffer.

`parley-transcript--fontified-properties' less the `display',
because a grid is characters standing in columns and what a
`display' property shows is a width no measurement of those
characters can take: `markdown--string-width' counts the `2' of
`x^2^' as the one column it is a character of, and the property
markdown-mode raises and shrinks it with puts it on screen
narrower than one.  The markers around it are hidden either way
-- that is `invisible', and a hidden character is a character the
measurement and the screen agree costs nothing.")

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

The tables TEXT holds are left in
`parley-transcript--fontified-tables' on the way past, because
this is the one buffer that knows where they are."
  (with-current-buffer (parley-transcript--fontify-buffer)
    (erase-buffer)
    (insert text)
    (font-lock-ensure)
    (setq parley-transcript--fontified-tables (parley-transcript--tables))
    (parley-transcript--fontified-string
     parley-transcript--fontified-properties)))

(defun parley-transcript--fontified-string (properties)
  "Return this buffer's text carrying PROPERTIES, and nothing else it carries.

PROPERTIES is an alist of the property to read and the property
to write it as, which is
`parley-transcript--fontified-properties' for a whole message and
`parley-transcript--cell-properties' for the cells of a table.
Called in `parley-transcript--fontify-buffer' with the
fontification already run.

Each property is walked over its own runs and not over the face
runs, because `markdown-fontify-sub-superscripts' puts `display'
on text that carries no face at all."
  (let ((string (substring-no-properties (buffer-string)))
        (start (point-min)))
    (dolist (copy properties)
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
    string))

(defun parley-transcript--record (line)
  "Return the projected object LINE holds, nil if it holds none.
A line in this buffer is not always JSON: `tail -F' reports a
transcript that does not exist yet on stderr, which shares the
buffer, and a pipeline that died mid-object left half of one.

JSON false is read as nil and not as the `:false' the default
would give, because every symbol but nil is true in Emacs Lisp.
The projection writes `meta' false on every record that is no
harness injection, which is nearly all of them, and `:false'
would make each of those say it is one."
  (and (string-prefix-p "{" line)
       (ignore-errors
         (json-parse-string line :object-type 'alist :false-object nil))))

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
would invent emphasis he never wrote.  The `❯ ' the quoting adds
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
                    (propertize (replace-regexp-in-string
                                 "^" parley-transcript--quote-marker trimmed)
                                'font-lock-face 'parley-user)))
            (marker (concat "^" (regexp-quote parley-transcript--quote-marker)))
            (position 0))
        ;; The newline ending a line is what its background is painted
        ;; from, so the one the block closes with carries the face
        ;; too: without it the last line of a turn stops at its last
        ;; character while every line above it runs to the edge.  The
        ;; newline the block opens with is left bare, because that
        ;; blank line is between two turns and belongs to neither.
        (put-text-property (1- (length block)) (length block)
                           'font-lock-face 'parley-user block)
        (while (string-match marker block position)
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

(defun parley-transcript--renderer-line (text)
  "Return the block of buffer text the renderer's own line TEXT renders to.
The bullet heads every line in this buffer that nobody in the
conversation wrote, so a line the renderer is telling the
operator something on cannot be read as one an agent typed, and
`parley-tool-run' is the face all of them are in."
  (parley-transcript--block
   (propertize (concat "● " text) 'font-lock-face 'parley-tool-run)))

(defun parley-transcript--tool-run (count)
  "Return the block of buffer text a run of COUNT tool calls collapses to.
The operator wants the conversation, so the calls an agent made
on its way to an answer are worth exactly one line however many
of them there were.  The pane is still there for anyone who wants
to watch the work."
  (parley-transcript--renderer-line
   (format "%d tool call%s" count (if (= count 1) "" "s"))))

(defconst parley-transcript--skill-base-rx
  "\\`Base directory for this skill: \\(.*\\)"
  "What a skill load opens with, around the directory the skill was read from.
Anchored at the start of the text, because this is the first line
of a skill load and nothing else -- a body that merely mentions
the phrase further down is a skill quoting one.")

(defconst parley-transcript--notification-rx
  "\\`<task-notification>"
  "What a task notification opens with, and nothing else does.
Anchored at the very first character and tolerating nothing in
front of it -- not a space and above all not a newline.  The
harness writes the tag as the whole of the record's opening:
every one of the 1622 notifications in the transcripts on this
machine opens with it at character zero.  So anything standing in
front of the tag was typed by the operator, and a turn of his
that quotes it on any line but the first is his own words.")

(defconst parley-transcript--notification-summary-rx
  "<summary>\\(.*\\)</summary>"
  "The tag a task notification's summary reaches the transcript in.
The group does not cross a newline because the summary does not:
measured over the 1622 notifications in the transcripts on this
machine, 1619 carry a summary and every one of those sits on one
line.")

(defun parley-transcript--injection (text)
  "Return the block of buffer text the harness injection TEXT renders to.

A task notification is worth a line, and the line is its
`<summary>'.  That is the whole of what the harness is telling
the operator he can act on: the task id, the tool-use id and the
output path are addressed to the agent, and `<status>' says
nothing the summary does not already say in its own words.  One
carrying no summary renders nothing, which is what a notification
with nothing new to say is.

A skill load is the other injection worth a line, and it names
itself.  Both ways into one -- the `Skill' tool and the slash
command the operator types for it -- open with the line
`parley-transcript--skill-base-rx' matches, and the skill's own
first `# ' heading stands under it.  That heading is the name,
because it is what the skill calls itself; a skill whose body
opens with no heading is named by the last segment of the
directory instead.  The name is quoted, so a heading of several
words cannot read as prose an agent wrote.

Every other injection renders nothing at all.  That is the empty
string a turn which said nothing renders to, so such an injection
is no break in a run of tool calls either.  A constant line
saying an injection happened carries no information, and the ones
there are -- the caveat a local command prepends, the expansion
of a personal command, the notice the `Agent' tool writes about a
fork -- each stand under a turn of the operator's that already
says what he did."
  (cond
   ((string-match-p parley-transcript--notification-rx text)
    (if (string-match parley-transcript--notification-summary-rx text)
        (parley-transcript--renderer-line (match-string 1 text))
      ""))
   ((not (string-match parley-transcript--skill-base-rx text)) "")
   (t
    (let ((directory (string-trim-right (match-string 1 text))))
      (parley-transcript--renderer-line
       (format "Loaded skill \"%s\""
               (if (string-match "^# +\\(.*[^ \t\n]\\)" text)
                   (match-string 1 text)
                 (file-name-nondirectory
                  (directory-file-name directory)))))))))

(defconst parley-transcript--local-output-rx
  "\\`[ \t\n]*<local-command-stdout>"
  "What a local command's own output opens with, and nothing else does.
Anchored at the start of the text, past whatever whitespace opens
it: a turn of the operator's that quotes the tag further down is
his own words.")

(defconst parley-transcript--command-name-rx
  "<command-name>\\(.*?\\)</command-name>"
  "The tag a slash command's name reaches the transcript in, slash and all.")

(defconst parley-transcript--command-args-rx
  "<command-args>\\(\\(?:.\\|\n\\)*?\\)</command-args>"
  "The tag a slash command's argument reaches the transcript in.
The argument holds the newlines of a paste, so the group crosses
them -- `.' does not -- and it is the first closing tag that ends
it.")

(defun parley-transcript--unwrapped (record)
  "Return RECORD with what the harness wrapped around its text dealt with.

Three `user' records carry no turn of the conversation: the tags
Claude Code writes when the operator types a slash command, the
output a local command printed at his terminal, and the
notification the harness writes when a background task reports
back.  None carries `isMeta', so none reaches
`parley-transcript--injection' on the mark, and all three would
be quoted as his own words, tags and all.

A slash command is three tags, and what he typed is the name and
the argument on one line -- `<command-message>' is the name a
second time without its slash and says nothing `<command-name>'
does not.  The argument is empty under a command he gave none, as
it is under `/plugin', and the trim is what leaves that turn the
name alone.  The tags arrive in either order and under an indent,
so each is looked up on its own.

A local command's own output renders nothing at all: it is the
terminal answering, and his own turn invoking that command stands
right above it saying what he did.

A task notification is marked here and otherwise left alone.  It
is an injection the harness did not mark, and the mark is the
whole of the rule: an injection is already what the render pass
hands to `parley-transcript--injection' and already what the
imenu index passes over, so a notification needs no third path
through the pass.  Its text stands as it arrived, the summary
being read out of it there.

Here, before the record is read for anything: what it renders to,
what `parley-transcript--echoed-p' compares against what was
sent, and what the imenu entry is labelled with all come off this
text.  RECORD is rewritten rather than copied, having been parsed
out of one line a moment earlier and reaching nobody else."
  (let ((text (and record
                   (equal (alist-get 'role record) "user")
                   (not (alist-get 'meta record))
                   (alist-get 'text record))))
    (when text
      (if (string-match-p parley-transcript--notification-rx text)
          (setcdr (assq 'meta record) t)
        (setcdr (assq 'text record)
                (cond
                 ((string-match-p parley-transcript--local-output-rx text) "")
                 ((string-match parley-transcript--command-name-rx text)
                  (let ((name (match-string 1 text)))
                    (string-trim
                     (concat name " "
                             (and (string-match
                                   parley-transcript--command-args-rx text)
                                  (match-string 1 text))))))
                 (t text))))))
  record)

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
          (let* (;; Unwrapped on the way in, so that nothing below
                 ;; reads the wrapper the harness wrote around a
                 ;; `user' record that is not speech.
                 (record (parley-transcript--unwrapped
                          (parley-transcript--record line)))
                 ;; What the harness injected under the operator's
                 ;; role, which the transcript marks and he never
                 ;; does.  The mark is the whole of the test: a
                 ;; pattern in the text would take the turn a slash
                 ;; command writes for what the command pulled in.
                 (meta (and record (alist-get 'meta record)))
                 (speech (cond
                          ((null record) (parley-transcript--block line))
                          (meta (parley-transcript--injection
                                 (or (alist-get 'text record) "")))
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
              ;; with.  Nothing an agent said or did is indexed, and
              ;; neither is an injection: it is not a prompt, so the
              ;; operator jumping through the index cannot land on
              ;; one.
              (when (and (equal (alist-get 'role record) "user")
                         (not meta))
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


;;; Writing the tables

;; A table lines up only if the agent lined it up, and a table whose
;; columns do not line up is a table nobody reads.  What stands in the
;; buffer is the grid this file writes, put there as text -- this
;; buffer is a rendering throughout, and a table is the same rendering
;; as the quote around the operator's turn and the one line a run of
;; tool calls collapses to.
;;
;; The grid is drawn: every column boundary in it is `│', the row
;; between the header and the body is `├─┼─┤', and a rule of `┌─┬─┐'
;; opens it with `└─┴─┘' to close.  Those characters are what the
;; writer emits, because the writer is what put every boundary there
;; and is the only thing that knows where one is.  Nothing scans a
;; finished grid for a bar, so the bar inside `[[target|link words]]'
;; stands in the cell holding it and nowhere in the grid.
;;
;; One writer for every table, the one that fits the window and the
;; one wrapped into it alike.  What that buys is the markup in a cell:
;; a character hidden by `invisible markdown-markup' costs no column,
;; and only a writer measuring every width on what the rendering shows
;; can say so.  `markdown--string-width' is markdown-mode's own answer
;; for that width and is what every width here is taken with -- a
;; column's, the floor under it, the room a wrapped line is packed
;; into, and the padding that fills a cell out.
;;
;; The table the agent wrote is carried by an overlay over it, which
;; is what a resize is rendered from: what the buffer holds is a grid
;; this file wrote, and reading the cells back out of one would render
;; the last render instead of the table.  The overlay is also what
;; says where a table is and what tracks a deletion --
;; `comint-truncate-buffer' taking the top of the conversation away
;; brings its ends together, where a text property would survive in
;; both halves of what was cut.
;;
;; What that costs the operator is the source in the buffer: a kill
;; over a table copies the form he is reading and not the table the
;; agent typed.

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

A rendered table is the buffer's text and not a window's, so a
buffer shown in two windows of different widths is aligned to
whichever of them changed last."
  (window-body-width (get-buffer-window (current-buffer) t)))

(defun parley-transcript--aligned (text width)
  "Return the grid parley writes for the table TEXT, laid out to fit WIDTH.

`parley-transcript--written' writes it, and writes every table:
one that fits WIDTH is the grid with no column narrowed and one
that does not is the same grid with its cells wrapped over as
many lines as they need.  A column no wrapping can narrow -- one
holding a piece longer than the room the rest of the grid leaves
it, a word or a wiki link a bar stands in -- keeps the table
wider than WIDTH, which is the honest outcome: a word broken
across two lines is one the operator cannot read back, and a link
broken across two is no longer a link at all.

Nil for everything `parley-transcript--written' refuses, which is
all that either is refused for: what the operator sees is then
the table as the agent wrote it.  None of those refusals is a
question of width, so a table that renders to nothing here
renders to nothing at any size of window."
  (let ((form (parley-transcript--written text width)))
    (when form
      (parley-transcript--table-faced form))))

(defun parley-transcript--table-faced (form)
  "Return FORM with `markdown-table-face' over everything the writer wrote.

The cells reach the writer carrying the faces markdown-mode
paints them with -- `markdown-table-face' over the whole of a
table line and the face of a construct over the construct -- so
what comes out of the writer with no face on it is the grid
itself: the bars, and the spaces a cell is padded out with.
Filling those in is what leaves a cell's own markup painted as
markdown-mode paints it.

The face is in `font-lock-face', which is the property every
other face this file writes ends up in --
`parley-transcript--fontified-properties' is where the render
pass maps it.  `face' is what global font lock strips in this
buffer: `font-lock-defaults' is `(nil t)' in a comint buffer, so
font lock turns on there with no keywords and unfontifying is the
only thing left for it to do."
  (let ((position 0)
        (end (length form)))
    (while (< position end)
      (let ((next (next-single-property-change position 'font-lock-face
                                               form end)))
        (unless (get-text-property position 'font-lock-face form)
          (put-text-property position next 'font-lock-face
                             'markdown-table-face form))
        (setq position next))))
  form)

(defun parley-transcript--table-closed (text)
  "Return TEXT with a bar on the end of every row that ends without one.

The outer bar at the end of a row is optional and an agent
writing a table by hand leaves it off, and
`markdown--table-line-to-columns' counts the characters of a line
against a position in a buffer, so it drops a last cell of one
column when no bar closes it: measured against the repository's
markdown-mode, `| a' and `| 1' come back with no cell at all, and
the last row of `| a | b |', `|---|---|', `| 1 | 2' comes back as
`(\"1\")'.

It is the copy the grid is written from that is closed and never
the table itself, so the row the agent left open is still open in
the table the overlay carries.  What is written into the buffer
in its place is one grid, and a grid has an edge."
  (mapconcat (lambda (line)
               (if (string-suffix-p "|" (string-trim-right line))
                   line
                 (concat line " |")))
             (split-string text "\n")
             "\n"))

(defun parley-transcript--table-content (text)
  "Return what TEXT says, with everything a reading of it may drop taken out.

The spaces around a cell, the bars between two of them, the
dashes and colons a delimiter row is written from, and the line
breaks -- so a table and the cells read out of it answer this the
same way exactly when the cells say what the table says.

The line breaks go because the cells are compared joined with
nothing between them, and a delimiter row goes with them: it is
dashes and colons and bars throughout, and it carries no cell to
compare.

A cell's own dashes and colons go with them, which can only make
two readings agree and never make them differ: what this is asked
is whether the reading dropped anything, and the answer may not
be yes when it did not.

What TEXT says is its characters, so the properties come off
before the scan rather than being carried through it: the cells
are joined with what the fontification marked still on them, and
rebuilding that run by run is the greater part of the work here."
  (replace-regexp-in-string "[ \t\n|:-]" "" (substring-no-properties text)))

(defun parley-transcript--written (text width)
  "Return the table TEXT written out as a grid of WIDTH columns, nil for no table.

The grid is written from the cells, and from them alone: the
widths are decided here and the padding follows from them, so
there is nothing for a second parse to read back but what has
just been written.  A table that fits WIDTH is this grid with no
column narrowed and a table that does not is this grid with its
cells wrapped, which is one writer and one layout for both.

It happens in `parley-transcript--fontify-buffer' because that is
where the cells can be read with what markdown-mode marked on
them still there -- `parley-transcript--cell-properties' is what
they come away with -- and because `markdown--string-width' reads
`buffer-invisibility-spec' to know what is hidden -- the spec
that names `markdown-markup' is that buffer's, put there by
`markdown-toggle-markup-hiding'.

What goes into that buffer is the copy
`parley-transcript--table-closed' returns and never TEXT itself,
because a row that ends without a bar loses its last cell to the
cell reader.  Asking that copy whether it is a table answers for
TEXT too: a table line is one that starts with a bar, and a bar
put on the end of a line moves nothing at the start of it.

Nil if TEXT is not a table, which is markdown-mode's own
question.  Nil as well for a table of nothing but delimiter rows,
which has nothing in it to line up: the widths come from the
cells, a delimiter row carries none, and a grid of no columns is
a row of two bars.  Whether a row is a delimiter row is asked
with markdown-mode's own `markdown--is-delimiter-row', because
that is the predicate the rows are sorted with here -- `| --- |
--- |' is a delimiter row, and anything reading the character
after the bar takes it for a row of data.

Nil, last, when the cells do not say what TEXT says.  Where a
cell begins and ends is markdown-mode's own
`markdown--table-line-to-columns' and which markdown-mode is
under this buffer is the operator's business, so a version of it
that dropped a cell would put that cell's row in the buffer
without it -- and a cell the operator cannot read at all is worse
than a table that is merely ragged.  It is the cells that are
held to TEXT and not the grid written from them, because a wrap
takes a cell down the lines its row spreads over: read back
across a line the grid says its columns in one order and TEXT
says them in another, where the cells are in the order TEXT has
them whatever any width does to the grid.

A cell may hold a bar that is no column boundary -- the one
inside a wiki link, which `markdown--table-line-to-columns' reads
over.  It reaches the buffer as the agent wrote it, inside its
cell, because the boundaries are drawn where the writer knows
they are and nothing scans a cell for a bar.
`parley-transcript--cell-words' is what hands the wrap such a
link whole rather than as words it may break apart."
  (with-current-buffer (parley-transcript--fontify-buffer)
    (erase-buffer)
    (insert (parley-transcript--table-closed text))
    (font-lock-ensure)
    (goto-char (point-min))
    (when (and (markdown-table-at-point-p)
               (not (seq-every-p #'markdown--is-delimiter-row
                                 (split-string text "\n"))))
      (let* ((lines (split-string (parley-transcript--fontified-string
                                   parley-transcript--cell-properties)
                                  "\n"))
             (rows (mapcar (lambda (line)
                             (unless (markdown--is-delimiter-row line)
                               (parley-transcript--table-cells line)))
                           lines))
             (widths (parley-transcript--column-widths (remq nil rows) width))
             (marks (markdown-table-colfmt
                     (seq-find #'markdown--is-delimiter-row lines))))
        (when (equal (parley-transcript--table-content
                      (mapconcat (lambda (row) (string-join row)) rows ""))
                     (parley-transcript--table-content text))
          (string-join
           (append
            (list (parley-transcript--table-rule widths "┌" "┬" "┐"))
            (mapcar (lambda (row)
                      (if row
                          (parley-transcript--wrapped-row row widths marks)
                        (parley-transcript--table-rule widths "├" "┼" "┤")))
                    rows)
            (list (parley-transcript--table-rule widths "└" "┴" "┘")))
           "\n"))))))

(defun parley-transcript--table-cells (line)
  "Return the cells LINE holds, each carrying the properties LINE carries.

Where a cell begins and ends is `markdown--table-line-to-columns',
because that is what reads over the bar inside a wiki link and
the escaped bar -- and it hands back text with nothing on it.  A
cell is a verbatim substring of the line it was read from, so
what the fontification marked is taken back off LINE by position.

Each search starts where the last cell ended, so two cells of one
text are two cells and not one found twice.  What stands between
them is the run of spaces and the bar the reader consumed, and a
cell begins with neither -- the reader trims the space around a
cell away -- so no search can land inside one.

A cell the reader did not take verbatim off LINE comes back
unpainted rather than signalling, because this runs in an output
filter.  Whether such a table is written at all is
`parley-transcript--written''s question, and it asks it of every
cell together."
  (let ((at 0))
    (mapcar (lambda (cell)
              (let ((from (string-search cell line at)))
                (if (not from)
                    cell
                  (setq at (+ from (length cell)))
                  (substring line from at))))
            (markdown--table-line-to-columns
             (substring-no-properties line)))))

(defun parley-transcript--cell-words (text)
  "Return the pieces of TEXT a wrap may put on lines of their own.

The words, except that a wiki link holding a bar is one piece
however many spaces stand inside it.  That bar is not a column
boundary -- `markdown--table-line-to-columns' reads over it, so
`[[target|link words]]' is one cell and not two, and every
boundary in the grid is a `│' the writer drew -- so it stands in
the cell the agent put it in and the operator reads it there.
What a break costs is the link: `[[target|link' on a line of its
own is that construct left open, and nothing reading the form
back has a link there any more.

Whether a link is read at all is markdown-mode's own
`markdown-enable-wiki-links', which is what
`markdown--thing-at-wiki-link' asks before the cell reader passes
over a bar.  With links off that bar is a boundary, what stands
either side of it is a cell of its own, and there is nothing here
to hold together.

A link carrying no bar is broken like any other run of words,
because it is the bar that says where the target ends and the
words begin.  A piece held together is a piece the column it
stands in cannot be narrowed past, which is width the table pays
for."
  (let ((links nil)
        (from 0))
    (while (and markdown-enable-wiki-links
                (string-match markdown-regex-wiki-link text from))
      (setq from (match-end 1))
      (when (match-beginning 4)
        (push (cons (match-beginning 1) (match-end 1)) links)))
    (let ((words nil)
          (cut 0)
          (at 0))
      (while (string-match "[ \t]+" text at)
        (let ((beginning (match-beginning 0))
              (end (match-end 0)))
          (setq at end)
          (unless (seq-some (lambda (link)
                              (and (< (car link) beginning) (< end (cdr link))))
                            links)
            (when (< cut beginning)
              (push (substring text cut beginning) words))
            (setq cut end))))
      (when (< cut (length text))
        (push (substring text cut) words))
      (nreverse words))))

(defun parley-transcript--column-widths (rows width)
  "Return the width each column of ROWS is wrapped to, to fit WIDTH in all.

What a column wants is its widest cell.  What it gets is that,
narrowed a column at a time and the widest of them first -- so
the cell of prose gives before the cells of one word each do --
until the grid fits WIDTH.

A column is never narrowed past the longest piece standing in it,
which is a word or a whole wiki link -- what
`parley-transcript--cell-words' returns.  That floor is not what
keeps a piece whole, which `parley-transcript--wrapped-cell' does
whatever width it is handed; it is what stops the columns beside
an incompressible one being packed tighter than the table they
share will ever be, and it is why a table holding a piece longer
than the window settles wider than WIDTH rather than at it.

A grid of N columns spends 3N+1 of WIDTH on what is not a cell: a
bar between two columns and one at each end, and a space on each
side of every cell.

Every width is `markdown--string-width', which is what the
rendering shows -- a character hidden by `invisible
markdown-markup' costs no column, so a cell of `**bold**' asks
its column for the four the operator reads and not the eight the
agent typed."
  (let* ((columns (apply #'max 0 (mapcar #'length rows)))
         (widths (make-vector columns 1))
         (floors (make-vector columns 1))
         (room (- width (1+ (* 3 columns)))))
    (dolist (row rows)
      (dotimes (column columns)
        (let ((cell (or (nth column row) "")))
          (aset widths column
                (max (aref widths column) (markdown--string-width cell)))
          (dolist (word (parley-transcript--cell-words cell))
            (aset floors column
                  (max (aref floors column) (markdown--string-width word)))))))
    (while (and (> (seq-reduce #'+ widths 0) room)
                (let ((widest nil))
                  (dotimes (column columns)
                    (when (and (> (aref widths column) (aref floors column))
                               (or (null widest)
                                   (> (aref widths column)
                                      (aref widths widest))))
                      (setq widest column)))
                  (when widest
                    (aset widths widest (1- (aref widths widest)))
                    t))))
    (append widths nil)))

(defun parley-transcript--wrapped-cell (text width)
  "Return the pieces of TEXT packed into lines of at most WIDTH columns.

A piece is what `parley-transcript--cell-words' returns: a word,
and a wiki link holding a bar however many words stand in it.

Whole pieces only: one that will not fit starts the next line
rather than being broken across two, and one wider than WIDTH
stands alone and over the end of it.  Breaking one is the thing
wrapping a table may not do -- what a broken word costs the
operator is the word and what a broken link costs him is the
link, where a table over the edge of the window costs him only
the grid, which he can still read back.

`parley-transcript--column-widths' is what keeps a table from
asking for that overflow at all, by never narrowing a column past
the longest piece standing in it.  The two together are why a
table holding a piece longer than the window comes out wider than
the window and not with a word broken in half.

A cell with nothing in it is one empty line, because a row is as
tall as its tallest cell and every cell of it has to reach the
foot of the row.

A cell already inside WIDTH is one line and is that cell, which
is not the same as packing it: packing puts one space between two
pieces, and a cell the agent wrote two spaces into is a cell he
can have them back in when nothing has to be moved to fit.  It is
the cheaper answer as well, and every cell of a table that fits
the window is one of them."
  (if (<= (markdown--string-width text) width)
      (list text)
    (let ((lines nil)
          (line ""))
      (dolist (word (parley-transcript--cell-words text))
        (setq line (cond ((equal line "") word)
                         ((<= (+ (markdown--string-width line) 1
                                 (markdown--string-width word))
                              width)
                          (concat line " " word))
                         (t (push line lines) word))))
      (nreverse (cons line lines)))))

(defun parley-transcript--wrapped-row (cells widths marks)
  "Return the lines CELLS wrapped to WIDTHS takes up, as one string.

As many lines as the cell that took the most of them, and each of
them a whole row of boundaries: a cell with nothing left to show
on a line stands empty there rather than the line stopping short,
so every line of a row carries the boundaries the table has.

A boundary is `│', at each end of the line as well as between two
cells, and it takes the one column the bar it stands for took.
A bar the operator reads in the grid is therefore one a cell
holds -- the one inside `[[target|link words]]' among them --
because the writer puts none anywhere else.

MARKS is what `markdown-table-colfmt' read off the delimiter row,
one for each column, and says which side of a cell its padding
goes on."
  (let* ((wrapped (seq-map-indexed
                   (lambda (cell column)
                     (parley-transcript--wrapped-cell cell (nth column widths)))
                   cells))
         (height (apply #'max 1 (mapcar #'length wrapped))))
    (mapconcat
     (lambda (line)
       (concat "│"
               (mapconcat (lambda (column)
                            (parley-transcript--padded
                             (or (nth line (nth column wrapped)) "")
                             (nth column widths)
                             (nth column marks)))
                          (number-sequence 0 (1- (length widths)))
                          "│")
               "│"))
     (number-sequence 0 (1- height))
     "\n")))

(defun parley-transcript--table-rule (widths left junction right)
  "Return the rule across WIDTHS that LEFT, JUNCTION and RIGHT draw.

Three rules are drawn from this and they differ in nothing else:
`┌┬┐' over the head of a grid, `├┼┤' between its header and its
body, and `└┴┘' under its foot.  JUNCTION stands where a boundary
stands, because the stretch it divides is a column's width and
the space either side of a cell -- which is what a row spends
there too.

The row between the header and the body is drawn and not written:
the `:---:' of the delimiter row the agent typed says how a
column is aligned, which is not something anyone reads off a
drawn table, and `parley-transcript--padded' is what says it in
the grid instead.  So no dash and no colon of that row reaches
the buffer.

Every character here takes the one column the character it stands
for took, so a rule is exactly as wide as a row of the grid."
  (concat left
          (mapconcat (lambda (width) (make-string (+ 2 width) ?─))
                     widths junction)
          right))

(defconst parley-transcript--drawn-characters "│─┌┬┐├┼┤└┴┘"
  "Every character the writer draws a grid in.")

(defun parley-transcript--drawn-width-table ()
  "Return `char-width-table' with every drawn character one column wide.

A CJK language environment makes box-drawing characters two
columns wide while `|' and `-' stay one: measured on Emacs 28.2
under Japanese, `│' is 2 and a rule of two one-column cells is 18
columns over a row of 12.  This table takes the drawn characters
back to the one column each character it stands for took and
leaves every other width to the table it is a child of, so a CJK
character in a cell is still the two columns it is.

The parent is the default value of `char-width-table' when this
is called, and never a buffer's own, which would be a table of
this function's.  `set-language-environment' installs a table of
its own rather than editing the one it finds, so a transcript
buffer set up before a switch keeps the widths of the environment
it was set up under."
  ;; ponytail: a transcript buffer's parent is captured once; watch
  ;; `char-width-table' if a mid-session environment switch matters.
  (let ((table (make-char-table nil)))
    (set-char-table-parent table (default-value 'char-width-table))
    (dolist (character (string-to-list parley-transcript--drawn-characters))
      (aset table character 1))
    table))

(defun parley-transcript--padded (text width mark)
  "Return TEXT as a cell of WIDTH columns, padded as MARK says, a space each side.

MARK is this column's entry in what `markdown-table-colfmt' read
off the delimiter row: `r' puts the padding in front of TEXT and
`c' splits it either side, the odd column going behind.  Anything
else puts it behind, which is where a column nobody marked wants
it.

`markdown--string-width' and not `length', because a cell of CJK
text takes two columns to the character and a character hidden by
`invisible markdown-markup' takes none -- a grid padded by the
character lines up under neither."
  (let ((pad (max 0 (- width (markdown--string-width text)))))
    (pcase mark
      ('r (concat " " (make-string pad ?\s) text " "))
      ('c (let ((left (/ pad 2)))
            (concat " " (make-string left ?\s) text
                    (make-string (- pad left) ?\s) " ")))
      (_ (concat " " text (make-string pad ?\s) " ")))))

(defun parley-transcript--render-table (overlay width)
  "Write the table OVERLAY carries into its region, rendered to WIDTH columns.

Rendered from the table the agent wrote, which OVERLAY carries in
`parley-table'.  What the region holds is a grid this file wrote,
and reading the cells back out of one would render the last
render rather than the table: a row wrapped over three lines
would come back as three rows of a table nobody wrote.

Only while the region still holds the text written there, which
is what `parley-table-form' carries.  `comint-truncate-buffer'
takes the top of the conversation away and the operator can edit
in this buffer, and a region that no longer holds what parley put
in it is not parley's to write over -- what is left of a table
cut in half stands as it stands.  The overlay is dropped then,
and nothing puts it back.

Dropped as well when the table renders to nothing, which
`parley-transcript--aligned' answers at every width alike: there
is no width to come back for.

The region is written over unless it already holds this form with
its properties.  A form is never the table it was rendered from,
whatever the agent lined up himself: the grid is drawn and the
table is his bars and his dashes, so the first render of one
always writes.

`equal-including-properties' compares two property values with
`eq', and a face markdown-mode painted a cell with is a fresh
list every fontification, so two computations of one form do not
agree under it either: what a width that changes the window
without changing the grid costs is the write, and not the render,
which has happened by then either way."
  (let ((form (and (equal (buffer-substring-no-properties (overlay-start overlay)
                                                          (overlay-end overlay))
                          (overlay-get overlay 'parley-table-form))
                   (parley-transcript--aligned
                    (overlay-get overlay 'parley-table) width))))
    (cond ((null form) (delete-overlay overlay))
          ((not (equal-including-properties
                 form (overlay-get overlay 'parley-table-form)))
           (parley-transcript--replace-table overlay form)))))

(defun parley-transcript--replace-table (overlay form)
  "Put FORM in the buffer in place of OVERLAY's region, and record it on OVERLAY.

A render is not an edit the operator made and not one he may
undo, which is the whole of what `with-silent-modifications'
says here: it binds `buffer-undo-list' away, so what `undo'
reaches past a table rendered again is his own last change, and
it binds the modification hooks away with it, so nothing takes a
render for text that has to be fontified again.

Point is put back where it stood, which comint reads back off the
buffer once its output filters have run -- it is the operator's,
and a filter that moved it has moved his.  Point outside the
table is a marker that follows the replacement; point inside one
is put the distance into the form that it stood into what was
there, and `save-excursion' alone would not do it -- a marker in
what a deletion takes survives at the boundary of it, which here
is the head of the table.  The distance is the most a grid laid
out again can promise, and the form it is measured into is as far
as it goes: a table point stood in is a table it stays in.

The process mark is a marker past the end of this region, because
a table ends before the newline that closes the block around it,
and it follows the replacement as the overlay over every other
table does.  The overlay over this one is moved by hand: the
deletion leaves it empty and it takes in nothing inserted at
either end, which is what keeps the text around a table out of
it."
  (let* ((start (overlay-start overlay))
         (end (overlay-end overlay))
         (into (and (<= start (point) end) (- (point) start))))
    (with-silent-modifications
      (save-excursion
        (delete-region start end)
        (goto-char start)
        (insert form)))
    (when into
      (goto-char (+ start (min into (length form)))))
    (move-overlay overlay start (+ start (length form)))
    (overlay-put overlay 'parley-table-form form)))

(defun parley-transcript--align-output (_string)
  "Lay an overlay over each table the last render pass produced, and render it.

On `comint-output-filter-functions', for the reason
`parley-transcript--index-output' is: the render pass ran before
the insertion and could only say how far into its string each
table was, and comint has just inserted that string at
`comint-last-output-start'.

Every overlay is laid before any table is rendered, because a
render replaces buffer text and moves everything after it -- an
overlay follows that move and an offset into the inserted string
does not.

What stands in the region as an overlay is laid is the table
itself, so it goes on the overlay as both the table a render is
computed from and the form standing there -- which is what leaves
a table the agent had already aligned untouched.

The overlay takes in neither what is inserted at its start nor
what is inserted at its end, because a table's own text is all it
stands for.

STRING is what the hook is called with and is not looked at: what
arrived is already in the buffer."
  (when parley-transcript--pending-tables
    (let ((width (parley-transcript--width))
          (overlays nil))
      (dolist (table parley-transcript--pending-tables)
        (let* ((overlay (make-overlay (+ comint-last-output-start (car table))
                                      (+ comint-last-output-start (cdr table))
                                      nil t))
               (text (buffer-substring-no-properties (overlay-start overlay)
                                                     (overlay-end overlay))))
          (overlay-put overlay 'parley-table text)
          (overlay-put overlay 'parley-table-form text)
          (push overlay overlays)))
      (dolist (overlay overlays)
        (parley-transcript--render-table overlay width)))
    (setq parley-transcript--pending-tables nil)))

(defun parley-transcript--realign-tables ()
  "Render this buffer's tables again for the width of the window showing it.

On `window-configuration-change-hook', whose buffer-local value
Emacs runs for each window showing the buffer once that window
has changed its body size -- with the window selected, so the
width read here is that window's.

It runs on a window being added, deleted or given another buffer
as well, and the tables are rendered again on none of those: the
form follows from the table the overlay carries and the width
alone, so nothing but a width that has changed can change it."
  (let ((width (parley-transcript--width)))
    (unless (eq width parley-transcript--aligned-width)
      (setq parley-transcript--aligned-width width)
      (dolist (overlay (overlays-in (point-min) (point-max)))
        (when (overlay-get overlay 'parley-table)
          (parley-transcript--render-table overlay width))))))


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

;; Permanent, because it is what this buffer is.  Which session a
;; buffer follows does not change because the major mode was entered
;; again over it, and a buffer that has lost the record follows
;; nothing: its status reads `unknown' for good, whatever draws what
;; the session is doing has nothing to draw, and
;; `parley-transcript--buffer' no longer finds it for its own session
;; and opens a second buffer over the same conversation.
(put 'parley-transcript-session 'permanent-local t)

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
  ;; The grid a table is written to is what fits the window, so it is
  ;; written again when the window changes width.  Buffer locally,
  ;; which is what has Emacs run it for each window showing this
  ;; buffer with that window selected.
  (add-hook 'window-configuration-change-hook
            #'parley-transcript--realign-tables nil t)
  ;; The zone the operator types in starts at the process mark, and
  ;; comint has just moved that mark past what it inserted, so the
  ;; overlay that marks the zone is put back after every output.
  (add-hook 'comint-output-filter-functions
            #'parley-transcript--mark-input-zone nil t)
  ;; Nothing announces what the session is doing, so the buffer reads
  ;; its file on a tick of its own -- see the section that starts at
  ;; `parley-transcript--status-interval'.
  (parley-transcript--watch-status)
  ;; An `:eval', so the line is built on every redisplay: which session
  ;; the buffer follows is fixed, and what it is doing is not.
  ;; The grid is drawn in box-drawing characters, which a CJK language
  ;; environment makes two columns wide.
  (setq-local char-width-table (parley-transcript--drawn-width-table))
  (setq-local header-line-format '(:eval (parley-transcript--header-line))))

(defun parley-transcript--buffer-name (session)
  "Return the name of the buffer that follows SESSION.
The name carries the session's name and its tag, which is the two
the switcher lists it under.  The name `claude agents' gives a
session is not unique -- two in sibling worktrees come back under
one, and two live sessions can even share a pane -- so what makes
this name one session's own is `parley-session-tag'."
  (format "*parley: %s %s*"
          (or (plist-get session :name) parley-session-no-name)
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
      (generate-new-buffer (parley-transcript--buffer-name session))))

;;;###autoload
(defun parley-transcript (session)
  "Show the transcript of SESSION in the selected window.
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
    ;; Outside the guard above, because a buffer already following this
    ;; session is following the record it was opened with, and what
    ;; `claude agents' says about a session goes stale.
    (with-current-buffer buffer (setq parley-transcript-session session))
    ;; The window the operator is already in, which is what every
    ;; caller of this asked for: go to this session.  `pop-to-buffer'
    ;; would hand the transcript to some other window and select that
    ;; one, taking over a window he was reading something else in.
    (switch-to-buffer buffer)))


;;; The session's live status

;; The record the buffer was opened with carries the status `claude
;; agents' reported then, and a conversation is read for minutes.  What
;; the session is doing now is in the session's own file, so the buffer
;; reads that file itself, on a tick.
;;
;; A tick and not a watch.  Nothing but a buffer someone is looking at
;; consumes a status -- the switcher builds every row from the `claude
;; agents --json' it has just run -- so the read is skipped while no
;; window is showing the buffer, and the status of a buffer nobody can
;; see is the whole of what a watch would have bought.  The tick is the
;; buffer's own, so killing the buffer is the whole of stopping it.

(defconst parley-transcript--status-interval 1
  "Seconds between two reads of the session's own file.
About a second, which is the rate a status is read at and well
under the time the operator would otherwise spend looking at a
stale one.")

(defvar-local parley-transcript-status 'unknown
  "What the session this buffer follows is doing, as of the last tick.
One of `working', `waiting', `idle' and `unknown' -- see
`parley-session-status', which is what puts it here.

This is the one place on the buffer the status is held, so
everything that draws it draws the same value and the file is
read once a tick however many of them there are.  `unknown' until
the first tick has run, which is what a buffer nothing is showing
stays at.")

;; Permanent for the reason `parley-transcript-session' is: what the
;; session is doing does not change because the major mode was entered
;; again over the buffer.  The animation in front of the prompt reads
;; this on a tick ten times as fast as the one that writes it, so a
;; reentry that cleared it would stop a working session's spinner
;; within a frame and leave it stopped until the next status tick put
;; the value back.
(put 'parley-transcript-status 'permanent-local t)

(defvar-local parley-transcript--status-timer nil
  "The timer reading this buffer's status, nil in a buffer with none.")

;; Permanent, and it has to be.  Reentering the major mode clears every
;; buffer-local binding that is not, and the timer this one names goes
;; on running with nothing left holding it: it is not the buffer's to
;; cancel any more, and killing the buffer would stop only whichever
;; timer was started last.
(put 'parley-transcript--status-timer 'permanent-local t)

(defun parley-transcript--read-status (buffer)
  "Put what BUFFER's session is doing on its `parley-transcript-status'.
Nothing is read for a buffer no window is showing: a status is
for whoever is looking at the conversation, and one nobody has on
screen is one nothing will draw.

The session is asked about whole, so a session that has ended
under a buffer still open reads as `unknown' on this same tick --
nothing announces that, and the file it left behind still says
what it was doing when it died."
  (when (and (buffer-live-p buffer) (get-buffer-window buffer t))
    (with-current-buffer buffer
      (setq parley-transcript-status
            (parley-session-status parley-transcript-session))
      ;; What draws it is `parley-transcript--show-status', in the
      ;; section below: the cell it changes is part of the mark at the
      ;; head of the input zone, and the zone is that section's.
      (parley-transcript--show-status))))

(defun parley-transcript--watch-status ()
  "Read this buffer's status on a tick, until the buffer is killed.
Whatever was reading it before is stopped first: the major mode
runs this, and a mode reentered over a buffer that already has a
tick would otherwise leave that one running for good."
  (parley-transcript--unwatch-status)
  (setq parley-transcript--status-timer
        (run-with-timer parley-transcript--status-interval
                        parley-transcript--status-interval
                        #'parley-transcript--read-status
                        (current-buffer)))
  (add-hook 'kill-buffer-hook #'parley-transcript--unwatch-status nil t))

(defun parley-transcript--unwatch-status ()
  "Stop reading this buffer's status."
  (when parley-transcript--status-timer
    (cancel-timer parley-transcript--status-timer)
    (setq parley-transcript--status-timer nil)))


;;; The header line

;; The buffer's name is the one thing in it that says which session it
;; follows, and it is a snapshot: `parley-transcript--buffer-name' runs
;; once, when the buffer is made, and nothing renames it afterwards.
;; The header line is parley's own line and is built on every
;; redisplay, so it says what is true now -- and a mode line says none
;; of this, being configured by whoever owns the Emacs.

(defun parley-transcript--header-line ()
  "Return what the top line of this buffer says about the session it follows.
Its name, what it is doing, where its pane is, and the mark
saying it cannot be typed into -- the placeholder for a session
`claude agents' named none and the mark itself are the switcher
row's, `parley-session-no-name' and
`parley-session-read-only-mark', and the mark is read from the
record having no pane for the reason `parley-session-fields'
reads it from there.

What it is doing is `parley-transcript-status', which is what the
session is doing now: the record carries what `claude agents'
said when the buffer was opened, and a conversation is read for
minutes.  All four states are told apart, `waiting' from `idle'
above all -- see `parley-session-status'.

The location is a bare lookup in `parley--pane-locations', and is
asked neither of `parley--pane-location' nor of
`parley-session-tag', which reaches that same accessor.  It fills
the cache when it reads `unasked', and filling it runs `tmux
list-panes -a' -- a `call-process' from redisplay, in every
transcript buffer on screen, every time `parley-sessions' puts
the cache back.  The lookup is also what keeps the location
current: the cache is refilled whenever the sessions are listed,
so a pane the operator moved is shown where it is now while the
buffer name still carries where it was.

A pane the cache holds nothing for shows no location -- and it
holds nothing for every pane while it reads `unasked', which is a
symbol and no alist.  The pane id is never shown in its place:
`%15' locates nothing the operator can act on.

The working directory is not here.  It is a switcher column
because the operator is choosing between sessions; in the buffer
it is `default-directory', and a line repeating what the buffer
already is spends a line on nothing."
  (let* ((session parley-transcript-session)
         (pane (plist-get session :pane))
         (location (and pane
                        (listp parley--pane-locations)
                        (cdr (assoc pane parley--pane-locations)))))
    (string-join
     (delq nil (list (or (plist-get session :name) parley-session-no-name)
                     (symbol-name parley-transcript-status)
                     (if pane location parley-session-read-only-mark)))
     "  ")))


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

(defface parley-input-rule-above '((t :inherit shadow :underline t))
  "Face for the rule that closes the input zone from above.
`:underline' draws at the foot of the row the rule is on, which
is the edge of that row nearest the zone.

Neither rule inherits `parley-input': a rule stands outside the
zone it closes, and one carrying the band would read as a line of
the zone rather than its edge."
  :group 'parley)

(defface parley-input-rule-below '((t :inherit shadow :overline t))
  "Face for the rule that closes the input zone from below.
`:overline' draws at the head of the row the rule is on, which is
the edge of that row nearest the zone -- so both rules stand
against the zone and the zone is closed evenly.  Underlining this
one instead leaves the whole of its row between the last line
typed and the line closing it.

A terminal draws no rule here: measured on Emacs 28.2 in a 40
column tmux pane, `capture-pane -e' over an overlined stretch of
space shows no SGR at all where the underlined one shows
`ESC[4m'.  Emacs emits `smul' for an underline and has nothing to
emit for an overline."
  :group 'parley)

(defconst parley-transcript--input-rule-above
  (propertize " " 'display '(space :align-to right)
              'face 'parley-input-rule-above)
  "The rule that closes the input zone from above.

A space stretched to the right edge, which is what makes the line
run the width of the window whatever that is: measured on Emacs
28.2 in a 60 column tmux pane, `capture-pane -e' shows the
underline SGR over every column of that row.  A line of `---'
characters instead would be a string as wide as the window, and
nothing rewrites this buffer after an insertion, so it would
still be the old width after a resize.")

(defconst parley-transcript--input-rule-below
  (propertize " " 'display '(space :align-to right)
              'face 'parley-input-rule-below)
  "The rule that closes the input zone from below.
The stretched space of `parley-transcript--input-rule-above', in
the face that draws the line at the other edge of its row.")

(defcustom parley-input-spinner-frames
  '("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
  "The frames the cell in front of the prompt cycles while the session works.
Shown in order, one per tick of `parley-transcript--spinner-interval',
and round again.

Every frame has to be one column wide, because the cell stands in
front of the prompt mark and a cell that changes width moves the
`❯' under the operator's hands.  Braille by default: the block is
neutral width, so Emacs lays every one of these out in one
column, and where the font has no glyph for them a terminal
usually draws two -- which is the case this variable exists for.

An empty list is a session that works with a blank in front of
its prompt, which is the whole of turning the animation off."
  :type '(repeat string)
  :group 'parley)

(defconst parley-transcript--input-waiting-mark
  "◆"
  "The cell in front of the prompt of a session waiting for the operator.
It does not move, and that is the point: motion says wait, and a
mark that stays says answer me.  The state that wants him is the
one that is not busy.

No frame of `parley-input-spinner-frames' and no glyph of their
block, so a spinner stopped on its last frame and a session
asking a question cannot be read for each other -- and not the
`●' a run of tool calls collapses to either, which stands in the
same conversation.  One column wide, as every frame is.")

(defun parley-transcript--status-cell ()
  "Return the cell that stands between the rule and the prompt mark.
One column in every state, so `parley-transcript--quote-marker'
stands in the same place whatever the session is doing: a frame
of `parley-input-spinner-frames' while it is working,
`parley-transcript--input-waiting-mark' while it waits for the
operator, and a space when it is idle or nothing is known about
it.

It wears the mark's own face, so the band under the zone runs
through it rather than breaking for a column."
  (propertize
   (pcase parley-transcript-status
     ('working (if parley-input-spinner-frames
                   (nth (mod parley-transcript--spinner-frame
                             (length parley-input-spinner-frames))
                        parley-input-spinner-frames)
                 " "))
     ('waiting parley-transcript--input-waiting-mark)
     (_ " "))
   'face 'parley-input-marker))

(defun parley-transcript--input-marker ()
  "Return what stands at the head of the input zone.
The zone's overlay shows it as its `before-string', which is
displayed and is not in the buffer -- and what
`comint-send-input' sends is buffer text from the process mark
on.

A rule across the window on its own line, then
`parley-transcript--status-cell' and
`parley-transcript--quote-marker' -- the mark every turn of the
operator's is quoted with, because what he is typing is the turn
it is about to be.  The rule is what separates that turn from the
one above it, and `parley-transcript--input-fill' closes the zone
with the other of the pair.

The cell is part of this string and not of the marker constant,
which is written into the buffer in front of every line of every
turn the operator took: a cell added there would put a spinner
down the whole conversation, and `parley-transcript--old-input'
strips that constant with a `^' anchored regexp to send a past
turn again.

It is built on each draw rather than held, because the cell
changes while the buffer is open and the rest of it does not
change at all."
  (concat parley-transcript--input-rule-above "\n"
          (parley-transcript--status-cell)
          (propertize parley-transcript--quote-marker
                      'face 'parley-input-marker)))

(defconst parley-transcript--input-fill
  (concat (propertize " " 'display '(space :align-to right)
                      'face 'parley-input 'cursor t)
          "\n" parley-transcript--input-rule-below)
  "What carries the band across the last line of the input zone, and closes it.
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
the last column of the window, without it.

The rule after it is the other of the pair
`parley-transcript--input-marker' opens the zone with, so the
zone is bounded whether or not anything has been typed in it.")

(defvar-local parley-transcript--input-overlay nil
  "The overlay marking the input zone, nil in a buffer that has none.")

;; Permanent, and for a sharper reason than the timers below: an
;; overlay belongs to the buffer and not to the binding, so reentering
;; the major mode leaves it on screen -- marker, cell and all -- while
;; clearing the only name the buffer had for it.  Everything that
;; redraws the cell goes through that name, so the mark would stand at
;; whatever the reentry caught it on for as long as the buffer lived,
;; and the next `parley-transcript--mark-input-zone' would hang a
;; second overlay over the first rather than move it.
(put 'parley-transcript--input-overlay 'permanent-local t)

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
        (overlay-put parley-transcript--input-overlay 'after-string
                     parley-transcript--input-fill))
      (parley-transcript--draw-input-marker))))

(defun parley-transcript--draw-input-marker ()
  "Show this buffer's status in the cell in front of its prompt.
The whole marker is redrawn, since the cell is part of it, and
only when the text has changed: the marker is drawn on every tick
and after every output, and an `overlay-put' of what is already
there is a window marked for redisplay that has nothing to
redisplay.  `equal' over two strings is their text, which is the
whole of what changes here."
  (when (overlayp parley-transcript--input-overlay)
    (let ((marker (parley-transcript--input-marker)))
      (unless (equal marker (overlay-get parley-transcript--input-overlay
                                         'before-string))
        (overlay-put parley-transcript--input-overlay 'before-string marker)))))

(defconst parley-transcript--spinner-interval 0.1
  "Seconds between two frames of the spinner in front of the prompt.
Ten frames a second, which reads as motion rather than as a mark
that keeps changing.")

(defvar-local parley-transcript--spinner-frame 0
  "Which frame of `parley-input-spinner-frames' the prompt shows, as a count.
It only ever goes up, and the frame is taken modulo the frames
there are: the operator may set that list to another length while
the spinner is running.")

;; Permanent, as everything else the animation stands on is: where a
;; spinner has got to is part of the animation, and one snapped back
;; to its first frame because the major mode was entered again jumps
;; on screen.
(put 'parley-transcript--spinner-frame 'permanent-local t)

(defvar-local parley-transcript--spinner-timer nil
  "The timer animating this buffer's spinner, nil when nothing is animating.")

;; Permanent for the reason `parley-transcript--status-timer' is:
;; reentering the major mode clears every buffer-local binding that is
;; not, and the timer this one names goes on running with nothing left
;; holding it.
(put 'parley-transcript--spinner-timer 'permanent-local t)

(defun parley-transcript--on-screen-p (buffer)
  "Non-nil when a window on a frame the operator can see is showing BUFFER.
`get-buffer-window' answers a near enough question and not this
one, whichever of its selectors it is given: t counts a window on
a frame that is not on screen, and `visible' counts only frames
on the terminal of the selected one -- an Emacs holding a
graphical frame and an `emacsclient -t' frame has two terminals,
and on that selector the spinner would stop in whichever of them
the operator is not typing in.  So the windows showing BUFFER are
asked for whole and their frames are asked whether they are up.
`frame-visible-p' answers `icon' for an iconified frame, which is
a frame nobody is reading."
  (seq-some (lambda (window) (eq t (frame-visible-p (window-frame window))))
            (get-buffer-window-list buffer nil t)))

(defun parley-transcript--show-status ()
  "Draw this buffer's status in front of its prompt, animating a working one.
The animation is started and stopped from here, which
`parley-transcript--read-status' calls on the tick that learns
the status: a session that has stopped working stops its spinner
within that tick, and a spinner is never left running over a
session that is doing nothing.

A buffer that is on no screen never starts one, though its status
is read: the reader takes a window on any frame at all for
looking at it, and `parley-transcript--on-screen-p' is the
question the animation has to ask."
  (if (and (eq parley-transcript-status 'working)
           (parley-transcript--on-screen-p (current-buffer)))
      (parley-transcript--animate-marker)
    (parley-transcript--unanimate-marker))
  (parley-transcript--draw-input-marker))

(defun parley-transcript--animate-marker ()
  "Advance this buffer's spinner on a tick of its own, if it is not already.
Idempotent, because what calls it is itself a tick: a second
timer over the same buffer would animate it twice as fast and be
half unstoppable."
  (unless (timerp parley-transcript--spinner-timer)
    (setq parley-transcript--spinner-timer
          (run-with-timer parley-transcript--spinner-interval
                          parley-transcript--spinner-interval
                          #'parley-transcript--advance-marker
                          (current-buffer)))
    ;; The hook is what stops a spinner running over a buffer about to
    ;; be killed, and it is kept over a major mode reentered on this
    ;; buffer as the timer above is: `kill-buffer-hook' carries
    ;; `permanent-local' itself (Emacs 28.2), so a reentry that cleared
    ;; it would be clearing every buffer-local kill hook in Emacs and
    ;; not this one alone.
    (add-hook 'kill-buffer-hook #'parley-transcript--unanimate-marker nil t)))

(defun parley-transcript--unanimate-marker ()
  "Stop animating this buffer's spinner."
  (when (timerp parley-transcript--spinner-timer)
    (cancel-timer parley-transcript--spinner-timer)
    (setq parley-transcript--spinner-timer nil)))

(defun parley-transcript--advance-marker (buffer)
  "Show BUFFER's spinner one frame on, and stop if there is nothing to animate.

It stops itself on a buffer that has gone off screen, which is
the case `parley-transcript--read-status' cannot stop: that one
reads nothing for a buffer no window is showing, so it never
reaches the status that would have stopped this.  A frame
redrawn where nobody is looking is a redisplay bought for no one,
and the status it would draw is stale anyway.

BUFFER coming back on screen starts it back up, on the tick that
reads the status.

What it reads is the status the buffer holds and not the session's
file.  `parley-transcript--read-status' is the one thing in the
package that goes to the file, on a tick of its own, and this one
runs ten times as often."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (if (and (eq parley-transcript-status 'working)
               (parley-transcript--on-screen-p buffer))
          (progn
            (setq parley-transcript--spinner-frame
                  (1+ parley-transcript--spinner-frame))
            (parley-transcript--draw-input-marker))
        (parley-transcript--unanimate-marker)))))

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
`parley-transcript--quote' puts the `❯ ' it marks every line of a
turn with -- and reading there rather than under point is what
leaves point at the end of a line still on it."
  (eq (get-text-property (line-beginning-position) 'font-lock-face)
      'parley-user-marker))

(defun parley-transcript--old-input ()
  "Return the turn point stands in, with the renderer's mark taken off.

This is the buffer's `comint-get-old-input', which is what RET on
a past turn resubmits.  comint's default reads the `field'
property and is wrong here in two ways at once.  A turn the
transcript delivered carries `field output', because
`comint-output-filter' puts that on everything it inserts, so the
default takes the line under point whole -- measured on Emacs
28.2 over the rendered turn `what is here', it returns \"❯ what
is here\", and the session is asked a question opening with the
mark the renderer put there.  A turn submitted here carries no `field' at all,
because `parley-transcript--render-input' deleted the text comint
had just put `field input' on and inserted a block that inherits
nothing, so the default returns the whole unfielded run around
it: \"\\n❯ what is here\\n\" over the same buffer.  Both are one
line where the turn may be four.

A turn is the run of lines whose head carries
`parley-user-marker', the face `parley-transcript--quote' puts on
the `❯ ' it writes in front of every line of every turn of the
operator's whichever door it came in by.  The face rather than
the mark itself, because a turn of his may open a line with one
too, and a mark he typed is his text rather than the renderer's
to strip.

Anything else -- an assistant turn, a line the renderer wrote, a
blank line between two blocks -- is nobody's turn for the
operator to send again, and a `user-error' naming that beats
typing a line of somebody else's markdown into a live session."
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
       (concat "^" (regexp-quote parley-transcript--quote-marker)) ""
       (buffer-substring-no-properties start (point))))))

(provide 'parley-transcript)
;;; parley-transcript.el ends here
