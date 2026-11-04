;;; parley-fixtures.el --- Fixtures more than one test file needs -*- lexical-binding: t -*-

;;; Commentary:

;; What a test file here shares with another.  It defines no test: a
;; test goes in the file mirroring its source.  Only the repository's
;; root is on the load path of the checks, so a test file requires this
;; one by the test file's own directory.

;;; Code:

(require 'cl-lib)
(require 'parley)


;;; The file a session writes about itself

;; The status reader compares that file's `procStart' against what
;; /proc reports for its pid, so the pid a fixture writes about has to
;; be a process really running, and no invented pid will do.  This
;; Emacs is one.

(defun parley-fixtures-proc-start (pid)
  "Return field 22 of `/proc/PID/stat', split on whitespace.
The reader finds that field another way -- from the closing paren
of the process name, the name being the one field that can hold a
space -- and a fixture it built itself would agree with it
whatever either of them did.  This Emacs is called `emacs', so
splitting the line works here and says so independently."
  (with-temp-buffer
    (insert-file-contents (format "/proc/%s/stat" pid))
    (nth 21 (split-string (buffer-string)))))

(cl-defun parley-fixtures-write-session-file
    (pid session-id status &key (proc-start (parley-fixtures-proc-start pid)))
  "Write the file session PID writes about itself.
It goes into `parley-claude-sessions-directory' and says the
process is running SESSION-ID and doing STATUS.  Its `procStart'
is PROC-START, by default what a live session's file really
holds: the start time /proc reports for PID."
  (with-temp-file (expand-file-name (format "%s.json" pid)
                                    parley-claude-sessions-directory)
    (insert (json-serialize
             `((pid . ,pid)
               (sessionId . ,session-id)
               (procStart . ,proc-start)
               (status . ,status)
               (updatedAt . 1790018687378))))))

(defmacro parley-fixtures-with-sessions-directory (&rest body)
  "Run BODY with `parley-claude-sessions-directory' an empty directory.
The directory is one of its own, deleted when BODY returns."
  (declare (indent 0) (debug t))
  `(let ((parley-claude-sessions-directory
          (make-temp-file "parley-fixtures-sessions-" t)))
     (unwind-protect (progn ,@body)
       (delete-directory parley-claude-sessions-directory t))))

;;; Where tmux says a pane is

;; Where every pane is is asked of tmux once and kept until the
;; sessions are next listed, in a place only `parley.el' itself may
;; touch.  So a fixture cannot hand it an answer; it stands in for the
;; machine instead, at the three places `parley.el' asks it: tmux
;; answers `list-panes', `claude agents --json' lists no session, and
;; a listing of /proc finds no process named `codex'.  Listing the
;; sessions on that machine is what drops the answer tmux last gave,
;; and the first location looked up after it is what asks again.

(defconst parley-fixtures-pane-locations
  '(("%23" . "app%8e:1.0")
    ("%61" . "orc-b3743fe3:2.0")
    ("%62" . "orc-b3743fe3:3.1")
    ("%64" . "orc-b3743fe3:4.0")
    ("%65" . "parley:0.1"))
  "Where the tmux of `parley-fixtures-with-pane-locations' says each pane is.
An alist of (PANE-ID . LOCATION).  A pane it does not name is one
tmux reports nothing for: a window closed under a session that
outlived it, and that session is still one to read.")

(defvar parley-fixtures-asked nil
  "What the machine of `parley-fixtures-with-pane-locations' was asked.
The latest first: the program `call-process' was asked to run --
\"tmux\" or `parley-claude-program' -- or \"/proc\" for a listing
of the processes.")

(defun parley-fixtures--call-process (real)
  "Return a `call-process' that answers for tmux and claude, and is REAL else.
`tmux list-panes' prints `parley-fixtures-pane-locations', with no
pane titled, and `parley-claude-program' run as `agents --json'
prints no session, each into the current buffer.  Any other run of
either signals, because nothing else is asked of them here.  A
run of either goes onto `parley-fixtures-asked'.

Another program is run for real: Emacs itself runs one when a
primitive is redefined, to compile what native code calls it by."
  (lambda (program &optional infile destination display &rest arguments)
    (cond ((equal program "tmux")
           (push program parley-fixtures-asked)
           (unless (equal (car arguments) "list-panes")
             (error "No `tmux %s' on the machine standing in" (car arguments)))
           (dolist (pane parley-fixtures-pane-locations 0)
             (insert (car pane) " " (cdr pane) "\t\n")))
          ((equal program parley-claude-program)
           (push program parley-fixtures-asked)
           (unless (equal arguments '("agents" "--json"))
             (error "No `%s' run with %S on the machine standing in"
                    program arguments))
           (insert "[]")
           0)
          (t (apply real program infile destination display arguments)))))

(defun parley-fixtures--directory-files (real)
  "Return a `directory-files' that finds no process and is REAL elsewhere.
A listing of /proc goes onto `parley-fixtures-asked' and is empty."
  (lambda (directory &rest arguments)
    (if (not (equal (directory-file-name directory) "/proc"))
        (apply real directory arguments)
      (push "/proc" parley-fixtures-asked)
      nil)))

(defmacro parley-fixtures-with-pane-locations (&rest body)
  "Run BODY on a machine whose tmux has panes and where no session runs.
tmux says each pane is where `parley-fixtures-pane-locations' says,
`claude agents --json' lists no session and no process is named
`codex'.  What BODY asks of them goes onto `parley-fixtures-asked'.

The sessions are listed before BODY and after it, because listing
them drops what tmux last answered: BODY starts with tmux not yet
asked, and what runs after BODY is not answered with these panes."
  (declare (indent 0) (debug t))
  `(let ((parley-fixtures-asked nil))
     (cl-letf (((symbol-function 'call-process)
                (parley-fixtures--call-process
                 (symbol-function 'call-process)))
               ((symbol-function 'directory-files)
                (parley-fixtures--directory-files
                 (symbol-function 'directory-files))))
       (parley-sessions)
       (setq parley-fixtures-asked nil)
       (unwind-protect (progn ,@body)
         (parley-sessions)))))

;;; Running tmux

(defun parley-fixtures-tmux (&rest arguments)
  "Run tmux with ARGUMENTS and return what it printed, trimmed."
  (with-temp-buffer
    (apply #'call-process "tmux" nil t nil arguments)
    (string-trim (buffer-string))))

(provide 'parley-fixtures)

;;; parley-fixtures.el ends here
