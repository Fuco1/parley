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

(require 'cl-lib)
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
  "Return a transcript line for an assistant turn that said TEXT.
TEXT is encoded on the way in, so a message with the newlines of
a table or a fence in it is written here as itself."
  (format (concat "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\","
                  "\"content\":[{\"type\":\"text\",\"text\":%s}]}}")
          (json-serialize text)))

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

(ert-deftest parley-transcript-test-opens-a-comint-buffer ()
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

(ert-deftest parley-transcript-test-reads-a-session-when-called-with-none ()
  "Called as a command with nothing in hand, it reads a session first.
It reads it with `parley-read-session', which is the reader the
switcher falls back to as well, so what the minibuffer offers is
a row of that one's making -- the name, the status, the read only
mark, the working directory and the tag.  The record that row
resolves to is what the buffer ends up following."
  (skip-unless (executable-find "jq"))
  (let* ((session (parley-transcript-test--session
                   "test" parley-transcript-test--lines))
         (file (plist-get session :transcript))
         (offered nil)
         (buffer nil))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'parley-sessions) (lambda () (list session)))
                    ((symbol-function 'completing-read)
                     (lambda (_prompt collection &rest _)
                       (setq offered (all-completions "" collection))
                       (car offered))))
            (save-window-excursion (call-interactively #'parley-transcript)))
          (should (equal offered
                         (list (parley-session-row
                                (parley-session-fields session)))))
          (should (= 1 (length (parley-transcript-test--buffers))))
          (setq buffer (car (parley-transcript-test--buffers)))
          (should (eq (buffer-local-value 'parley-transcript-session buffer)
                      session)))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-file file))))

(ert-deftest parley-transcript-test-renders-the-conversation ()
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

(ert-deftest parley-transcript-test-drops-the-tool-payloads ()
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

(ert-deftest parley-transcript-test-follows-the-file ()
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

(ert-deftest parley-transcript-test-kill-stops-the-pipeline ()
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

(ert-deftest parley-transcript-test-names-two-sessions-of-one-name-apart ()
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

(ert-deftest parley-transcript-test-one-buffer-per-session ()
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

(ert-deftest parley-transcript-test-collapses-a-run-of-tool-calls ()
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

(ert-deftest parley-transcript-test-backs-a-turn-to-the-window-edge ()
  "The background on a turn of the operator's runs to the window edge.
A face that sets only `:background' leaves `:extend' unspecified
and the colour stops at the last character of a line, which makes
a turn of short lines a ragged patch rather than the band the eye
finds it by.

What the colour to the edge is painted from is the newline that
ends a line, so the newline the block closes with has to carry
the face as well as the text before it -- a turn faced by its
text alone has every line but its last running to the edge."
  (let ((block (parley-transcript--quote "first line\nsecond")))
    (should (stringp (face-attribute 'parley-user :background nil t)))
    (should (eq t (face-attribute 'parley-user :extend nil t)))
    (should (equal "\n> first line\n> second\n"
                   (substring-no-properties block)))
    (should (eq ?\n (aref block (1- (length block)))))
    (should (eq 'parley-user
                (get-text-property (1- (length block)) 'font-lock-face
                                   block)))))

(ert-deftest parley-transcript-test-marks-a-turn-in-a-face-of-its-own ()
  "The `> ' at the head of a quoted line is faced apart from the turn's text.
The mark is the renderer's and the words after it are the
operator's, so `parley-user-marker' is what the first two
characters of every line of a turn carry and `parley-user' -- the
face that carries the background -- is what the rest of the line
carries, its newline included.

The two faces stand on one band: the marker inherits
`parley-user' before it inherits anything else, so the background
is unbroken across a mark the operator never typed."
  (let ((block (parley-transcript--quote "first line\nsecond")))
    (should (equal (parley-transcript-test--shape block)
                   '(("\n" . nil)
                     ("> " . parley-user-marker)
                     ("first line\n" . parley-user)
                     ("> " . parley-user-marker)
                     ("second\n" . parley-user))))
    (should (stringp (face-attribute 'parley-user :background nil t)))
    (should (equal (face-attribute 'parley-user-marker :background nil t)
                   (face-attribute 'parley-user :background nil t)))))

(ert-deftest parley-transcript-test-fontifies-in-another-buffer ()
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

(ert-deftest parley-transcript-test-marks-the-markup-hidden ()
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

(ert-deftest parley-transcript-test-copies-three-properties-and-no-others ()
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

(ert-deftest parley-transcript-test-mode-hides-the-markdown-markup ()
  "The mode names `markdown-markup' in the buffer's invisibility spec.
The default spec is t, under which any non-nil `invisible' hides,
so naming it changes nothing on its own -- and one
`add-to-invisibility-spec' from anywhere else makes the default a
list this value would not be in."
  (with-temp-buffer
    (parley-transcript-mode)
    (should (memq 'markdown-markup (ensure-list buffer-invisibility-spec)))))

(ert-deftest parley-transcript-test-faces-survive-font-lock ()
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

(ert-deftest parley-transcript-test-hiding-survives-font-lock ()
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

(ert-deftest parley-transcript-test-holds-back-a-split-line ()
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

(ert-deftest parley-transcript-test-shows-what-tail-says ()
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

(defun parley-transcript-test--tail (buffer characters)
  "Return the last CHARACTERS characters of BUFFER, properties and all."
  (with-current-buffer buffer
    (buffer-substring (max (point-min) (- (point-max) characters))
                      (point-max))))

(defun parley-transcript-test--shape (string)
  "Return STRING as the runs of `font-lock-face' over it, as (TEXT . FACE).
The shape of a turn is its text and the face on it, so every
other property is dropped: comint marks what it inserts at the
prompt as a field and the render pass marks nothing, and a
comparison of the two has no business failing over that."
  (let ((runs nil)
        (position 0))
    (while (< position (length string))
      (let ((next (or (next-single-property-change position 'font-lock-face
                                                   string)
                      (length string))))
        (push (cons (substring-no-properties string position next)
                    (get-text-property position 'font-lock-face string))
              runs)
        (setq position next)))
    (nreverse runs)))

(ert-deftest parley-transcript-test-sends-a-line-to-the-pane ()
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

(ert-deftest parley-transcript-test-pastes-input-with-a-newline-in-it ()
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

(defun parley-transcript-test--open-line (buffer)
  "Press S-<return> in BUFFER, as the operator does to open a line.
The binding is looked up rather than the command called directly,
because the binding is half of what is under test."
  (with-current-buffer buffer
    (let ((command (key-binding (kbd "S-<return>"))))
      (should command)
      (call-interactively command))))

(defun parley-transcript-test--zone (buffer)
  "Return the input standing unsent in BUFFER.
That is everything past the process mark, which is where
`comint-send-input' reads the input from."
  (with-current-buffer buffer
    (buffer-substring-no-properties
     (process-mark (get-buffer-process buffer))
     (point-max))))

(defun parley-transcript-test--three-lines (buffer)
  "Stand three lines unsent in BUFFER, opening each with S-<return>."
  (with-current-buffer buffer
    (goto-char (point-max))
    (insert "first line"))
  (parley-transcript-test--open-line buffer)
  (with-current-buffer buffer (insert "second line"))
  (parley-transcript-test--open-line buffer)
  (with-current-buffer buffer (insert "third line")))

(ert-deftest parley-transcript-test-opens-a-line-without-submitting ()
  "S-<return> opens a line in the input zone and submits nothing.
The zone is a block the operator may edit before he sends it, and
the only other way to open a line in it is `comint-accumulate'
under `C-c SPC', which nobody guesses.

Nothing having been sent is asserted by the fake tmux never
having been run at all: its log is written by the program itself,
so the file not existing is the strongest form of that claim."
  (skip-unless (executable-find "jq"))
  (parley-transcript-test--with-session parley-transcript-test--lines
    (should (parley-transcript-test--settled buffer))
    (parley-transcript-test--pane buffer "%7")
    (parley-transcript-test--with-tmux
      (parley-transcript-test--three-lines buffer)
      (should (equal (parley-transcript-test--zone buffer)
                     "first line\nsecond line\nthird line"))
      (should-not (file-exists-p tmux-log)))))

(ert-deftest parley-transcript-test-sends-the-whole-zone-from-inside-it ()
  "The whole input zone goes as one message however point stands in it.
comint is not line oriented on the way out: unsent input carries
no `field' property, so `comint-eol-on-send' moves point to the
end of the buffer and `comint-send-input' hands
`comint-input-sender' everything from the process mark as one
string.  Measured against Emacs 28.2, which is why the send is
driven with point on the second of three lines and two lines of
text standing after it.

One paste and not three sends is what says the three lines
arrived as one string, since a string with a newline in it is
what chooses the paste shape and the text tmux was given on
standard input is that string."
  (skip-unless (executable-find "jq"))
  (parley-transcript-test--with-session parley-transcript-test--lines
    (should (parley-transcript-test--settled buffer))
    (parley-transcript-test--pane buffer "%7")
    (parley-transcript-test--with-tmux
      (parley-transcript-test--three-lines buffer)
      (with-current-buffer buffer
        (goto-char (point-max))
        (search-backward "second line")
        (forward-char 3)
        (should (equal (buffer-substring-no-properties (point) (point-max))
                       "ond line\nthird line"))
        (comint-send-input))
      (let ((calls (parley-transcript-test--calls tmux-log)))
        (should (equal (mapcar #'car calls)
                       '(("load-buffer" "-b" "parley" "-")
                         ("paste-buffer" "-d" "-p" "-b" "parley" "-t" "%7")
                         ("send-keys" "-t" "%7" "Enter"))))
        (should (equal (cdar calls)
                       "first line\nsecond line\nthird line"))))))

(ert-deftest parley-transcript-test-says-a-session-without-a-pane-is-read-only ()
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

(ert-deftest parley-transcript-test-quotes-what-was-submitted-at-the-prompt ()
  "A line submitted at the prompt stands in the buffer as a rendered turn does.
`comint-send-input' inserts what the operator submitted itself,
before the sender runs and without passing the render pass, so
what lands is raw text under `comint-highlight-input'.  The
sender rewrites it into the block a `user' record renders to: the
blank line it opens with, the quote, and `parley-user'.

The transcript then delivers that message twice.  The first is
the echo and is dropped; the second was typed at the pane and is
rendered -- so the buffer ends with the two renderings side by
side and the comparison is one assertion.  Which is what keeps
them from drifting apart, and the literal shape is what keeps
that comparison from being satisfied by two identical wrongs."
  (skip-unless (executable-find "jq"))
  (parley-transcript-test--with-session parley-transcript-test--lines
    (should (parley-transcript-test--settled buffer))
    (parley-transcript-test--pane buffer "%7")
    (parley-transcript-test--with-tmux
      (parley-transcript-test--submit buffer "hello there"))
    (should (equal (parley-transcript-test--shape
                    (parley-transcript-test--tail buffer 15))
                   '(("\n" . nil) ("> " . parley-user-marker)
                     ("hello there\n" . parley-user))))
    (with-current-buffer buffer
      (should-not (text-property-any (point-min) (point-max) 'font-lock-face
                                     'comint-highlight-input)))
    (parley-transcript-test--write
     file (make-list 2 (parley-transcript-test--user-turn "hello there")))
    (should (parley-transcript-test--wait
             (lambda () (= 2 (seq-count (lambda (line) (equal line "> hello there"))
                                        (parley-transcript-test--shown buffer))))))
    (should (equal (parley-transcript-test--shape
                    (parley-transcript-test--tail buffer 30))
                   '(("\n" . nil) ("> " . parley-user-marker)
                     ("hello there\n" . parley-user)
                     ("\n" . nil) ("> " . parley-user-marker)
                     ("hello there\n" . parley-user))))))

(ert-deftest parley-transcript-test-quotes-every-line-of-what-was-submitted ()
  "A submission of several lines is quoted on every one of them.
A `user' record of several lines is, and the two are the same
turn seen from two sides: the block the sender writes for what
the operator submitted here is compared against the block the
render pass writes for the same message coming back."
  (skip-unless (executable-find "jq"))
  (parley-transcript-test--with-session parley-transcript-test--lines
    (should (parley-transcript-test--settled buffer))
    (parley-transcript-test--pane buffer "%7")
    (parley-transcript-test--with-tmux
      (parley-transcript-test--submit buffer "first line\nsecond line"))
    (parley-transcript-test--write
     file (make-list 2 (parley-transcript-test--user-turn
                        "first line\\nsecond line")))
    (should (parley-transcript-test--wait
             (lambda () (= 2 (seq-count (lambda (line) (equal line "> second line"))
                                        (parley-transcript-test--shown buffer))))))
    (should (equal (parley-transcript-test--shape
                    (parley-transcript-test--tail
                     buffer (* 2 (length "\n> first line\n> second line\n"))))
                   '(("\n" . nil)
                     ("> " . parley-user-marker) ("first line\n" . parley-user)
                     ("> " . parley-user-marker) ("second line\n" . parley-user)
                     ("\n" . nil)
                     ("> " . parley-user-marker) ("first line\n" . parley-user)
                     ("> " . parley-user-marker)
                     ("second line\n" . parley-user))))))

(ert-deftest parley-transcript-test-does-not-render-its-own-echo ()
  "A message sent from the prompt is not shown again when it comes back.
The sender has already put it in the buffer, and the session
writes the same message to its transcript seconds later; without
the guard every prompt appears twice.

The turn that follows it is what says the transcript's copy went
by: it is behind the message in the file, so a buffer holding it
is a buffer that has seen the message too."
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
    (should (= 1 (seq-count (lambda (line) (equal line "> hello there"))
                            (parley-transcript-test--shown buffer))))))

(ert-deftest parley-transcript-test-drops-an-echo-however-late-it-comes-back ()
  "Messages submitted at the prompt appear once each, however late they land.
A session that is working holds everything submitted at it until
the turn it is on has finished, so the operator can have more
than one message in flight and the transcript can deliver them
minutes later -- behind the whole of the turn that was running
when they arrived, which is what stands between them here.

Neither the conversation that went by in between nor the time it
took spends the guard: both messages are still this buffer's own
echoes when they land."
  (skip-unless (executable-find "jq"))
  (parley-transcript-test--with-session parley-transcript-test--lines
    (should (parley-transcript-test--settled buffer))
    (parley-transcript-test--pane buffer "%7")
    (parley-transcript-test--with-tmux
      (parley-transcript-test--submit buffer "first question")
      (parley-transcript-test--submit buffer "second question"))
    (parley-transcript-test--write
     file (list (parley-transcript-test--tool-turn 3)
                (parley-transcript-test--text-turn "still working")
                (parley-transcript-test--user-turn "first question")
                (parley-transcript-test--user-turn "second question")
                (parley-transcript-test--text-turn "both answered")))
    (should (parley-transcript-test--wait
             (lambda () (member "both answered"
                                (parley-transcript-test--shown buffer)))))
    (let ((shown (parley-transcript-test--shown buffer)))
      (dolist (quoted '("> first question" "> second question"))
        (should (= 1 (seq-count (lambda (line) (equal line quoted)) shown)))))))

(ert-deftest parley-transcript-test-drops-one-echo-for-each-copy-submitted ()
  "The same message submitted twice is dropped twice when both come back.
Each send stands on its own, so the first copy to arrive spends
one of them and the second spends the other.  A guard that took
every entry of that text at the first copy would have nothing
left for the second, and would show it under the two the buffer
already holds."
  (skip-unless (executable-find "jq"))
  (parley-transcript-test--with-session parley-transcript-test--lines
    (should (parley-transcript-test--settled buffer))
    (parley-transcript-test--pane buffer "%7")
    (parley-transcript-test--with-tmux
      (parley-transcript-test--submit buffer "say it again")
      (parley-transcript-test--submit buffer "say it again"))
    (parley-transcript-test--write
     file (append (make-list 2 (parley-transcript-test--user-turn
                                "say it again"))
                  (list (parley-transcript-test--text-turn "twice then"))))
    (should (parley-transcript-test--wait
             (lambda () (member "twice then"
                                (parley-transcript-test--shown buffer)))))
    (should (= 2 (seq-count (lambda (line) (equal line "> say it again"))
                            (parley-transcript-test--shown buffer))))))

(ert-deftest parley-transcript-test-renders-what-was-typed-at-the-pane ()
  "A user message parley did not send is rendered, guard or no guard.
The operator can type at the pane instead, and what he says there
has to reach the buffer like everything else.

The guard is spent on the first message that matches it, which is
what makes that true even of a message identical to the one just
sent: the first `hello there' here is the echo and is dropped,
the second was typed at the pane and is shown -- beside the one
the sender wrote when it was submitted, which is why there are
two of them and not one."
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
    (should (= 2 (seq-count (lambda (line) (equal line "> hello there"))
                            (parley-transcript-test--shown buffer))))))

(defun parley-transcript-test--after (buffer text)
  "Return the position in BUFFER just past the first TEXT in it.
That is the end of the rendered line, where a reader's point
naturally stands and where the block carries no face of its own."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (should (search-forward text nil t))
      (point))))

(defun parley-transcript-test--resubmit (buffer position)
  "Press RET in BUFFER with point at POSITION, as the operator sends a turn again.
The binding is looked up rather than `comint-send-input' called
directly, because RET is how he reaches this at all."
  (with-current-buffer buffer
    (goto-char position)
    (call-interactively (key-binding (kbd "RET")))))

(ert-deftest parley-transcript-test-sends-a-past-turn-without-the-quote ()
  "RET on a turn the operator took sends it again without the renderer's quote.
`comint-get-old-input-default' branches on the `field' property,
and `comint-output-filter' puts `field output' on everything it
inserts -- so over a turn the transcript delivered it takes the
line whole.  Measured on Emacs 28.2 over this fixture with point
in the rendered `what is here', it returns \"> what is here\",
and the session is asked a question opening with a quote mark.

One `send-keys' and not a paste is also what says no newline came
with it, which is the shape the other branch returns."
  (skip-unless (executable-find "jq"))
  (parley-transcript-test--with-session parley-transcript-test--lines
    (should (parley-transcript-test--settled buffer))
    (parley-transcript-test--pane buffer "%7")
    (parley-transcript-test--with-tmux
      (parley-transcript-test--resubmit
       buffer (parley-transcript-test--after buffer "what is here"))
      (should (equal (mapcar #'car (parley-transcript-test--calls tmux-log))
                     '(("send-keys" "-t" "%7" "-l" "--" "what is here")
                       ("send-keys" "-t" "%7" "Enter")))))))

(ert-deftest parley-transcript-test-sends-every-line-of-a-past-turn ()
  "RET on a turn of several lines sends all of them and not the one under point.
The operator means the prompt when he sends one again, and both
of comint's default branches are line oriented.  Point stands on
the second of three lines, and one paste rather than three sends
is what says the three reached the pane as one message."
  (skip-unless (executable-find "jq"))
  (parley-transcript-test--with-session parley-transcript-test--lines
    (should (parley-transcript-test--settled buffer))
    (parley-transcript-test--pane buffer "%7")
    (parley-transcript-test--write
     file (list (parley-transcript-test--user-turn
                 "alpha line\\nbeta line\\ngamma line")))
    (should (parley-transcript-test--wait
             (lambda () (member "> gamma line"
                                (parley-transcript-test--shown buffer)))))
    (parley-transcript-test--with-tmux
      (parley-transcript-test--resubmit
       buffer (parley-transcript-test--after buffer "beta line"))
      (let ((calls (parley-transcript-test--calls tmux-log)))
        (should (equal (mapcar #'car calls)
                       '(("load-buffer" "-b" "parley" "-")
                         ("paste-buffer" "-d" "-p" "-b" "parley" "-t" "%7")
                         ("send-keys" "-t" "%7" "Enter"))))
        (should (equal (cdar calls)
                       "alpha line\nbeta line\ngamma line"))))))

(ert-deftest parley-transcript-test-sends-a-turn-submitted-here-alike ()
  "The two doors a turn reaches the buffer by send the same text again.
A turn submitted here carries no `field' property at all:
`parley-transcript--render-input' deleted the text comint had
just put `field input' on and inserted a block that inherits
nothing.  So `comint-get-old-input-default' takes its other
branch and returns the whole unfielded run -- measured on Emacs
28.2 over this buffer, \"\\n> what is here\\n\" rather than the
turn.

The same text is sent through both doors and both positions are
taken before either is resubmitted, so the two calls compared are
the delivered turn and the submitted one and not a resubmission
of one of them."
  (skip-unless (executable-find "jq"))
  (parley-transcript-test--with-session parley-transcript-test--lines
    (should (parley-transcript-test--settled buffer))
    (parley-transcript-test--pane buffer "%7")
    (parley-transcript-test--with-tmux
      (parley-transcript-test--submit buffer "what is here"))
    (let ((delivered (parley-transcript-test--after buffer "what is here"))
          (submitted (with-current-buffer buffer
                       (goto-char (point-max))
                       (should (search-backward "what is here" nil t))
                       (+ (point) 3)))
          (first nil)
          (second nil))
      (parley-transcript-test--with-tmux
        (parley-transcript-test--resubmit buffer delivered)
        (setq first (parley-transcript-test--calls tmux-log)))
      (parley-transcript-test--with-tmux
        (parley-transcript-test--resubmit buffer submitted)
        (setq second (parley-transcript-test--calls tmux-log)))
      (should (equal (mapcar #'car first)
                     '(("send-keys" "-t" "%7" "-l" "--" "what is here")
                       ("send-keys" "-t" "%7" "Enter"))))
      (should (equal first second)))))

(ert-deftest parley-transcript-test-refuses-a-turn-that-is-not-the-operators ()
  "RET on an assistant turn or on a tool-run line sends nothing and says why.
Neither is the operator's to send again, and a line of somebody
else's markdown typed into a live session is worse than an error
saying nothing went.

Nothing having been sent is asserted by the fake tmux never
having run at all: its log is written by the program itself, so
the file not existing is the strongest form of that claim.  The
buffer standing untouched is the rest of it, since comint inserts
what this hands back at the prompt before the sender ever sees
it."
  (skip-unless (executable-find "jq"))
  (parley-transcript-test--with-session parley-transcript-test--lines
    (should (parley-transcript-test--settled buffer))
    (parley-transcript-test--pane buffer "%7")
    (let ((before (parley-transcript-test--shown buffer)))
      (parley-transcript-test--with-tmux
        (dolist (line '("Let me look." "2 tool calls"))
          (let ((signalled (should-error
                            (parley-transcript-test--resubmit
                             buffer (parley-transcript-test--after buffer line))
                            :type 'user-error)))
            (should (string-match-p "sent again" (cadr signalled)))))
        (should-not (file-exists-p tmux-log)))
      (should (equal (parley-transcript-test--shown buffer) before)))))


(defun parley-transcript-test--marked-zone (buffer)
  "Return the overlay marking the input zone of BUFFER, nil if it is unmarked.
It is looked up by its face and not in the variable holding it,
because an overlay the buffer has lost is one the operator cannot
see either.  Marking the zone is standing over the whole of it:
from the process mark, which is where `comint-send-input' reads
what it sends from, to the end of the buffer."
  (with-current-buffer buffer
    (let ((overlay (seq-find (lambda (overlay)
                               (eq (overlay-get overlay 'face) 'parley-input))
                             (overlays-in (point-min) (point-max)))))
      (and overlay
           (= (overlay-start overlay)
              (marker-position (process-mark (get-buffer-process buffer))))
           (= (overlay-end overlay) (point-max))
           overlay))))

(ert-deftest parley-transcript-test-marks-the-input-zone-with-nothing-in-it ()
  "The zone the operator types in is marked before he has typed anything.
Nothing else in the buffer says where typing begins: the pipeline
emits no prompt, so his text is the tail of a buffer whose tail
is otherwise conversation -- and an empty zone is when he most
needs to see where it is.  A text property cannot mark it, since
there is no text under it to carry one; an overlay has a position
either way, and this one is empty.

What the overlay shows is shown and is not in the buffer, which
is what the two strings assert: the mark stands before the zone
and the space that carries the band across its last line stands
after it."
  (skip-unless (executable-find "jq"))
  (parley-transcript-test--with-session parley-transcript-test--lines
    (should (parley-transcript-test--settled buffer))
    (let ((overlay (parley-transcript-test--marked-zone buffer)))
      (should overlay)
      (should (equal "" (parley-transcript-test--zone buffer)))
      (should (= (overlay-start overlay) (overlay-end overlay)))
      (should (equal (overlay-get overlay 'before-string)
                     parley-transcript--input-marker))
      (should (equal (overlay-get overlay 'after-string)
                     parley-transcript--input-fill)))))

(ert-deftest parley-transcript-test-marks-the-input-zone-before-anything-arrives ()
  "A session that has said nothing yet still shows the operator where to type.
Its transcript is there and holds nothing, so the pipeline writes
nothing and no output filter runs at all.  The zone is marked
when the process is started as well as after every output, or the
first message of a session would be typed into an empty buffer
with nothing in it to type at."
  (skip-unless (executable-find "jq"))
  (parley-transcript-test--with-session nil
    (with-current-buffer buffer
      (should (= (point-min) (point-max))))
    (should (parley-transcript-test--marked-zone buffer))))

(ert-deftest parley-transcript-test-marks-the-input-zone-again-after-output ()
  "Output arriving moves the process mark, and the zone is marked at the new one.
The transcript is followed, so output arrives while the operator
is typing: comint inserts it at the process mark and moves the
mark past what it inserted, which pushes the zone down the buffer
every time.  The overlay starts at that mark and has to be put
back at it.

What he had typed is still the zone and still all of it.  The
output went in in front of it, so an overlay left where it was
would hold the message the session sent as well as the message he
is writing."
  (skip-unless (executable-find "jq"))
  (parley-transcript-test--with-session parley-transcript-test--lines
    (should (parley-transcript-test--settled buffer))
    (with-current-buffer buffer
      (goto-char (point-max))
      (insert "half a thought"))
    (let ((mark (marker-position (process-mark (get-buffer-process buffer)))))
      (parley-transcript-test--write
       file (list (parley-transcript-test--text-turn "a late answer")))
      (should (parley-transcript-test--wait
               (lambda () (member "a late answer"
                                  (parley-transcript-test--shown buffer)))))
      (should (> (marker-position (process-mark (get-buffer-process buffer)))
                 mark))
      (should (parley-transcript-test--marked-zone buffer))
      (should (equal "half a thought" (parley-transcript-test--zone buffer))))))

(ert-deftest parley-transcript-test-sends-the-zone-and-not-what-marks-it ()
  "What is submitted from a marked zone is what was typed and nothing else.
`comint-send-input' sends the buffer text from the process mark
to the end of the field, so anything the mark or the band put
into the buffer after that mark would be typed into the session.
Neither puts anything there: one is an overlay's `before-string'
and the other its face and its `after-string'.

The block the send leaves behind moves the process mark again,
and the zone is marked at that one -- empty, because what stood
in it has gone to the pane."
  (skip-unless (executable-find "jq"))
  (parley-transcript-test--with-session parley-transcript-test--lines
    (should (parley-transcript-test--settled buffer))
    (parley-transcript-test--pane buffer "%7")
    (should (parley-transcript-test--marked-zone buffer))
    (parley-transcript-test--with-tmux
      (parley-transcript-test--submit buffer "hello there")
      (should (equal (mapcar #'car (parley-transcript-test--calls tmux-log))
                     '(("send-keys" "-t" "%7" "-l" "--" "hello there")
                       ("send-keys" "-t" "%7" "Enter"))))
      (should (parley-transcript-test--marked-zone buffer))
      (should (equal "" (parley-transcript-test--zone buffer))))))

(ert-deftest parley-transcript-test-bands-the-input-zone-to-the-window-edge ()
  "The band under the input zone runs to the window edge on every line of it.
`:extend' is what carries a background past the last character of
a line, and it is painted from the newline that ends the line.
Every line of the zone ends in one except the last, which is the
last line of the buffer: that one is carried by a space stretched
to the right edge instead, and `cursor' on it is what keeps point
drawn at the head of that space rather than at the far end of it.

The mark at the head of the zone stands on the same band, because
it inherits the face that carries it before it inherits anything
else."
  (should (stringp (face-attribute 'parley-input :background nil t)))
  (should (eq t (face-attribute 'parley-input :extend nil t)))
  (should (equal '(space :align-to right)
                 (get-text-property 0 'display parley-transcript--input-fill)))
  (should (eq 'parley-input
              (get-text-property 0 'face parley-transcript--input-fill)))
  (should (get-text-property 0 'cursor parley-transcript--input-fill))
  (should (equal (face-attribute 'parley-input-marker :background nil t)
                 (face-attribute 'parley-input :background nil t))))


;;; Aligning a table

(defconst parley-transcript-test--table
  (concat "| name | what it does |\n"
          "|---|---|\n"
          "| a | short |\n"
          "| bbbbbb | a much longer cell |")
  "A table as an agent writes one, whose columns do not line up.
Its aligned form is 31 columns wide and the text itself is 30, so
a window of 20 has room for neither -- and wrapped it comes to
exactly 20, because no cell of it holds a word longer than the
column it is then given.")

(defconst parley-transcript-test--prose
  "a cell of prose long enough that aligning the table runs it past the window"
  "A cell that takes the table it stands in past any ordinary window.
Every word of it is short, so it is a cell wrapping can narrow as
far as it is asked to.")

(defconst parley-transcript-test--wide
  (concat "| id | what it does |\n"
          "|---|---|\n"
          "| 7 | " parley-transcript-test--prose " |\n"
          "| 8 | short |")
  "A table one cell of prose takes to 84 columns aligned.")

(defun parley-transcript-test--tables (buffer)
  "Return the overlays over a table in BUFFER, in buffer order."
  (with-current-buffer buffer
    (sort (seq-filter (lambda (overlay) (overlay-get overlay 'parley-table))
                      (overlays-in (point-min) (point-max)))
          (lambda (one other) (< (overlay-start one) (overlay-start other))))))

(defun parley-transcript-test--under (overlay)
  "Return the buffer text OVERLAY covers, which is not what it shows."
  (with-current-buffer (overlay-buffer overlay)
    (buffer-substring-no-properties (overlay-start overlay)
                                    (overlay-end overlay))))

(defun parley-transcript-test--bars (text)
  "Return the columns the `|' of TEXT stand in, one list per line.
A table is aligned when every line of it answers this the same
way, and the fixture is the case that says a test of it can
fail: the table an agent wrote answers it differently on every
line."
  (mapcar (lambda (line)
            (let ((columns nil)
                  (position 0))
              (while (setq position (string-search "|" line position))
                (push position columns)
                (setq position (1+ position)))
              (nreverse columns)))
          (split-string text "\n")))

(defun parley-transcript-test--cells (line)
  "Return the cells of the aligned table LINE, each without its padding.
The bars are read off the line itself rather than with
markdown-mode's parser, which is the parser the wrapping is
computed with: what this answers is what the operator sees."
  (mapcar #'string-trim (butlast (cdr (split-string line "|")))))

(ert-deftest parley-transcript-test-aligns-a-table-over-the-text-as-written ()
  "A table is shown with its columns aligned, over the text the transcript delivered.

Both halves are what the overlay is for.  What it shows lines the
columns up; what the buffer holds under it is the table the agent
wrote, character for character -- so a rendering that left the
text alone fails the alignment and one that rewrote the buffer
fails the text.

The face is asserted on the string the overlay shows and not on
the text under it, because what a `display' property shows are
the string's own properties: the `font-lock-face' markdown-mode
left on the buffer text never reaches the screen through one.

Two turns, each with a table in it, because where a table is is
an offset into what the render pass returned: the second table's
is one the length of the first turn's block into that string, and
a pass that forgot to count the turns before it would put the
overlay over the wrong text and pass everything else here.

The rows of that second one end without the closing bar the first
one's have, which is the other way an agent writes a table, and
its last cell is one column wide -- which is the cell the aligner
drops when no bar closes it, unless the copy it is given has that
bar put back.  Every cell of it is read out of what is shown for
that reason, and each of those one-column cells is a character
the rest of the table does not hold."
  (skip-unless (executable-find "jq"))
  (let ((other (concat "| id | flag\n"
                       "|---|---\n"
                       "| 1 | x\n"
                       "| 22 | q")))
    (parley-transcript-test--with-session
        (list (parley-transcript-test--text-turn
               (concat "Here it is:\n\n" parley-transcript-test--table
                       "\n\nand that is all"))
              (parley-transcript-test--text-turn (concat "And again:\n\n" other)))
      (let* ((overlays (parley-transcript-test--wait
                        (lambda ()
                          (let ((found (parley-transcript-test--tables buffer)))
                            (and (= 2 (length found)) found)))))
             (shown (mapcar (lambda (overlay) (overlay-get overlay 'display))
                            overlays)))
        (should (= 2 (length overlays)))
        (should (equal (list parley-transcript-test--table other)
                       (mapcar #'parley-transcript-test--under overlays)))
        (should (string-search parley-transcript-test--table
                               (with-current-buffer buffer
                                 (buffer-substring-no-properties (point-min)
                                                                 (point-max)))))
        (dolist (form shown)
          (should (stringp form))
          (should (= 1 (length (seq-uniq (parley-transcript-test--bars form)))))
          (should (eq 'markdown-table-face (get-text-property 0 'face form))))
        (should (< 1 (length (seq-uniq (parley-transcript-test--bars
                                        parley-transcript-test--table)))))
        (dolist (cell '("name" "what it does" "bbbbbb" "a much longer cell"))
          (should (string-search cell (car shown))))
        (dolist (cell '("id" "flag" "1" "x" "22" "q"))
          (should (string-search cell (cadr shown))))))))

(ert-deftest parley-transcript-test-aligns-again-when-the-window-changes-width ()
  "What is shown over a table follows the width of the window, and the text does not.

A window with no room for the aligned form gets the table wrapped
into it instead -- more lines than the agent wrote and the same
columns throughout -- and the unwrapped form comes back when the
window has room for it again.  That the rendering can answer a
resize at all is why it is an overlay and not text written once
on the way in, and a wrap costs nothing to come back from because
what both forms are computed from is the text under the overlay,
which is the table the agent wrote through all of it.

Batch Emacs never redisplays and this hook runs during redisplay,
so it is run here by hand.  What is under test is what the hook
does; that `parley-transcript-mode' puts it on the buffer's own
value is what makes it the hook Emacs will call."
  (skip-unless (executable-find "jq"))
  (let ((columns (frame-width)))
    (unwind-protect
        (parley-transcript-test--with-session
            (list (parley-transcript-test--text-turn parley-transcript-test--table))
          (let ((overlay (car (parley-transcript-test--wait
                               (lambda () (parley-transcript-test--tables buffer)))))
                (aligned nil))
            (save-window-excursion
              (set-window-buffer (selected-window) buffer)
              (set-frame-width (selected-frame) 100)
              (with-current-buffer buffer
                (run-hooks 'window-configuration-change-hook))
              (setq aligned (overlay-get overlay 'display))
              (should (stringp aligned))
              (should (= 1 (length (seq-uniq
                                    (parley-transcript-test--bars aligned)))))
              (set-frame-width (selected-frame) 20)
              (with-current-buffer buffer
                (run-hooks 'window-configuration-change-hook))
              (let ((wrapped (overlay-get overlay 'display)))
                (should (stringp wrapped))
                (should (>= 20 (parley-transcript--columns wrapped)))
                (should (< (length (split-string aligned "\n"))
                           (length (split-string wrapped "\n"))))
                (should (= 1 (length (seq-uniq
                                      (parley-transcript-test--bars wrapped))))))
              (set-frame-width (selected-frame) 100)
              (with-current-buffer buffer
                (run-hooks 'window-configuration-change-hook))
              (should (equal aligned (overlay-get overlay 'display))))
            (should (equal parley-transcript-test--table
                           (parley-transcript-test--under overlay)))))
      (set-frame-width (selected-frame) columns))))

(ert-deftest parley-transcript-test-wraps-a-cell-of-prose-into-the-width ()
  "A table a cell of prose takes past its width is wrapped until it fits.

Aligning a wide table only makes it wider, so the cell is broken
over as many lines as it takes and the row grows to match, which
is the only thing that makes a table of prose fit at all.

Every line of the wrapped row stands in the columns the rest of
the table stands in, and the cells beside the prose stand in
theirs: the id on the first line of the row with nothing under
it, and the row after the wrapped one still a row of two cells.

What a wrap may not do is lose a word or invent one, so the lines
of the prose are read back out of their column and joined -- that
is the cell the agent wrote.  The same table aligned for a width
it fits in is asserted to be wider than this one, so a wrap that
did nothing at all fails here rather than passing for having had
nothing to do."
  (let* ((width 40)
         (form (parley-transcript--aligned parley-transcript-test--wide width))
         (rows (mapcar #'parley-transcript-test--cells (split-string form "\n")))
         (start (seq-position (mapcar #'car rows) "7"))
         (row (cons (nth start rows)
                    (seq-take-while (lambda (cells) (equal "" (car cells)))
                                    (nthcdr (1+ start) rows)))))
    (should (< width (parley-transcript--columns
                      (parley-transcript--aligned parley-transcript-test--wide 200))))
    (should (>= width (parley-transcript--columns form)))
    (should (= 1 (length (seq-uniq (parley-transcript-test--bars form)))))
    (should (< 1 (length row)))
    (should (equal parley-transcript-test--prose
                   (string-join (mapcar #'cadr row) " ")))
    (should (equal '("8" "short") (car (last rows))))))

(ert-deftest parley-transcript-test-leaves-a-table-nothing-narrows-too-wide ()
  "A cell no wrapping can narrow leaves the table wider than the width.

A word is never broken to make a table fit.  A URL the operator
cannot read back is worse than a table that runs past the edge of
the window, and the table that runs past it is still one he can
read, so the column that word stands in is a floor under the
whole table.

Everything beside it gives what it can all the same, which is
what the table being narrower than its unwrapped form says: the
prose wrapped, and what is left over the width is the word."
  (let* ((url "https://example.invalid/a/very/long/path/that/will/not/break")
         (text (concat "| link | what it does |\n|---|---|\n| " url " | "
                       parley-transcript-test--prose " |"))
         (form (parley-transcript--aligned text 40)))
    (should form)
    (should (< 40 (parley-transcript--columns form)))
    (should (seq-find (lambda (line) (string-search url line))
                      (split-string form "\n")))
    (should (< (parley-transcript--columns form)
               (parley-transcript--columns (parley-transcript--aligned text 200))))
    (should (= 1 (length (seq-uniq (parley-transcript-test--bars form)))))))

(ert-deftest parley-transcript-test-shows-a-table-with-no-data-row-as-written ()
  "A table of nothing but delimiter rows is shown as the agent wrote it.

There is nothing in it to line up, and `markdown-table-align'
raises `Empty table' rather than saying so: it is the cells it
formats from, and a delimiter row contributes none.  Nothing may
come back out of here but the aligned form or nil, because this
is called from an output filter and from a hook run during
redisplay, where a signal is a conversation that stops rendering
and says nothing about why.

A delimiter row is what markdown-mode calls one and is asked with
markdown-mode's own predicate, because the caller that raises
uses that one: `| --- | --- |' is a delimiter row with a space
after the bar, which reads as a row of data to anything matching
on the character after it.

The table with rows in it is aligned in the same breath, so a
guard tightened until nothing at all is aligned fails here."
  (dolist (text '("| --- | --- |" "|---|---|" "| :-: | --: |\n|---|---|"))
    (should-not (parley-transcript--aligned text 80)))
  (should (parley-transcript--aligned parley-transcript-test--table 80)))

(ert-deftest parley-transcript-test-aligns-a-table-whose-rows-end-without-a-bar ()
  "A table whose rows leave the closing bar off is aligned, and all of it is there.

The outer bar at the end of a row is optional, which is how an
agent writes a table by hand, and
`markdown--table-line-to-columns' drops a last cell of one column
when no bar closes it -- so what is aligned is a copy with those
bars put back.  Every cell of the text has to stand in the
aligned form, because a display over a table that lost a cell is
a cell of the agent's the operator cannot read at all.

The last of them is a table of one column, where the cell that
would be dropped is the only cell there is."
  (dolist (case '(("| a | b |\n|---|---|\n| 1 | 2" . ("a" "b" "1" "2"))
                  ("| name | note |\n|---|---|\n| x | a longer cell"
                   . ("name" "note" "x" "a longer cell"))
                  ("| a\n|---\n| 1" . ("a" "1"))))
    (let ((aligned (parley-transcript--aligned (car case) 80)))
      (should aligned)
      (should (= 1 (length (seq-uniq (parley-transcript-test--bars aligned)))))
      (should (= (length (split-string (car case) "\n"))
                 (length (split-string aligned "\n"))))
      (dolist (cell (cdr case))
        (should (string-search cell aligned))))))

(ert-deftest parley-transcript-test-shows-a-table-an-aligner-would-cut-as-written ()
  "A table whose aligned form does not say what the text says is shown as written.

Which markdown-mode is under the buffer is the operator's
business, and an aligner that dropped a cell would put a display
over the table showing text the agent never wrote.  The aligner
is stood in for here because the one in this tree keeps every
cell of a table the closing bars were put back on, and what is
under test is what becomes of a result that does not.

An aligner that leaves the table alone is stood in the same way,
so that what refuses the first is the cell it dropped and not the
standing in."
  (let ((text "| a | b |\n|---|---|\n| 1 | 2 |"))
    (cl-letf (((symbol-function 'markdown-table-align)
               (lambda () (erase-buffer) (insert "| a | b |\n|---|---|\n| 1 |"))))
      (should-not (parley-transcript--aligned text 80)))
    (cl-letf (((symbol-function 'markdown-table-align) #'ignore))
      (should (parley-transcript--aligned text 80)))))

(ert-deftest parley-transcript-test-leaves-a-table-in-a-fence-as-written ()
  "A table inside a fenced code block is shown as the agent wrote it.

It is not a table, it is text he is showing, and aligning it
would rewrite what he quoted.  The difference is markdown-mode's
syntax over the fence and is known in the buffer the render pass
fontifies in -- the transcript buffer holds no markdown syntax at
all, so a pass over the finished text could not tell the two
apart.

The message holds the same table twice, fenced and not, so a
render pass that found no table anywhere fails the first
assertion rather than passing this test by having done nothing."
  (skip-unless (executable-find "jq"))
  (parley-transcript-test--with-session
      (list (parley-transcript-test--text-turn
             (concat parley-transcript-test--table
                     "\n\nwhich is written:\n\n```\n"
                     parley-transcript-test--table "\n```")))
    (let ((overlays (parley-transcript-test--wait
                     (lambda () (parley-transcript-test--tables buffer)))))
      (should (= 1 (length overlays)))
      (should (equal parley-transcript-test--table
                     (parley-transcript-test--under (car overlays))))
      (with-current-buffer buffer
        (save-excursion
          (goto-char (point-min))
          (should (search-forward parley-transcript-test--table nil t))
          (should (search-forward parley-transcript-test--table nil t))
          (should-not (seq-find (lambda (overlay)
                                  (overlay-get overlay 'parley-table))
                                (overlays-in (match-beginning 0)
                                             (match-end 0)))))))))


;;; The imenu index

(defun parley-transcript-test--index (buffer)
  "Return BUFFER's imenu index, as whatever imenu would ask it for."
  (with-current-buffer buffer (funcall imenu-create-index-function)))

(defun parley-transcript-test--index-prompts (text n)
  "Record N prompts of TEXT in the current buffer's index, one line each.
The way the render pass records them, which is all the index
needs and is what lets a test of the index start no pipeline."
  (dotimes (_ n)
    (let ((start (point)))
      (insert text "\n")
      (parley-transcript--index-prompt text start))))

(defun parley-transcript-test--at (buffer entry)
  "Return the line of BUFFER that imenu ENTRY points at."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (cdr entry))
      (buffer-substring-no-properties (point) (line-end-position)))))

(ert-deftest parley-transcript-test-indexes-the-prompts ()
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

(ert-deftest parley-transcript-test-labels-an-entry-with-the-first-line ()
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

(ert-deftest parley-transcript-test-tells-two-prompts-of-one-line-apart ()
  "Two prompts with one first line get a name each, and both can be reached.

`imenu' carries what the operator picked back to an entry with
`assoc' on its name, so two entries under one name are one entry
he can act on: the second is in the index, is offered once, and
answers with the first.  The later of the two is numbered `<2>'
instead, the way Emacs tells two buffers of one name apart, and
the first keeps the name he was going to search for.

`continue' is not a contrived prompt.  A long conversation is
full of it, of `yes', and of the same question asked twice, which
are exactly the short prompts an index is navigated by.

The command itself is what has to land on each of the three,
because `assoc' is the whole of the resolution and an index that
merely looks right says nothing about it.  The prompts differ on
their second line, which is how this can tell which of them it
arrived at.

The numbering counts the entries that share the label and not the
messages before the prompt: nine lines of fixture and a prompt of
their own stand in front of the first `continue', and it is still
`continue'.

No length limit is in force over the labels, which is what lets
them be read whole here.  What a limit does to the number is the
next two tests."
  (skip-unless (executable-find "jq"))
  (parley-transcript-test--with-session parley-transcript-test--lines
    (should (parley-transcript-test--settled buffer))
    (parley-transcript-test--write
     file (list (parley-transcript-test--user-turn "continue\\nwith the first")
                (parley-transcript-test--user-turn "continue\\nwith the second")
                (parley-transcript-test--user-turn "continue\\nwith the third")))
    (should (parley-transcript-test--wait
             (lambda () (member "> with the third"
                                (parley-transcript-test--shown buffer)))))
    (let ((imenu-max-item-length nil))
      (should (equal (mapcar #'car (parley-transcript-test--index buffer))
                     '("what is here" "continue" "continue<2>" "continue<3>"))))
    (with-current-buffer buffer
      (dolist (entry '(("continue" . "> with the first")
                       ("continue<2>" . "> with the second")
                       ("continue<3>" . "> with the third")))
        (goto-char (point-min))
        (imenu (car entry))
        (should (looking-at-p "> continue"))
        (forward-line 1)
        (should (looking-at-p (regexp-quote (cdr entry))))))))

(ert-deftest parley-transcript-test-renames-a-first-line-shaped-like-a-number ()
  "A first line that is itself a suffix is renamed like any other duplicate.

The index is built in one pass over the prompts in buffer order
and the number is read off the entries already in it, so a prompt
whose first line is `foo<2>' collides with the `foo<2>' an
earlier duplicate of `foo' was handed and is renamed
`foo<2><2>'.  The distinct first lines are not reserved in a pass
of their own, which would leave that one bare.

`generate-new-buffer-name' is what that is the transcript's copy
of, and it is asked here rather than quoted: four buffers made in
the same order under the same four names take the same four
names, so the two rules are one rule and not two that happen to
agree on the fixtures above.

No length limit is in force, because what the limit does to a
number is the next two tests and it would cut these names short
of the point."
  (let ((names '("foo" "foo" "foo<2>" "foo"))
        (buffers nil)
        (emacs nil)
        (parley nil))
    (unwind-protect
        (setq emacs (mapcar (lambda (name)
                              (let ((buffer (generate-new-buffer name)))
                                (push buffer buffers)
                                (buffer-name buffer)))
                            names))
      (mapc #'kill-buffer buffers))
    (with-temp-buffer
      (parley-transcript-mode)
      (let ((imenu-max-item-length nil))
        (dolist (name names)
          (parley-transcript-test--index-prompts name 1))
        (setq parley (mapcar #'car (parley-transcript--imenu-index)))))
    (should (equal parley '("foo" "foo<2>" "foo<2><2>" "foo<3>")))
    (should (equal parley emacs))))

(ert-deftest parley-transcript-test-numbers-a-label-inside-the-length-limit ()
  "The number on a label at the limit does not push itself off the end.

`imenu--truncate-items' cuts every label to
`imenu-max-item-length' with `substring', and it does so after
`imenu-create-index-function' has returned -- so a `<2>' hung off
a label already that long is cut straight back off, leaving two
entries under one name again and the second of them out of reach.
The label gives up the characters the number needs instead.

Two prompts whose first line is longer than the limit are what
shows it, and `imenu--make-index-alist' is what is asked, because
imenu's own truncation is the thing under test and the index
function returns before it runs.

The limit is bound low here, to a length no default could be
mistaken for.  It has to stay bound for the jump as well: the
labels were truncated to it when the prompts arrived, and imenu
rebuilds the index on every look."
  (skip-unless (executable-find "jq"))
  (parley-transcript-test--with-session parley-transcript-test--lines
    (should (parley-transcript-test--settled buffer))
    (let ((imenu-max-item-length 20))
      (parley-transcript-test--write
       file (list (parley-transcript-test--user-turn
                   (concat (make-string 30 ?x) "\\nthe first of them"))
                  (parley-transcript-test--user-turn
                   (concat (make-string 30 ?x) "\\nthe second of them"))))
      (should (parley-transcript-test--wait
               (lambda () (member "> the second of them"
                                  (parley-transcript-test--shown buffer)))))
      (with-current-buffer buffer
        (let ((labels (mapcar #'car (imenu--make-index-alist))))
          (should (= 3 (length labels)))
          (should (= 3 (length (delete-dups (copy-sequence labels)))))
          (should (seq-every-p (lambda (label) (<= (length label) 20)) labels))
          (should (string-suffix-p "<2>" (car (last labels))))
          (goto-char (point-min))
          (imenu (car (last labels)))
          (forward-line 1)
          (should (looking-at-p "> the second of them")))))))

(ert-deftest parley-transcript-test-numbers-a-label-a-short-limit-crowds-out ()
  "A number that fills the limit takes the label's place rather than its own.

`imenu-max-item-length' can be shorter than the number needs the
label to give up.  A label that kept so much as its first
character there would be cut back to exactly that by
`imenu--truncate-items', losing the number -- which is the one
part of the name telling it from the entry above it.

A limit of 4 is the whole of the room `<10>' needs, and eleven
prompts under one label reach it: the label is down to its
ellipsis while the number is one digit and gone once it is two.
Eleven, because the tenth is the first with nowhere to put a
second digit.

What is asserted is the resolution and not the strings: every
label is looked up the way `imenu' looks one up, and the eleven
have to come back pointing at eleven different places.  Two
entries under one name resolve to one of them.

The last two names are read as well, because a number imenu cut
the end off is still a name of its own and the resolution alone
would not notice: the tenth and eleventh are the number and
nothing else, and the closing bracket is still on it.

A limit narrower than the number is past what the numbering can
hold -- imenu cuts the number itself there, which
`parley-transcript--index-numbered' says -- and what is left to
ask of it is that it come back: the eleven are all entries, and
the search for a free number ends rather than going round after
one it can never take.

This starts no pipeline.  The prompts go into the index through
the function the render pass puts them there with, which is all
the index needs, and `imenu--make-index-alist' is what is asked
for them because imenu's own truncation is the thing under test."
  (with-temp-buffer
    (parley-transcript-mode)
    (let ((imenu-max-item-length 4))
      (parley-transcript-test--index-prompts "continue with it" 11)
      (let* ((index (imenu--make-index-alist))
             (found (mapcar (lambda (entry) (cdr (assoc (car entry) index)))
                            index)))
        (should (= 11 (length index)))
        (should (= 11 (length (delete-dups found))))
        (should (equal (last (mapcar #'car index) 2) '("<10>" "<11>")))
        (should (seq-every-p (lambda (entry) (<= (length (car entry)) 4))
                             index)))))
  (with-temp-buffer
    (parley-transcript-mode)
    (let ((imenu-max-item-length 2))
      (parley-transcript-test--index-prompts "continue with it" 11)
      (should (= 11 (length (imenu--make-index-alist)))))))

(ert-deftest parley-transcript-test-numbers-a-label-imenu-counts-longer ()
  "The number survives on a label whose characters outrun its columns.

The two lengths are not the same length.  `imenu--truncate-items'
cuts with `substring', which counts characters, and a label is
made to fit with `truncate-string-to-width', which counts the
columns it displays in -- so a label of five characters in two
columns is inside a limit of five by one count and not by the
other, and the `<2>' hung off it is what imenu takes back.

The prompt here is `a' wearing three combining acute accents and
then `b': five characters and two columns, which no room
reserved in columns alone can keep the number on.  Both prompts
are the same prompt, so the second is the one that has to be
numbered, and it is the one the collision would swallow."
  (with-temp-buffer
    (parley-transcript-mode)
    (let ((imenu-max-item-length 5)
          (text (concat "a" (make-string 3 ?́) "b")))
      (parley-transcript-test--index-prompts text 2)
      (let* ((index (imenu--make-index-alist))
             (found (mapcar (lambda (entry) (cdr (assoc (car entry) index)))
                            index)))
        (should (= 2 (length index)))
        (should (= 2 (length (delete-dups found))))
        (should (string-suffix-p "<2>" (car (nth 1 index))))
        (should (seq-every-p (lambda (entry) (<= (length (car entry)) 5))
                             index))))))

(ert-deftest parley-transcript-test-labels-a-prompt-that-opens-blank ()
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

(ert-deftest parley-transcript-test-indexes-a-prompt-sent-from-the-prompt ()
  "A message submitted at the prompt is one entry, pointing at it.

The guard on the echo drops the transcript's copy of it when it
comes back, so the render pass never sees the prompts the
operator sent from here.  They are also the prompts he is most
likely to go looking for, so the sender records them as it
rewrites them into the buffer.

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
                     "> ask it something")))))

(ert-deftest parley-transcript-test-indexes-a-prompt-typed-below-a-blank-line ()
  "A message submitted at the prompt is entered at the first thing it says.

The entry is labelled with the first line the prompt says
something on, so that is the line it has to point at -- an entry
on the blank line above would be pointing at a line the operator
cannot see and which nothing in the buffer holds in place.  The
sender trims the prompt before it quotes it, which is what leaves
those the same line here as for a prompt the transcript
delivered."
  (skip-unless (executable-find "jq"))
  (parley-transcript-test--with-session parley-transcript-test--lines
    (should (parley-transcript-test--settled buffer))
    (parley-transcript-test--pane buffer "%7")
    (parley-transcript-test--with-tmux
      (parley-transcript-test--submit buffer "\n  \nask it something"))
    (should-not (member "> " (parley-transcript-test--shown buffer)))
    (let ((entry (assoc "ask it something"
                        (parley-transcript-test--index buffer))))
      (should entry)
      (should (equal (parley-transcript-test--at buffer entry)
                     "> ask it something")))))

(ert-deftest parley-transcript-test-index-survives-a-truncated-buffer ()
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

(ert-deftest parley-transcript-test-index-does-not-go-stale ()
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

(ert-deftest parley-transcript-test-indexes-a-prompt-after-a-run ()
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
