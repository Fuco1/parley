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

(defface parley-user '((t :inherit bold))
  "Face for a turn the operator took."
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
plain fontify-region it looks like."
  (unless (buffer-live-p parley-transcript--markdown-buffer)
    (setq parley-transcript--markdown-buffer
          (get-buffer-create " *parley-markdown*"))
    (with-current-buffer parley-transcript--markdown-buffer
      (delay-mode-hooks (markdown-mode))))
  parley-transcript--markdown-buffer)

(defun parley-transcript--fontify (text)
  "Return TEXT as markdown-mode fontifies it, in `font-lock-face' properties.

The fontification happens in `parley-transcript--fontify-buffer'
and not in the transcript buffer, because markdown fontification
is not a set of keywords that can be lifted out of markdown-mode:
fences and inline code are found by its syntax table and its
`syntax-propertize-function', so the keywords alone would give a
broken subset -- and font lock in the transcript buffer would
refontify the whole conversation on every append.

The faces are then copied onto a clean string rather than
remapped in place, because markdown-mode also leaves `invisible'
and its own `markdown-heading' properties behind and the
transcript buffer has business with none of them.  `face' in
particular has to go: comint sets `font-lock-defaults' to
`(nil t)', which is not nil, so global font lock turns font lock
on in that buffer with no keywords at all, where the only thing
it can do is strip -- and `face' is exactly what
`font-lock-default-unfontify-region' removes.  `font-lock-face'
survives it, and is what comint itself puts on its prompt and its
input.  Both were measured."
  (with-current-buffer (parley-transcript--fontify-buffer)
    (erase-buffer)
    (insert text)
    (font-lock-ensure)
    (let ((string (substring-no-properties (buffer-string)))
          (start (point-min))
          (position (point-min)))
      (while (< position (point-max))
        (let ((next (next-single-property-change position 'face nil (point-max)))
              (face (get-text-property position 'face)))
          (when face
            (put-text-property (- position start) (- next start)
                               'font-lock-face face string))
          (setq position next)))
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

(defun parley-transcript--speech (record)
  "Return the block of buffer text RECORD said, nothing if it said nothing.
An assistant turn is markdown and is fontified as markdown.  The
operator's own turn is quoted and otherwise left alone: what he
typed at a terminal is not markdown, and fontifying it as though
it were would invent emphasis he never wrote."
  (let ((text (string-trim-right (or (alist-get 'text record) ""))))
    (cond
     ((string= text "") "")
     ((equal (alist-get 'role record) "assistant")
      (parley-transcript--block (parley-transcript--fontify text)))
     (t (parley-transcript--block
         (propertize (replace-regexp-in-string "^" "> " text)
                     'font-lock-face 'parley-user))))))

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
            (blocks nil))
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
                (setq run 0))
              (push speech blocks))
            (setq run (+ run (or (alist-get 'tools record) 0)))))
        (setq parley-transcript--run run)
        (when (> run 0)
          (push (parley-transcript--tool-run run) blocks))
        (mapconcat #'identity (nreverse blocks) "")))))


;;; The buffer

(defvar-local parley-transcript-session nil
  "The session record this buffer follows.")

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
  ;; A preoutput filter, so the objects are turned into conversation on
  ;; the way in rather than inserted and rewritten in place.
  (add-hook 'comint-preoutput-filter-functions #'parley-transcript--filter
            nil t)
  ;; The pipeline reads a file and nothing else, so its stdin is not a
  ;; way to reach the session.  What the operator submits goes to the
  ;; session's tmux pane instead, which is the door that does reach it.
  (setq-local comint-input-sender #'parley-transcript--send-input))

(defun parley-transcript-buffer-name (session)
  "Return the name of the buffer that follows SESSION."
  (format "*parley: %s*"
          (or (plist-get session :name) (plist-get session :session-id))))

(defun parley-transcript--buffer (session)
  "Return the buffer to show SESSION in, creating it if there is none.

The buffer is found by the session id it records and not by its
name, because the name `claude agents' gives a session is not
unique: two sessions in sibling worktrees come back under one,
and a background agent is named after its prompt.  A lookup by
name would hand the second session the first one's buffer.

`generate-new-buffer' is therefore what creates it -- the name
carries no promise of being free, and every buffer that has one
of these names already belongs to a session that is not this
one."
  (or (seq-find (lambda (buffer)
                  (equal (plist-get (buffer-local-value 'parley-transcript-session
                                                        buffer)
                                    :session-id)
                         (plist-get session :session-id)))
                (buffer-list))
      (generate-new-buffer (parley-transcript-buffer-name session))))

(defun parley-transcript--read-session ()
  "Read one of the live sessions in the minibuffer."
  (let ((table (mapcar (lambda (session)
                         (cons (format "%s  %s"
                                       (or (plist-get session :name)
                                           (plist-get session :session-id))
                                       (plist-get session :cwd))
                               session))
                       (parley-sessions))))
    (unless table
      (user-error "No live Claude Code session to read"))
    (cdr (assoc (completing-read "Session: " table nil t) table))))

;;;###autoload
(defun parley-transcript (session)
  "Show the transcript of SESSION in a comint buffer.
SESSION is a record as `parley-sessions' returns them.
Interactively, read one of the live sessions in the minibuffer.

The buffer's process delivers the transcript from its first byte
and then follows the file, so nothing appended while the history
was arriving is missed.  It is stopped when the buffer is killed.

A buffer already following SESSION is shown as it stands, process
and history and all."
  (interactive (list (parley-transcript--read-session)))
  (let ((buffer (parley-transcript--buffer session)))
    (unless (comint-check-proc buffer)
      (with-current-buffer buffer
        (parley-transcript-mode)
        ;; After the mode, which is what `kill-all-local-variables'
        ;; would otherwise clear this out of.
        (setq parley-transcript-session session)
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
        (set-process-query-on-exit-flag (get-buffer-process buffer) nil)))
    (pop-to-buffer buffer)))


;;; Typing into the pane

(defcustom parley-transcript-echo-window 30
  "Seconds a message sent from the prompt is given to come back.
A user message the transcript delivers within this many seconds
of the same message having been sent from this buffer is comint's
echo of it arriving a second time, and is not shown again.
Later than that it is taken for a message of its own.

Which is what a session that was busy when the message arrived
produces: it holds the input until the turn it was working on has
finished and only then writes it to the transcript, minutes later
if the turn was long.  Raising this makes that case rarer at the
cost of swallowing a message genuinely typed twice."
  :type 'number
  :group 'parley)

(defvar-local parley-transcript--sent nil
  "What was last sent from this buffer, as a cons of the text and the time.
Nil when there is nothing outstanding, which is both before
anything has been sent and after the transcript has delivered the
last thing that was.")

(defun parley-transcript--echoed-p (record)
  "Non-nil if RECORD is the transcript delivering what was sent from here.

comint puts what the operator submitted into the buffer itself,
and the session writes the same message to its transcript seconds
later, so without this every prompt appears twice.

The guard is the last string sent from this buffer, and it is
spent on the first user message that matches it: a second message
saying the very same thing was typed at the pane, and is shown.
So is everything else the operator typed at the pane, which
matches nothing that was sent from here."
  (and parley-transcript--sent
       (equal (alist-get 'role record) "user")
       (equal (string-trim (or (alist-get 'text record) ""))
              (car parley-transcript--sent))
       (< (- (float-time) (cdr parley-transcript--sent))
          parley-transcript-echo-window)
       (progn (setq parley-transcript--sent nil) t)))

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
    (setq parley-transcript--sent (cons (string-trim string) (float-time)))))

(provide 'parley-transcript)
;;; parley-transcript.el ends here
