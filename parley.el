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

(defcustom parley-sessions-directory "~/.claude/sessions"
  "Directory Claude Code keeps one file per session under.
Each session's file is PID.json and holds that session's own
account of itself: its `status', the `sessionId' it is running
and the `procStart' of the process writing it."
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

;; A pane id is what `tmux send-keys -t' takes; where the pane is is
;; what a session is shown by, because `%15' locates nothing the
;; operator can act on.  `tmux list-panes -a' maps the one to the
;; other, and it maps the whole server in a single call.

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
spaces and `list-panes' prints it as it is.  It may contain a `%'
as well, which the location then carries and which is no pane id
-- measured against tmux 3.2a, which sanitises `:' and `.' in a
session name and nothing else, a session named `parley %test'
prints its first pane as `%0 parley %test:0.0'."
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
  :status      the status it reports, as `parley--statuses' spells
               one, or nil
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
needs it, and `:pane' is where it stays.  A `%' in a tag is
therefore the tmux session name's own and never a pane id, tmux
allowing one there -- see `parley--tmux-pane-locations'.

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


;;; What a session is doing

;; A session writes what it is doing to `PID.json' under
;; `parley-sessions-directory', and that file is where this is read
;; from: `claude agents --json' reads the same files and costs 0.38 s a
;; call, which is 0.38 s of the one thread Emacs has, and all it adds
;; is the liveness filter that the two comparisons below make anyway.
;;
;; There is no heartbeat in the file -- it is written in place when the
;; session changes what it is doing and not otherwise, so a `busy' with
;; a `statusUpdatedAt' hours old is a session still working -- and
;; nothing in it says the session died.  What says that is the pid: the
;; `sessionId' has to be the one being asked about, because a pane is
;; reused and the next session in it is another conversation, and the
;; `procStart' has to be the one /proc reports, because a pid that has
;; been handed to an unrelated process would otherwise read as that
;; session forever.

(defconst parley--statuses
  '(("busy" . working) ("waiting" . waiting) ("idle" . idle))
  "What each status a session writes about itself is read as.
A status not named here is read as `unknown'.")

(defun parley--status-file (pid)
  "Return what session PID says about itself, nil if it says nothing.
The contents of `PID.json' under `parley-sessions-directory' as
an alist, and nil if there is no such file or it does not parse:
a session that says nothing about itself is not an error, it is a
session nothing can be said about."
  (ignore-errors
    (with-temp-buffer
      (insert-file-contents
       (expand-file-name (format "%s.json" pid) parley-sessions-directory))
      (json-parse-buffer :object-type 'alist :null-object nil))))

(defun parley--process-start (pid)
  "Return the start time /proc reports for PID, nil if PID is not running.
Field 22 of `/proc/PID/stat', counted from the closing paren of
the process name: the name is field 2 and is printed in parens,
it may hold spaces and parens of its own, and so nothing up to
that paren can be split on whitespace.  The process state is
field 3 and the first field after it, which puts the start time
twentieth."
  (ignore-errors
    (with-temp-buffer
      (insert-file-contents (format "/proc/%s/stat" pid))
      (goto-char (point-max))
      (when (search-backward ")" nil t)
        (nth 19 (split-string (buffer-substring (1+ (point)) (point-max))))))))

(defun parley-session-status (session)
  "Return what SESSION is doing now, as one of four symbols.

`working' for a session that is going, `waiting' for one that has
stopped on something only the operator can answer, `idle' for one
that has finished and will read what is typed at it next, and
`unknown' for a session none of that can be said about.

Waiting is not a slower kind of idle, which is why it is its own
value: an idle session needs nothing, and a waiting one needs the
operator and is going nowhere until it has him.  A session's file
carries a `waitingFor' beside the status saying what it is
waiting for, and nothing here reads it -- one sample of that
field is no vocabulary to read it against.

It is read from the session's own file and costs no subprocess.
Two comparisons stand in for the liveness `claude agents' would
have filtered by, and both are needed: the file's `sessionId' has
to be the one SESSION is following, a pane being reused and the
next session in it being another conversation, and its
`procStart' has to be the start time /proc reports for that pid,
a pid handed on to an unrelated process otherwise reading as this
session for as long as that process lives.

A status this does not know, a file that is not there, a file
about another session and a process that is gone all return
`unknown', and none of them ever returns `working': what draws a
status draws working as motion, and motion that never stops is
worse than no indicator at all."
  (let* ((pid (plist-get session :pid))
         (id (plist-get session :session-id))
         (fields (and pid (parley--status-file pid)))
         (start (and fields (parley--process-start pid))))
    (or (and start
             (stringp id)
             (equal (alist-get 'sessionId fields) id)
             (equal (alist-get 'procStart fields) start)
             (cdr (assoc (alist-get 'status fields) parley--statuses)))
        'unknown)))


;;; Listing a session, and reading one

;; Every way into a session offers the same list in the same order and
;; reads it the same way: `parley-switch' without sallet, and
;; `parley-transcript' called with no session in hand.  Neither of
;; those files can reach the other -- the picker requires the view and
;; a `require' does not survive a cycle -- so the list, the columns and
;; the one `completing-read' over them are here, below both.

(defconst parley-status-order '(waiting idle working)
  "The statuses sessions are listed in, first to last.
Each is a value `parley--statuses' reads a status as, so the
strings a session writes are spelled in one place.

A waiting session is stopped and cannot go on until the operator
answers it, where an idle one is not stopped: it has finished,
and it will read what he types next.  Both are open to him and
only one of them is blocked on him, so waiting leads and idle
follows.  A busy session needs nothing from him at all and comes
last.  A status this list does not name sorts after every status
it does.")

(defun parley--status-rank (session)
  "Return the rank of SESSION in `parley-status-order'.
SESSION's status is mapped through `parley--statuses' and the
value it maps to is what the order is over: `claude agents'
reports a status out of the session's own file, which is the file
that table reads, so the two spell one status alike.

A status neither the order nor that table names -- including the
nil `claude agents' reports for a session it knows no status for
-- maps to nothing, is in no order, and ranks after every status
they do."
  (or (seq-position parley-status-order
                    (cdr (assoc (plist-get session :status)
                                parley--statuses)))
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

(defconst parley-session-no-name "unnamed"
  "What stands in for the name of a session `claude agents' named none.
One string and not one per frontend: a switcher row, a transcript
buffer's name and that buffer's header line each show such a
session, and three spellings of the placeholder are three
sessions the operator has to match up himself.")

(defconst parley-session-read-only-mark "[RO]"
  "The mark saying a session cannot be typed into.
Here for the reason `parley-session-no-name' is: a switcher row
and a transcript buffer's header line both carry it, and the
operator reads the two against each other.")

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
placeholder for a status `claude agents' did not report is chosen
once here rather than by each frontend, and the one for a name it
did not report is `parley-session-no-name'."
  (vector (or (plist-get session :name) parley-session-no-name)
          (or (plist-get session :status) "unknown")
          (if (plist-get session :pane) "" parley-session-read-only-mark)
          (abbreviate-file-name (plist-get session :cwd))
          (parley-session-tag session)))

;; Both frontends draw this row, so the faces go on it:
;; `completing-read' displays a face on a candidate as readily as a
;; sallet buffer does, and faces the picker owned would leave the
;; minibuffer fallback plain.

(defface parley-row-name '((t :inherit font-lock-function-name-face))
  "Face for the name column of a session row.")

(defface parley-row-status-idle '((t :inherit success))
  "Face for the status column of a session that is idle.")

(defface parley-row-status-busy '((t :inherit warning))
  "Face for the status column of a session that is busy.")

(defface parley-row-status-waiting '((t :inherit error))
  "Face for the status column of a session that is waiting.")

(defface parley-row-status-other '((t :inherit shadow))
  "Face for a status column holding a status parley does not name.")

(defface parley-row-read-only '((t :inherit font-lock-constant-face))
  "Face for the mark saying a session cannot be typed into.")

(defface parley-row-directory '((t :inherit font-lock-string-face))
  "Face for the working directory column of a session row.")

(defface parley-row-tag '((t :inherit font-lock-comment-face))
  "Face for the tag column of a session row.")

(defun parley--status-face (status)
  "Return the face the status column draws STATUS in.
\"idle\", \"busy\" and \"waiting\" are what the operator scans a
list for, so each has a colour of its own.  Any other status --
including the \"unknown\" placeholder for a session `claude
agents' reports none for -- is drawn in
`parley-row-status-other'."
  (cond ((equal status "idle") 'parley-row-status-idle)
        ((equal status "busy") 'parley-row-status-busy)
        ((equal status "waiting") 'parley-row-status-waiting)
        (t 'parley-row-status-other)))

(defun parley--column (string width face &optional cut)
  "Return STRING as a column WIDTH wide, padded with spaces in FACE.
The padding carries FACE and not the default, so a column is
coloured across the whole of it and a theme giving one of these
faces a background gets a column and not a ragged stripe.
STRING brings its own faces, which is how the read only mark
keeps its colour inside the status column.

WIDTH is a display width and not a count of characters: a name
written in a script drawn two columns to the glyph lines up with
the rest of the list only if it is measured the way it is drawn.

STRING is drawn whole unless CUT, and drawing it whole is what
pushes the columns after it along that one row.  CUT is for a
column holding one of a handful of values -- a status -- where
what is lost is nothing the operator picks a session by.  A name
and a working directory are exactly that, so neither is ever
cut."
  (let* ((drawn (if cut (truncate-string-to-width string width) string))
         (padding (max 0 (- width (string-width drawn)))))
    (concat drawn (propertize (make-string padding ?\s) 'face face))))

(defun parley-session-row (fields)
  "Return FIELDS as one row of faced columns, the name first.
FIELDS is a vector from `parley-session-fields'.  A row is what
`completing-read' completes over, because it matches one flat
string and the annotation has to be inside it; the sallet
renderer draws the same row from the same fields.  The faces are
on the string itself, so both frontends colour a session alike.

The read only mark is drawn inside the status column, after the
status, and has none of its own: a column of its own is blank on
every session that has a pane, which is nearly all of them, and
what it holds reads as something about the status anyway.  Twelve
columns is what the two come to together at their longest,
\"waiting [RO]\", and a status parley does not name is cut to
that: it is the one column here holding a value from a short
list, and a row whose status runs long would carry every column
after it out of line."
  (let* ((name (aref fields 0))
         (status (aref fields 1))
         (mark (aref fields 2))
         (directory (aref fields 3))
         (tag (aref fields 4))
         (status-face (parley--status-face status)))
    (concat
     (parley--column (propertize name 'face 'parley-row-name)
                     50 'parley-row-name)
     "  "
     (parley--column
      (if (equal mark "")
          (propertize status 'face status-face)
        (concat (propertize (concat status " ") 'face status-face)
                (propertize mark 'face 'parley-row-read-only)))
      12 status-face t)
     "  "
     (parley--column (propertize directory 'face 'parley-row-directory)
                     40 'parley-row-directory)
     "  "
     (propertize tag 'face 'parley-row-tag))))

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
