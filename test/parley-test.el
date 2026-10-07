;;; parley-test.el --- Tests for parley -*- lexical-binding: t -*-

;;; Commentary:

;; Discovery reads three things about a session: the entry `claude
;; agents --json' printed for it, what its standard input resolves to
;; and its environment block.  All three are text, so all three come
;; from fixtures here and no test needs a live session.
;;
;; The fourth thing it reads is tmux, for where a pane is, and that is
;; a fixture map bound over `parley--pane-locations' -- so no test
;; here is answered by the panes of whatever server the machine
;; happens to be running.  The one test that does ask a real tmux
;; starts a server of its own, because the shape of a location is what
;; it is asserting.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'parley)
(require 'parley-fixtures
         (expand-file-name "parley-fixtures"
                           (file-name-directory (macroexp-file-name))))


;;; Fixtures

;; Entries as `claude agents --json' really prints them: a session
;; in a tmux pane, one started outside tmux, a headless worker lane
;; reported as `interactive' all the same, one the command knows no
;; name or status for, and an entry whose pid it printed as null.
(defconst parley-test--agents-json "[
  {
    \"pid\": 4079793,
    \"cwd\": \"/home/matus/dev/go/orc\",
    \"kind\": \"interactive\",
    \"startedAt\": 1788627408524,
    \"sessionId\": \"9a5a5635-26c3-4705-b06e-4dc108d75439\",
    \"name\": \"orc-0c\",
    \"status\": \"idle\"
  },
  {
    \"pid\": 1334764,
    \"cwd\": \"/home/matus/dev/ydistri/Ydistri.Pairing\",
    \"kind\": \"interactive\",
    \"startedAt\": 1788535649889,
    \"sessionId\": \"eb6ab7cd-21e6-434f-9bf6-f561b5852de2\",
    \"name\": \"app-8e\",
    \"status\": \"busy\"
  },
  {
    \"pid\": 40796,
    \"cwd\": \"/home/matus/dev/orc/trees/worker-4/orc\",
    \"kind\": \"interactive\",
    \"startedAt\": 1788627408525,
    \"sessionId\": \"7c1d0f9a-0000-4000-8000-000000000001\",
    \"name\": \"orc-w4\",
    \"status\": null
  },
  {
    \"pid\": 652261,
    \"cwd\": \"/home/matus\",
    \"kind\": \"interactive\",
    \"startedAt\": 1788627408527,
    \"sessionId\": \"7c1d0f9a-0000-4000-8000-000000000003\",
    \"name\": null,
    \"status\": null
  },
  {
    \"pid\": null,
    \"cwd\": \"/home/matus/dev/orc\",
    \"kind\": \"background\",
    \"startedAt\": 1788627408526,
    \"sessionId\": \"7c1d0f9a-0000-4000-8000-000000000002\",
    \"name\": null,
    \"status\": null
  }
]")

;; Standard input per pid, as `readlink /proc/PID/fd/0' gave it: a
;; terminal for every entry but the lane running `claude -p', whose
;; standard input is a pipe.
(defconst parley-test--stdin
  '((4079793 . "/dev/pts/44")
    (1334764 . "/dev/pts/23")
    (40796 . "pipe:[175832757]")
    (652261 . "/dev/pts/180")))

;; Environment blocks per pid.  The worker lane has a TMUX_PANE too --
;; tmux exports it into every descendant of the pane -- which is why
;; nothing about the pane can be used to exclude it.
(defconst parley-test--environ
  '((4079793 . "SHELL=/bin/bash\0TMUX_PANE=%61\0TMUX=/tmp/tmux-1000/default,3661208,3\0")
    (1334764 . "SHELL=/bin/bash\0TERM=xterm-256color\0")
    (40796 . "TMUX_PANE=%627\0TMUX=/tmp/tmux-1000/default,3661208,3\0")
    (652261 . "TMUX_PANE=%238\0SHELL=/bin/bash\0")))

(defmacro parley-test--with-fixtures (&rest body)
  "Run BODY with discovery reading the fixtures instead of the machine."
  (declare (indent 0))
  `(let ((parley-projects-directory "/home/matus/.claude/projects"))
     (cl-letf (((symbol-function 'parley--agents-json)
                (lambda () parley-test--agents-json))
               ((symbol-function 'parley--stdin-target)
                (lambda (pid) (alist-get pid parley-test--stdin)))
               ((symbol-function 'parley--process-environ)
                (lambda (pid) (alist-get pid parley-test--environ))))
       ,@body)))


;;; The exclusion rule

(ert-deftest parley-test-a-terminal-passes-and-a-pipe-does-not ()
  "A terminal is a terminal; a pipe, a socket and /dev/null are not."
  (dolist (target '("/dev/pts/0" "/dev/pts/44" "/dev/pts/180" "/dev/tty"
                    "/dev/tty1" "/dev/ttyS0"))
    (should (parley--terminal-device-p target)))
  (dolist (target '("pipe:[175832757]" "pipe:[1]" "socket:[175832757]"
                    "/dev/null" "anon_inode:[eventpoll]" "/home/matus/log"
                    "/dev/pts/" "/dev/pts/44 (deleted)" "" nil))
    (should-not (parley--terminal-device-p target))))

(ert-deftest parley-test-sessions-exclude-headless-lanes ()
  "Only the sessions with a terminal on standard input get a record."
  (parley-test--with-fixtures
    (should (equal (mapcar (lambda (s) (plist-get s :pid)) (parley-sessions))
                   '(4079793 1334764 652261)))))

(ert-deftest parley-test-sessions-carry-the-agents-fields ()
  "Every field of the record comes from the entry it was built from."
  (parley-test--with-fixtures
    (let ((session (car (parley-sessions))))
      (should (equal (plist-get session :name) "orc-0c"))
      (should (equal (plist-get session :kind) "interactive"))
      (should (equal (plist-get session :status) "idle"))
      (should (equal (plist-get session :cwd) "/home/matus/dev/go/orc"))
      (should (equal (plist-get session :session-id)
                     "9a5a5635-26c3-4705-b06e-4dc108d75439")))
    (should (equal (plist-get (nth 1 (parley-sessions)) :name) "app-8e"))
    (should (equal (plist-get (nth 1 (parley-sessions)) :status) "busy"))
    ;; A JSON null reaches the record as nil, and not as a symbol some
    ;; caller would have to know about.
    (should (equal (plist-get (nth 2 (parley-sessions)) :name) nil))
    (should (equal (plist-get (nth 2 (parley-sessions)) :status) nil))))


;;; The pane id

(ert-deftest parley-test-reads-tmux-pane-whole-and-only-when-it-is-there ()
  "TMUX_PANE is read whole, and only when it is really there."
  (should (equal (parley--environ-tmux-pane "TMUX_PANE=%61\0TERM=dumb\0")
                 "%61"))
  (should (equal (parley--environ-tmux-pane "TERM=dumb\0TMUX_PANE=%624")
                 "%624"))
  (should (equal (parley--environ-tmux-pane "A=1\0TMUX_PANE=%7\0B=2\0")
                 "%7"))
  ;; A variable that merely ends in the name is not the name, and
  ;; neither is one that merely starts with it.
  (should-not (parley--environ-tmux-pane "OLD_TMUX_PANE=%99\0TERM=dumb\0"))
  (should-not (parley--environ-tmux-pane
               "TMUX_PANE_BACKUP=%99\0TMUX_PLUGIN_MANAGER_PATH=/x\0"))
  ;; Outside tmux there is no TMUX_PANE, and an empty one is no pane
  ;; either -- `tmux send-keys -t ""' is not a target.
  (should-not (parley--environ-tmux-pane "TERM=dumb\0SHELL=/bin/bash\0"))
  (should-not (parley--environ-tmux-pane "TMUX_PANE=\0TERM=dumb\0"))
  ;; An unreadable /proc/PID/environ.
  (should-not (parley--environ-tmux-pane nil)))

(ert-deftest parley-test-sessions-carry-the-pane ()
  "The pane comes from the session's own environment, nil outside tmux."
  (parley-test--with-fixtures
    (should (equal (mapcar (lambda (s) (plist-get s :pane)) (parley-sessions))
                   '("%61" nil "%238")))))


;;; Where the pane is

(defconst parley-test--pane-locations
  '(("%61" . "orc-orc-b3743fe3:3.1")
    ("%238" . "home:0.0"))
  "Where the fixture sessions' panes are, as tmux reports them.
The two panes the fixture records carry, and nothing for the pane
`%627' of the headless lane -- which is no record at all.")

(defun parley-test--tmux (&rest arguments)
  "Run tmux with ARGUMENTS and return what it printed, trimmed."
  (with-temp-buffer
    (apply #'call-process "tmux" nil t nil arguments)
    (string-trim (buffer-string))))

(ert-deftest parley-test-tag-is-the-location-and-the-id ()
  "A tag is where the session's pane is and then its session id.
And the id alone in the two cases there is no location: a session
with no pane, which is a background agent or one started outside
tmux, and a session whose pane tmux does not report -- a window
closed under a session that outlived it.

The pane id survives in none of them.  It is what
`tmux send-keys -t' takes and the record keeps it; it is not what
a switcher row or a buffer name shows.  A `%' in a location is
not one: it came from the tmux session name, which tmux prints as
it is."
  (let ((parley--pane-locations parley-test--pane-locations))
    (should (equal (parley-session-tag
                    (list :pane "%61" :session-id "1111ffff-0001"))
                   "orc-orc-b3743fe3:3.1 1111ffff-0001"))
    (should (equal (parley-session-tag
                    (list :pane nil :session-id "2222ffff-0002"))
                   "2222ffff-0002"))
    (should (equal (parley-session-tag
                    (list :pane "%999" :session-id "3333ffff-0003"))
                   "3333ffff-0003"))
    (dolist (session (list (list :pane "%61" :session-id "1111ffff-0001")
                           (list :pane nil :session-id "2222ffff-0002")
                           (list :pane "%999" :session-id "3333ffff-0003")))
      (let ((pane (plist-get session :pane)))
        (should-not (and pane
                         (string-match-p (regexp-quote pane)
                                         (parley-session-tag session))))))))

(ert-deftest parley-test-asks-tmux-once-for-a-whole-list ()
  "The locations of a whole session list cost one tmux call, not one each.
`list-panes -a' prints every pane on the server, so the first tag
that needs a location resolves every session's; a
`display-message' per session would cost a subprocess per row.

And the next list asks again: a pane moved to another window is
somewhere else now, so the map is dropped by `parley-sessions'
and not kept for the rest of the Emacs session.

A tmux that reports no pane at all still costs one call and not
one per session, which is why `unasked' and nil are two states
and not one: a server that died under the list answers nothing
for every session in it, and asking it again per session is the
dozen subprocesses the one call exists to avoid."
  (parley-test--with-fixtures
    (let ((calls nil)
          (parley--pane-locations 'unasked))
      (cl-letf (((symbol-function 'call-process)
                 (lambda (program &rest arguments)
                   (push (cons program (nthcdr 3 arguments)) calls)
                   (insert "%61 orc-orc-b3743fe3:3.1\n%238 home:0.0\n")
                   0)))
        (let ((sessions (parley-sessions)))
          (should (equal (mapcar #'parley-session-tag sessions)
                         (list (concat "orc-orc-b3743fe3:3.1 "
                                       "9a5a5635-26c3-4705-b06e-4dc108d75439")
                               "eb6ab7cd-21e6-434f-9bf6-f561b5852de2"
                               (concat "home:0.0 "
                                       "7c1d0f9a-0000-4000-8000-000000000003"))))
          (should (equal (length calls) 1))
          (should (equal (car calls)
                         '("tmux" "list-panes" "-a" "-F"
                           "#{pane_id} #{session_name}:#{window_index}.#{pane_index}"))))
        (mapc #'parley-session-tag (parley-sessions))
        (should (equal (length calls) 2))))
    (let ((calls nil)
          (parley--pane-locations 'unasked))
      (cl-letf (((symbol-function 'call-process)
                 (lambda (program &rest arguments)
                   (push (cons program (nthcdr 3 arguments)) calls)
                   0)))
        (let ((sessions (parley-sessions)))
          (should (equal (mapcar #'parley-session-tag sessions)
                         '("9a5a5635-26c3-4705-b06e-4dc108d75439"
                           "eb6ab7cd-21e6-434f-9bf6-f561b5852de2"
                           "7c1d0f9a-0000-4000-8000-000000000003")))
          (should (equal (length calls) 1)))))))

(ert-deftest parley-test-a-known-location-never-asks-tmux ()
  "A known location is what tmux last answered, and asking it is not.
A pane the answer holds is where it says, and one it holds
nothing for is nowhere.  Before tmux has been asked every pane is
nowhere, the map stays unasked, and no subprocess runs -- which
is what lets a header line look a pane up on every redisplay.

The tmux standing in here would answer for `%61', so a lookup
that asked it would find the pane rather than nothing."
  (let ((parley--pane-locations parley-test--pane-locations))
    (should (equal (parley-known-pane-location "%61")
                   "orc-orc-b3743fe3:3.1"))
    (should-not (parley-known-pane-location "%999")))
  (let ((calls nil)
        (parley--pane-locations 'unasked))
    (cl-letf (((symbol-function 'call-process)
               (lambda (program &rest _)
                 (push program calls)
                 (insert "%61 orc-orc-b3743fe3:3.1\n")
                 0)))
      (should-not (parley-known-pane-location "%61"))
      (should (eq parley--pane-locations 'unasked))
      (should-not calls))))

(ert-deftest parley-test-a-location-is-the-session-the-window-and-the-pane ()
  "A location is the tmux session, window index and pane index of a pane.
Only tmux knows, so this asks a real one -- a server of its own
under a `TMUX_TMPDIR' of its own, so the operator's server is
neither read nor written.  Started with `-f /dev/null' because a
`base-index' or a `pane-base-index' in a configuration file moves
every index this asserts.

The session is named `parley %test', which tmux allows and
`list-panes' prints as it is.  The space says a location is
everything after the first space of a line and not the second
field of it.  The `%' says a location may legally carry one --
tmux 3.2a sanitises `:' and `.' in a session name and nothing
else, measured here -- so what the tag is free of is the pane id
and not the character it begins with.

A pane the server does not report resolves to no location and to
no error either, which is the third tag shape."
  (skip-unless (executable-find "tmux"))
  (let* ((directory (make-temp-file "parley-tmux-" t))
         (process-environment
          (cons (concat "TMUX_TMPDIR=" directory)
                (seq-remove (lambda (variable)
                              (string-prefix-p "TMUX=" variable))
                            process-environment)))
         (parley--pane-locations 'unasked))
    (unwind-protect
        (progn
          (parley-test--tmux "-f" "/dev/null" "new-session" "-d"
                             "-s" "parley %test")
          (let ((split (parley-test--tmux "split-window" "-d" "-P"
                                          "-F" "#{pane_id}"
                                          "-t" "parley %test:"))
                (window (parley-test--tmux "new-window" "-d" "-P"
                                           "-F" "#{pane_id}"
                                           "-t" "parley %test:")))
            (should (string-prefix-p "%" split))
            (should (string-prefix-p "%" window))
            (let ((locations (parley--tmux-pane-locations)))
              (should (equal (cdr (assoc split locations)) "parley %test:0.1"))
              (should (equal (cdr (assoc window locations)) "parley %test:1.0"))
              (should (equal (sort (mapcar #'cdr locations) #'string<)
                             '("parley %test:0.0" "parley %test:0.1"
                               "parley %test:1.0"))))
            (should (equal (parley-session-tag
                            (list :pane window :session-id "abc"))
                           "parley %test:1.0 abc"))
            (should-not (string-match-p (regexp-quote window)
                                        (parley-session-tag
                                         (list :pane window
                                               :session-id "abc"))))
            (should-not (parley--pane-location "%999"))
            (should (equal (parley-session-tag
                            (list :pane "%999" :session-id "abc"))
                           "abc"))))
      (parley-test--tmux "kill-server")
      (delete-directory directory t))))


;;; The transcript

(ert-deftest parley-test-slugs-the-working-directory-into-the-transcript-path ()
  "The slug is the working directory with every non-alphanumeric dashed."
  (let ((parley-projects-directory "/home/matus/.claude/projects"))
    (should (equal (parley--transcript-file "/home/matus/dev/go/orc" "abc")
                   "/home/matus/.claude/projects/-home-matus-dev-go-orc/abc.jsonl"))
    ;; A dot is not a separator and is replaced all the same, which is
    ;; the case a slug built by splitting on `/' gets wrong.
    (should (equal (parley--transcript-file
                    "/home/matus/dev/ydistri/Ydistri.Pairing" "abc")
                   (concat "/home/matus/.claude/projects/"
                           "-home-matus-dev-ydistri-Ydistri-Pairing/abc.jsonl")))
    ;; Case survives; `/.claude' doubles the dash.
    (should (equal (parley--transcript-file "/home/matus/.emacs.d" "abc")
                   "/home/matus/.claude/projects/-home-matus--emacs-d/abc.jsonl")))
  ;; The path is absolute even though the directory is written with a ~.
  (let ((parley-projects-directory "~/.claude/projects"))
    (should (file-name-absolute-p
             (parley--transcript-file "/tmp" "abc")))
    (should-not (string-prefix-p "~" (parley--transcript-file "/tmp" "abc")))))

(ert-deftest parley-test-sessions-carry-the-transcript ()
  "Each record names the transcript of that session, under its own slug."
  (parley-test--with-fixtures
    (should (equal (mapcar (lambda (s) (plist-get s :transcript))
                           (parley-sessions))
                   (list (concat "/home/matus/.claude/projects"
                                 "/-home-matus-dev-go-orc"
                                 "/9a5a5635-26c3-4705-b06e-4dc108d75439.jsonl")
                         (concat "/home/matus/.claude/projects"
                                 "/-home-matus-dev-ydistri-Ydistri-Pairing"
                                 "/eb6ab7cd-21e6-434f-9bf6-f561b5852de2.jsonl")
                         (concat "/home/matus/.claude/projects"
                                 "/-home-matus"
                                 "/7c1d0f9a-0000-4000-8000-000000000003.jsonl"))))))


;;; What a session is doing

;; The status reader is pointed at a directory of its own, and the pid
;; in it is this Emacs, for the reason `parley-fixtures' gives.  The one
;; test about a process that is gone picks a pid /proc has nothing
;; under.

(defconst parley-test--session-id "0b1b9b7c-1111-4000-8000-000000000001"
  "The session the status fixtures are about.")

(defun parley-test--dead-pid ()
  "Return a pid no process on this machine has."
  (let ((pid 999999))
    (while (file-exists-p (format "/proc/%d" pid))
      (setq pid (1+ pid)))
    pid))

(defun parley-test--status (&optional pid)
  "Return what the reader says the fixture session is doing.
PID defaults to this Emacs, which is the process the fixtures are
written about."
  (parley-session-status (list :pid (or pid (emacs-pid))
                               :session-id parley-test--session-id)))

(ert-deftest parley-test-reads-the-three-statuses-a-session-reports ()
  "Each status a live session writes about itself reads as its own value.
Waiting is its own value and not a kind of idle: an idle session
will read what is typed at it next and a waiting one is going
nowhere until the operator answers it."
  (dolist (pair '(("busy" . working) ("waiting" . waiting) ("idle" . idle)))
    (parley-fixtures-with-sessions-directory
      (parley-fixtures-write-session-file
       (emacs-pid) parley-test--session-id (car pair))
      (should (eq (parley-test--status) (cdr pair))))))

(ert-deftest parley-test-a-status-the-reader-does-not-know-is-unknown ()
  "A status nobody here has a value for is unknown and never working."
  (dolist (status '("compacting" "busy " "BUSY" ""))
    (parley-fixtures-with-sessions-directory
      (parley-fixtures-write-session-file
       (emacs-pid) parley-test--session-id status)
      (should (eq (parley-test--status) 'unknown)))))

(ert-deftest parley-test-another-sessions-file-is-unknown ()
  "A file about another session says nothing about this one.
A pane is reused, and the session started in it next is another
conversation with the same pid in front of it."
  (parley-fixtures-with-sessions-directory
    (parley-fixtures-write-session-file
     (emacs-pid) "0b1b9b7c-2222-4000-8000-000000000002" "busy")
    (should (eq (parley-test--status) 'unknown))))

(ert-deftest parley-test-a-missing-file-is-unknown ()
  "A session with no file at all is unknown and not an error."
  (parley-fixtures-with-sessions-directory
    (should (eq (parley-test--status) 'unknown))))

(ert-deftest parley-test-a-reused-pid-is-unknown ()
  "A file whose `procStart' is not the running process's is unknown.
A pid is handed on, and /proc having something under it says only
that some process has it -- without this a session would read as
working for as long as whatever inherited its pid lives."
  (parley-fixtures-with-sessions-directory
    (parley-fixtures-write-session-file
     (emacs-pid) parley-test--session-id "busy" :proc-start "1613841")
    (should (eq (parley-test--status) 'unknown))))

(ert-deftest parley-test-a-session-whose-process-is-gone-is-unknown ()
  "A session that died leaves a file still saying what it was doing.
Nothing in the file says otherwise, so what says so is the pid:
/proc has nothing under it.  A file carrying no start time at all
is the same answer and not a match against the nothing /proc has
to say about a process that is not there."
  (parley-fixtures-with-sessions-directory
    (let ((pid (parley-test--dead-pid)))
      (parley-fixtures-write-session-file
       pid parley-test--session-id "busy" :proc-start "1613841")
      (should (eq (parley-test--status pid) 'unknown))
      (parley-fixtures-write-session-file
       pid parley-test--session-id "busy" :proc-start :null)
      (should (eq (parley-test--status pid) 'unknown)))))


;;; Listing a session, and reading one

(ert-deftest parley-test-lists-waiting-first-then-idle-then-busy ()
  "Sessions are listed by what their status asks of the operator.
A waiting session is stopped until he answers it and leads; an
idle one merely reads him next and follows; a busy one needs
nothing from him and comes last.  A status neither the order nor
`parley--statuses' names sorts after every status they do, and so
does the nil `claude agents' reports for a session it knows no
status for.

The records are handed over in an order none of that would
produce, and two share a status: `sort' is stable, so those two
come out in the order discovery returned them in."
  (let ((sessions (list (list :pid 1 :status "busy")
                        (list :pid 2 :status "compacting")
                        (list :pid 3 :status "idle")
                        (list :pid 4 :status nil)
                        (list :pid 5 :status "waiting")
                        (list :pid 6 :status "busy"))))
    (cl-letf (((symbol-function 'parley-sessions) (lambda () sessions)))
      (should (equal (mapcar (lambda (session) (plist-get session :pid))
                             (parley-sessions-by-status))
                     '(5 3 1 6 2 4))))))

(ert-deftest parley-test-a-session-is-five-fields ()
  "A session is five fields: name, status, mark, directory, tag."
  (let ((parley--pane-locations parley-test--pane-locations))
    (should (equal (parley-session-fields
                    (list :name "orc-w1" :status "idle" :pane "%61"
                          :cwd "/srv/orc/trees/worker-1/orc"
                          :session-id "1111ffff-0001"))
                   (list :name "orc-w1" :status "idle" :mark ""
                         :directory "/srv/orc/trees/worker-1/orc"
                         :tag "orc-orc-b3743fe3:3.1 1111ffff-0001")))
    ;; The working directory is shown the way the operator writes it.
    (should (equal (plist-get (parley-session-fields
                               (list :cwd (expand-file-name
                                           "dev/ydistri/Ydistri.Pairing" "~")))
                              :directory)
                   "~/dev/ydistri/Ydistri.Pairing"))
    ;; A name and a status `claude agents' did not report still leave
    ;; five fields, and the tag column falls back to the session id.
    (should (equal (parley-session-fields
                    (list :name nil :status nil :pane nil :cwd "/srv/matus"
                          :session-id "7c1d0f9a-0003"))
                   (list :name "unnamed" :status "unknown" :mark "[RO]"
                         :directory "/srv/matus"
                         :tag "7c1d0f9a-0003")))))

(ert-deftest parley-test-a-placeholder-stands-in-only-for-what-is-missing ()
  "The name placeholder and the read only mark each stand in for one field.
`parley-session-name' gives the placeholder for a record with no
name and the name for one with it, and `parley-session-mark' gives
the mark for a record with no pane and nothing for one with a
pane.  Every display of a session takes both from these two, so
this is what the switcher row and the header line both show."
  (should (equal (parley-session-name (list :name nil :pane "%61"))
                 parley-session-no-name))
  (should (equal (parley-session-name (list :pane nil))
                 parley-session-no-name))
  (should (equal (parley-session-name (list :name "orc-w1" :pane nil))
                 "orc-w1"))
  (should (equal (parley-session-mark (list :name "orc-w1" :pane nil))
                 parley-session-read-only-mark))
  (should (equal (parley-session-mark (list :name "orc-w1"))
                 parley-session-read-only-mark))
  (dolist (pane '("%61" "%999"))
    (should (null (parley-session-mark (list :name nil :pane pane))))))

(ert-deftest parley-test-marks-a-session-with-no-pane-read-only ()
  "A session with no pane is listed as one that cannot be typed into.
The mark is in the row before anything has been submitted, which
is the only point at which the operator can still pick another
session.

It is read from the pane and not from the kind: both sessions
here without a pane are reported interactive, and a session
started outside tmux is as unreachable as a background agent
dispatched from the agent view.

It is read from the pane and not from its location either: one
session here has a pane tmux reports nothing for, so its tag is
its session id alone, and `send-keys -t' still takes that pane."
  (let ((parley--pane-locations parley-test--pane-locations))
    (dolist (session (list (list :name "app-8e" :kind "interactive"
                                 :status "busy" :pane nil :cwd "/srv/app"
                                 :session-id "eb6ab7cd-0001")
                           (list :name nil :kind "interactive" :status nil
                                 :pane nil :cwd "/srv/matus"
                                 :session-id "7c1d0f9a-0003")))
      (let ((fields (parley-session-fields session)))
        (should (equal (plist-get session :kind) "interactive"))
        (should (equal (plist-get fields :mark) "[RO]"))
        (should (string-match-p "\\[RO\\]" (parley-session-row fields)))))
    ;; And a session with a pane carries no mark, so the row says
    ;; something about this session rather than about every session.
    (dolist (pane '("%61" "%238" "%999"))
      (let ((fields (parley-session-fields
                     (list :name "orc-w1" :kind "interactive" :status "idle"
                           :pane pane :cwd "/srv/orc"
                           :session-id "1111ffff-0001"))))
        (should (equal (plist-get fields :mark) ""))
        (should-not (string-match-p "\\[RO\\]"
                                    (parley-session-row fields)))))))

(ert-deftest parley-test-row-begins-with-the-name ()
  "Every row begins with the session name and carries every field."
  (let ((parley--pane-locations parley-test--pane-locations))
    (dolist (session (list (list :name "orc-w1" :status "idle" :pane "%61"
                                 :cwd "/srv/orc/trees/worker-1/orc"
                                 :session-id "1111ffff-0001")
                           (list :name "app-8e" :status "busy" :pane "%999"
                                 :cwd (expand-file-name "dev/app" "~")
                                 :session-id "eb6ab7cd-0002")
                           (list :name nil :status nil :pane nil
                                 :cwd "/srv/matus"
                                 :session-id "7c1d0f9a-0003")))
      (let* ((fields (parley-session-fields session))
             (row (parley-session-row fields)))
        (should (string-prefix-p (plist-get fields :name) row))
        (cl-loop for (_key field) on fields by #'cddr
                 do (should (string-match-p (regexp-quote field) row)))))))

(ert-deftest parley-test-rows-are-unique ()
  "No two sessions produce the same row, name sharing or not."
  (let* ((parley--pane-locations parley-test--pane-locations)
         (sessions (list (list :name "orc-w1" :status "idle" :pane "%61"
                               :cwd "/srv/orc/trees/worker-1/orc"
                               :session-id "1111ffff-0001")
                         (list :name "orc-w1" :status "idle" :pane "%999"
                               :cwd "/srv/orc/trees/worker-1/orc"
                               :session-id "3333ffff-0003")
                         (list :name "orc-w1" :status "idle" :pane "%238"
                               :cwd "/srv/orc/trees/worker-2/orc"
                               :session-id "2222ffff-0002")
                         (list :name "app-8e" :status "busy" :pane nil
                               :cwd "/srv/app" :session-id "eb6ab7cd-0004")))
         (rows (mapcar (lambda (session)
                         (parley-session-row (parley-session-fields session)))
                       sessions)))
    (should (equal (length (delete-dups (copy-sequence rows)))
                   (length sessions)))))

;; The offsets below are the columns themselves: the name is 50 wide
;; and the status 12, the working directory 40, and two spaces stand
;; between one column and the next.  So a row begins its name at 0,
;; its status at 52, its working directory at 66 and its tag at 108,
;; and a test that reads a face at one of those is reading the column
;; the width puts there.

(defun parley-test--display-column (row string)
  "Return the display column ROW draws STRING at.
Measured the way the row is drawn and not by counting
characters: a glyph two columns wide is one character, so an
index into the string says nothing about where the operator sees
it."
  (string-width (substring row 0 (string-match-p (regexp-quote string) row))))

(ert-deftest parley-test-every-column-is-faced-apart ()
  "Each of the four columns of a row carries a face of its own.
The faces are on the row `parley-session-row' returns and not put
there by whatever draws it, so the `completing-read' fallback
shows what the sallet source shows.

A face runs the width of its column and not the length of the
value in it -- the padding after a short name is the name
column -- so a face a theme gives a background to colours a
column and not a ragged stripe down the list.  The two spaces
between one column and the next are no column's and carry
nothing.

The whole of each run is asserted and not its first character: a
face on the value alone passes an assertion made at the offset
the value starts at, which is the one place the two cannot
differ."
  (let ((parley--pane-locations parley-test--pane-locations))
    (let ((row (parley-session-row
                (parley-session-fields
                 (list :name "app-8e" :status "busy" :pane "%61"
                       :cwd "/srv/app" :session-id "eb6ab7cd-0001")))))
      (should (equal (get-text-property 0 'face row) 'parley-row-name))
      (should (equal (get-text-property 52 'face row)
                     'parley-row-status-working))
      (should (equal (get-text-property 66 'face row) 'parley-row-directory))
      (should (equal (get-text-property 108 'face row) 'parley-row-tag))
      ;; Where each run ends: the name at 50, the status at 64 and
      ;; the working directory at 106, which is each column's own
      ;; width and none of the gap after it.  The tag is last and
      ;; runs to the end of the row.
      (should (equal (next-single-property-change 0 'face row) 50))
      (should (equal (next-single-property-change 50 'face row) 52))
      (should (equal (next-single-property-change 52 'face row) 64))
      (should (equal (next-single-property-change 64 'face row) 66))
      (should (equal (next-single-property-change 66 'face row) 106))
      (should (equal (next-single-property-change 106 'face row) 108))
      (should-not (next-single-property-change 108 'face row))
      (dolist (gap '(50 51 64 65 106 107))
        (should-not (get-text-property gap 'face row))))))

(ert-deftest parley-test-an-open-row-faces-its-name-column-and-nothing-else ()
  "A row drawn open has its whole name column in a face of its own.
The padding after a short name is the name column too, so the
face runs the whole fifty and not the length of the name.

The rest of the row is the rest of the row built from the same
fields and not drawn open, face for face: the status colours
carry the status, and the read only mark inside that column keeps
its own.  Every status value is drawn, with the mark and without,
so a face that leaked past the name into one of them is found."
  (dolist (status '("idle" "working" "waiting" "unknown"))
    (dolist (mark '("" "[RO]"))
      (let* ((fields (list :name "orc-b3" :status status :mark mark
                           :directory "/srv/orc" :tag "orc:1.0 1111ffff"))
             (plain (parley-session-row fields))
             (open (parley-session-row fields t)))
        (should (equal (get-text-property 0 'face open) 'parley-row-name-open))
        (should (equal (next-single-property-change 0 'face open) 50))
        (should (equal (get-text-property 0 'face plain) 'parley-row-name))
        (should (equal (next-single-property-change 0 'face plain) 50))
        (should (equal-including-properties (substring open 50)
                                            (substring plain 50)))))))

(ert-deftest parley-test-finds-no-buffer-without-the-view-loaded ()
  "Asking for a session's buffer with only `parley' loaded answers nil.
The variable a buffer records its session in is the view's, and
`parley' cannot require the view, so the lookup reads it by name
in an Emacs that may never have defined it.  The suite loads
every test file into one Emacs, and the view with them, so the
question is put to a child Emacs that loads `parley' alone."
  (with-temp-buffer
    (should (eq 0 (call-process
                   (expand-file-name invocation-name invocation-directory)
                   nil '(t nil) nil "-Q" "--batch"
                   "-L" (file-name-directory (locate-library "parley"))
                   "-l" "parley" "--eval"
                   "(prin1 (list (featurep 'parley-transcript)
                                 (parley-session-buffer
                                  (list :session-id \"7c1d0f9a-0003\"))))")))
    (should (equal (buffer-string) "(nil nil)"))))

(ert-deftest parley-test-a-status-is-shown-and-faced-by-its-value ()
  "The status column holds the value a status is read as, in its face.
A session that wrote `busy' is listed `working', the word the
transcript's header line shows for it, and a status parley does
not name -- or none at all -- is listed `unknown'.  The word and
the colour both follow from that value, so a row cannot keep its
colour and lose its word or the other way round.

`idle', `working' and `waiting' are the three the operator scans
a list for and no two of them look alike; `unknown' is a fourth
colour rather than one of theirs."
  (let ((parley--pane-locations parley-test--pane-locations))
    (let ((columns
           (mapcar (lambda (status)
                     (let ((row (parley-session-row
                                 (parley-session-fields
                                  (list :name "orc-w1" :status status
                                        :pane "%61" :cwd "/srv/orc"
                                        :session-id "1111ffff-0001")))))
                       (list (car (split-string (substring row 52 64)))
                             (get-text-property 52 'face row))))
                   '("idle" "busy" "waiting" "compacting" nil))))
      (should (equal columns '(("idle" parley-row-status-idle)
                               ("working" parley-row-status-working)
                               ("waiting" parley-row-status-waiting)
                               ("unknown" parley-row-status-other)
                               ("unknown" parley-row-status-other))))
      (should (equal (length (delete-dups (mapcar #'cadr columns))) 4)))))

(ert-deftest parley-test-the-name-column-is-fifty-wide ()
  "A short name puts the status where a fifty-character name does.
Fifty is what the name is padded to, so the columns after it line
up down the list whatever the sessions are called.

Fifty columns as they are drawn, and not fifty characters: the
name of a session working in a Japanese or Chinese tree is drawn
two columns to the glyph, and a column counted in characters
would put that row's status two columns past every other row's.

A name longer than fifty is drawn whole and pushes the rest of
its own row along: a background agent is named after its prompt,
and cutting the name cuts the one handle the operator has on the
session."
  (let ((short (parley-session-row
                (list :name "orc-w1" :status "idle" :mark ""
                      :directory "/srv/orc" :tag "tag")))
        (fifty (parley-session-row
                (list :name (make-string 50 ?n) :status "idle" :mark ""
                      :directory "/srv/orc" :tag "tag")))
        (wide (parley-session-row
               (list :name "追跡" :status "idle" :mark ""
                     :directory "/srv/orc" :tag "tag")))
        (long (parley-session-row
               (list :name (make-string 62 ?n) :status "idle" :mark ""
                     :directory "/srv/orc" :tag "tag"))))
    (dolist (row (list short fifty wide))
      (should (= (parley-test--display-column row "idle") 52))
      (should (equal (get-text-property (string-match-p "idle" row) 'face row)
                     'parley-row-status-idle)))
    ;; Four display columns of name and four characters of it, so
    ;; the row a character count lines up is the row it lines up
    ;; wrong: its status would start two columns late.
    (should (= (string-width "追跡") 4))
    (should (string-prefix-p (make-string 62 ?n) long))
    (should (= (parley-test--display-column long "idle") 64))))

(ert-deftest parley-test-a-status-never-runs-past-its-column ()
  "A status of any length leaves the columns after it in line.
A status of any length at all is what `claude agents' may report
tomorrow, and the one thing it may not do is carry every column
after it out of line on that row.  It is listed as the value it
is read as, `unknown', which fits the status column with the
read only mark beside it, so no column is cut -- a name and a
working directory are what the operator picks a session by, and
both are drawn whole."
  (let ((row (parley-session-row
              (parley-session-fields
               (list :name "orc-w1" :status "awaiting-approval" :pane nil
                     :cwd "/srv/go/orc" :session-id "9a5a5635-0005")))))
    (should (equal (substring row 52 64) "unknown [RO]"))
    (should (= (parley-test--display-column row "/srv/go/orc") 66))
    ;; And a working directory past its own column is not cut: the
    ;; tail of a path is what tells two worktrees apart.
    (let ((deep (parley-session-row
                 (list :name "orc-w1" :status "idle" :mark ""
                       :directory
                       "/srv/orc/trees/worker-1/a/very/deep/tree/indeed/here"
                       :tag "tag"))))
      (should (string-match-p
               "/srv/orc/trees/worker-1/a/very/deep/tree/indeed/here" deep)))))

(ert-deftest parley-test-the-read-only-mark-shares-the-status-column ()
  "The mark is drawn after the status, in the status column.
No column is kept for it: one would be blank on every session
that has a pane.  `waiting [RO]' is the longest the two come to
together and is what twelve characters leave room for, so the
working directory begins at the same offset marked or not."
  (let ((marked (parley-session-row
                 (list :name "orc-w1" :status "waiting" :mark "[RO]"
                       :directory "/srv/orc" :tag "tag")))
        (plain (parley-session-row
                (list :name "orc-w1" :status "waiting" :mark ""
                      :directory "/srv/orc" :tag "tag"))))
    (should (equal (substring marked 52 64) "waiting [RO]"))
    (should (equal (get-text-property 60 'face marked) 'parley-row-read-only))
    ;; The space between the two is the status column's own, so
    ;; nothing inside the column is left in the default face.
    (should (equal (next-single-property-change 52 'face marked) 60))
    (should (equal (next-single-property-change 60 'face marked) 64))
    (should (equal (substring marked 66 74) "/srv/orc"))
    (should (equal (substring plain 66 74) "/srv/orc"))
    (should-not (string-match-p "\\[RO\\]" plain))))

(ert-deftest parley-test-the-placeholders-are-faced-like-a-value ()
  "A session reported with no name and no status is coloured too.
Its `unnamed' and `unknown' stand in the same columns as any
other session's name and status and carry the same faces: a row
drawn in the default face is the row the operator cannot pick out
of a dozen, and the session nothing is known about is not the one
to hide."
  (let ((row (parley-session-row
              (parley-session-fields
               (list :name nil :status nil :pane nil :cwd "/srv/matus"
                     :session-id "7c1d0f9a-0003")))))
    (should (string-prefix-p "unnamed" row))
    (should (equal (get-text-property 0 'face row) 'parley-row-name))
    (should (equal (substring row 52 64) "unknown [RO]"))
    (should (equal (get-text-property 52 'face row)
                   'parley-row-status-other))
    (should (equal (get-text-property 60 'face row)
                   'parley-row-read-only))))

(ert-deftest parley-test-resolves-the-row-picked-to-its-own-record ()
  "Two sessions alike in every column but their id are still two rows.
A row is resolved back to its record by the string itself, so two
records that produced one row would both resolve to the first of
them and the operator would land in the other one's conversation.
`claude agents' really can report two live sessions with one
name, one status and one working directory, and a session
suspended in a pane with another started there gives them one
pane, and so one location, as well: all that is left to tell them
apart is the session id, and the whole of it -- these two agree
on its first eight characters, which is all a head of it would
carry."
  (let* ((one (list :pid 11 :name "orc-w1" :status "idle"
                    :cwd "/srv/orc/trees/worker-1/orc" :pane "%61"
                    :session-id "11111111-0000-4000-8000-000000000001"))
         (two (list :pid 12 :name "orc-w1" :status "idle"
                    :cwd "/srv/orc/trees/worker-1/orc" :pane "%61"
                    :session-id "11111111-ffff-4000-8000-000000000002"))
         (parley--pane-locations parley-test--pane-locations)
         (row (parley-session-row (parley-session-fields two))))
    (should-not (equal row (parley-session-row (parley-session-fields one))))
    (cl-letf (((symbol-function 'parley-sessions) (lambda () (list one two)))
              ((symbol-function 'completing-read) (lambda (&rest _) row)))
      (should (eq (parley-read-session) two)))))

(ert-deftest parley-test-reading-with-nothing-running-says-so ()
  "Reading a session when none is running says so instead of asking.
The minibuffer is never reached: an empty prompt the operator can
only abort tells him nothing about why it is empty."
  (let ((asked nil))
    (cl-letf (((symbol-function 'parley-sessions) (lambda () nil))
              ((symbol-function 'completing-read)
               (lambda (&rest _) (setq asked t) "")))
      (should-error (parley-read-session) :type 'user-error)
      (should-not asked))))

(provide 'parley-test)
;;; parley-test.el ends here
