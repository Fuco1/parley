;;; parley-test.el --- Tests for parley -*- lexical-binding: t -*-

;;; Commentary:

;; Discovery reads three things about a session: the entry `claude
;; agents --json' printed for it, what its standard input resolves to
;; and its environment block.  All three are text, so all three come
;; from fixtures here and no test needs a live session.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'parley)


;;; Fixtures

;; Four entries as `claude agents --json' really prints them: a session
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

;; Standard input per pid, as `readlink /proc/PID/fd/0' gave it: two
;; terminals and the pipe of a lane running `claude -p'.
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

(ert-deftest parley-test-terminal-device-p ()
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

(ert-deftest parley-test-environ-tmux-pane ()
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


;;; The transcript

(ert-deftest parley-test-transcript-file ()
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

(provide 'parley-test)
;;; parley-test.el ends here
