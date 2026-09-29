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
It goes into `parley-sessions-directory' and says the process is
running SESSION-ID and doing STATUS.  Its `procStart' is
PROC-START, by default what a live session's file really holds:
the start time /proc reports for PID."
  (with-temp-file (expand-file-name (format "%s.json" pid)
                                    parley-sessions-directory)
    (insert (json-serialize
             `((pid . ,pid)
               (sessionId . ,session-id)
               (procStart . ,proc-start)
               (status . ,status)
               (updatedAt . 1790018687378))))))

(defmacro parley-fixtures-with-sessions-directory (&rest body)
  "Run BODY with `parley-sessions-directory' an empty directory of its own."
  (declare (indent 0) (debug t))
  `(let ((parley-sessions-directory
          (make-temp-file "parley-fixtures-sessions-" t)))
     (unwind-protect (progn ,@body)
       (delete-directory parley-sessions-directory t))))

(provide 'parley-fixtures)

;;; parley-fixtures.el ends here
