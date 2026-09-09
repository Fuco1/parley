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
;; comint requires a live process, since `comint-send-input' errors
;; without one, and this pipeline is it.  Nothing is ever written to
;; its stdin: typing into the buffer is how the operator will drive the
;; session's tmux pane, and a pane is not this process.

;;; Code:

(require 'comint)
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

(defvar-local parley-transcript-session nil
  "The session record this buffer follows.")

(define-derived-mode parley-transcript-mode comint-mode "Parley"
  "Major mode for the projected transcript of a Claude Code session.

The buffer holds one JSON object per message, as
`parley-transcript-projection' emitted it.  Turning those into a
conversation is the renderer's job and not this mode's."
  ;; `ansi-color-process-output' is in the default value of
  ;; `comint-output-filter-functions' as of Emacs 28, and `jq -M'
  ;; leaves it nothing to find: measured over the 26 MB transcript, not
  ;; one escape byte reaches the buffer.  Scanning the 1.3 MB for them
  ;; anyway costs 2.4 s of the 6.9 s that history takes to settle, and
  ;; not spending Emacs's one thread on a search that cannot succeed is
  ;; the whole reason jq is in this pipeline.
  (setq-local comint-output-filter-functions
              (remq 'ansi-color-process-output comint-output-filter-functions))
  ;; The pipeline reads a file and nothing else, so its stdin is not a
  ;; way to reach the session.  Discarding the line keeps comint's echo
  ;; of what was typed, which is all this mode can honestly offer.
  (setq-local comint-input-sender #'ignore))

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

(provide 'parley-transcript)
;;; parley-transcript.el ends here
