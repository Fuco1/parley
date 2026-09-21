;;; parley-switch-test.el --- Tests for parley-switch -*- lexical-binding: t -*-

;;; Commentary:

;; Switching reads nothing about the machine except the session list
;; and where tmux says each session's pane is, so every test here
;; stubs the first with records and binds the second to a fixture map:
;; none of them needs a live session, and no server the machine
;; happens to be running can answer instead.
;;
;; The six records are what the sallet source is matched and rendered
;; against, and the columns it draws them in are
;; `parley-session-fields' -- which lives below both frontends,
;; because `parley-transcript' reads a session too.  The columns and
;; the order are asserted here, against the fixture they were built
;; for; the reader over them is asserted where it lives.
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
;; and the case a row without the pane's location cannot tell apart.
;; A third has no pane at all and a fourth a pane tmux does not
;; report, so the tag of each falls back to its session id.  One
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

(defconst parley-switch-test--pane-locations
  '(("%23" . "app%8e:1.0")
    ("%61" . "orc-b3743fe3:2.0")
    ("%62" . "orc-b3743fe3:3.1")
    ("%64" . "orc-b3743fe3:4.0"))
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
there, so BODY must not open a buffer over one: the test that
opens one builds a session it can really follow."
  (declare (indent 0))
  `(parley-switch-test--with-locations
     (cl-letf (((symbol-function 'parley-sessions)
                (lambda () (copy-sequence parley-switch-test--sessions))))
       ,@body)))

(defun parley-switch-test--opened ()
  "Return every buffer following a session."
  (seq-filter (lambda (buffer)
                (buffer-local-value 'parley-transcript-session buffer))
              (buffer-list)))

(defconst parley-switch-test--expected-tags
  '((1 . "app%8e:1.0 eb6ab7cd-21e6-434f-9bf6-f561b5852de2")
    (2 . "orc-b3743fe3:2.0 1111ffff-0000-4000-8000-000000000001")
    (3 . "7c1d0f9a-0000-4000-8000-000000000003")
    (4 . "orc-b3743fe3:3.1 2222ffff-0000-4000-8000-000000000002")
    (5 . "9a5a5635-26c3-4705-b06e-4dc108d75439")
    (6 . "3333ffff-0000-4000-8000-000000000003"))
  "The tag each fixture session is listed and named under, by pid.
A whole session id, and where the session's pane is before it
when tmux reports one -- never the pane id itself, which is what
`tmux send-keys -t' takes and nothing the operator can act on.
One location carries a `%\' because a tmux session name may:
tmux 3.2a sanitises `:\' and `.\' in one and nothing else, so a
`%\' here is a session name's and never a pane id.
These are written out rather than computed with
`parley-session-tag', so that a test comparing a tag against one
of them is comparing it against something a change to that
function cannot move with it.")

(defun parley-switch-test--tag (pid)
  "Return the tag the fixture session whose pid is PID is listed under."
  (cdr (assq pid parley-switch-test--expected-tags)))


;;; The columns

(ert-deftest parley-switch-test-a-session-is-five-fields ()
  "A session is five fields: name, status, mark, directory, tag."
  (parley-switch-test--with-locations
    (should (equal (parley-session-fields (parley-switch-test--session 2))
                   (vector "orc-w1" "idle" "" "/srv/orc/trees/worker-1/orc"
                           (parley-switch-test--tag 2))))
    ;; The working directory is shown the way the operator writes it.
    (should (equal (aref (parley-session-fields
                          (parley-switch-test--session 1))
                         3)
                   "~/dev/ydistri/Ydistri.Pairing"))
    ;; A name and a status `claude agents' did not report still leave
    ;; five fields, and the tag column falls back to the session id.
    (should (equal (parley-session-fields (parley-switch-test--session 3))
                   (vector "unnamed" "unknown" "read only" "/srv/matus"
                           (parley-switch-test--tag 3))))))

(ert-deftest parley-switch-test-marks-a-session-with-no-pane-read-only ()
  "A session with no pane is listed as one that cannot be typed into.
The mark is in the row before anything has been submitted, which
is the only point at which the operator can still pick another
session.

It is read from the pane and not from the kind: both fixture
sessions without a pane are reported interactive, and a session
started outside tmux is as unreachable as a background agent
dispatched from the agent view.

It is read from the pane and not from its location either: the
sixth record has a pane tmux reports nothing for, so its tag is
its session id alone, and `send-keys -t' still takes that pane."
  (parley-switch-test--with-locations
    (dolist (pid '(3 5))
      (let ((fields (parley-session-fields (parley-switch-test--session pid))))
        (should (equal (plist-get (parley-switch-test--session pid) :kind)
                       "interactive"))
        (should (equal (aref fields 2) "read only"))
        (should (string-match-p "read only" (parley-session-row fields)))))
    ;; And a session with a pane carries no mark, so the row says
    ;; something about this session rather than about every session.
    (dolist (pid '(1 2 4 6))
      (let ((fields (parley-session-fields (parley-switch-test--session pid))))
        (should (equal (aref fields 2) ""))
        (should-not (string-match-p "read only"
                                    (parley-session-row fields)))))))

(ert-deftest parley-switch-test-tag-tells-one-name-apart ()
  "The four sessions named `orc-w1' have four different tags.
Two of them share a working directory as well, one lives outside
tmux and has no pane to be told apart by, and one has a pane tmux
reports no location for, so what every tag ends in is the session
id -- the one thing two records cannot share.

And no tag carries the pane id its location was resolved from:
that is what the record keeps for `tmux send-keys -t' and not
what a row shows."
  (parley-switch-test--with-locations
    (let ((tags (mapcar #'parley-session-tag
                        (list (parley-switch-test--session 2)
                              (parley-switch-test--session 4)
                              (parley-switch-test--session 5)
                              (parley-switch-test--session 6)))))
      (should (equal tags (mapcar #'parley-switch-test--tag '(2 4 5 6))))
      (should (equal (length (delete-dups (copy-sequence tags))) 4))
      (dolist (session parley-switch-test--sessions)
        (let ((pane (plist-get session :pane)))
          (should-not (and pane
                           (string-match-p (regexp-quote pane)
                                           (parley-session-tag session)))))))))

(ert-deftest parley-switch-test-row-begins-with-the-name ()
  "Every row begins with the session name and carries every field."
  (parley-switch-test--with-locations
    (dolist (session parley-switch-test--sessions)
      (let* ((fields (parley-session-fields session))
             (row (parley-session-row fields)))
        (should (string-prefix-p (aref fields 0) row))
        (dolist (field (append fields nil))
          (should (string-match-p (regexp-quote field) row)))))))

(ert-deftest parley-switch-test-rows-are-unique ()
  "No two sessions produce the same row, name sharing or not."
  (parley-switch-test--with-locations
    (let ((rows (mapcar (lambda (session)
                          (parley-session-row
                           (parley-session-fields session)))
                        parley-switch-test--sessions)))
      (should (equal (length (delete-dups (copy-sequence rows)))
                     (length parley-switch-test--sessions))))))


;;; The order

(ert-deftest parley-switch-test-sessions-are-ordered-by-status ()
  "Idle sessions come first, then busy, then the ones with no status.
Sessions sharing a status keep the order discovery returned them
in, which is not the order they come out in here."
  (parley-switch-test--with-sessions
    (should (equal (mapcar (lambda (session) (plist-get session :pid))
                           (parley-sessions-by-status))
                   '(2 4 6 1 5 3)))))


;;; The buffer, which belongs to the transcript

(ert-deftest parley-switch-test-shows-the-buffer-the-pipeline-runs-in ()
  "The session picked is shown in the buffer its transcript is running in.
Not an empty buffer of the switcher's own: the buffer is in
`parley-transcript-mode', it has the pipeline in it and it
records the session that was picked.

And it is the one buffer there is for that session.  Calling
`parley-transcript' with the same record afterwards lands in it
-- the same buffer object and the same process, so the history
already in it is still there and no second pipeline was started."
  (skip-unless (executable-find "jq"))
  (let* ((file (make-temp-file "parley-switch-test-" nil ".jsonl"))
         (session (list :pid 7 :name "orc-w1" :kind "interactive"
                        :status "idle" :cwd temporary-file-directory
                        :session-id "4444ffff-0000-4000-8000-000000000004"
                        :pane "%64" :transcript file))
         (parley--pane-locations parley-switch-test--pane-locations)
         (buffer nil))
    (unwind-protect
        ;; The fallback frontend, picking this one session: the sallet
        ;; source is taken away and `completing-read' answers with the
        ;; row the session is listed under.
        (cl-letf (((symbol-function 'parley-sessions) (lambda () (list session)))
                  ((symbol-function 'sallet-source-parley) nil)
                  ((symbol-function 'completing-read)
                   (lambda (&rest _)
                     (parley-session-row (parley-session-fields session)))))
          ;; The assertions are inside, because leaving a
          ;; `save-window-excursion' puts the old buffer back.
          (save-window-excursion
            (parley-switch)
            (setq buffer (current-buffer))
            (should (eq major-mode 'parley-transcript-mode))
            (should (eq parley-transcript-session session))
            (should (process-live-p (get-buffer-process buffer)))
            (let ((process (get-buffer-process buffer))
                  ;; The same session as `claude agents' reports it a
                  ;; moment later: a record of its own, and the one the
                  ;; buffer should be following afterwards.
                  (again (plist-put (copy-sequence session) :status "busy")))
              (parley-transcript again)
              (should (eq (current-buffer) buffer))
              (should (eq (get-buffer-process buffer) process))
              (should (eq parley-transcript-session again)))
            (should (equal (parley-switch-test--opened) (list buffer)))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-file file))))


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
      (should (equal (mapcar (lambda (candidate) (aref (car candidate) 4))
                             candidates)
                     (mapcar #'parley-switch-test--tag '(2 4 6 1 5 3))))
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
                           4))
                   (parley-switch--matcher
                    candidates (list (cons 'prompt prompt))))))
        (should (equal (tags "")
                       (mapcar #'parley-switch-test--tag '(2 4 6 1 5 3))))
        (should (equal (tags "orc-w1")
                       (mapcar #'parley-switch-test--tag '(2 4 6 5))))
        (should (equal (tags "/worker-2") (list (parley-switch-test--tag 4))))
        ;; An @ token matches the tag, so a window finds the session
        ;; running in it and a tmux session all of its windows --
        ;; though the tag it matches carries the session id too.
        (should (equal (tags "@orc-b3743fe3:2.0")
                       (list (parley-switch-test--tag 2))))
        (should (equal (tags "@orc-b3743fe3")
                       (mapcar #'parley-switch-test--tag '(2 4))))
        (should (equal (tags "@2222ffff")
                       (list (parley-switch-test--tag 4))))
        ;; A `%' in a location is the tmux session name's, so the
        ;; column carries it and the @ token finds it.
        (should (equal (tags "@app%8e:1.0")
                       (list (parley-switch-test--tag 1))))
        ;; And a pane id finds nothing at all: no column carries one,
        ;; so a % token is matched against the name like any other.
        (should (equal (tags "%61") nil))
        (should (equal (tags ":busy")
                       (mapcar #'parley-switch-test--tag '(1 5))))
        (should (equal (tags ":idle")
                       (mapcar #'parley-switch-test--tag '(2 4 6))))
        (should (equal (tags "orc-w1 /worker-1")
                       (mapcar #'parley-switch-test--tag '(2 6))))
        (should (equal (tags "/worker-1 @orc-b3743fe3:2")
                       (list (parley-switch-test--tag 2))))
        (should (equal (tags "orc-w1 @app-8e") nil))
        (should (equal (tags "nothing") nil))))))

(provide 'parley-switch-test)
;;; parley-switch-test.el ends here
