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
    (list :name name :cwd temporary-file-directory
          :session-id file :transcript file)))

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
      (should (equal (plist-get parley-transcript-session :transcript) file))
      ;; In the session's own directory, so that what the operator does
      ;; here happens where the session he is reading is working.
      (should (equal default-directory
                     (file-name-as-directory temporary-file-directory))))))

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

(ert-deftest parley-transcript-names-two-sessions-of-one-name-apart ()
  "Two live sessions reported under one name get two buffer names.

`claude agents' names a session after the directory it was
started in, so sessions in sibling worktrees come back under the
same name and the name alone cannot say which buffer is whose.
Nor can the pane on its own: two live sessions share one when the
session running in it is suspended and another is started there,
which is `same' and `sharing' below.  What ends every name is
therefore the session id, the one thing two records cannot both
carry -- and a session outside tmux, which has no pane at all, is
named by that alone.

Whole, and not a head of it: `same' and `sharing' agree on their
name, their pane and the first eight characters of their id, so a
name built from a prefix is one name for two live sessions.

This needs no session to be running, which is why it is the one
test here that does not start a pipeline."
  (let* ((one (list :name "orc-w1" :pane "%61"
                    :session-id "1111ffff-0000-4000-8000-000000000001"))
         (two (list :name "orc-w1" :pane "%62"
                    :session-id "2222ffff-0000-4000-8000-000000000002"))
         (same (list :name "shared" :pane "%1"
                     :session-id "44444444-0000-4000-8000-000000000004"))
         (sharing (list :name "shared" :pane "%1"
                        :session-id "44444444-ffff-4000-8000-000000000005"))
         (outside (list :name "orc-w1" :pane nil
                        :session-id "9a5a5635-26c3-4705-b06e-4dc108d75439"))
         (unnamed (list :name nil :pane nil
                        :session-id "7c1d0f9a-0000-4000-8000-000000000003"))
         (names (mapcar #'parley-transcript-buffer-name
                        (list one two same sharing outside unnamed))))
    (should (equal names
                   '("*parley: orc-w1 %61 1111ffff-0000-4000-8000-000000000001*"
                     "*parley: orc-w1 %62 2222ffff-0000-4000-8000-000000000002*"
                     "*parley: shared %1 44444444-0000-4000-8000-000000000004*"
                     "*parley: shared %1 44444444-ffff-4000-8000-000000000005*"
                     "*parley: orc-w1 9a5a5635-26c3-4705-b06e-4dc108d75439*"
                     "*parley: unnamed 7c1d0f9a-0000-4000-8000-000000000003*")))
    (should (equal (length (delete-dups (copy-sequence names))) 6))))

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
carries `font-lock-face' and not `face'."
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
        (should-not (plist-get (text-properties-at position string) 'face))))))

(ert-deftest parley-transcript-marks-the-markup-hidden ()
  "Markup comes back carrying the two properties markdown-mode hides it with.
`invisible markdown-markup' is what the emphasis, code and fence
markers carry, and `display' is what a heading's `#' carries --
and a horizontal rule, a blockquote's `>' and a list bullet,
which markup hiding turns into glyphs rather than removes.

The superscript is the case a walk over the face runs cannot
reach: `markdown-fontify-sub-superscripts' raises the 2 with a
`display' property and gives it no face at all, so a copy that
only looked where a face was would drop it."
  (let ((bold (parley-transcript--fontify "**first**"))
        (heading (parley-transcript--fontify "# Heading"))
        (super (parley-transcript--fontify "x^2^")))
    (should (eq 'markdown-markup (get-text-property 0 'invisible bold)))
    (should-not (get-text-property 2 'invisible bold))
    (should (get-text-property 0 'display heading))
    (should-not (get-text-property 2 'display heading))
    (should (get-text-property 2 'display super))
    (should-not (get-text-property 2 'font-lock-face super))))

(ert-deftest parley-transcript-copies-three-properties-and-no-others ()
  "What comes back carries `font-lock-face', `invisible', `display' and nothing else.
markdown-mode leaves `markdown-heading', `font-lock-multiline'
and, on an HTML comment, a `syntax-table' property behind in the
buffer it fontifies in.  The transcript buffer has business with
none of them -- a `syntax-table' property in a comint buffer
least of all -- so the copy is a selected set rather than the
buffer string taken whole.

The fontify buffer is checked for those properties afterwards, so
that a fontification that stopped happening at all would fail
this test rather than pass it with a string carrying nothing."
  (let ((string (parley-transcript--fontify
                 (concat "# Heading\n\n<!-- note -->\n\n"
                         "```sh\nls\n```\n\n- item **bold** x^2^\n")))
        (position 0))
    (while (< position (length string))
      (let ((properties (text-properties-at position string)))
        (while properties
          (should (memq (car properties)
                        '(font-lock-face invisible display)))
          (setq properties (cddr properties))))
      (setq position (or (next-property-change position string)
                         (length string))))
    (with-current-buffer (parley-transcript--fontify-buffer)
      (dolist (property '(face markdown-heading font-lock-multiline
                               syntax-table))
        (should (text-property-not-all (point-min) (point-max)
                                       property nil))))))

(ert-deftest parley-transcript-mode-hides-the-markdown-markup ()
  "The mode names `markdown-markup' in the buffer's invisibility spec.
The default spec is t, under which any non-nil `invisible' hides,
so naming it changes nothing on its own -- and one
`add-to-invisibility-spec' from anywhere else makes the default a
list this value would not be in."
  (with-temp-buffer
    (parley-transcript-mode)
    (should (memq 'markdown-markup (ensure-list buffer-invisibility-spec)))))

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

(ert-deftest parley-transcript-hiding-survives-font-lock ()
  "The markup hidden in what was inserted is still hidden after font lock has run.
The whole feature rests on it: neither `invisible' nor `display'
is in `font-lock-extra-managed-props', so the strip that takes
`face' out of this buffer leaves both of them alone.

The control is what makes that a claim about font lock and not
about a pass that never happened -- it carries a `face' property,
and font lock is the only thing here that can take one away."
  (skip-unless (executable-find "jq"))
  (parley-transcript-test--with-session
      (list (parley-transcript-test--text-turn "# Heading with **bold**"))
    (with-current-buffer buffer
      (should (parley-transcript-test--wait
               (lambda () (save-excursion
                            (goto-char (point-min))
                            (search-forward "**bold**" nil t)))))
      (let ((inhibit-read-only t)
            (marker nil)
            (asterisk nil)
            (control nil))
        (goto-char (point-min))
        (should (search-forward "# Heading" nil t))
        (setq marker (match-beginning 0))
        (goto-char (point-min))
        (should (search-forward "**bold**" nil t))
        (setq asterisk (match-beginning 0))
        (goto-char (point-max))
        (setq control (point))
        (insert (propertize "CONTROL" 'face 'markdown-bold-face))
        (font-lock-ensure)
        (should-not (plist-get (text-properties-at control) 'face))
        (should (eq 'markdown-markup (get-text-property asterisk 'invisible)))
        (should (get-text-property marker 'display))))))

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


;;; Typing into the pane

;; A real tmux would need a real server, a real pane and a real Claude
;; Code in it before it could say whether the right thing arrived.  The
;; argument vector is the whole of what parley decides, so the argument
;; vector is what these tests capture -- from a `tmux' on `exec-path'
;; that writes down what it was given and nothing else.

(defmacro parley-transcript-test--with-tmux (&rest body)
  "Run BODY with a fake `tmux' first on `exec-path'.
BODY sees `tmux-log', the file every call appends a record to;
`parley-transcript-test--calls' reads them back."
  (declare (indent 0) (debug t))
  `(let* ((directory (make-temp-file "parley-tmux-" t))
          (tmux-log (expand-file-name "log" directory))
          (program (expand-file-name "tmux" directory))
          (exec-path (cons directory exec-path)))
     (unwind-protect
         (progn
           (with-temp-file program
             (insert "#!/bin/sh\n"
                     "{ printf '%s\\n' \"$@\" '--stdin--'\n"
                     "  cat\n"
                     "  printf '%s\\n' '' '--end--'\n"
                     "} >> " (shell-quote-argument tmux-log) "\n"))
           (set-file-modes program #o755)
           ,@body)
       (delete-directory directory t))))

(defun parley-transcript-test--calls (log)
  "Return one record per call in LOG, as (ARGUMENTS . STANDARD-INPUT)."
  (mapcar (lambda (record)
            (let ((halves (split-string record "\n--stdin--\n")))
              (cons (split-string (car halves) "\n" t) (cadr halves))))
          (split-string (with-temp-buffer
                          (insert-file-contents log)
                          (buffer-string))
                        "\n--end--\n" t)))

(defun parley-transcript-test--pane (buffer pane)
  "Tell BUFFER's session that it lives in tmux pane PANE."
  (with-current-buffer buffer
    (setq parley-transcript-session
          (plist-put parley-transcript-session :pane pane))))

(defun parley-transcript-test--submit (buffer text)
  "Type TEXT at BUFFER's prompt and submit it, as the operator would."
  (with-current-buffer buffer
    (goto-char (point-max))
    (insert text)
    (comint-send-input)))

(defun parley-transcript-test--user-turn (text)
  "Return a transcript line for a user turn that said TEXT."
  (format (concat "{\"type\":\"user\",\"message\":"
                  "{\"role\":\"user\",\"content\":\"%s\"}}")
          text))

(ert-deftest parley-transcript-sends-a-line-to-the-pane ()
  "A submitted line is typed into the session's pane and submitted there.
It leaves by `comint-input-sender' and not down the process,
whose standard input is a `tail' reading a file and reaches
nobody.  `-l' is what stops tmux reading the text as key names,
and the `Enter' after it is what submits it.

The trailing semicolon of the second line is escaped because tmux
reads one at the end of an argument as the separator between two
of its own commands and drops it -- so `select 1;' would arrive
as `select 1', which is a different question."
  (skip-unless (executable-find "jq"))
  (parley-transcript-test--with-session parley-transcript-test--lines
    (should (parley-transcript-test--settled buffer))
    (parley-transcript-test--pane buffer "%7")
    (with-current-buffer buffer
      (should (eq comint-input-sender #'parley-transcript--send-input)))
    (parley-transcript-test--with-tmux
      (parley-transcript-test--submit buffer "hello there")
      (parley-transcript-test--submit buffer "select 1;")
      (should (equal (mapcar #'car (parley-transcript-test--calls tmux-log))
                     '(("send-keys" "-t" "%7" "-l" "--" "hello there")
                       ("send-keys" "-t" "%7" "Enter")
                       ("send-keys" "-t" "%7" "-l" "--" "select 1\\;")
                       ("send-keys" "-t" "%7" "Enter")))))))

(ert-deftest parley-transcript-pastes-input-with-a-newline-in-it ()
  "Input with a newline in it reaches the pane as one bracketed paste.
`send-keys' would type the newline and the CLI would submit at
it, so a message of three lines would arrive as three messages.
`paste-buffer -p' wraps it in a bracketed paste instead, which
the CLI takes as one paste however many lines it has.

The text goes to tmux on standard input rather than in the
argument vector, and the paste buffer it lands in is named and
deleted on the way out so that the operator's own buffer stack is
where he left it."
  (skip-unless (executable-find "jq"))
  (parley-transcript-test--with-session parley-transcript-test--lines
    (should (parley-transcript-test--settled buffer))
    (parley-transcript-test--pane buffer "%7")
    (parley-transcript-test--with-tmux
      (parley-transcript-test--submit buffer "first line\nsecond line")
      (let ((calls (parley-transcript-test--calls tmux-log)))
        (should (equal (mapcar #'car calls)
                       '(("load-buffer" "-b" "parley" "-")
                         ("paste-buffer" "-d" "-p" "-b" "parley" "-t" "%7")
                         ("send-keys" "-t" "%7" "Enter"))))
        (should (equal (cdar calls) "first line\nsecond line"))))))

(ert-deftest parley-transcript-says-a-session-without-a-pane-is-read-only ()
  "Submitting in a buffer whose session has no pane says so and sends nothing.
A session started outside tmux inherited no TMUX_PANE, so there
is no terminal to type into and the buffer can only be read.  A
silent no-op would look exactly like a message that had been
sent, which is the worst thing this could do."
  (skip-unless (executable-find "jq"))
  (parley-transcript-test--with-session parley-transcript-test--lines
    (should (parley-transcript-test--settled buffer))
    (should-not (plist-get (buffer-local-value 'parley-transcript-session buffer)
                           :pane))
    (parley-transcript-test--with-tmux
      (let ((signalled (should-error
                        (parley-transcript-test--submit buffer "hello there")
                        :type 'user-error)))
        (should (string-match-p "read only" (cadr signalled))))
      (should-not (file-exists-p tmux-log)))))

(ert-deftest parley-transcript-does-not-render-its-own-echo ()
  "A message sent from the prompt is not shown again when it comes back.
comint has already put it in the buffer, and the session writes
the same message to its transcript seconds later; without the
guard every prompt appears twice.

The window is what makes it a guard rather than a permanent
blindness to one string, and shutting it is what proves it is
there: the second message is delivered and shown."
  (skip-unless (executable-find "jq"))
  (parley-transcript-test--with-session parley-transcript-test--lines
    (should (parley-transcript-test--settled buffer))
    (parley-transcript-test--pane buffer "%7")
    (parley-transcript-test--with-tmux
      (parley-transcript-test--submit buffer "hello there"))
    (parley-transcript-test--write
     file (list (parley-transcript-test--user-turn "hello there")
                (parley-transcript-test--text-turn "of course")))
    (should (parley-transcript-test--wait
             (lambda () (member "of course"
                                (parley-transcript-test--shown buffer)))))
    (let ((shown (parley-transcript-test--shown buffer)))
      (should (member "hello there" shown))
      (should-not (member "> hello there" shown)))
    (let ((parley-transcript-echo-window 0))
      (parley-transcript-test--with-tmux
        (parley-transcript-test--submit buffer "and again"))
      (parley-transcript-test--write
       file (list (parley-transcript-test--user-turn "and again")
                  (parley-transcript-test--text-turn "quite")))
      (should (parley-transcript-test--wait
               (lambda () (member "quite"
                                  (parley-transcript-test--shown buffer)))))
      (should (member "> and again" (parley-transcript-test--shown buffer))))))

(ert-deftest parley-transcript-renders-what-was-typed-at-the-pane ()
  "A user message parley did not send is rendered, guard or no guard.
The operator can type at the pane instead, and what he says there
has to reach the buffer like everything else.

The guard is spent on the first message that matches it, which is
what makes that true even of a message identical to the one just
sent: the first `hello there' here is the echo and is dropped,
the second was typed at the pane and is shown."
  (skip-unless (executable-find "jq"))
  (parley-transcript-test--with-session parley-transcript-test--lines
    (should (parley-transcript-test--settled buffer))
    (parley-transcript-test--pane buffer "%7")
    (parley-transcript-test--with-tmux
      (parley-transcript-test--submit buffer "hello there"))
    (parley-transcript-test--write
     file (list (parley-transcript-test--user-turn "hello there")
                (parley-transcript-test--user-turn "hello there")
                (parley-transcript-test--user-turn "typed at the pane")))
    (should (parley-transcript-test--wait
             (lambda () (member "> typed at the pane"
                                (parley-transcript-test--shown buffer)))))
    (should (= 1 (seq-count (lambda (line) (equal line "> hello there"))
                            (parley-transcript-test--shown buffer))))))


;;; The imenu index

(defun parley-transcript-test--index (buffer)
  "Return BUFFER's imenu index, as whatever imenu would ask it for."
  (with-current-buffer buffer (funcall imenu-create-index-function)))

(defun parley-transcript-test--at (buffer entry)
  "Return the line of BUFFER that imenu ENTRY points at."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (cdr entry))
      (buffer-substring-no-properties (point) (line-end-position)))))

(ert-deftest parley-transcript-indexes-the-prompts ()
  "The imenu index of the buffer is its prompts and nothing else.

The nine fixture lines hold one prompt that renders, so the index
has one entry: what the agent said, the line its two tool calls
collapsed to and the turns that rendered to nothing are all
absent, and an operator jumping through the index lands only on
his own turns.

The entry points at the prompt itself and not at the blank line
the block it stands in opens with."
  (skip-unless (executable-find "jq"))
  (parley-transcript-test--with-session parley-transcript-test--lines
    (should (parley-transcript-test--settled buffer))
    (with-current-buffer buffer
      (should (eq imenu-create-index-function
                  #'parley-transcript--imenu-index)))
    (let ((index (parley-transcript-test--index buffer)))
      (should (equal (mapcar #'car index) '("what is here")))
      (should (equal (parley-transcript-test--at buffer (car index))
                     "> what is here")))
    ;; And an entry is something imenu can act on, not merely something
    ;; shaped like one: the command itself is what has to land on the
    ;; prompt.
    (with-current-buffer buffer
      (goto-char (point-min))
      (imenu "what is here")
      (should (looking-at-p "> what is here")))))

(ert-deftest parley-transcript-labels-an-entry-with-the-first-line ()
  "An entry is labelled with the first line of its prompt, truncated.

The first line, because that is what the operator will search the
index for; the rest of the message is not in the label and a
count of messages would tell him nothing.

Truncated to `imenu-max-item-length' -- bound low here, to a
length no default could be mistaken for -- which is imenu's own
variable for this and the reason parley does not have one of its
own.

The entries come back in the order the prompts were inserted,
which is the order they stand in the buffer, and the prompt that
was there before these two arrived still points at itself."
  (skip-unless (executable-find "jq"))
  (parley-transcript-test--with-session parley-transcript-test--lines
    (should (parley-transcript-test--settled buffer))
    (let ((imenu-max-item-length 20))
      (parley-transcript-test--write
       file (list (parley-transcript-test--user-turn
                   "first line of it\\nsecond line")
                  (parley-transcript-test--user-turn (make-string 100 ?x))
                  (parley-transcript-test--text-turn "seen")))
      (should (parley-transcript-test--wait
               (lambda () (member "seen"
                                  (parley-transcript-test--shown buffer))))))
    (let* ((index (parley-transcript-test--index buffer))
           (labels (mapcar #'car index)))
      (should (equal (butlast labels) '("what is here" "first line of it")))
      (should (= 20 (length (car (last labels)))))
      (should (string-prefix-p (make-string 15 ?x) (car (last labels))))
      (should (equal (mapcar (lambda (entry)
                               (parley-transcript-test--at buffer entry))
                             index)
                     (list "> what is here"
                           "> first line of it"
                           (concat "> " (make-string 100 ?x))))))))

(ert-deftest parley-transcript-labels-a-prompt-that-opens-blank ()
  "A prompt that opens with a blank line is named and pointed at its first line.

The label and the position have to be the same line.  So the
prompt is trimmed before it is quoted: the block opens with the
first thing the prompt says, the label is that line, and the
entry points at it.

The alternative was to take the prompt's literal first line --
which for this prompt is the empty string, so the entry would be
labelled with nothing and the operator could not search for it at
all."
  (skip-unless (executable-find "jq"))
  (parley-transcript-test--with-session parley-transcript-test--lines
    (should (parley-transcript-test--settled buffer))
    (parley-transcript-test--write
     file (list (parley-transcript-test--user-turn
                 "\\n  \\nfind the bug\\nand fix it")))
    (should (parley-transcript-test--wait
             (lambda () (member "> and fix it"
                                (parley-transcript-test--shown buffer)))))
    ;; The blank lines the prompt opened with are not quoted into the
    ;; buffer, which is what leaves the label and the entry on one line.
    (should-not (member "> " (parley-transcript-test--shown buffer)))
    (let ((entry (assoc "find the bug"
                        (parley-transcript-test--index buffer))))
      (should entry)
      (should (equal (parley-transcript-test--at buffer entry)
                     "> find the bug")))))

(ert-deftest parley-transcript-indexes-a-prompt-sent-from-the-prompt ()
  "A message submitted at the prompt is one entry, pointing at it.

comint put that message in the buffer itself and the guard on the
echo drops the transcript's copy of it when it comes back, so the
render pass never sees the prompts the operator sent from here.
They are also the prompts he is most likely to go looking for, so
they are recorded where they are inserted: as comint takes the
input.

One entry and not two, which is what makes this the echo and not
a second message."
  (skip-unless (executable-find "jq"))
  (parley-transcript-test--with-session parley-transcript-test--lines
    (should (parley-transcript-test--settled buffer))
    (parley-transcript-test--pane buffer "%7")
    (parley-transcript-test--with-tmux
      (parley-transcript-test--submit buffer "ask it something"))
    (parley-transcript-test--write
     file (list (parley-transcript-test--user-turn "ask it something")
                (parley-transcript-test--text-turn "of course")))
    (should (parley-transcript-test--wait
             (lambda () (member "of course"
                                (parley-transcript-test--shown buffer)))))
    (let ((index (parley-transcript-test--index buffer)))
      (should (equal (mapcar #'car index)
                     '("what is here" "ask it something")))
      (should (equal (parley-transcript-test--at buffer (cadr index))
                     "ask it something")))))

(ert-deftest parley-transcript-indexes-a-prompt-typed-below-a-blank-line ()
  "A message submitted at the prompt is entered at the first thing it says.

comint puts what the operator submitted in the buffer exactly as
he wrote it, blank opening line and all, where the render pass
would have trimmed it first.  The entry is labelled with the
first line that says something either way, so that is the line it
has to point at -- an entry on the blank line above would be
pointing at a line the operator cannot see and which nothing in
the buffer holds in place."
  (skip-unless (executable-find "jq"))
  (parley-transcript-test--with-session parley-transcript-test--lines
    (should (parley-transcript-test--settled buffer))
    (parley-transcript-test--pane buffer "%7")
    (parley-transcript-test--with-tmux
      (parley-transcript-test--submit buffer "\n  \nask it something"))
    (let ((entry (assoc "ask it something"
                        (parley-transcript-test--index buffer))))
      (should entry)
      (should (equal (parley-transcript-test--at buffer entry)
                     "ask it something")))))

(ert-deftest parley-transcript-index-survives-a-truncated-buffer ()
  "The top of the buffer going takes its entries and moves the rest.

`comint-truncate-buffer' is how a comint buffer is kept from
growing without end, and it deletes from the top -- as does an
operator killing a stretch of conversation he is done with.

Either moves every prompt below it, which is why an entry holds a
marker rather than the number that marker had when the prompt
arrived; and either deletes the prompts above it, which a marker
does not notice.  A marker in deleted text survives at the
boundary of the deletion, so the entry for a prompt that is no
longer in the buffer would keep its label and point at whatever
text is at that boundary now -- here, at the message after the
one it names.  It has to go instead."
  (skip-unless (executable-find "jq"))
  (parley-transcript-test--with-session parley-transcript-test--lines
    (should (parley-transcript-test--settled buffer))
    (parley-transcript-test--write
     file (list (parley-transcript-test--user-turn "the last word")))
    (should (parley-transcript-test--wait
             (lambda () (member "> the last word"
                                (parley-transcript-test--shown buffer)))))
    (with-current-buffer buffer
      (let ((comint-buffer-maximum-size 4))
        (comint-truncate-buffer))
      (should-not (member "> what is here" (parley-transcript-test--shown buffer))))
    (let ((index (parley-transcript-test--index buffer)))
      (should (equal (mapcar #'car index) '("the last word")))
      (should (equal (parley-transcript-test--at buffer (car index))
                     "> the last word")))))

(ert-deftest parley-transcript-index-does-not-go-stale ()
  "imenu finds a prompt that arrived after it last looked.

`imenu--make-index-alist' remembers the index it built for a
buffer and, left at its default, never builds it again.  A
transcript grows for as long as
its session runs, so the remembered index is the conversation as
it stood when the operator first opened the index -- and this one
costs a `reverse' to rebuild, since it was never parsed out of the
buffer in the first place.

The size at which imenu gives up rebuilding anyway is lifted in
the mode as well, which this cannot show: no fixture here renders
the 600 KB that guard turns on."
  (skip-unless (executable-find "jq"))
  (parley-transcript-test--with-session parley-transcript-test--lines
    (should (parley-transcript-test--settled buffer))
    (with-current-buffer buffer
      (should (equal (mapcar #'car (imenu--make-index-alist))
                     '("what is here"))))
    (parley-transcript-test--write
     file (list (parley-transcript-test--user-turn "and one more thing")))
    (should (parley-transcript-test--wait
             (lambda () (member "> and one more thing"
                                (parley-transcript-test--shown buffer)))))
    (with-current-buffer buffer
      (should (equal (mapcar #'car (imenu--make-index-alist))
                     '("what is here" "and one more thing"))))))

(ert-deftest parley-transcript-indexes-a-prompt-after-a-run ()
  "A prompt that arrives with a rewritten tool run line still points at itself.

The prompt ends the run of two, so the chunk that carries it
takes the line that run collapsed to back out of the buffer and
writes it again above the prompt.  The prompt therefore does not
land at the start of what that chunk rendered, and neither the
take-back nor the line put back in front of it may move the entry
off it."
  (skip-unless (executable-find "jq"))
  (parley-transcript-test--with-session parley-transcript-test--lines
    (should (parley-transcript-test--settled buffer))
    (parley-transcript-test--write
     file (list (parley-transcript-test--tool-turn 2)))
    (should (parley-transcript-test--wait
             (lambda () (member "2 tool calls"
                                (parley-transcript-test--shown buffer)))))
    (parley-transcript-test--write
     file (list (parley-transcript-test--user-turn "after the run")
                (parley-transcript-test--tool-turn 3)))
    (should (parley-transcript-test--wait
             (lambda () (member "3 tool calls"
                                (parley-transcript-test--shown buffer)))))
    (let ((index (parley-transcript-test--index buffer)))
      (should (equal (mapcar #'car index)
                     '("what is here" "after the run")))
      (should (equal (parley-transcript-test--at buffer (cadr index))
                     "> after the run")))))

(provide 'parley-transcript-test)
;;; parley-transcript-test.el ends here
