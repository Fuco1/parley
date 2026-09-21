;;; parley.el --- Read and drive local Claude Code sessions -*- lexical-binding: t -*-

;; Copyright (C) 2026 Matúš Goljer <matus.goljer@gmail.com>

;; Author: Matúš Goljer <matus.goljer@gmail.com>
;; Maintainer: Matúš Goljer <matus.goljer@gmail.com>
;; Version: 0.0.1
;; Created: 9th September 2026
;; Package-Requires: ((emacs "28.1") (markdown-mode "2.3"))
;; Keywords: convenience, processes
;; URL: https://github.com/Fuco1/parley

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

;; A conversation view for the Claude Code sessions running on this
;; machine.  Every session writes an append-only JSONL transcript, and
;; every session started inside tmux carries the pane it lives in.
;; Parley reads the first and types into the second.
;;
;; What you get is the conversation and nothing else: the tool calls an
;; agent makes on its way to an answer collapse to a single line saying
;; how many there were.
;;
;; Sessions are discovered with `claude agents --json' and are not
;; parley's to start or stop -- tmux owns them, whether they were
;; launched by hand or by something like orc.

;;; Code:

(require 'seq)

(defgroup parley nil
  "A conversation view for local Claude Code sessions."
  :group 'tools
  :prefix "parley-")

(defcustom parley-claude-program "claude"
  "The `claude' executable session discovery asks for the live sessions."
  :type 'string)

(defcustom parley-projects-directory "~/.claude/projects"
  "Directory Claude Code keeps session transcripts under.
Each session's transcript is SESSION-ID.jsonl in the
subdirectory named after the session's working directory."
  :type 'directory)


;;; Discovery

;; `claude agents --json' needs no terminal and prints one entry per
;; live session, but its `kind' field does not say what parley needs to
;; know: a worker lane running `claude -p --input-format stream-json'
;; is reported as interactive too.  Standard input is the discriminator
;; that holds -- a session someone types at has a terminal on fd 0, a
;; headless child has a pipe.

(defun parley--agents-json ()
  "Return the raw output of `claude agents --json'."
  (with-temp-buffer
    (let ((status (call-process parley-claude-program nil t nil
                                "agents" "--json")))
      (unless (eq status 0)
        (error "`%s agents --json' failed (%S): %s" parley-claude-program
               status (buffer-string)))
      (buffer-string))))

(defun parley--agents ()
  "Return the entries of `claude agents --json' as a list of alists."
  (append (json-parse-string (parley--agents-json)
                             :object-type 'alist
                             :null-object nil)
          nil))

(defun parley--stdin-target (pid)
  "Return what standard input of PID resolves to, nil if unreadable."
  (file-symlink-p (format "/proc/%s/fd/0" pid)))

(defun parley--terminal-device-p (target)
  "Non-nil if TARGET names a terminal device.
TARGET is what `/proc/PID/fd/0' resolves to: a `/dev/pts/N' for a
session someone is typing at, and `pipe:[N]' for a headless child."
  (and (stringp target)
       (string-match-p "\\`/dev/\\(pts/[0-9]+\\|tty[A-Za-z0-9]*\\)\\'" target)
       t))

(defun parley--process-environ (pid)
  "Return the environment block of PID, nil if unreadable.
The block is the NUL-separated string `/proc/PID/environ' holds."
  (ignore-errors
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert-file-contents-literally (format "/proc/%s/environ" pid))
      (buffer-string))))

(defun parley--environ-tmux-pane (environ)
  "Return the TMUX_PANE value in ENVIRON, nil if it carries none.
ENVIRON is a NUL-separated environment block.  tmux exports
TMUX_PANE into the pane and every descendant inherits it, so the
value is there whoever started the session -- in the `%N' form
`tmux send-keys -t' takes."
  (let* ((entry (seq-find (lambda (var) (string-prefix-p "TMUX_PANE=" var))
                          (split-string (or environ "") "\0" t)))
         (pane (and entry (substring entry (length "TMUX_PANE=")))))
    (unless (equal pane "") pane)))

;; A pane id is what `tmux send-keys -t' takes and nothing the operator
;; can act on: `%15' says nothing about where that pane is, and its `%'
;; reads as a stray format directive wherever it is displayed.  What
;; locates a session is its tmux session, window and pane index, and
;; `tmux list-panes -a' maps every pane id on the server to exactly
;; that -- the whole list in one call, so a dozen sessions cost one
;; subprocess and not a dozen.

(defvar parley--pane-locations 'unasked
  "Where every tmux pane on this machine is, keyed by pane id.
An alist of (PANE-ID . LOCATION), or `unasked' before tmux has
been asked.  Nil is an answer and not the absence of one -- it is
what a machine with no tmux server says -- so the two are
distinct states: asking again for every session is the one thing
the single call exists to avoid.

`parley-sessions' puts this back to `unasked', so the locations
shown beside a list are no older than the list itself.  A pane
the operator moved to another window is somewhere else now.")

(defun parley--tmux-pane-locations ()
  "Return where every tmux pane is, as an alist of (PANE-ID . LOCATION).
LOCATION is the pane's SESSION:WINDOW.PANE.

Nil if tmux is not installed or has no server running, which is a
machine nothing has a pane on anyway.

The location is everything after the first space of a line and
not the second field of it: a tmux session name may contain
spaces and `list-panes' prints it as it is -- measured against
tmux 3.2a, a session named `parley test' prints its first pane as
`%0 parley test:0.0'."
  (with-temp-buffer
    (when (eq 0 (ignore-error file-error
                  (call-process
                   "tmux" nil t nil "list-panes" "-a" "-F"
                   "#{pane_id} #{session_name}:#{window_index}.#{pane_index}")))
      (delq nil
            (mapcar (lambda (line)
                      (when (string-match "\\`\\([^ ]+\\) \\(.+\\)\\'" line)
                        (cons (match-string 1 line) (match-string 2 line))))
                    (split-string (buffer-string) "\n" t))))))

(defun parley--pane-location (pane)
  "Return where tmux pane PANE is, nil if tmux reports no such pane.
Nil rather than an error: a pane can be closed while the session
started in it outlives it, and a session that can no longer be
typed into is still one to read."
  (when (eq parley--pane-locations 'unasked)
    (setq parley--pane-locations (parley--tmux-pane-locations)))
  (cdr (assoc pane parley--pane-locations)))

(defun parley--transcript-file (cwd session-id)
  "Return the absolute path of the transcript of SESSION-ID run in CWD.
Claude Code names the directory after CWD with every character
outside [A-Za-z0-9] replaced by a dash, so `/home/me/a.b' keeps
its transcripts in `-home-me-a-b'."
  (expand-file-name
   (concat session-id ".jsonl")
   (expand-file-name (replace-regexp-in-string "[^A-Za-z0-9]" "-" cwd)
                     parley-projects-directory)))

(defun parley--session (entry)
  "Return the session record for ENTRY, nil if parley cannot talk to it.
ENTRY is one element of `claude agents --json'."
  (let ((pid (alist-get 'pid entry))
        (cwd (alist-get 'cwd entry))
        (session-id (alist-get 'sessionId entry)))
    (when (and pid cwd session-id
               (parley--terminal-device-p (parley--stdin-target pid)))
      (list :pid pid
            :name (alist-get 'name entry)
            :kind (alist-get 'kind entry)
            :status (alist-get 'status entry)
            :cwd cwd
            :session-id session-id
            :pane (parley--environ-tmux-pane (parley--process-environ pid))
            :transcript (parley--transcript-file cwd session-id)))))

(defun parley-sessions ()
  "Return one record per live Claude Code session on this machine.
A record is a plist with these keys:

  :pid         the session process
  :name        the name `claude agents' gives it, or nil
  :kind        \"interactive\" or \"background\" as reported; a headless
               lane says \"interactive\" too, so this is passed on and
               not believed
  :status      \"idle\" or \"busy\" as reported, or nil
  :cwd         its working directory
  :session-id  its session id
  :pane        the tmux pane it lives in, or nil if it is outside tmux
  :transcript  the absolute path of its JSONL transcript

Sessions whose standard input is not a terminal are headless
children -- a lane running `claude -p' -- and are left out."
  ;; The pane locations go back to unasked and are not resolved here:
  ;; what needs one is the tag, and a list nothing tags asks tmux
  ;; nothing at all.
  (setq parley--pane-locations 'unasked)
  (delq nil (mapcar #'parley--session (parley--agents))))

(defun parley-session-tag (session)
  "Return what tells SESSION apart from every other live session.
Something has to: two sessions in sibling worktrees come back
under one name, and a switcher row or a buffer name that cannot
tell them apart lands in the wrong conversation.

Its session id, which is the only thing a record carries that
another record cannot also carry, and where its pane is before
that when it has one: the SESSION:WINDOW.PANE that
`parley--pane-location' resolves the record's `:pane' to.  The
location is what the operator recognises a session by and what he
searches the switcher with, but it is not enough on its own:
suspend the session running in a pane, start another there, and
`claude agents' reports two live sessions in one location.

The pane id is in neither the tag nor anything built from it.  It
is what `tmux send-keys -t' takes, typing is the only thing that
needs it, and `:pane' is where it stays.

A session outside tmux has no pane and so no location, and
neither has one whose pane tmux no longer reports: the tag of
each is its session id alone.

The id whole, and not a head of it: a head is a prefix, two ids
can share one, and two sessions that share a name, a location and
a prefix are then two the tag cannot tell apart at all -- which
is the one thing it exists to do.  A long tag is the price, and
it is the last column of a row and the tail of a buffer name.

It is here rather than in either of the files that need it,
because both do: the switcher lists it as a column and the
transcript buffer is named with it."
  (let* ((id (or (plist-get session :session-id) ""))
         (pane (plist-get session :pane))
         (location (and pane (parley--pane-location pane))))
    (if location (concat location " " id) id)))


;;; Listing a session, and reading one

;; Every way into a session offers the same list in the same order and
;; reads it the same way: `parley-switch' without sallet, and
;; `parley-transcript' called with no session in hand.  Neither of
;; those files can reach the other -- the picker requires the view and
;; a `require' does not survive a cycle -- so the list, the columns and
;; the one `completing-read' over them are here, below both.

(defconst parley-status-order '("idle" "busy")
  "The statuses sessions are listed in, first to last.
An idle session is the one that will read what you type now, so
it comes first.  A status this list does not name sorts after
every status it does.")

(defun parley--status-rank (session)
  "Return the rank of SESSION in `parley-status-order'.
A status the order does not name -- including the nil `claude
agents' reports for a session it knows no status for -- ranks
after every status it does."
  (or (seq-position parley-status-order (plist-get session :status))
      (length parley-status-order)))

(defun parley-sessions-by-status ()
  "Return the live sessions ordered by status.
This is the one place the list a session is picked from is built,
so no frontend can disagree with another about what is running or
in what order.  `sort' is stable, so sessions sharing a status
stay in the order `parley-sessions' discovered them in."
  (sort (parley-sessions)
        (lambda (a b) (< (parley--status-rank a)
                         (parley--status-rank b)))))

(defun parley-session-fields (session)
  "Return the columns SESSION is listed and matched by.
A vector of five strings: its name, its status, the mark saying
it cannot be typed into, its working directory and its tag --
where its pane is and its session id, see `parley-session-tag'.
The tag is matched as one string, so a token naming a tmux window
finds the session running in it.

The mark is what says a session cannot be typed into while the
operator is still choosing which one to open; without it the
first he hears of it is the error his first message raises, by
which point he has written the message.  It is read from the pane
being nil, because the pane is the only way into a session and a
record without one is a record nothing can be sent to.  A
background agent has none, being dispatched from a terminal it
does not own, and so does a session started outside tmux --
`:kind' names the first and says nothing at all about the second,
so it is not what the mark can be read from.

Nothing in a session record is guaranteed to be there, so the
placeholders for a name and a status `claude agents' did not
report are chosen once here rather than by each frontend."
  (vector (or (plist-get session :name) "unnamed")
          (or (plist-get session :status) "unknown")
          (if (plist-get session :pane) "" "read only")
          (abbreviate-file-name (plist-get session :cwd))
          (parley-session-tag session)))

(defun parley-session-row (fields)
  "Return FIELDS as one row of columns, the name first.
FIELDS is a vector from `parley-session-fields'.  A row is what
`completing-read' completes over, because it matches one flat
string and the annotation has to be inside it; the sallet
renderer draws the same row from the same fields.

The read only mark is early in the row and not after the tag,
which is the longest column and the first thing a narrow window
drops: a mark the operator has to scroll to see is one he types
past."
  (apply #'format "%-16s  %-7s  %-9s  %-40s  %s" (append fields nil)))

(defun parley-read-session ()
  "Read one of the live sessions in the minibuffer and return its record.
This is the only `completing-read' over the sessions there is:
`parley-switch' reads with it when sallet is missing and
`parley-transcript' when it is called with no session in hand, so
a row is the same row and an empty list the same error whichever
of them the operator reached for.

The candidates are the rows of `parley-session-row', so each
begins with the session name and carries its tag -- two sessions
started in one repo come back under one name and one working
directory, and without the tag they would be one candidate the
`assoc' below resolves to whichever of them came first: a buffer
showing one conversation and typing into the other one's pane.

The completion metadata keeps the rows in the order
`parley-sessions-by-status' put them in; the default would sort
them alphabetically and lose the status order."
  (let ((rows (mapcar (lambda (session)
                        (cons (parley-session-row
                               (parley-session-fields session))
                              session))
                      (parley-sessions-by-status))))
    (unless rows
      (user-error "No live Claude Code session"))
    (cdr (assoc (completing-read
                 "Session: "
                 (lambda (string predicate action)
                   (if (eq action 'metadata)
                       '(metadata (display-sort-function . identity)
                                  (cycle-sort-function . identity))
                     (complete-with-action action rows string predicate)))
                 nil t)
                rows))))

(provide 'parley)
;;; parley.el ends here
