;;; parley-switch-test.el --- Tests for parley-switch -*- lexical-binding: t -*-

;;; Commentary:

;; Switching reads nothing about the machine except the session list,
;; so every test here stubs `parley-sessions' with records and none of
;; them needs a live session.
;;
;; sallet is not on the load path of the check that runs these, which
;; is exactly the environment the `completing-read' fallback exists
;; for, and the test of that fallback removes the sallet source even
;; when it is there.  The one test that needs sallet itself to run
;; says so with `skip-unless'; put sallet on the load path to see it.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'parley-switch)


;;; Fixtures

;; Six records as `parley-sessions' returns them, in an order no
;; frontend should show them in.  Four share the name `orc-w1': that
;; is what sibling worktrees really look like.  Two of those four
;; share a working directory and a status as well and differ in
;; nothing but their pane, which is two sessions started in one repo
;; and the case a row without the pane cannot tell apart.  A third has
;; no pane at all, so its tag has to fall back to its session id.  One
;; record has neither name nor status, which is what `claude agents'
;; reports for a session it knows none for.
(defconst parley-switch-test--sessions
  (list (list :pid 1 :name "app-8e" :kind "interactive" :status "busy"
              :cwd (expand-file-name "dev/ydistri/Ydistri.Pairing" "~")
              :session-id "eb6ab7cd-21e6-434f-9bf6-f561b5852de2"
              :pane "%23" :transcript "/tmp/eb6ab7cd.jsonl")
        (list :pid 2 :name "orc-w1" :kind "interactive" :status "idle"
              :cwd "/srv/orc/trees/worker-1/orc"
              :session-id "1111ffff-0000-4000-8000-000000000001"
              :pane "%61" :transcript "/tmp/1111ffff.jsonl")
        (list :pid 3 :name nil :kind "interactive" :status nil
              :cwd "/srv/matus"
              :session-id "7c1d0f9a-0000-4000-8000-000000000003"
              :pane nil :transcript "/tmp/7c1d0f9a.jsonl")
        (list :pid 4 :name "orc-w1" :kind "interactive" :status "idle"
              :cwd "/srv/orc/trees/worker-2/orc"
              :session-id "2222ffff-0000-4000-8000-000000000002"
              :pane "%62" :transcript "/tmp/2222ffff.jsonl")
        (list :pid 5 :name "orc-w1" :kind "interactive" :status "busy"
              :cwd "/srv/go/orc"
              :session-id "9a5a5635-26c3-4705-b06e-4dc108d75439"
              :pane nil :transcript "/tmp/9a5a5635.jsonl")
        (list :pid 6 :name "orc-w1" :kind "interactive" :status "idle"
              :cwd "/srv/orc/trees/worker-1/orc"
              :session-id "3333ffff-0000-4000-8000-000000000003"
              :pane "%63" :transcript "/tmp/3333ffff.jsonl")))

(defun parley-switch-test--session (pid)
  "Return the fixture record whose pid is PID."
  (seq-find (lambda (session) (eq (plist-get session :pid) pid))
            parley-switch-test--sessions))

(defmacro parley-switch-test--with-sessions (&rest body)
  "Run BODY with `parley-sessions' returning the fixture records.
The list is copied on every call because the switcher sorts it,
and every transcript buffer BODY opened is killed afterwards."
  (declare (indent 0))
  `(cl-letf (((symbol-function 'parley-sessions)
              (lambda () (copy-sequence parley-switch-test--sessions))))
     (unwind-protect (progn ,@body)
       (dolist (buffer (buffer-list))
         (when (string-prefix-p "*parley " (buffer-name buffer))
           (kill-buffer buffer))))))

(defun parley-switch-test--tags (sessions)
  "Return the tag of each of SESSIONS, which no two of them share."
  (mapcar #'parley-switch--tag sessions))


;;; The columns

(ert-deftest parley-switch-test-fields ()
  "A session is four separate fields: name, status, directory, pane."
  (should (equal (parley-switch--fields (parley-switch-test--session 2))
                 ["orc-w1" "idle" "/srv/orc/trees/worker-1/orc" "%61"]))
  ;; The working directory is shown the way the operator writes it.
  (should (equal (aref (parley-switch--fields
                        (parley-switch-test--session 1))
                       2)
                 "~/dev/ydistri/Ydistri.Pairing"))
  ;; A name and a status `claude agents' did not report still leave
  ;; four fields, and the pane column falls back to the session id.
  (should (equal (parley-switch--fields (parley-switch-test--session 3))
                 ["unnamed" "unknown" "/srv/matus" "7c1d0f9a"])))

(ert-deftest parley-switch-test-tag-tells-one-name-apart ()
  "The four sessions named `orc-w1' have four different tags.
Two of them share a working directory as well, so the pane is all
that is left to tell those apart."
  (let ((tags (parley-switch-test--tags
               (list (parley-switch-test--session 2)
                     (parley-switch-test--session 4)
                     (parley-switch-test--session 5)
                     (parley-switch-test--session 6)))))
    (should (equal tags '("%61" "%62" "9a5a5635" "%63")))
    (should (equal (length (delete-dups (copy-sequence tags))) 4))))

(ert-deftest parley-switch-test-row-begins-with-the-name ()
  "Every row begins with the session name and carries every field."
  (dolist (session parley-switch-test--sessions)
    (let* ((fields (parley-switch--fields session))
           (row (parley-switch--row fields)))
      (should (string-prefix-p (aref fields 0) row))
      (dolist (field (append fields nil))
        (should (string-match-p (regexp-quote field) row))))))

(ert-deftest parley-switch-test-rows-are-unique ()
  "No two sessions produce the same row, name sharing or not."
  (let ((rows (mapcar (lambda (session)
                        (parley-switch--row (parley-switch--fields session)))
                      parley-switch-test--sessions)))
    (should (equal (length (delete-dups (copy-sequence rows)))
                   (length parley-switch-test--sessions)))))


;;; The order

(ert-deftest parley-switch-test-sessions-are-ordered-by-status ()
  "Idle sessions come first, then busy, then the ones with no status.
Sessions sharing a status keep the order discovery returned them
in, which is not the order they come out in here."
  (parley-switch-test--with-sessions
    (should (equal (mapcar (lambda (session) (plist-get session :pid))
                           (parley-switch--sessions))
                   '(2 4 6 1 5 3)))))


;;; The buffer

(ert-deftest parley-switch-test-buffer-names-are-unique ()
  "Each session gets its own buffer name, carrying its name and tag."
  (parley-switch-test--with-sessions
    (let ((names (mapcar #'parley-switch--buffer-name
                         (parley-switch--sessions))))
      (should (equal names '("*parley orc-w1 %61*"
                             "*parley orc-w1 %62*"
                             "*parley orc-w1 %63*"
                             "*parley app-8e %23*"
                             "*parley orc-w1 9a5a5635*"
                             "*parley unnamed 7c1d0f9a*")))
      (should (equal (length (delete-dups (copy-sequence names))) 6)))))

(ert-deftest parley-switch-test-buffer-is-created-then-reused ()
  "The buffer is created the first time and the same one comes back after."
  (parley-switch-test--with-sessions
    (let ((session (parley-switch-test--session 4)))
      (should-not (get-buffer "*parley orc-w1 %62*"))
      (let ((buffer (parley-switch--buffer session)))
        (should (equal (buffer-name buffer) "*parley orc-w1 %62*"))
        (with-current-buffer buffer
          (should (eq parley-session session))
          (should (equal default-directory "/srv/orc/trees/worker-2/orc/")))
        (should (eq (parley-switch--buffer session) buffer))
        (should (equal (length (seq-filter
                                (lambda (b) (string-prefix-p
                                             "*parley " (buffer-name b)))
                                (buffer-list)))
                       1))))))


;;; Without sallet

(ert-deftest parley-switch-test-falls-back-to-completing-read ()
  "With no sallet source the command reads the session in the minibuffer.
The one picked is the second of the three sessions named
`orc-w1', so a switcher that told them apart by name alone would
land in the wrong buffer here."
  (parley-switch-test--with-sessions
    (let ((session (parley-switch-test--session 4))
          (asked nil)
          (collection nil))
      (cl-letf (((symbol-function 'sallet-source-parley) nil)
                ((symbol-function 'completing-read)
                 (lambda (_prompt table &rest _)
                   (setq asked t collection table)
                   (parley-switch--row (parley-switch--fields session)))))
        ;; The assertions are inside, because leaving a
        ;; `save-window-excursion' puts the old buffer back.
        (save-window-excursion
          (parley-switch)
          (should asked)
          (should (equal (buffer-name) "*parley orc-w1 %62*"))
          (should (eq parley-session session)))
        ;; The rows are offered in the switcher order, and the
        ;; completion metadata is what stops the minibuffer from
        ;; sorting them alphabetically and losing it.
        (should (equal (mapcar (lambda (row) (car (split-string row)))
                               (all-completions "" collection))
                       '("orc-w1" "orc-w1" "orc-w1" "app-8e" "orc-w1"
                         "unnamed")))
        (should (eq (alist-get 'display-sort-function
                               (cdr (completion-metadata "" collection nil)))
                    #'identity))))))

(ert-deftest parley-switch-test-fallback-with-nothing-running ()
  "Reading a session when none is running says so instead of picking one."
  (cl-letf (((symbol-function 'parley-sessions) (lambda () nil))
            ((symbol-function 'sallet-source-parley) nil))
    (should-error (parley-switch) :type 'user-error)))


;;; With sallet

(ert-deftest parley-switch-test-candidate-carries-the-record ()
  "A candidate is its fields and the record itself, in switcher order."
  (parley-switch-test--with-sessions
    (let ((candidates (parley-switch--candidates)))
      (should (equal (mapcar (lambda (candidate) (aref (car candidate) 3))
                             candidates)
                     '("%61" "%62" "%63" "%23" "9a5a5635" "7c1d0f9a")))
      ;; The record travels with the candidate, so nothing has to look
      ;; a session up by a name four of them share.
      (should (eq (cdr (nth 1 candidates)) (parley-switch-test--session 4)))
      (should (equal (mapcar (lambda (candidate)
                               (plist-get (cdr candidate) :pid))
                             candidates)
                     '(2 4 6 1 5 3))))))

(ert-deftest parley-switch-test-renderer-draws-every-field ()
  "The rendered candidate begins with the name and shows all four fields."
  (parley-switch-test--with-sessions
    (let* ((candidate (nth 1 (parley-switch--candidates)))
           (rendered (parley-switch--renderer candidate nil nil)))
      (should (string-prefix-p "orc-w1" rendered))
      (dolist (field (append (car candidate) nil))
        (should (string-match-p (regexp-quote field) rendered))))))

(ert-deftest parley-switch-test-action-opens-the-candidate-session ()
  "Acting on a candidate opens the buffer of the record it carries."
  (parley-switch-test--with-sessions
    (let ((candidate (nth 4 (parley-switch--candidates))))
      (save-window-excursion
        (parley-switch--action nil candidate)
        (should (equal (buffer-name) "*parley orc-w1 9a5a5635*"))
        (should (eq parley-session (parley-switch-test--session 5)))))))

(ert-deftest parley-switch-test-matcher-matches-columns ()
  "Each column is matched on its own, and the prompt is matched in order."
  (skip-unless (featurep 'sallet))
  (parley-switch-test--with-sessions
    (let ((candidates (vconcat (parley-switch--candidates))))
      (cl-flet ((tags (prompt)
                  (mapcar
                   (lambda (index)
                     (aref (car (aref candidates
                                      (if (consp index) (car index) index)))
                           3))
                   (parley-switch--matcher
                    candidates (list (cons 'prompt prompt))))))
        (should (equal (tags "")
                       '("%61" "%62" "%63" "%23" "9a5a5635" "7c1d0f9a")))
        (should (equal (tags "orc-w1") '("%61" "%62" "%63" "9a5a5635")))
        (should (equal (tags "/worker-2") '("%62")))
        (should (equal (tags "%61") '("%61")))
        (should (equal (tags ":busy") '("%23" "9a5a5635")))
        (should (equal (tags ":idle") '("%61" "%62" "%63")))
        (should (equal (tags "orc-w1 /worker-1") '("%61" "%63")))
        (should (equal (tags "/worker-1 %63") '("%63")))
        (should (equal (tags "orc-w1 %23") nil))
        (should (equal (tags "nothing") nil))))))

(provide 'parley-switch-test)
;;; parley-switch-test.el ends here
