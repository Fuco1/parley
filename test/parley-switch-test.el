;;; parley-switch-test.el --- Tests for parley-switch -*- lexical-binding: t -*-

;;; Commentary:

;; Switching reads nothing about the machine except the session list
;; and where tmux says each session's pane is, so every test here
;; stubs the first with records and has the second answered by the
;; tmux of `parley-fixtures-with-pane-locations': none of them needs a
;; live session, and no server the machine happens to be running can
;; answer instead.
;;
;; The nine records are what the sallet sources are matched and
;; rendered against, and the columns they draw them in are
;; `parley-session-fields' -- which lives below both frontends,
;; because `parley-transcript' reads a session too.
;;
;; The check that runs these loads sallet, so the matcher is asked
;; through sallet's own dispatch.  The test of the `completing-read'
;; fallback removes the sallet sources, which is the environment that
;; fallback exists for.  What needs sallet itself to run says so with
;; `featurep', so a run by hand without sallet skips it.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'parley-switch)
(require 'parley-fixtures
         (expand-file-name "parley-fixtures"
                           (file-name-directory (macroexp-file-name))))

;; What a test below needs sallet for skips without it, and the
;; compile runs without it.
(declare-function sallet-init-source "sallet-source" (source))
(declare-function sallet-source-get-candidates "sallet-source" (source))
(declare-function sallet-source-get-matcher "sallet-source" (source))
(declare-function sallet-render-header "sallet" (source))
(declare-function sallet-update-candidates "sallet" (state source))
(declare-function eieio-object-class "eieio" (obj))


;;; The live sessions and where tmux says their panes are

;; Nine records as `parley-sessions' returns them, in an order no
;; frontend should show them in.  Seven are Claude Code sessions and
;; the last two Codex ones, listed in each other's status order.  Four share the name `orc-w1': that
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
  (list (list :vendor 'claude
              :pid 1 :name "app-8e" :kind "interactive" :status "busy"
              :cwd (expand-file-name "dev/ydistri/Ydistri.Pairing" "~")
              :session-id "eb6ab7cd-21e6-434f-9bf6-f561b5852de2"
              :pane "%23" :transcript "/tmp/eb6ab7cd.jsonl")
        (list :vendor 'claude
              :pid 2 :name "orc-w1" :kind "interactive" :status "idle"
              :cwd "/srv/orc/trees/worker-1/orc"
              :session-id "1111ffff-0000-4000-8000-000000000001"
              :pane "%61" :transcript "/tmp/1111ffff.jsonl")
        (list :vendor 'claude
              :pid 3 :name nil :kind "interactive" :status nil
              :cwd "/srv/matus"
              :session-id "7c1d0f9a-0000-4000-8000-000000000003"
              :pane nil :transcript "/tmp/7c1d0f9a.jsonl")
        (list :vendor 'claude
              :pid 4 :name "orc-w1" :kind "interactive" :status "idle"
              :cwd "/srv/orc/trees/worker-2/orc"
              :session-id "2222ffff-0000-4000-8000-000000000002"
              :pane "%62" :transcript "/tmp/2222ffff.jsonl")
        (list :vendor 'claude
              :pid 5 :name "orc-w1" :kind "interactive" :status "busy"
              :cwd "/srv/go/orc"
              :session-id "9a5a5635-26c3-4705-b06e-4dc108d75439"
              :pane nil :transcript "/tmp/9a5a5635.jsonl")
        (list :vendor 'claude
              :pid 6 :name "orc-w1" :kind "interactive" :status "idle"
              :cwd "/srv/orc/trees/worker-1/orc"
              :session-id "3333ffff-0000-4000-8000-000000000003"
              :pane "%63" :transcript "/tmp/3333ffff.jsonl")
        (list :vendor 'claude
              :pid 7
              :name (concat "review the diff in /srv/orc/trees/worker-2/orc"
                            " and say whether each of its new tests can fail")
              :kind "background" :status "busy"
              :cwd "/srv/orc/trees/worker-1/orc"
              :session-id "4444ffff-0000-4000-8000-000000000004"
              :pane nil :transcript "/tmp/4444ffff.jsonl")
        (list :vendor 'codex
              :pid 8 :name "triage" :status "Working"
              :cwd "/srv/orc/trees/worker-3/orc"
              :session-id "019a4a3c-5d10-7c42-9e2a-5d1c0b6f8a21"
              :pane "%64" :transcript "/tmp/019a4a3c.jsonl")
        (list :vendor 'codex
              :pid 9 :name "parley" :status "Action Required"
              :cwd "/srv/parley"
              :session-id "019a4b7e-0a31-7f05-8b44-0c2d9e1f3b62"
              :pane "%65" :transcript "/tmp/019a4b7e.jsonl")))

(defun parley-switch-test--session (pid)
  "Return the fixture record whose pid is PID."
  (seq-find (lambda (session) (eq (plist-get session :pid) pid))
            parley-switch-test--sessions))

(defmacro parley-switch-test--with-sessions (&rest body)
  "Run BODY with `parley-sessions' returning the fixture records.
tmux reports the panes `parley-fixtures-pane-locations' names, so
the pane `%63' is one it reports nothing for.  The list is copied
on every call because the switcher sorts it.
The records name working directories and transcripts that are not
there, so BODY must not open a buffer over one."
  (declare (indent 0))
  `(parley-fixtures-with-pane-locations
     (cl-letf (((symbol-function 'parley-sessions)
                (lambda () (copy-sequence parley-switch-test--sessions))))
       ,@body)))


;;; Switching to a session

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
      (cl-letf (((symbol-function 'sallet-source-parley-claude) nil)
                ((symbol-function 'sallet-source-parley-codex) nil)
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
                       '("parley" "orc-w1" "orc-w1" "orc-w1" "app-8e"
                         "orc-w1" "review" "triage" "unnamed")))
        ;; One list has no header to say which CLI a row runs, so a
        ;; Codex row says it in the status column, where a session
        ;; with no pane says it is read only, and a Claude Code row
        ;; says nothing.
        (should (equal (mapcar (lambda (row) (substring row 72 84))
                               (all-completions "" collection))
                       '("waiting [CX]" "idle        " "idle        "
                         "idle        " "working     " "working [RO]"
                         "working [RO]" "working [CX]" "unknown [RO]")))
        (should (equal (get-text-property 80 'face (car (all-completions
                                                         "" collection)))
                       'parley-row-vendor))
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
            ((symbol-function 'sallet-source-parley-claude) nil)
            ((symbol-function 'sallet-source-parley-codex) nil))
    (should-error (parley-switch) :type 'user-error)))


;;; With sallet: the columns kept apart

(ert-deftest parley-switch-test-candidate-carries-the-record ()
  "A candidate is its fields and the record itself, in switcher order.
The candidates of one vendor are the records of that vendor's
sessions and no other's, in the order of their statuses.

The windows are written out rather than computed, so a test
comparing against them compares against something a change to
the fields cannot move with it.  One location carries a `%'
because a tmux session name may, and the window is what follows
the session name all the same."
  (parley-switch-test--with-sessions
    (let ((candidates (parley-switch--candidates 'claude))
          (codex (parley-switch--candidates 'codex)))
      (should (equal (mapcar (lambda (candidate)
                               (plist-get (cdr candidate) :pid))
                             codex)
                     '(9 8)))
      (should (equal (mapcar (lambda (candidate)
                               (plist-get (car candidate) :window))
                             codex)
                     '("0.1" "4.0")))
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
    (let* ((candidate (nth 1 (parley-switch--candidates 'claude)))
           (rendered (parley-switch--renderer candidate nil nil)))
      (should (string-prefix-p "orc-w1" rendered))
      (cl-loop for (_key field) on (car candidate) by #'cddr
               do (should (string-match-p (regexp-quote field) rendered)))
      (should (equal (get-text-property 0 'face rendered) 'parley-row-name))
      (should (equal (get-text-property 72 'face rendered)
                     'parley-row-status-idle)))))

(ert-deftest parley-switch-test-renderer-draws-no-vendor-mark ()
  "A Codex row in a sallet source carries no mark saying it is one.
The header of the source it is drawn under says that, and the row
shows only the mark `parley-session-mark' gives, which for a
session with a pane is none."
  (parley-switch-test--with-sessions
    (should (equal (mapcar (lambda (candidate)
                             (substring (parley-switch--renderer
                                         candidate nil nil)
                                        72 84))
                           (parley-switch--candidates 'codex))
                   '("waiting     " "working     ")))))

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
                      (parley-switch--candidates 'claude))
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
    (let ((candidate (nth 4 (parley-switch--candidates 'claude)))
          (shown nil))
      (cl-letf (((symbol-function 'parley-transcript)
                 (lambda (picked) (setq shown picked))))
        (parley-switch--action nil candidate)
        (should (eq shown (parley-switch-test--session 5)))))))

(defun parley-switch-test--open ()
  "Open the switcher and return the sallet sources it opened, initialised.
`sallet' is stood in for by the first thing it does, which is to
initialise each source it is handed, in order, with sallet's own
`sallet-init-source': that is where a source's candidates are
made, and the minibuffer `sallet' reads next has nothing to read
from in a batch run."
  (let ((opened nil))
    (cl-letf (((symbol-function 'sallet)
               (lambda (sources)
                 (setq opened (mapcar #'sallet-init-source sources)))))
      (parley-switch))
    opened))

(defun parley-switch-test--source-pids (source)
  "Return the pid of each record SOURCE has a candidate for, in order."
  (mapcar (lambda (candidate) (plist-get (cdr candidate) :pid))
          (sallet-source-get-candidates source)))

(ert-deftest parley-switch-test-opens-a-source-per-cli ()
  "The switcher is one view over a Claude Code source and a Codex source.
Each source lists the sessions of its own CLI, in status order,
under a header naming the CLI, and matches with the matcher that
keeps the columns apart.  A status token typed at the prompt is
matched by both sources: no Claude Code session is waiting, so
the Claude Code header is not drawn, and the Codex header counts
the one Codex session that is.

The sessions are discovered once for the view, whatever number of
sources it has."
  (skip-unless (featurep 'sallet))
  (parley-switch-test--with-sessions
    (let* ((discovered 0)
           (listed (symbol-function 'parley-sessions))
           (sources (cl-letf (((symbol-function 'parley-sessions)
                               (lambda ()
                                 (cl-incf discovered)
                                 (funcall listed))))
                      (parley-switch-test--open))))
      (should (= discovered 1))
      (should-not (fboundp 'sallet-source-parley))
      (should (equal (mapcar #'eieio-object-class sources)
                     '(sallet-source-parley-claude
                       sallet-source-parley-codex)))
      (should (equal (mapcar #'parley-switch-test--source-pids sources)
                     '((2 4 6 1 5 7 3) (9 8))))
      (should (equal (mapcar (lambda (source)
                               (substring-no-properties
                                (sallet-render-header source)))
                             sources)
                     '(" • Claude Code sessions [7/7]\n"
                       " • Codex sessions [2/2]\n")))
      (dolist (source sources)
        (should (eq (sallet-source-get-matcher source)
                    'parley-switch--matcher))
        (sallet-update-candidates (list (cons 'prompt ":waiting")) source))
      (should (equal (mapcar (lambda (source)
                               (and (sallet-render-header source)
                                    (substring-no-properties
                                     (sallet-render-header source))))
                             sources)
                     '(nil " • Codex sessions [1/2]\n"))))))

(ert-deftest parley-switch-test-discovers-once-per-opening ()
  "Opening the switcher asks `claude agents' once and reads /proc once.
Both sources take their sessions from the one list the opening
discovered, so a second source is not a second discovery.  What
is counted is the run of `claude agents --json' and the listing
of /proc that finds the `codex' processes, which are what
discovery costs; neither finds a session here, so tmux is never
asked."
  (skip-unless (featurep 'sallet))
  (parley-fixtures-with-pane-locations
    (should (= (length (parley-switch-test--open)) 2))
    (should (equal parley-fixtures-asked
                   (list "/proc" parley-claude-program)))))

(ert-deftest parley-switch-test-a-field-filter-reads-its-own-column ()
  "A field filter matches its pattern against the column its key names.
Each pattern below is held by that one column of the fixtures, so
a filter reading any other column finds other sessions or none.

The one function of sallet's the filter calls,
`sallet-candidate-aref', is stood in for, so this runs where the
matcher test below is skipped."
  (parley-switch-test--with-sessions
    (let* ((candidates (vconcat (parley-switch--candidates 'claude)))
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
    (let* ((candidates (vconcat (parley-switch--candidates 'claude)))
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
    (let ((candidates (vconcat (parley-switch--candidates 'claude))))
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
