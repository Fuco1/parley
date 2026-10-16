;;; parley-switch-test.el --- Tests for parley-switch -*- lexical-binding: t -*-

;;; Commentary:

;; Switching reads nothing about the machine except the session list
;; and where tmux says each session's pane is, so every test here
;; stubs the first with records and binds the second to a fixture map:
;; none of them needs a live session, and no server the machine
;; happens to be running can answer instead.
;;
;; The seven records are what the sallet source is matched and
;; rendered against, and the columns it draws them in are
;; `parley-session-fields' -- which lives below both frontends,
;; because `parley-transcript' reads a session too.
;;
;; The check that runs these loads sallet, so the matcher is asked
;; through sallet's own dispatch.  The test of the `completing-read'
;; fallback removes the sallet source, which is the environment that
;; fallback exists for.  What needs sallet itself to run says so with
;; `featurep', so a run by hand without sallet skips it.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'parley-switch)


;;; Fixtures

;; Seven records as `parley-sessions' returns them, in an order no
;; frontend should show them in.  Four share the name `orc-w1': that
;; is what sibling worktrees really look like.  Two of those four
;; share a working directory and a status as well and differ in
;; nothing but their pane, which is two sessions started in one repo.
;; A third has no pane at all and a fourth a pane tmux does not
;; report, so neither row shows a window.  One record has neither
;; name nor status, which is what `claude agents' reports for a
;; session it knows none for.  And one is a background agent named
;; after its prompt, wider than the name column: the word its name
;; ends with is in the part a row cuts off, and a path in it names a
;; worktree another session is working in.
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
              :pane "%63" :transcript "/tmp/3333ffff.jsonl")
        (list :pid 7
              :name (concat "review the diff in /srv/orc/trees/worker-2/orc"
                            " and say whether each of its new tests can fail")
              :kind "background" :status "busy"
              :cwd "/srv/orc/trees/worker-1/orc"
              :session-id "4444ffff-0000-4000-8000-000000000004"
              :pane nil :transcript "/tmp/4444ffff.jsonl")))

(defconst parley-switch-test--pane-locations
  '(("%23" . "app%8e:1.0")
    ("%61" . "orc-b3743fe3:2.0")
    ("%62" . "orc-b3743fe3:3.1"))
  "Where tmux says each fixture pane is, keyed by pane id.
The pane `%63' of the sixth record is missing on purpose: a
window closed under a session that outlived it is a pane tmux
reports nothing for, and that session is still one to read.")

(defmacro parley-switch-test--with-locations (&rest body)
  "Run BODY with tmux reporting the fixture pane locations.
Bound and not started: a real tmux would answer with the panes of
whatever the machine is running."
  (declare (indent 0))
  `(let ((parley--pane-locations parley-switch-test--pane-locations))
     ,@body))

(defun parley-switch-test--session (pid)
  "Return the fixture record whose pid is PID."
  (seq-find (lambda (session) (eq (plist-get session :pid) pid))
            parley-switch-test--sessions))

(defmacro parley-switch-test--with-sessions (&rest body)
  "Run BODY with `parley-sessions' returning the fixture records.
The list is copied on every call because the switcher sorts it.
The records name working directories and transcripts that are not
there, so BODY must not open a buffer over one."
  (declare (indent 0))
  `(parley-switch-test--with-locations
     (cl-letf (((symbol-function 'parley-sessions)
                (lambda () (copy-sequence parley-switch-test--sessions))))
       ,@body)))

;;; Without sallet

(ert-deftest parley-switch-test-falls-back-to-completing-read ()
  "With no sallet source the command reads the session in the minibuffer.
The one picked is the second of the four sessions named `orc-w1',
and it is that record `parley-transcript' is handed: a switcher
that told them apart by name alone would hand over the wrong one.
Where that record is shown is the transcript's business and is
tested there, so the command is stubbed here."
  (parley-switch-test--with-sessions
    (let ((session (parley-switch-test--session 4))
          (asked nil)
          (shown nil)
          (collection nil))
      (cl-letf (((symbol-function 'sallet-source-parley) nil)
                ((symbol-function 'parley-transcript)
                 (lambda (picked) (setq shown picked)))
                ((symbol-function 'completing-read)
                 (lambda (_prompt table &rest _)
                   (setq asked t collection table)
                   (parley-session-row (parley-session-fields session)))))
        (parley-switch)
        (should asked)
        (should (eq shown session))
        ;; The rows are offered in the switcher order, and the
        ;; completion metadata is what stops the minibuffer from
        ;; sorting them alphabetically and losing it.
        (should (equal (mapcar (lambda (row) (car (split-string row)))
                               (all-completions "" collection))
                       '("orc-w1" "orc-w1" "orc-w1" "app-8e" "orc-w1"
                         "review" "unnamed")))
        (should (eq (alist-get 'display-sort-function
                               (cdr (completion-metadata "" collection nil)))
                    #'identity))
        ;; And the colours reach the minibuffer: the faces are on the
        ;; rows themselves, so what the completion machinery hands the
        ;; frontend is faced the way the sallet source is.
        (should (equal (get-text-property 0 'face (car (all-completions
                                                        "" collection)))
                       'parley-row-name))))))

(ert-deftest parley-switch-test-fallback-with-nothing-running ()
  "Reading a session when none is running says so instead of picking one."
  (cl-letf (((symbol-function 'parley-sessions) (lambda () nil))
            ((symbol-function 'sallet-source-parley) nil))
    (should-error (parley-switch) :type 'user-error)))


;;; With sallet

(ert-deftest parley-switch-test-candidate-carries-the-record ()
  "A candidate is its fields and the record itself, in switcher order.
The windows are written out rather than computed, so a test
comparing against them compares against something a change to
the fields cannot move with it.  One location carries a `%'
because a tmux session name may, and the window is what follows
the session name all the same."
  (parley-switch-test--with-sessions
    (let ((candidates (parley-switch--candidates)))
      (should (equal (mapcar (lambda (candidate)
                               (plist-get (car candidate) :window))
                             candidates)
                     '("2.0" "3.1" "" "1.0" "" "" "")))
      ;; The record travels with the candidate, so nothing has to look
      ;; a session up by a name four of them share.
      (should (eq (cdr (nth 1 candidates)) (parley-switch-test--session 4)))
      (should (equal (mapcar (lambda (candidate)
                               (plist-get (cdr candidate) :pid))
                             candidates)
                     '(2 4 6 1 5 7 3))))))

(ert-deftest parley-switch-test-renderer-draws-every-field ()
  "The rendered candidate begins with the name and shows all four fields.
It is drawn coloured, because it is the row that carries the
faces and the renderer hands that row over as it is."
  (parley-switch-test--with-sessions
    (let* ((candidate (nth 1 (parley-switch--candidates)))
           (rendered (parley-switch--renderer candidate nil nil)))
      (should (string-prefix-p "orc-w1" rendered))
      (cl-loop for (_key field) on (car candidate) by #'cddr
               do (should (string-match-p (regexp-quote field) rendered)))
      (should (equal (get-text-property 0 'face rendered) 'parley-row-name))
      (should (equal (get-text-property 72 'face rendered)
                     'parley-row-status-idle)))))

(ert-deftest parley-switch-test-renderer-draws-a-session-with-a-buffer-open ()
  "The rendered row of a session with a buffer has its name drawn open.
The buffer follows a copy of the second of the four sessions
named `orc-w1', as a buffer opened earlier follows the record it
was opened with, so the renderer has to find it by the session
id: only that one row is drawn open, across the whole of its name
column, and the three sessions sharing its name are not."
  (parley-switch-test--with-sessions
    (with-temp-buffer
      (setq-local parley-transcript-session
                  (copy-sequence (parley-switch-test--session 4)))
      (should (equal (mapcar
                      (lambda (candidate)
                        (let ((row (parley-switch--renderer candidate nil nil)))
                          (list (plist-get (cdr candidate) :pid)
                                (get-text-property 0 'face row)
                                (next-single-property-change 0 'face row))))
                      (parley-switch--candidates))
                     '((2 parley-row-name 70)
                       (4 parley-row-name-open 70)
                       (6 parley-row-name 70)
                       (1 parley-row-name 70)
                       (5 parley-row-name 70)
                       (7 parley-row-name 70)
                       (3 parley-row-name 70)))))))

(ert-deftest parley-switch-test-action-opens-the-candidate-session ()
  "Acting on a candidate shows the record it carries and no other.
The candidate acted on is one of the four named `orc-w1', which
is what makes this worth asserting: the record travels with the
candidate, so nothing has to find it again by a name it shares."
  (parley-switch-test--with-sessions
    (let ((candidate (nth 4 (parley-switch--candidates)))
          (shown nil))
      (cl-letf (((symbol-function 'parley-transcript)
                 (lambda (picked) (setq shown picked))))
        (parley-switch--action nil candidate)
        (should (eq shown (parley-switch-test--session 5)))))))

(ert-deftest parley-switch-test-a-field-filter-reads-its-own-column ()
  "A field filter matches its pattern against the column its key names.
Each pattern below is held by that one column of the fixtures, so
a filter reading any other column finds other sessions or none.

The one function of sallet's the filter calls,
`sallet-candidate-aref', is stood in for, so this runs where the
matcher test below is skipped."
  (parley-switch-test--with-sessions
    (let* ((candidates (vconcat (parley-switch--candidates)))
           (indices (number-sequence 0 (1- (length candidates)))))
      (cl-letf (((symbol-function 'sallet-candidate-aref)
                 (lambda (candidates index) (car (aref candidates index)))))
        (cl-flet ((pids (key pattern)
                    (mapcar (lambda (index)
                              (plist-get (cdr (aref candidates index)) :pid))
                            (funcall (parley-switch--field-filter key)
                                     candidates indices pattern))))
          (should (equal (pids :name "app") '(1)))
          (should (equal (pids :status "working") '(1 5 7)))
          ;; The column holds the value and not the string the
          ;; session wrote, so that string finds nothing.
          (should-not (pids :status "busy"))
          (should (equal (pids :mark "[RO]") '(5 7 3)))
          (should (equal (pids :window "3.1") '(4)))
          (should (equal (pids :window ".0") '(2 1)))
          (dolist (pattern '("working" "[RO]" "3.1"))
            (should-not (pids :name pattern))))))))

(ert-deftest parley-switch-test-a-word-cut-off-the-row-still-matches ()
  "A word in the part of a name the row cuts off still finds the session.
The cut is the row's, and the name column a token is matched
against holds the whole name.  The background agent's name ends
past the seventy columns its row has room for, so the rendered
row carries neither its last word nor its last whole words, and
a token naming either finds it.

The name filter is called with `sallet-candidate-aref' stood in
for, as the field filter test does, so this runs where sallet is
not on the load path; with sallet there the matcher is asked as
well."
  (parley-switch-test--with-sessions
    (let* ((candidates (vconcat (parley-switch--candidates)))
           (indices (number-sequence 0 (1- (length candidates))))
           (agent (aref candidates 5))
           (row (parley-switch--renderer agent nil nil)))
      (should (eq (cdr agent) (parley-switch-test--session 7)))
      (should (string-match-p "…" row))
      (should-not (string-search "fail" row))
      (should-not (string-search "new tests" row))
      (cl-letf (((symbol-function 'sallet-candidate-aref)
                 (lambda (candidates index) (car (aref candidates index)))))
        (dolist (pattern '("fail" "new tests"))
          (should (equal (mapcar (lambda (index)
                                   (plist-get (cdr (aref candidates index))
                                              :pid))
                                 (funcall (parley-switch--field-filter :name)
                                          candidates indices pattern))
                         '(7)))))
      (when (featurep 'sallet)
        (should (equal (mapcar (lambda (index)
                                 (let ((index (if (consp index)
                                                  (car index)
                                                index)))
                                   (plist-get (cdr (aref candidates index))
                                              :pid)))
                               (parley-switch--matcher
                                candidates (list (cons 'prompt "fail"))))
                       '(7)))))))

(ert-deftest parley-switch-test-matcher-matches-columns ()
  "Each column is matched on its own, and the prompt is matched in order.
An @ token is matched against the WINDOW.PANE a row draws and
against nothing else: neither the tmux session the pane is in nor
the session id finds a session.  A / token is a word of the name:
the one the background agent's prompt holds finds it, and not the
session whose working directory it names."
  (skip-unless (featurep 'sallet))
  (parley-switch-test--with-sessions
    (let ((candidates (vconcat (parley-switch--candidates))))
      (cl-flet ((pids (prompt)
                  (mapcar
                   (lambda (index)
                     (let ((index (if (consp index) (car index) index)))
                       (plist-get (cdr (aref candidates index)) :pid)))
                   (parley-switch--matcher
                    candidates (list (cons 'prompt prompt))))))
        (should (equal (pids "") '(2 4 6 1 5 7 3)))
        (should (equal (pids "orc-w1") '(2 4 6 5)))
        (should (equal (pids "/worker-2") '(7)))
        (should (equal (pids "/srv/orc/trees/worker-1") nil))
        ;; An @ token matches the window, so a window and pane finds
        ;; the session running in it, and a window all of its panes.
        (should (equal (pids "@3.1") '(4)))
        (should (equal (pids "@2.0") '(2)))
        (should (equal (pids "@.0") '(2 1)))
        ;; The window of a location whose tmux session carries a `%'.
        (should (equal (pids "@1.0") '(1)))
        (should (equal (pids "@orc-b3743fe3") nil))
        (should (equal (pids "@2222ffff") nil))
        ;; And a pane id finds nothing at all: no column carries one,
        ;; so a % token is matched against the name like any other.
        (should (equal (pids "%61") nil))
        (should (equal (pids ":working") '(1 5 7)))
        (should (equal (pids ":busy") nil))
        (should (equal (pids ":idle") '(2 4 6)))
        (should (equal (pids "orc-w1 @3") '(4)))
        (should (equal (pids ":idle @.0") '(2)))
        (should (equal (pids "orc-w1 @app-8e") nil))
        (should (equal (pids "nothing") nil))))))

(provide 'parley-switch-test)
;;; parley-switch-test.el ends here
