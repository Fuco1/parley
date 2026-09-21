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


;;; Reading a session

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
