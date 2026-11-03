;;; parley.el --- Read and drive local Claude Code and Codex sessions -*- lexical-binding: t -*-

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

;; A conversation view for the Claude Code and Codex sessions running
;; on this machine.  Every session writes an append-only JSONL
;; transcript, and every session started inside tmux carries the pane
;; it lives in.  Parley reads the first and types into the second.
;;
;; What you get is the conversation and nothing else: the tool calls an
;; agent makes on its way to an answer collapse to a single line saying
;; how many there were.
;;
;; Claude Code sessions are discovered with `claude agents --json',
;; and Codex sessions by the thread id a Codex TUI writes into its
;; tmux pane's title, which it does once `~/.codex/config.toml' has
;;
;;   [tui]
;;   terminal_title = ["run-state", "spinner", "thread-id"]
;;
;; Neither is parley's to start -- tmux owns them, whether they were
;; launched by hand or by something like orc.  A transcript buffer
;; ends one only the way the operator would at its pane, by typing
;; `/exit' there: see `parley-transcript-exit'.

;;; Code:

(require 'seq)

(defgroup parley nil
  "A conversation view for local Claude Code and Codex sessions."
  :group 'tools
  :prefix "parley-")


;;; Discovery

;; `claude agents --json' needs no terminal and prints one entry per
;; live session, but its `kind' field does not say what parley needs to
;; know: a worker lane running `claude -p --input-format stream-json'
;; is reported as interactive too.  Standard input is the discriminator
;; that holds -- a session someone types at has a terminal on fd 0, a
;; headless child has a pipe.

(defcustom parley-claude-program "claude"
  "The `claude' executable session discovery asks for the live sessions."
  :type 'string)

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
the operator moved to another window is somewhere else now.  When
listing them asks tmux for the title of a Codex TUI's pane, what
tmux answered goes here, because that one answer says where every
pane is as well.")

(defun parley--tmux-panes ()
  "Return every tmux pane, as a list of (PANE-ID LOCATION TITLE).
LOCATION is the pane's SESSION:WINDOW.PANE and TITLE the title
its program last set, which is where a Codex TUI writes the
thread it is on -- see `parley--codex-sessions'.

Nil if tmux is not installed or has no server running, which is a
machine nothing has a pane on anyway.

The location is everything between the first space of a line and
its first tab, and not the second field of it: a tmux session
name may contain spaces and `list-panes' prints it as it is.  It
may contain a `%' as well, which the location then carries and
which is no pane id -- measured against tmux 3.2a, which
sanitises `:' and `.' in a session name, a session named
`parley %test' prints its first pane as `%0 parley %test:0.0'.
It contains no tab, which tmux writes as the two characters \\t,
so the tab is what ends it.

The title is the rest of the line, and may hold any character but
a newline: tmux refuses a title with a control character in it."
  (with-temp-buffer
    (when (eq 0 (ignore-error file-error
                  (call-process
                   "tmux" nil t nil "list-panes" "-a" "-F"
                   (concat "#{pane_id} #{session_name}:#{window_index}"
                           ".#{pane_index}\t#{pane_title}"))))
      (delq nil
            (mapcar (lambda (line)
                      (when (string-match
                             "\\`\\([^ ]+\\) \\([^\t]+\\)\t\\(.*\\)\\'" line)
                        (list (match-string 1 line) (match-string 2 line)
                              (match-string 3 line))))
                    (split-string (buffer-string) "\n" t))))))

(defun parley--remember-pane-locations (panes)
  "Make PANES what tmux last answered about where every pane is.
PANES is what `parley--tmux-panes' returns, and what it says goes
on `parley--pane-locations' for every lookup until the sessions
are next listed."
  (setq parley--pane-locations
        (mapcar (lambda (pane) (cons (car pane) (nth 1 pane))) panes)))

(defun parley-known-pane-location (pane)
  "Return where tmux pane PANE is by what tmux last answered.
Nil for a pane that answer holds nothing for, and nil for every
pane while tmux has not been asked since the sessions were last
listed.  This never asks it: asking runs `tmux list-panes -a',
and a caller on every redisplay cannot pay a subprocess each
time.  `parley-session-fields' and `parley-session-tag' are what
ask."
  (and (listp parley--pane-locations)
       (cdr (assoc pane parley--pane-locations))))

(defun parley--pane-location (pane)
  "Return where tmux pane PANE is, nil if tmux reports no such pane.
Nil rather than an error: a pane can be closed while the session
started in it outlives it, and a session that can no longer be
typed into is still one to read."
  (when (eq parley--pane-locations 'unasked)
    (parley--remember-pane-locations (parley--tmux-panes)))
  (parley-known-pane-location pane))

(define-obsolete-variable-alias 'parley-projects-directory
  'parley-claude-projects-directory "0.0.1")

(defcustom parley-claude-projects-directory "~/.claude/projects"
  "Directory Claude Code keeps session transcripts under.
Each session's transcript is SESSION-ID.jsonl in the
subdirectory named after the session's working directory."
  :type 'directory)

(defun parley--claude-transcript-file (cwd session-id)
  "Return the absolute path of the transcript of SESSION-ID run in CWD.
Claude Code names the directory after CWD with every character
outside [A-Za-z0-9] replaced by a dash, so `/home/me/a.b' keeps
its transcripts in `-home-me-a-b'."
  (expand-file-name
   (concat session-id ".jsonl")
   (expand-file-name (replace-regexp-in-string "[^A-Za-z0-9]" "-" cwd)
                     parley-claude-projects-directory)))

(defun parley--claude-session (entry)
  "Return the Claude Code record for ENTRY, nil if parley cannot talk to it.
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
            :transcript (parley--claude-transcript-file cwd session-id)))))

(defun parley--claude-sessions ()
  "Return one record per Claude Code session parley can follow.
The sessions are the ones `claude agents --json' lists, and
`parley--claude-session' says which of them get a record."
  (delq nil (mapcar #'parley--claude-session (parley--agents))))

(defun parley-sessions ()
  "Return one record per live Claude Code or Codex session on this machine.
A record is a plist with these keys:

  :vendor      `codex' for a Codex session, and absent from a Claude
               Code one
  :pid         the session process
  :name        the name `claude agents' gives it, or the name Codex
               gave the thread; nil when there is none
  :kind        \"interactive\" or \"background\" as `claude agents'
               reports it; a headless lane says \"interactive\" too,
               so this is passed on and not believed.  Absent from a
               Codex session
  :status      the status it reports, as `parley--statuses' spells
               one, or nil
  :cwd         its working directory
  :session-id  its session id, which for Codex is the thread's id
  :pane        the tmux pane it lives in, or nil if it is outside tmux
  :transcript  the absolute path of its JSONL transcript, which for
               Codex is the thread's rollout

Sessions whose standard input is not a terminal are headless
children -- a lane running `claude -p', Codex's daemon, a
`codex exec' -- and are left out.  The Claude Code sessions come
first, and `parley--claude-sessions' says which of them are
listed.  The Codex sessions come after them, and
`parley--codex-sessions' says which of those are listed."
  ;; The pane locations go back to unasked and are not resolved here:
  ;; what needs one is a row or a tag, and a list nothing draws asks
  ;; tmux nothing at all -- unless a Codex process asked it already.
  (setq parley--pane-locations 'unasked)
  (append (parley--claude-sessions) (parley--codex-sessions)))

(defun parley-session-tag (session)
  "Return what tells SESSION apart from every other live session.
That is its whole session id, and before it, when there is one,
the SESSION:WINDOW.PANE that `parley--pane-location' resolves the
record's `:pane' to and a space.  A session outside tmux, or one
whose pane tmux no longer reports, is tagged by its id alone.  The
pane id itself is never in the tag, so a `%' in one is the tmux
session name's own -- see `parley--tmux-pane-locations'.

A name is not enough: two sessions in sibling worktrees come back
under one, and a background agent is named after its prompt.  The
location is not enough either, though it is what a session is
recognised by: a session suspended in a pane and another started
there are two live sessions `claude agents' reports in one
location.  The id goes in whole and never as a prefix, because two
ids can share one, and two sessions sharing a name, a location and
a prefix would be two the tag could not tell apart."
  (let* ((id (or (plist-get session :session-id) ""))
         (pane (plist-get session :pane))
         (location (and pane (parley--pane-location pane))))
    (if location (concat location " " id) id)))


;;; Discovering a Codex session

;; Nothing on a Codex TUI's process says which thread it is on: the
;; rollout is open in Codex's daemon and not in the TUI, and a TUI
;; started as plain `codex' has no id among its arguments.  Its pane
;; title does, once `tui.terminal_title' carries `thread-id', so the
;; title is where a pane and a thread meet.

(defcustom parley-codex-home "~/.codex"
  "Directory Codex keeps its threads under.
A thread's rollout is under `sessions/YYYY/MM/DD' here, and what
the operator named each thread is in `session_index.jsonl'."
  :type 'directory)

(defun parley--processes-named (name)
  "Return the pid of every process on this machine named NAME.
A process's name is what `/proc/PID/comm' holds, which is the
name of the file it runs and not a word of its arguments."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    ;; Nothing under /proc is a file a handler is for, and matching
    ;; every handler's regexp against each of several hundred names is
    ;; most of what the scan would cost otherwise.
    (let ((file-name-handler-alist nil)
          (comm (concat name "\n"))
          (pids nil))
      (dolist (pid (directory-files "/proc" nil "\\`[0-9]+\\'" t) pids)
        (erase-buffer)
        (when (and (ignore-errors
                     (insert-file-contents-literally
                      (format "/proc/%s/comm" pid))
                     t)
                   (equal (buffer-string) comm))
          (push (string-to-number pid) pids))))))

(defun parley--process-cwd (pid)
  "Return the working directory of PID, nil if unreadable."
  (file-symlink-p (format "/proc/%s/cwd" pid)))

(defun parley--codex-title-thread (title)
  "Return the start of the thread id in pane title TITLE, nil if none.
Codex writes the first twenty-nine characters of the id, the hex
digits grouped 8-4-4-4-5, and three dots after them."
  (let ((case-fold-search nil))
    (and title
         (string-match (concat "[0-9a-f]\\{8\\}-[0-9a-f]\\{4\\}-[0-9a-f]\\{4\\}"
                               "-[0-9a-f]\\{4\\}-[0-9a-f]\\{5\\}")
                       title)
         (match-string 0 title))))

(defun parley--codex-rollout (prefix)
  "Return the rollout of the thread whose id starts with PREFIX, nil if none.
PREFIX is what `parley--codex-title-thread' read.  The id's first
twelve hex digits are the thread's creation time in Unix
milliseconds, and Codex files the rollout under the day that time
falls on in local time, as
`sessions/YYYY/MM/DD/rollout-YYYY-MM-DDTHH-MM-SS-ID.jsonl' under
`parley-codex-home'.  That one directory is the only place looked
in.

Codex writes the rollout when the thread is sent its first
message, so a thread nothing has been sent yet has none."
  (let ((created (string-to-number (concat (substring prefix 0 8)
                                           (substring prefix 9 13))
                                   16)))
    (car (file-expand-wildcards
          (expand-file-name
           (format-time-string
            (format "sessions/%%Y/%%m/%%d/rollout-*-%s???????.jsonl" prefix)
            (/ created 1000))
           parley-codex-home)))))

(defun parley--codex-thread-names ()
  "Return what the operator named each Codex thread, as (ID . NAME).
Read from `session_index.jsonl' under `parley-codex-home', which
Codex appends a line to on each rename, so the newest name of a
thread is the first `assoc' finds here.  Nil if there is no such
file."
  (with-temp-buffer
    (ignore-error file-missing
      (insert-file-contents
       (expand-file-name "session_index.jsonl" parley-codex-home)))
    (let ((names nil))
      (dolist (line (split-string (buffer-string) "\n" t) names)
        (let ((entry (ignore-errors
                       (json-parse-string line :object-type 'alist
                                          :null-object nil))))
          (push (cons (alist-get 'id entry) (alist-get 'thread_name entry))
                names))))))

(defun parley--codex-session (pid panes names)
  "Return the record of the Codex TUI PID, nil if parley cannot follow it.
PANES is what `parley--tmux-panes' returned and NAMES what
`parley--codex-thread-names' did.  PID gets a record when its
TMUX_PANE names a pane among PANES, that pane's title carries a
thread id, and the thread has a rollout."
  (let* ((pane (parley--environ-tmux-pane (parley--process-environ pid)))
         (title (nth 2 (assoc pane panes)))
         (prefix (parley--codex-title-thread title))
         (rollout (and prefix (parley--codex-rollout prefix))))
    (when rollout
      ;; The file name ends in the whole id, which the title cuts short.
      (let ((id (substring (file-name-base rollout) -36)))
        (list :vendor 'codex
              :pid pid
              :name (cdr (assoc id names))
              :status (parley--codex-title-status title)
              :cwd (parley--process-cwd pid)
              :session-id id
              :pane pane
              :transcript rollout)))))

(defun parley--codex-sessions ()
  "Return one record per Codex TUI on this machine parley can follow.
A Codex TUI is a process named `codex' with a terminal on standard
input.  Codex's daemon, `codex app-server', is named `codex' too
and has the null device there, and a `codex exec' has a pipe, so
`parley--terminal-device-p' leaves both out as it leaves out a
headless Claude Code.

Which thread a TUI is on is read from its pane's title, the one
place the pane and the thread meet, and a TUI whose title carries
no thread id, or whose thread has no rollout yet, gets no record:
see `parley--codex-session'.

tmux is asked once for the whole list, and only when there is a
TUI to ask about.  The same answer says where every pane is, so
it is kept for the rows and tags drawn from the list rather than
asked for again."
  (let ((pids (seq-filter (lambda (pid)
                            (parley--terminal-device-p
                             (parley--stdin-target pid)))
                          (parley--processes-named "codex"))))
    (when pids
      (let ((panes (parley--tmux-panes))
            (names (parley--codex-thread-names)))
        (parley--remember-pane-locations panes)
        (delq nil (mapcar (lambda (pid)
                            (parley--codex-session pid panes names))
                          pids))))))


;;; What a session is doing

;; A session writes what it is doing to `PID.json' under
;; `parley-claude-sessions-directory', and that file is where this is
;; read from: `claude agents --json' reads the same files and costs a
;; subprocess on the one thread Emacs has, and all it adds is the
;; liveness filter that the two comparisons below make anyway.
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
;;
;; A Codex session writes no such file, and outside its daemon the one
;; place it says what it is doing is its pane's title -- the title its
;; thread id is read from -- so that is read instead, and the thread
;; id in it is what stands in for the comparisons.

(define-obsolete-variable-alias 'parley-sessions-directory
  'parley-claude-sessions-directory "0.0.1")

(defcustom parley-claude-sessions-directory "~/.claude/sessions"
  "Directory Claude Code keeps one file per session under.
Each session's file is PID.json and holds that session's own
account of itself: its `status', the `sessionId' it is running
and the `procStart' of the process writing it."
  :type 'directory)

(defconst parley--statuses
  '(("busy" . working) ("waiting" . waiting) ("idle" . idle)
    ("shell" . idle) ("Ready" . idle) ("Working" . working)
    ("Thinking" . working) ("Action Required" . waiting))
  "What each status a session writes about itself is read as.
The first four are what Claude Code writes into the file it
keeps about itself.  It writes `shell' where it would write
`idle' while a background shell it started is still running, and
the session takes what is typed at it all the same.  The rest are
what a Codex TUI writes into its pane's title: its run state,
which is `Ready', `Working' or `Thinking', and `Action Required'
while it waits on the operator to approve something.  A status
not named here is read as `unknown'.")

(defun parley--status-value (status)
  "Return the value STATUS, as a session writes it, is read as.
The value `parley--statuses' maps STATUS to, and `unknown' for a
STATUS that table does not name -- including the nil `claude
agents' reports for a session it knows no status for."
  (or (cdr (assoc status parley--statuses)) 'unknown))

(defun parley--codex-title-status (title)
  "Return the status pane title TITLE says, nil if it says none.
That is the first status `parley--statuses' names that stands in
TITLE as words of its own.  A Codex TUI writes its run state at
the head of its title, and while it waits on the operator writes
`Action Required' there instead, behind a `[ ! ]' or a `[ . ]'
that alternate."
  (let ((case-fold-search nil))
    (and title
         (string-match (regexp-opt (mapcar #'car parley--statuses) 'words)
                       title)
         (match-string 0 title))))

(defun parley--claude-status-file (pid)
  "Return what Claude Code session PID says about itself, nil if nothing.
The contents of `PID.json' under `parley-claude-sessions-directory'
as an alist, and nil if there is no such file or it does not
parse: a session that says nothing about itself is not an error,
it is a session nothing can be said about."
  (ignore-errors
    (with-temp-buffer
      (insert-file-contents
       (expand-file-name (format "%s.json" pid)
                         parley-claude-sessions-directory))
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
worse than no indicator at all.

A Codex session, one whose `:vendor' is `codex', writes no such
file, and what it is doing is read from its pane's title as tmux
reports it now, by `parley--codex-title-status', which costs a
subprocess.  The title has to carry the start of SESSION's thread
id: Codex moves the title to another thread on `/new' and
`/resume', and the status beside that id is another thread's.  A
title carrying another id or none, and a pane tmux does not
report, return `unknown'."
  (if (eq (plist-get session :vendor) 'codex)
      (let* ((id (plist-get session :session-id))
             (title (nth 2 (assoc (plist-get session :pane)
                                  (parley--tmux-panes))))
             (prefix (parley--codex-title-thread title)))
        (if (and prefix (stringp id) (string-prefix-p prefix id))
            (parley--status-value (parley--codex-title-status title))
          'unknown))
    (let* ((pid (plist-get session :pid))
           (id (plist-get session :session-id))
           (fields (and pid (parley--claude-status-file pid)))
           (start (and fields (parley--process-start pid))))
      (or (and start
               (stringp id)
               (equal (alist-get 'sessionId fields) id)
               (equal (alist-get 'procStart fields) start)
               (cdr (assoc (alist-get 'status fields) parley--statuses)))
          'unknown))))


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
SESSION's status is read by `parley--status-value' and the value
it is read as is what the order is over: `claude agents' reports
a status out of the session's own file, which is the file
`parley--statuses' reads, so the two spell one status alike.

A value the order does not name -- `unknown' among them -- ranks
after every value it does."
  (or (seq-position parley-status-order
                    (parley--status-value (plist-get session :status)))
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
Nothing reads it but `parley-session-name', which every display
of a session takes its name from.")

(defun parley-session-name (session)
  "Return the name SESSION is shown under.
That is the name `claude agents' reported for it, or
`parley-session-no-name' for a session it named none.  A switcher
row, a transcript buffer's name and that buffer's header line
each show such a session, and three placeholders chosen three
times are three sessions the operator has to match up himself."
  (or (plist-get session :name) parley-session-no-name))

(defconst parley-session-read-only-mark "[RO]"
  "The mark saying a session cannot be typed into.
Nothing reads it but `parley-session-mark', which every display
of a session takes the mark from.")

(defun parley-session-mark (session)
  "Return the mark saying SESSION cannot be typed into, or nil.
That is `parley-session-read-only-mark' for a session with no
pane and nil for one with a pane.  A switcher row and a
transcript buffer's header line both carry it, and the operator
reads the two against each other.

It is read from the pane being nil, because the pane is the only
way into a session and a record without one is a record nothing
can be sent to.  A background agent has none, being dispatched
from a terminal it does not own, and so does a session started
outside tmux -- `:kind' names the first and says nothing at all
about the second, so it is not what the mark can be read from."
  (unless (plist-get session :pane) parley-session-read-only-mark))

(defun parley-session-fields (session)
  "Return the columns SESSION is listed and matched by.
A plist of four strings, one keyword per column: `:name',
`:status', `:mark' saying it cannot be typed into, and `:window'
for the WINDOW.PANE of its pane -- the location
`parley--pane-location' resolves the record's `:pane' to, without
the tmux session.  `:window' is the empty string for a session
with no pane and for one whose pane tmux does not report.

The name is the whole name, though `parley-session-row' cuts a
long one to its column: what the sallet matcher reads is this
plist, so a word in the part of a name the row cuts off still
finds the session.

The name is taken from `parley-session-name' and the mark from
`parley-session-mark', with the empty string for a session that
gives no mark.  The mark is what says a session cannot be typed into
while the operator is still choosing which one to open; without
it the first he hears of it is the error his first message
raises, by which point he has written the message.

The status is the name of the value `parley--status-value' reads
the record's status as, and not the string the session wrote: a
session that wrote \"busy\" is listed `working', which is the word
the transcript's header line shows for it, and one whose status
parley does not name, or that `claude agents' reported none for,
is listed `unknown'.  Nothing in a session record is guaranteed
to be there, so that placeholder is chosen once here rather than
by each frontend."
  (let* ((pane (plist-get session :pane))
         (location (and pane (parley--pane-location pane))))
    (list :name (parley-session-name session)
          :status (symbol-name
                   (parley--status-value (plist-get session :status)))
          :mark (or (parley-session-mark session) "")
          ;; tmux takes the colons out of a session name, so the last
          ;; colon of a location is the one after the tmux session.
          :window (if location (car (last (split-string location ":"))) ""))))

(defun parley-session-buffer (session)
  "Return the live buffer that follows SESSION, nil if there is none.
That is a buffer whose `parley-transcript-session' carries
SESSION's `:session-id'.

This is the one test there is of whether a session has a buffer:
`parley-transcript' shows the buffer it returns rather than
opening a second over the same conversation, and a switcher row
draws the name of a session it returns one for in
`parley-row-name-open'.  A row drawn so is therefore exactly a
session that switching to lands in a buffer already there.

The buffer is found by the session id it records and not by its
name.  The name tells two live sessions apart, but a session that
has ended leaves its buffer behind with its name still on it, and
the next session in that pane would be handed it."
  (let ((id (plist-get session :session-id)))
    (seq-find (lambda (buffer)
                ;; `parley-transcript-session' is the view's, and this
                ;; file cannot require the view.  A buffer has its own
                ;; binding of it only once the view has set one, so
                ;; `local-variable-p' answers nil for every buffer
                ;; while the view is not loaded, where
                ;; `buffer-local-value' would signal on a variable
                ;; nothing has defined.
                (and (local-variable-p 'parley-transcript-session buffer)
                     (equal (plist-get (buffer-local-value
                                        'parley-transcript-session buffer)
                                       :session-id)
                            id)))
              (buffer-list))))

;; Both frontends draw this row, so the faces go on it:
;; `completing-read' displays a face on a candidate as readily as a
;; sallet buffer does, and faces the picker owned would leave the
;; minibuffer fallback plain.

(defface parley-row-name '((t :inherit font-lock-function-name-face))
  "Face for the name column of a session row.")

(defface parley-row-name-open '((t :inherit font-lock-keyword-face))
  "Face for the name column of a session that has a transcript buffer.
`parley-session-buffer' is what says it has one.")

(defface parley-row-status-idle '((t :inherit success))
  "Face for the status column of a session that is idle.")

(defface parley-row-status-working '((t :inherit warning))
  "Face for the status column of a session that is working.")

(defface parley-row-status-waiting '((t :inherit error))
  "Face for the status column of a session that is waiting.")

(defface parley-row-status-other '((t :inherit shadow))
  "Face for a status column holding a status parley does not name.")

(defface parley-row-read-only '((t :inherit font-lock-constant-face))
  "Face for the mark saying a session cannot be typed into.")

(defface parley-row-window '((t :inherit font-lock-comment-face))
  "Face for the column of a session row holding its pane's WINDOW.PANE.")

(defun parley--status-face (value)
  "Return the face the status column draws VALUE in.
VALUE is what `parley--status-value' reads a status as.  `idle',
`working' and `waiting' are what the operator scans a list for,
so each has a colour of its own, and `unknown' is drawn in
`parley-row-status-other'."
  (pcase value
    ('idle 'parley-row-status-idle)
    ('working 'parley-row-status-working)
    ('waiting 'parley-row-status-waiting)
    (_ 'parley-row-status-other)))

(defun parley--column (string width face)
  "Return STRING as a column WIDTH wide, padded with spaces in FACE.
The padding carries FACE and not the default, so a column is
coloured across the whole of it and a theme giving one of these
faces a background gets a column and not a ragged stripe.
STRING brings its own faces, which is how the read only mark
keeps its colour inside the status column.

WIDTH is a display width and not a count of characters: a name
written in a script drawn two columns to the glyph lines up with
the rest of the list only if it is measured the way it is drawn.

STRING wider than WIDTH is cut to it, with an ellipsis in FACE as
its last display column: a string drawn whole would push the
columns after it along that one row, and the columns exist to be
read down.  A glyph two columns wide that does not fit before the
ellipsis leaves a space in its place, ahead of the ellipsis, so
the ellipsis ends the column on every row it is drawn in."
  (let* ((ellipsis (if (> (string-width string) width)
                       (propertize "…" 'face face)
                     ""))
         (head (truncate-string-to-width
                string (- width (string-width ellipsis)))))
    (concat head
            (propertize (make-string (- width (string-width head)
                                        (string-width ellipsis))
                                     ?\s)
                        'face face)
            ellipsis)))

(defun parley-session-row (fields &optional open)
  "Return FIELDS as one row of three faced columns.
FIELDS is a plist from `parley-session-fields'.  The columns are
the name, the status with the read only mark after it, and the
WINDOW.PANE of the session's pane, which is empty for a session
with no pane.  A row is what `completing-read' completes over,
because it matches one flat string and the annotation has to be
inside it; the sallet renderer draws the same row from the same
fields.  The faces are on the string itself, so both frontends
colour a session alike.

OPEN non-nil says the session already has a buffer, which is
what `parley-session-buffer' answers, and draws the name column
in `parley-row-name-open' rather than `parley-row-name'.  Only
the name column changes: the status colours carry the status,
and a second meaning on them would cost the operator the one he
scans the list for.  Sessions named after a directory and a short
suffix read alike in a list, and without the face a session he is
already reading looks like one he never opened.

The name column is seventy display columns wide, and a wider name
is cut to it with an ellipsis as its last: a background agent is
named after its prompt, and a name drawn whole pushes the status
along its own row and out of line with every other row's.  The
cut is in the row only, and the sallet matcher reads the whole
name from FIELDS.

The read only mark is drawn inside the status column, after the
status, and has none of its own: a column of its own is blank on
every session that has a pane, which is nearly all of them, and
what it holds reads as something about the status anyway.  Twelve
columns is what the two come to together at their longest,
\"waiting [RO]\" or \"unknown [RO]\": the column holds one of
the values `parley--status-value' reads a status as, so a status
parley does not name is listed `unknown' and never runs past it.

Neither the working directory nor the tmux session is drawn: the
sessions on a machine running one fleet share both, so either
column would be one string repeated down the list.  Nor is the
session id, which is not what the operator picks a session by.
Two sessions can therefore draw one row, and each frontend keeps
them apart itself: a sallet candidate carries its record, and
`parley-read-session' numbers a row drawn again."
  (let* ((name (plist-get fields :name))
         (status (plist-get fields :status))
         (mark (plist-get fields :mark))
         (window (plist-get fields :window))
         (name-face (if open 'parley-row-name-open 'parley-row-name))
         (status-face (parley--status-face (intern status))))
    (concat
     (parley--column (propertize name 'face name-face) 70 name-face)
     "  "
     (parley--column
      (if (equal mark "")
          (propertize status 'face status-face)
        (concat (propertize (concat status " ") 'face status-face)
                (propertize mark 'face 'parley-row-read-only)))
      12 status-face)
     "  "
     (propertize window 'face 'parley-row-window))))

(defun parley-read-session ()
  "Read one of the live sessions in the minibuffer and return its record.
This is the only `completing-read' over the sessions there is:
`parley-switch' reads with it when sallet is missing and
`parley-transcript' when it is called with no session in hand, so
a row is the same row and an empty list the same error whichever
of them the operator reached for.

The candidates are the rows of `parley-session-row', and a row
drawn again is offered with \"<N>\" after it, N counting the
sessions that drew that row so far.  Two live sessions can draw
one: a session suspended in a pane and another started there
share a name, a status and a window, and two background agents
named after one prompt share a name and a status and have no
pane.  A row is resolved back to its record by the string itself,
so without the number they would be one candidate the `assoc'
below resolves to whichever of them came first: a buffer showing
one conversation and typing into the other one's pane.  A session
`parley-session-buffer' finds a buffer for has its row drawn
open, as the sallet renderer draws it.

The completion metadata keeps the rows in the order
`parley-sessions-by-status' put them in; the default would sort
them alphabetically and lose the status order."
  (let ((drawn nil)
        (rows nil))
    (dolist (session (parley-sessions-by-status))
      (let* ((row (parley-session-row (parley-session-fields session)
                                      (parley-session-buffer session)))
             (before (seq-count (lambda (other) (equal other row)) drawn)))
        (push row drawn)
        (push (cons (if (zerop before) row (format "%s <%d>" row (1+ before)))
                    session)
              rows)))
    (setq rows (nreverse rows))
    (unless rows
      (user-error "No live Claude Code or Codex session"))
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
