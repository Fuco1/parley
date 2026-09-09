;;; parley-transcript-test.el --- Tests for parley-transcript -*- lexical-binding: t -*-

;;; Commentary:

;; What is worth testing here is not the elisp, which is short, but
;; the pipeline and the render pass: whether jq really drops the
;; payloads, whether a line appended after the history has arrived
;; really shows up, whether killing the buffer really takes `tail' and
;; `jq' with it, and whether the faces the renderer inserts are still
;; on the text once font lock has been over it.  None of those can be
;; established by reading the code, so every test below but one runs
;; the real `parley-transcript' over a real temporary transcript and
;; looks at what came out.
;;
;; Those tests need `jq' on PATH and are skipped without it.

;;; Code:

(require 'ert)
(require 'parley-transcript)


;;; Fixtures

;; A string every payload in the fixture carries and no projected
;; object may: a tool call's input, a tool result, its top-level
;; `toolUseResult' twin, an assistant's thinking and the transcript's
;; non-message lines.  Finding it in the buffer means something that
;; should have stayed in the pipe reached Emacs.
(defconst parley-transcript-test--payload "PAYLOAD-MUST-NOT-REACH-EMACS")

;; Nine lines in the shapes a Claude Code transcript really holds: a
;; user turn whose content is a bare string, an assistant turn that
;; spoke and then made two tool calls, the `tool_result' turn that came
;; back, an assistant turn that was only thinking, a `system' line, a
;; `summary' line, an assistant turn whose text spans two lines, a user
;; turn with no content at all, and an assistant turn with markdown in
;; it.
(defconst parley-transcript-test--lines
  '("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"what is here\"}}"
    "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"Let me look.\"},{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"Bash\",\"input\":{\"command\":\"ls PAYLOAD-MUST-NOT-REACH-EMACS\"}},{\"type\":\"tool_use\",\"id\":\"toolu_2\",\"name\":\"Read\",\"input\":{\"file_path\":\"/PAYLOAD-MUST-NOT-REACH-EMACS\"}}]}}"
    "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"toolu_1\",\"content\":\"PAYLOAD-MUST-NOT-REACH-EMACS\"}]},\"toolUseResult\":{\"stdout\":\"PAYLOAD-MUST-NOT-REACH-EMACS\"}}"
    "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"PAYLOAD-MUST-NOT-REACH-EMACS\"}]}}"
    "{\"type\":\"system\",\"content\":\"PAYLOAD-MUST-NOT-REACH-EMACS\",\"level\":\"info\"}"
    "{\"type\":\"summary\",\"summary\":\"PAYLOAD-MUST-NOT-REACH-EMACS\"}"
    "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"first line\\nsecond line\"}]}}"
    "{\"type\":\"user\",\"message\":{\"role\":\"user\"}}"
    "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"**done** now\"}]}}")
  "The transcript the tests project, one JSONL line per element.")

(defun parley-transcript-test--tool-turn (count)
  "Return a transcript line for an assistant turn that made COUNT tool calls.
It says nothing besides the calls, which is the shape an agent
working produces: the run is what the renderer has to join, and
the payload in every call is what must not come with it."
  (format "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[%s]}}"
          (mapconcat
           (lambda (n)
             (format (concat "{\"type\":\"tool_use\",\"id\":\"toolu_%d\","
                             "\"name\":\"Bash\",\"input\":{\"command\":\"echo %s\"}}")
                     n parley-transcript-test--payload))
           (number-sequence 1 count) ",")))

(defun parley-transcript-test--text-turn (text)
  "Return a transcript line for an assistant turn that said TEXT."
  (format (concat "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\","
                  "\"content\":[{\"type\":\"text\",\"text\":\"%s\"}]}}")
          text))

;; What the nine lines above render to, blank lines dropped.  The tool
;; result, the thinking, the two non-message lines and the empty turn
;; contribute nothing at all; what the operator said is quoted; the two
;; tool calls are one line, and it stands where the run happened rather
;; than inside the turn that started it.
(defconst parley-transcript-test--rendered
  '("> what is here"
    "Let me look."
    "2 tool calls"
    "first line"
    "second line"
    "**done** now")
  "The conversation `parley-transcript-test--lines' must render to.")


;;; Driving a real buffer

(defun parley-transcript-test--write (file lines)
  "Append LINES to FILE, each as its own line."
  (let ((coding-system-for-write 'utf-8-unix))
    (write-region (mapconcat (lambda (line) (concat line "\n")) lines "")
                  nil file :append :silent)))

(defun parley-transcript-test--wait (predicate)
  "Wait up to ten seconds for PREDICATE to return non-nil.
Return what it last returned, so a caller can `should' it.
`accept-process-output' with no process is the wait, so the
pipeline's output is read while the test blocks."
  (let ((deadline (+ (float-time) 10))
        (result nil))
    (while (and (not (setq result (funcall predicate)))
                (< (float-time) deadline))
      (accept-process-output nil 0.05))
    result))

(defun parley-transcript-test--shown (buffer)
  "Return the non-blank lines BUFFER shows."
  (split-string (with-current-buffer buffer
                  (buffer-substring-no-properties (point-min) (point-max)))
                "\n" t))

(defun parley-transcript-test--runs (buffer)
  "Return the lines of BUFFER a run of tool calls collapsed to."
  (seq-filter (lambda (line) (string-match-p "tool calls?\\'" line))
              (parley-transcript-test--shown buffer)))

(defun parley-transcript-test--settled (buffer)
  "Wait for the whole projected history to have rendered in BUFFER."
  (parley-transcript-test--wait
   (lambda () (equal (parley-transcript-test--shown buffer)
                     parley-transcript-test--rendered))))

(defun parley-transcript-test--commands (predicate)
  "Return the command line of every live process PREDICATE accepts.
PREDICATE is called with the attribute alist of each process.
`process-attributes' rather than a `pgrep' subprocess, which
would have the pattern it is looking for in the command line of
the shell that ran it and find itself."
  (delq nil (mapcar (lambda (pid)
                      (let ((attributes (process-attributes pid)))
                        (and (funcall predicate attributes)
                             (alist-get 'args attributes))))
                    (list-system-processes))))

(defun parley-transcript-test--group (pgid)
  "Return the command line of every live process in process group PGID."
  (parley-transcript-test--commands
   (lambda (attributes) (eq (alist-get 'pgrp attributes) pgid))))

(defun parley-transcript-test--naming (file)
  "Return the command line of every live process whose own names FILE.
This is the check the process group cannot make: a `tail' that
left the group -- and so escaped the signal that killing the
buffer sends it -- still has the transcript in its command line."
  (parley-transcript-test--commands
   (lambda (attributes)
     (let ((args (alist-get 'args attributes)))
       (and args (string-search file args))))))

(defun parley-transcript-test--running (pgid program)
  "Return the command of PROGRAM in process group PGID, nil if it has none.
Matched on the head of the command line, so the shell whose -c
argument merely mentions `tail' is not mistaken for it."
  (seq-find (lambda (command) (string-prefix-p (concat program " ") command))
            (parley-transcript-test--group pgid)))

(defun parley-transcript-test--session (name lines)
  "Return a session record called NAME over a fresh transcript of LINES.
Its transcript doubles as its session id, which no other record
built here can share -- and which is what the buffers are told
apart by."
  (let ((file (make-temp-file "parley-transcript-test-" nil ".jsonl")))
    (parley-transcript-test--write file lines)
    (list :name name :session-id file :transcript file)))

(defun parley-transcript-test--buffers ()
  "Return every buffer following a session."
  (seq-filter (lambda (buffer)
                (buffer-local-value 'parley-transcript-session buffer))
              (buffer-list)))

(defmacro parley-transcript-test--with-session (lines &rest body)
  "Run BODY over a transcript buffer following a file holding LINES.
BODY sees `file', the transcript, and `buffer', the buffer
`parley-transcript' opened for a session record naming it.  The
buffer is the one that turned up rather than the one the naming
looked up, so a test that leaked one is a test that fails here
and not one that quietly reads someone else's buffer.  Both the
buffer and the file are gone afterwards, and so -- this being the
point of the last test -- is the pipeline."
  (declare (indent 1) (debug (form body)))
  `(let* ((session (parley-transcript-test--session "test" ,lines))
          (file (plist-get session :transcript))
          (buffer nil))
     (unwind-protect
         (progn
           (save-window-excursion (parley-transcript session))
           (should (= 1 (length (parley-transcript-test--buffers))))
           (setq buffer (car (parley-transcript-test--buffers)))
           ,@body)
       (when (buffer-live-p buffer) (kill-buffer buffer))
       (delete-file file))))


;;; The tests

(ert-deftest parley-transcript-opens-a-comint-buffer ()
  "The command opens a live comint buffer for a session record."
  (skip-unless (executable-find "jq"))
  (parley-transcript-test--with-session parley-transcript-test--lines
    (with-current-buffer buffer
      (should (derived-mode-p 'comint-mode))
      (should (eq major-mode 'parley-transcript-mode))
      (should (process-live-p (get-buffer-process buffer)))
      (should (equal (plist-get parley-transcript-session :transcript) file)))))

(ert-deftest parley-transcript-renders-the-conversation ()
  "The whole history reaches the buffer as a conversation and nothing else.
The turn that was only thinking and the `tool_result' turn
produce no buffer text whatever -- there is no line for either in
what the buffer shows."
  (skip-unless (executable-find "jq"))
  (parley-transcript-test--with-session parley-transcript-test--lines
    (should (equal (parley-transcript-test--wait
                    (lambda ()
                      (let ((shown (parley-transcript-test--shown buffer)))
                        (and (= (length shown)
                                (length parley-transcript-test--rendered))
                             shown))))
                   parley-transcript-test--rendered))
    ;; The markdown faces in that text came from somewhere else: this
    ;; buffer has comint's own font lock and no markdown rules in it.
    (with-current-buffer buffer
      (should (equal '(nil t) font-lock-defaults)))))

(ert-deftest parley-transcript-drops-the-tool-payloads ()
  "Nothing a tool sent or received reaches the Emacs process."
  (skip-unless (executable-find "jq"))
  (parley-transcript-test--with-session parley-transcript-test--lines
    (should (parley-transcript-test--settled buffer))
    (parley-transcript-test--write
     file (list (parley-transcript-test--tool-turn 3)))
    (should (parley-transcript-test--wait
             (lambda () (member "3 tool calls"
                                (parley-transcript-test--shown buffer)))))
    (with-current-buffer buffer
      (goto-char (point-min))
      (should-not (search-forward parley-transcript-test--payload nil t)))))

(ert-deftest parley-transcript-follows-the-file ()
  "A line appended after the history has arrived arrives too.
Without `--unbuffered' jq holds the append until its block fills,
which is never on a transcript this size, and this test is what
notices."
  (skip-unless (executable-find "jq"))
  (parley-transcript-test--with-session parley-transcript-test--lines
    (should (parley-transcript-test--settled buffer))
    (parley-transcript-test--write
     file '("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"and now this\"}}"))
    (should (equal (parley-transcript-test--wait
                    (lambda ()
                      (let ((shown (parley-transcript-test--shown buffer)))
                        (and (> (length shown)
                                (length parley-transcript-test--rendered))
                             (car (last shown))))))
                   "> and now this"))))

(ert-deftest parley-transcript-kill-stops-the-pipeline ()
  "Killing the buffer leaves no `tail' and no `jq' behind.
Emacs puts the pipeline's shell in a process group of its own, so
the group is where `tail' and `jq' are found and where they have
to be gone from.  The transcript is looked for across every
process afterwards as well, because a `tail' that had left the
group would have left that check with it."
  (skip-unless (executable-find "jq"))
  (parley-transcript-test--with-session parley-transcript-test--lines
    (let ((pgid (process-id (get-buffer-process buffer))))
      (should (parley-transcript-test--wait
               (lambda () (parley-transcript-test--running pgid "tail"))))
      (should (parley-transcript-test--running pgid "jq"))
      (kill-buffer buffer)
      (should (parley-transcript-test--wait
               (lambda () (null (parley-transcript-test--group pgid)))))
      (should-not (parley-transcript-test--naming file)))))

(ert-deftest parley-transcript-one-buffer-per-session ()
  "A session gets one buffer however often the command is called.
Two sessions get one each even when they share a name, which two
in sibling worktrees do: what tells the buffers apart is the
session id each records, and looking them up by name would give
the second session the first one's buffer -- or, since the name
is then taken, a fresh buffer and a fresh pipeline every time it
was asked for."
  (skip-unless (executable-find "jq"))
  (let ((one (parley-transcript-test--session
              "shared" parley-transcript-test--lines))
        (two (parley-transcript-test--session
              "shared" parley-transcript-test--lines))
        (buffers nil))
    (unwind-protect
        (progn
          (dolist (session (list one two two one two))
            (save-window-excursion (parley-transcript session)))
          (setq buffers (parley-transcript-test--buffers))
          (should (= 2 (length buffers)))
          (should (equal (sort (mapcar
                                (lambda (buffer)
                                  (plist-get (buffer-local-value
                                              'parley-transcript-session buffer)
                                             :session-id))
                                buffers)
                               #'string<)
                         (sort (list (plist-get one :session-id)
                                     (plist-get two :session-id))
                               #'string<))))
      (mapc #'kill-buffer buffers)
      (delete-file (plist-get one :transcript))
      (delete-file (plist-get two :transcript)))))

(ert-deftest parley-transcript-collapses-a-run-of-tool-calls ()
  "A run of tool calls is one line, however many messages it spans.
The count cannot be known when the line is first written, since a
run cannot be counted until it has ended and a line that waited
for that would appear only once the agent had stopped working.
So the line is rewritten as the run grows: the twelve calls of
one message and the three of the next are one line saying
fifteen, not two lines and not fifteen.

The line then stays where the run happened, above whatever the
agent said when it was done, and the earlier run of two is still
its own line further up."
  (skip-unless (executable-find "jq"))
  (parley-transcript-test--with-session parley-transcript-test--lines
    (should (parley-transcript-test--settled buffer))
    (parley-transcript-test--write
     file (list (parley-transcript-test--tool-turn 12)))
    (should (equal (parley-transcript-test--wait
                    (lambda ()
                      (let ((runs (parley-transcript-test--runs buffer)))
                        (and (= 2 (length runs)) runs))))
                   '("2 tool calls" "12 tool calls")))
    (parley-transcript-test--write
     file (list (parley-transcript-test--tool-turn 3)))
    (should (equal (parley-transcript-test--wait
                    (lambda ()
                      (let ((runs (parley-transcript-test--runs buffer)))
                        (and (member "15 tool calls" runs) runs))))
                   '("2 tool calls" "15 tool calls")))
    (parley-transcript-test--write
     file (list (parley-transcript-test--text-turn "and here it is")))
    (should (equal (parley-transcript-test--wait
                    (lambda ()
                      (let ((shown (parley-transcript-test--shown buffer)))
                        (and (equal "and here it is" (car (last shown)))
                             (last shown 2)))))
                   '("15 tool calls" "and here it is")))
    (should (equal (parley-transcript-test--runs buffer)
                   '("2 tool calls" "15 tool calls")))))

(ert-deftest parley-transcript-fontifies-in-another-buffer ()
  "Assistant text is fontified by markdown-mode, and not here.
The fontification happens in a buffer of its own because markdown
fontification is not a set of keywords that can be lifted out of
markdown-mode: fences and inline code are found by its syntax
table and its `syntax-propertize-function'.

That buffer is reused from message to message, which is the
hazard worth a test: whatever state one message leaves it in, the
next message has to come back fontified too.  And what comes back
carries `font-lock-face' and neither `face' nor any of the
properties markdown-mode keeps for its own use."
  (let ((bold (parley-transcript--fontify "**first**"))
        (code (parley-transcript--fontify "`second`")))
    (should (eq 'markdown-mode
                (buffer-local-value 'major-mode
                                    (parley-transcript--fontify-buffer))))
    ;; The text is what it was; only properties were added to it.
    (should (equal "**first**" (substring-no-properties bold)))
    (should (memq 'markdown-bold-face
                  (ensure-list (get-text-property 2 'font-lock-face bold))))
    (should (memq 'markdown-inline-code-face
                  (ensure-list (get-text-property 2 'font-lock-face code))))
    (dolist (string (list bold code))
      (dolist (position '(0 2))
        (should-not (plist-get (text-properties-at position string) 'face))
        (should-not (plist-get (text-properties-at position string) 'invisible))))))

(ert-deftest parley-transcript-faces-survive-font-lock ()
  "What was inserted still carries its faces after font lock has run.
comint sets `font-lock-defaults' to `(nil t)', which is not nil,
so global font lock turns font lock on in this buffer with no
keywords at all, where the only thing it can do is strip.  A
`face' property does not survive that -- the control inserted
here is proof, since it is gone by the end of the test -- and the
`font-lock-face' the renderer inserts does.

The properties are read with `text-properties-at' and not
`get-text-property', because font lock makes `face' an alias for
`font-lock-face' in the buffer it is on in, and the alias would
answer for a `face' property that is not there."
  (skip-unless (executable-find "jq"))
  (parley-transcript-test--with-session parley-transcript-test--lines
    (should (parley-transcript-test--settled buffer))
    (with-current-buffer buffer
      (let ((inhibit-read-only t)
            (emphasis nil)
            (control nil))
        (goto-char (point-min))
        (should (search-forward "**done**" nil t))
        ;; Inside the word, which is what carries the face; the two
        ;; characters before point are the closing markup.
        (setq emphasis (- (point) 3))
        (goto-char (point-max))
        (setq control (point))
        (insert (propertize "CONTROL" 'face 'markdown-bold-face))
        (font-lock-ensure)
        (should (memq 'markdown-bold-face
                      (ensure-list (get-text-property emphasis
                                                      'font-lock-face))))
        (should-not (plist-get (text-properties-at emphasis) 'face))
        (should-not (plist-get (text-properties-at control) 'face))))))

(ert-deftest parley-transcript-holds-back-a-split-line ()
  "A message too big for one chunk of output still renders once, and whole.
Emacs reads at most `read-process-output-max' bytes of process
output at a time and a projected object is one line however long
the message was, so any answer over that -- which is an ordinary
answer -- arrives split down the middle.  The half a line is held
back until the rest of it comes: what a chunk boundary must never
do is leave JSON in the buffer."
  (skip-unless (executable-find "jq"))
  (let ((text (mapconcat #'identity (make-list 1000 "a long answer") " ")))
    (should (> (length text) read-process-output-max))
    (parley-transcript-test--with-session
        (list (parley-transcript-test--text-turn text))
      (should (equal (parley-transcript-test--wait
                      (lambda () (car (parley-transcript-test--shown buffer))))
                     text))
      (should (= 1 (length (parley-transcript-test--shown buffer)))))))

(ert-deftest parley-transcript-shows-what-tail-says ()
  "A line that is not JSON is shown as it stands.
A session that has not spoken yet has no transcript to open and
`tail -F' says so on stderr, which shares this buffer.  Dropping
what cannot be parsed would leave the operator watching an empty
buffer with no idea why."
  (skip-unless (executable-find "jq"))
  (let* ((file (make-temp-file "parley-transcript-test-" nil ".jsonl"))
         (session (list :name "unspoken" :session-id file :transcript file))
         (buffer nil))
    (delete-file file)
    (unwind-protect
        (progn
          (save-window-excursion (parley-transcript session))
          (setq buffer (car (parley-transcript-test--buffers)))
          (should (parley-transcript-test--wait
                   (lambda ()
                     (seq-find (lambda (line)
                                 (string-match-p (regexp-quote file) line))
                               (parley-transcript-test--shown buffer))))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(provide 'parley-transcript-test)
;;; parley-transcript-test.el ends here
