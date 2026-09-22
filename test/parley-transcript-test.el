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

(defun parley-transcript-test--user-turn (text)
  "Return a transcript line for a user turn that said TEXT."
  (format (concat "{\"type\":\"user\",\"message\":"
                  "{\"role\":\"user\",\"content\":\"%s\"}}")
          text))

(defun parley-transcript-test--command-turn (name args)
  "Return a transcript line for the turn the slash command NAME with ARGS writes.
Three tags and not one, and the name twice over: the harness
writes it again without its slash in `<command-message>'.  ARGS
is empty under a command the operator gave none, which is what
`/plugin' is.  Nothing here carries `isMeta', because the
transcript marks none of this."
  (parley-transcript-test--user-turn
   (format (concat "<command-message>%s</command-message>\\n"
                   "<command-name>%s</command-name>\\n"
                   "<command-args>%s</command-args>")
           (string-remove-prefix "/" name) name args)))

(defun parley-transcript-test--local-output (text)
  "Return a transcript line for a local command printing TEXT at the terminal.
Under the operator's role and unmarked, as the harness writes it."
  (parley-transcript-test--user-turn
   (concat "<local-command-stdout>" text "</local-command-stdout>")))

(defun parley-transcript-test--meta-turn (text)
  "Return a transcript line for an injected turn carrying TEXT.
A harness injection reaches a transcript under the operator's
role and with `isMeta' on it, which is the mark the transcript
puts on what he did not type."
  (format (concat "{\"type\":\"user\",\"isMeta\":true,\"message\":"
                  "{\"role\":\"user\",\"content\":%s}}")
          (json-serialize text)))

(defconst parley-transcript-test--skill-body
  "You are a lazy senior developer, and laziness is the whole of the law."
  "A line of the instructions a skill load carries into a transcript.
The buffer shows no line of them, and finding this one in it
means a skill body reached the conversation.")

(defun parley-transcript-test--skill-load (directory heading)
  "Return the text a skill read from DIRECTORY injects, under HEADING.
HEADING is nil for a skill whose body opens with none, which is
what `unslop', `ponytail-review' and `ponytail-audit' do."
  (concat "Base directory for this skill: " directory "\n\n"
          (if heading (concat "# " heading "\n\n") "")
          parley-transcript-test--skill-body "\n"))

(defconst parley-transcript-test--caveat
  (concat "<local-command-caveat>Caveat: The messages below were generated"
          " by the user while running local commands."
          "</local-command-caveat>")
  "The injection a local command prepends, which the buffer shows nowhere.")

;; What the nine lines above render to, blank lines dropped.  The tool
;; result, the thinking, the two non-message lines and the empty turn
;; contribute nothing at all; what the operator said is quoted; the two
;; tool calls are one line, and it stands where the run happened rather
;; than inside the turn that started it.
(defconst parley-transcript-test--rendered
  '("❯ what is here"
    "Let me look."
    "● 2 tool calls"
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
    ;; Its pid is this Emacs, which is a process really running: what
    ;; the status reader compares a session's file against is the start
    ;; time /proc reports for that pid, and an invented pid has none.
    ;; Its `:status' is what `claude agents' said when the record was
    ;; built, and a buffer holding that instead of what the session's
    ;; file says now is what the status tests are looking for.
    (list :name name :cwd temporary-file-directory :pid (emacs-pid)
          :status "idle" :session-id file :transcript file)))

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


;;; The pipeline

(ert-deftest parley-transcript-test-drops-the-tool-payloads ()
  "Nothing a tool sent or received reaches the Emacs process."
  (skip-unless (executable-find "jq"))
  (parley-transcript-test--with-session parley-transcript-test--lines
    (should (parley-transcript-test--settled buffer))
    (parley-transcript-test--write
     file (list (parley-transcript-test--tool-turn 3)))
    (should (parley-transcript-test--wait
             (lambda () (member "● 3 tool calls"
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
                   "❯ and now this"))))

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


;;; Rendering

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
                   '("● 2 tool calls" "● 12 tool calls")))
    (parley-transcript-test--write
     file (list (parley-transcript-test--tool-turn 3)))
    (should (equal (parley-transcript-test--wait
                    (lambda ()
                      (let ((runs (parley-transcript-test--runs buffer)))
                        (and (member "● 15 tool calls" runs) runs))))
                   '("● 2 tool calls" "● 15 tool calls")))
    (parley-transcript-test--write
     file (list (parley-transcript-test--text-turn "and here it is")))
    (should (equal (parley-transcript-test--wait
                    (lambda ()
                      (let ((shown (parley-transcript-test--shown buffer)))
                        (and (equal "and here it is" (car (last shown)))
                             (last shown 2)))))
                   '("● 15 tool calls" "and here it is")))
    (should (equal (parley-transcript-test--runs buffer)
                   '("● 2 tool calls" "● 15 tool calls")))))

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
    (should (equal "\n❯ first line\n❯ second\n"
                   (substring-no-properties block)))
    (should (eq ?\n (aref block (1- (length block)))))
    (should (eq 'parley-user
                (get-text-property (1- (length block)) 'font-lock-face
                                   block)))))

(ert-deftest parley-transcript-test-marks-a-turn-in-a-face-of-its-own ()
  "The `❯ ' at the head of a quoted line is faced apart from the turn's text.
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
                     ("❯ " . parley-user-marker)
                     ("first line\n" . parley-user)
                     ("❯ " . parley-user-marker)
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

(ert-deftest parley-transcript-test-collapses-a-skill-load-to-one-line ()
  "A skill load is one line naming the skill, and no other injection is shown.

Four shapes, which is what the render pass has to tell apart.  A
skill whose body opens with a heading is named by that heading,
because it is what the skill calls itself; one whose body opens
with none is named by the last segment of the directory it was
read from.  The caveat a local command prepends is shown nowhere
at all, a constant line saying an injection happened carrying no
information.  And the turn a slash command writes is not marked,
so it is quoted and indexed as any turn of his is -- the mark is
the whole of the test, and the tags in that turn's text decide
nothing about which of the two it is.

The instructions a load carries are the point of collapsing it:
a skill body is a thousand lines of them, and none belongs in a
buffer whose subject is the conversation."
  (skip-unless (executable-find "jq"))
  (parley-transcript-test--with-session
      (list (parley-transcript-test--meta-turn
             (parley-transcript-test--skill-load
              "/home/x/.claude/plugins/cache/ponytail/4.9.0/skills/ponytail"
              "Ponytail"))
            (parley-transcript-test--meta-turn
             (parley-transcript-test--skill-load
              "/home/x/.claude/plugins/cache/ydistri/3.2.0/skills/unslop" nil))
            (parley-transcript-test--meta-turn parley-transcript-test--caveat)
            (parley-transcript-test--command-turn "/ydistri:unslop" ""))
    (should (equal (parley-transcript-test--wait
                    (lambda ()
                      (let ((shown (parley-transcript-test--shown buffer)))
                        (and (= 3 (length shown)) shown))))
                   (list "● Loaded skill \"Ponytail\""
                         "● Loaded skill \"unslop\""
                         "❯ /ydistri:unslop")))
    (with-current-buffer buffer
      (goto-char (point-min))
      (should-not (search-forward parley-transcript-test--skill-body nil t))
      ;; The line is the renderer's and not anyone's in the
      ;; conversation, so it stands in the face the tool run line
      ;; stands in.
      (goto-char (point-min))
      (should (search-forward "● Loaded skill" nil t))
      (should (eq (get-text-property (match-beginning 0) 'font-lock-face)
                  'parley-tool-run)))
    ;; Marked and indexed as well as quoted: the unmarked turn is a
    ;; prompt like any other, and the two loads above it are in no
    ;; index however they render.
    (should (equal (mapcar #'car (parley-transcript-test--index buffer))
                   (list "/ydistri:unslop")))))

(ert-deftest parley-transcript-test-keeps-a-run-unbroken-across-an-injection ()
  "An injection the buffer does not show is no break in a run of tool calls.

It renders the empty string, which is what a turn that said
nothing renders to, and a run carries across one of those.  Two
calls, the caveat, three calls: one line saying five, and no
blank block where the caveat was."
  (skip-unless (executable-find "jq"))
  (parley-transcript-test--with-session
      (list (parley-transcript-test--tool-turn 2)
            (parley-transcript-test--meta-turn parley-transcript-test--caveat)
            (parley-transcript-test--tool-turn 3))
    (should (equal (parley-transcript-test--wait
                    (lambda ()
                      (let ((shown (parley-transcript-test--shown buffer)))
                        (and (equal shown (list "● 5 tool calls")) shown))))
                   (list "● 5 tool calls")))
    (with-current-buffer buffer
      (goto-char (point-min))
      (should-not (search-forward "\n\n\n" nil t)))))

(ert-deftest parley-transcript-test-shows-nothing-for-a-local-commands-output ()
  "The output a local command printed is no turn, and is shown nowhere.

It renders the empty string a turn that said nothing renders to,
so the run of tool calls it stands in is unbroken and there is no
blank block where it was: two calls, two of these, three calls,
and one line saying five.

The escape bytes settle with it.  A compaction notice arrives
wrapped in a real ESC[2m -- jq hands the byte through as the six
characters of its JSON escape and `json-parse-string' turns them
back into it -- and nothing strips one out of this buffer, which
has `ansi-color-process-output' taken out of its filters."
  (skip-unless (executable-find "jq"))
  (parley-transcript-test--with-session
      (list (parley-transcript-test--tool-turn 2)
            (parley-transcript-test--local-output
             "\\u2713 Installed orc. Plugin is now active.")
            (parley-transcript-test--local-output
             "\\u001b[2mCompacted (ctrl+o to see full summary)\\u001b[22m")
            (parley-transcript-test--tool-turn 3))
    (should (equal (parley-transcript-test--wait
                    (lambda ()
                      (let ((shown (parley-transcript-test--shown buffer)))
                        (and (equal shown (list "● 5 tool calls")) shown))))
                   (list "● 5 tool calls")))
    (with-current-buffer buffer
      (dolist (absent (list "\n\n\n" "Installed orc" "Compacted" "\e"
                            "local-command-stdout"))
        (goto-char (point-min))
        (should-not (search-forward absent nil t))))
    ;; None of it is a prompt either, so the operator jumping through
    ;; the index cannot land where one was.
    (should-not (parley-transcript-test--index buffer))))

(ert-deftest parley-transcript-test-renders-a-command-turn-as-the-line-typed ()
  "A slash command's turn is the one line the operator typed, quoted.

Three shapes of it.  A command with an argument is its name and
that argument on one line, which is what he typed at the prompt;
a command he gave no argument -- `/plugin' -- is the name alone,
the space of the joining gone with the trim; and an argument he
pasted over several lines keeps them, each quoted as the first
is.

No tag reaches the buffer and neither does `<command-message>',
which is the name a second time without its slash and says
nothing the name does not."
  (skip-unless (executable-find "jq"))
  (parley-transcript-test--with-session
      (list (parley-transcript-test--command-turn
             "/one" "so what's the actual fix then")
            (parley-transcript-test--command-turn "/plugin" "")
            (parley-transcript-test--command-turn
             "/note" "write this down:\\nand this under it"))
    (should (equal (parley-transcript-test--wait
                    (lambda ()
                      (let ((shown (parley-transcript-test--shown buffer)))
                        (and (= 4 (length shown)) shown))))
                   (list "❯ /one so what's the actual fix then"
                         "❯ /plugin"
                         "❯ /note write this down:"
                         "❯ and this under it")))
    (with-current-buffer buffer
      (dolist (absent (list "<command" "</command" "one</" ">plugin<"))
        (goto-char (point-min))
        (should-not (search-forward absent nil t))))))


;;; The buffer

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

(ert-deftest parley-transcript-test-shows-a-session-in-the-selected-window ()
  "The transcript replaces the buffer of the window the operator is in.

The frame is split first, because a frame of one window cannot
tell the two ways of showing a buffer apart.  Under `emacs -Q
--batch' it is about 80 by 25, under both
`split-height-threshold' and `split-width-threshold', so
`display-buffer' can pop no window up and reuses the only window
there is -- and over that frame `pop-to-buffer' passes as well.
Given a second window it takes that one instead, which is the
window holding whatever the operator was reading beside the
session he asked for."
  (skip-unless (executable-find "jq"))
  (let* ((session (parley-transcript-test--session
                   "test" parley-transcript-test--lines))
         (file (plist-get session :transcript))
         (elsewhere (get-buffer-create "*parley-transcript-test-elsewhere*"))
         (buffer nil))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (let* ((here (selected-window))
                 (other (split-window)))
            (set-window-buffer other elsewhere)
            (parley-transcript session)
            (should (= 1 (length (parley-transcript-test--buffers))))
            (setq buffer (car (parley-transcript-test--buffers)))
            (should (eq (selected-window) here))
            (should (eq (window-buffer here) buffer))
            (should (eq (window-buffer other) elsewhere))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (kill-buffer elsewhere)
      (delete-file file))))

(ert-deftest parley-transcript-test-names-two-sessions-of-one-name-apart ()
  "Two live sessions reported under one name get two buffer names.

`claude agents' names a session after the directory it was
started in, so sessions in sibling worktrees come back under the
same name and the name alone cannot say which buffer is whose.
Nor can where a session's pane is on its own: two live sessions
share a pane, and so a location, when the session running in it
is suspended and another is started there, which is `same' and
`sharing' below.  What ends every name is therefore the session
id, the one thing two records cannot both carry -- and a session
with no location is named by that alone.  Two have none: `gone',
whose pane tmux no longer reports because the window closed under
it, and `outside', which was started outside tmux and never had a
pane at all.

Whole, and not a head of it: `same' and `sharing' agree on their
name, their location and the first eight characters of their id,
so a name built from a prefix is one name for two live sessions.

No name carries the pane id its location was resolved from.  That
is what `tmux send-keys -t' takes, the record keeps it for that,
and a buffer name with one in it reads as a name with a stray
format directive in it.  `app%8e' is not one: a tmux session name
may carry a `%' -- tmux 3.2a sanitises `:' and `.' in one and
nothing else -- and the location is printed as tmux prints it.

This needs no session to be running, which is why it is the one
test here that does not start a pipeline."
  (let* ((parley--pane-locations '(("%61" . "orc-b3:2.0")
                                   ("%62" . "orc-b3:3.0")
                                   ("%1" . "app%8e:1.0")))
         (one (list :name "orc-w1" :pane "%61"
                    :session-id "1111ffff-0000-4000-8000-000000000001"))
         (two (list :name "orc-w1" :pane "%62"
                    :session-id "2222ffff-0000-4000-8000-000000000002"))
         (same (list :name "shared" :pane "%1"
                     :session-id "44444444-0000-4000-8000-000000000004"))
         (sharing (list :name "shared" :pane "%1"
                        :session-id "44444444-ffff-4000-8000-000000000005"))
         (gone (list :name "orc-w1" :pane "%99"
                     :session-id "5555ffff-0000-4000-8000-000000000006"))
         (outside (list :name "orc-w1" :pane nil
                        :session-id "9a5a5635-26c3-4705-b06e-4dc108d75439"))
         (unnamed (list :name nil :pane nil
                        :session-id "7c1d0f9a-0000-4000-8000-000000000003"))
         (names (mapcar #'parley-transcript--buffer-name
                        (list one two same sharing gone outside unnamed))))
    (should (equal names
                   '("*parley: orc-w1 orc-b3:2.0 1111ffff-0000-4000-8000-000000000001*"
                     "*parley: orc-w1 orc-b3:3.0 2222ffff-0000-4000-8000-000000000002*"
                     "*parley: shared app%8e:1.0 44444444-0000-4000-8000-000000000004*"
                     "*parley: shared app%8e:1.0 44444444-ffff-4000-8000-000000000005*"
                     "*parley: orc-w1 5555ffff-0000-4000-8000-000000000006*"
                     "*parley: orc-w1 9a5a5635-26c3-4705-b06e-4dc108d75439*"
                     "*parley: unnamed 7c1d0f9a-0000-4000-8000-000000000003*")))
    (dolist (session (list one two same sharing gone outside unnamed))
      (let ((pane (plist-get session :pane)))
        (should-not
         (and pane (string-match-p
                    (regexp-quote pane)
                    (parley-transcript--buffer-name session))))))
    (should (equal (length (delete-dups (copy-sequence names))) 7))))

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


;;; The session's live status

;; The buffer reads the session's own file, so the fixture is that
;; file: a directory of its own, and the pid in it this Emacs, whose
;; start time /proc really reports.

(defun parley-transcript-test--write-status (buffer status)
  "Write STATUS as the file BUFFER's session writes about itself.
The `procStart' is field 22 of `/proc/PID/stat' split on
whitespace, read here and not by the reader under test: a fixture
the reader built would agree with it whatever either of them
did."
  (let ((pid (emacs-pid)))
    (with-temp-file (expand-file-name (format "%s.json" pid)
                                      parley-sessions-directory)
      (insert (json-serialize
               `((pid . ,pid)
                 (sessionId . ,(plist-get (buffer-local-value
                                           'parley-transcript-session buffer)
                                          :session-id))
                 (procStart . ,(with-temp-buffer
                                 (insert-file-contents
                                  (format "/proc/%s/stat" pid))
                                 (nth 21 (split-string (buffer-string)))))
                 (status . ,status)))))))

(defun parley-transcript-test--status (buffer)
  "Return the status BUFFER holds."
  (buffer-local-value 'parley-transcript-status buffer))

(defmacro parley-transcript-test--with-sessions-directory (&rest body)
  "Run BODY with `parley-sessions-directory' a directory of its own."
  (declare (indent 0))
  `(let ((parley-sessions-directory
          (make-temp-file "parley-transcript-test-sessions-" t)))
     (unwind-protect (progn ,@body)
       (delete-directory parley-sessions-directory t))))

(ert-deftest parley-transcript-test-holds-what-the-session-file-says ()
  "The buffer holds the status its session's file gives it, and follows it.
Nothing announces a change, so what the buffer holds after the
file has been written again is what the tick found there.  The
record the buffer was opened with says `idle' throughout and the
file never does, so a buffer holding the record's status would
hold `idle' at both of the reads below.

And nothing is read at all for a buffer no window is showing:
before the buffer is put in a window it stays at `unknown' with a
file beside it saying otherwise."
  (skip-unless (executable-find "jq"))
  (parley-transcript-test--with-sessions-directory
    (parley-transcript-test--with-session parley-transcript-test--lines
      (parley-transcript-test--write-status buffer "busy")
      (parley-transcript--read-status buffer)
      (should (eq (parley-transcript-test--status buffer) 'unknown))
      (set-window-buffer (selected-window) buffer)
      (should (parley-transcript-test--wait
               (lambda ()
                 (eq (parley-transcript-test--status buffer) 'working))))
      (parley-transcript-test--write-status buffer "waiting")
      (should (parley-transcript-test--wait
               (lambda ()
                 (eq (parley-transcript-test--status buffer) 'waiting)))))))

(ert-deftest parley-transcript-test-kill-stops-the-status-tick ()
  "Killing the buffer cancels every timer that has read its status.
The tick is the buffer's own, so there is nothing else to stop.

Reentering the major mode is where one gets left behind: the mode
is what starts a tick, and every buffer-local binding it does not
keep is cleared on the way in -- so the second tick would be
started with nothing left naming the first, and killing the
buffer would cancel the second alone."
  (skip-unless (executable-find "jq"))
  (parley-transcript-test--with-session parley-transcript-test--lines
    (let ((first (buffer-local-value 'parley-transcript--status-timer buffer)))
      (should (memq first timer-list))
      (with-current-buffer buffer (parley-transcript-mode))
      (let ((second (buffer-local-value 'parley-transcript--status-timer buffer)))
        (should-not (eq first second))
        (should (memq second timer-list))
        (kill-buffer buffer)
        (should-not (memq first timer-list))
        (should-not (memq second timer-list))))))


;;; The header line

(defun parley-transcript-test--header (buffer)
  "Return the line BUFFER shows at its top, by evaluating its own format.
`format-mode-line' returns the empty string under `emacs -Q
--batch', there being no frame to format a line for, so the
`:eval' form the buffer carries is evaluated here instead -- in
the buffer, which is what redisplay does with it.  Read off the
buffer rather than named, so a mode that stopped installing the
line fails every test below."
  (with-current-buffer buffer
    (should (eq (car header-line-format) :eval))
    (substring-no-properties (eval (cadr header-line-format) t))))

(defun parley-transcript-test--header-for (session status)
  "Return the line a transcript buffer following SESSION at STATUS shows."
  (with-temp-buffer
    (parley-transcript-mode)
    (setq parley-transcript-session session
          parley-transcript-status status)
    (parley-transcript-test--header (current-buffer))))

(defconst parley-transcript-test--in-pane
  (list :name "orc-w1" :pane "%61" :cwd "/home/me/worktrees/orc-w1"
        :session-id "1111ffff-0000-4000-8000-000000000001")
  "A session record living in a tmux pane, for the lines below.
Its working directory is one no line may carry: inside the buffer
that is `default-directory', and a header line repeating it
spends a line on what the buffer already is.")

(ert-deftest parley-transcript-test-header-line-names-the-session-and-its-state ()
  "The header line names the session, what it is doing and where its pane is.

All four states are told apart in words, and waiting is a word of
its own: it is the state that wants the operator, and a line
drawing it as a shade of idle would say nothing about the one
session he has to answer.  The cell in front of the prompt says
that something is working, in one column, where he is typing;
this says which session and what it is doing, wherever in the
buffer he is.

A session `claude agents' named none shows the placeholder a
switcher row shows for it, and the mark saying a session cannot
be typed into is read from the record having no pane -- a
background agent and a session started outside tmux both have
none, and `:kind' names only the first.

The location is what `parley--pane-locations' holds for the
record's pane.  A pane it holds nothing for shows no location at
all and never the pane id, which locates nothing the operator can
act on."
  (let ((parley--pane-locations '(("%61" . "orc-b3:2.0")))
        (unnamed (list :name nil :pane nil :cwd "/home/me/worktrees/orc-w1"
                       :session-id "7c1d0f9a-0000-4000-8000-000000000003"))
        (moved (plist-put (copy-sequence parley-transcript-test--in-pane)
                          :pane "%99")))
    (should (equal (mapcar (lambda (status)
                             (parley-transcript-test--header-for
                              parley-transcript-test--in-pane status))
                           '(working waiting idle unknown))
                   '("orc-w1  working  orc-b3:2.0"
                     "orc-w1  waiting  orc-b3:2.0"
                     "orc-w1  idle  orc-b3:2.0"
                     "orc-w1  unknown  orc-b3:2.0")))
    (should (equal (parley-transcript-test--header-for unnamed 'idle)
                   "unnamed  idle  [RO]"))
    (should (equal (parley-transcript-test--header-for moved 'working)
                   "orc-w1  working"))
    (dolist (line (list (parley-transcript-test--header-for
                         parley-transcript-test--in-pane 'working)
                        (parley-transcript-test--header-for unnamed 'idle)
                        (parley-transcript-test--header-for moved 'working)))
      (should-not (string-match-p (regexp-quote "%99") line))
      (should-not (string-match-p (regexp-quote "worktrees") line)))))

(ert-deftest parley-transcript-test-header-line-asks-tmux-nothing ()
  "Drawing the header line runs no subprocess, whatever the cache holds.
`parley--pane-location' fills the cache when it reads `unasked',
and filling it is a `tmux list-panes -a' -- from redisplay, in
every transcript buffer on screen, every time `parley-sessions'
puts the cache back to `unasked'.  So the lookup is bare: the
cache is left as this test found it, and a line drawn over an
`unasked' cache shows no location rather than asking tmux for
one.

`call-process' is what a fill would reach, and it errors here
instead: a test that only read the location off the line would
pass over a header line that ran tmux and got an answer."
  (let ((parley--pane-locations 'unasked)
        (line nil))
    (cl-letf (((symbol-function 'call-process)
               (lambda (&rest _) (error "The header line asked tmux"))))
      (setq line (parley-transcript-test--header-for
                  parley-transcript-test--in-pane 'working)))
    (should (equal line "orc-w1  working"))
    (should (eq parley--pane-locations 'unasked))))

(ert-deftest parley-transcript-test-header-line-follows-the-live-status ()
  "A real transcript buffer carries the line, and it says what is true now.
The record the buffer was opened with says `idle' throughout and
the session's own file never does, so a line built from that
record would read `idle' at both of the reads below."
  (skip-unless (executable-find "jq"))
  (parley-transcript-test--with-sessions-directory
    (parley-transcript-test--with-session parley-transcript-test--lines
      (should (equal (parley-transcript-test--header buffer)
                     "test  unknown  [RO]"))
      (set-window-buffer (selected-window) buffer)
      (parley-transcript-test--write-status buffer "busy")
      (should (parley-transcript-test--wait
               (lambda ()
                 (equal (parley-transcript-test--header buffer)
                        "test  working  [RO]"))))
      (parley-transcript-test--write-status buffer "waiting")
      (should (parley-transcript-test--wait
               (lambda ()
                 (equal (parley-transcript-test--header buffer)
                        "test  waiting  [RO]")))))))



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
                   '(("\n" . nil) ("❯ " . parley-user-marker)
                     ("hello there\n" . parley-user))))
    (with-current-buffer buffer
      (should-not (text-property-any (point-min) (point-max) 'font-lock-face
                                     'comint-highlight-input)))
    (parley-transcript-test--write
     file (make-list 2 (parley-transcript-test--user-turn "hello there")))
    (should (parley-transcript-test--wait
             (lambda () (= 2 (seq-count (lambda (line) (equal line "❯ hello there"))
                                        (parley-transcript-test--shown buffer))))))
    (should (equal (parley-transcript-test--shape
                    (parley-transcript-test--tail buffer 30))
                   '(("\n" . nil) ("❯ " . parley-user-marker)
                     ("hello there\n" . parley-user)
                     ("\n" . nil) ("❯ " . parley-user-marker)
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
             (lambda () (= 2 (seq-count (lambda (line) (equal line "❯ second line"))
                                        (parley-transcript-test--shown buffer))))))
    (should (equal (parley-transcript-test--shape
                    (parley-transcript-test--tail
                     buffer (* 2 (length "\n❯ first line\n❯ second line\n"))))
                   '(("\n" . nil)
                     ("❯ " . parley-user-marker) ("first line\n" . parley-user)
                     ("❯ " . parley-user-marker) ("second line\n" . parley-user)
                     ("\n" . nil)
                     ("❯ " . parley-user-marker) ("first line\n" . parley-user)
                     ("❯ " . parley-user-marker)
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
    (should (= 1 (seq-count (lambda (line) (equal line "❯ hello there"))
                            (parley-transcript-test--shown buffer))))))

(ert-deftest parley-transcript-test-does-not-render-a-command-twice ()
  "A slash command submitted at the prompt appears once and not twice.

The transcript's copy of it is three tags around what he typed,
and `parley-transcript--echoed-p' recognises a copy by comparing
the text that was sent -- so the copy has to be unwrapped before
it is compared or it matches nothing and the turn stands in the
buffer a second time.

The turn that follows it is what says the copy went by: it is
behind the message in the file, so a buffer holding it is a
buffer that has seen the copy too."
  (skip-unless (executable-find "jq"))
  (parley-transcript-test--with-session parley-transcript-test--lines
    (should (parley-transcript-test--settled buffer))
    (parley-transcript-test--pane buffer "%7")
    (parley-transcript-test--with-tmux
      (parley-transcript-test--submit
       buffer "/one so what's the actual fix then"))
    (parley-transcript-test--write
     file (list (parley-transcript-test--command-turn
                 "/one" "so what's the actual fix then")
                (parley-transcript-test--text-turn "of course")))
    (should (parley-transcript-test--wait
             (lambda () (member "of course"
                                (parley-transcript-test--shown buffer)))))
    (let ((shown (parley-transcript-test--shown buffer))
          (quoted "❯ /one so what's the actual fix then"))
      ;; Once, and as the line he typed.  The count on its own is
      ;; satisfied by a copy rendered as its three tags, which is no
      ;; line it looks at; the two lines on their own are satisfied by
      ;; a second copy of the line, which is what stands above the
      ;; answer when the guard misses it.
      (should (= 1 (seq-count (lambda (line) (equal line quoted)) shown)))
      (should (equal (last shown 2) (list quoted "of course"))))))

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
      (dolist (quoted '("❯ first question" "❯ second question"))
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
    (should (= 2 (seq-count (lambda (line) (equal line "❯ say it again"))
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
             (lambda () (member "❯ typed at the pane"
                                (parley-transcript-test--shown buffer)))))
    (should (= 2 (seq-count (lambda (line) (equal line "❯ hello there"))
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
in the rendered `what is here', it returns \"❯ what is here\",
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
             (lambda () (member "❯ gamma line"
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
28.2 over this buffer, \"\\n❯ what is here\\n\" rather than the
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
        (dolist (line '("Let me look." "● 2 tool calls"))
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
after it.  The mark is named rather than built again from the
code that put it there, which would agree with it whatever either
of them showed.  Nothing has been read about this session yet, so
it stands at `unknown' and its cell is a blank."
  (skip-unless (executable-find "jq"))
  (parley-transcript-test--with-session parley-transcript-test--lines
    (should (parley-transcript-test--settled buffer))
    (let ((overlay (parley-transcript-test--marked-zone buffer)))
      (should overlay)
      (should (equal "" (parley-transcript-test--zone buffer)))
      (should (= (overlay-start overlay) (overlay-end overlay)))
      (should (eq 'unknown (parley-transcript-test--status buffer)))
      (should (equal (overlay-get overlay 'before-string)
                     (concat parley-transcript--input-rule-above "\n"
                             " " parley-transcript--quote-marker)))
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

(ert-deftest parley-transcript-test-closes-the-input-zone-with-a-rule ()
  "A rule across the window stands above the input zone and another below it.
What the operator is writing is closed off from the conversation
above it and from the end of the buffer below, and both rules are
shown and are not in the buffer: one is a line of the overlay's
`before-string' and the other a line of its `after-string', for
the reason the mark itself is neither.

Each line runs the width of the window because it is drawn on a
space stretched to the right edge, so nothing has to redraw it
when the window changes size -- and each is drawn at the edge of
its own row nearest the zone, which is what `:underline' above
and `:overline' below come to."
  (dolist (rule (list parley-transcript--input-rule-above
                      parley-transcript--input-rule-below))
    (should (equal '(space :align-to right)
                   (get-text-property 0 'display rule))))
  (should (face-attribute 'parley-input-rule-above :underline nil t))
  (should (face-attribute 'parley-input-rule-below :overline nil t))
  (should (string-prefix-p (concat parley-transcript--input-rule-above "\n")
                           (parley-transcript--input-marker)))
  (should (string-suffix-p (concat "\n" parley-transcript--input-rule-below)
                           parley-transcript--input-fill)))

(defun parley-transcript-test--cell (buffer)
  "Return the cell BUFFER draws in front of its prompt mark.
Read back off the overlay rather than built again, so what this
returns is what is on screen: the character between the rule's
line and `parley-transcript--quote-marker', which the marker
ends with."
  (let* ((marker (overlay-get (buffer-local-value
                               'parley-transcript--input-overlay buffer)
                              'before-string))
         (end (- (length marker) (length parley-transcript--quote-marker))))
    (substring-no-properties marker (1- end) end)))

(defun parley-transcript-test--cell-changes (buffer seconds)
  "Return how many times the cell BUFFER draws changes over SECONDS.
Sampled far faster than anything that redraws it, so what this
counts is how often a frame really reached the overlay and not
how often this looked."
  (let ((last (parley-transcript-test--cell buffer))
        (changes 0)
        (deadline (+ (float-time) seconds)))
    (while (< (float-time) deadline)
      (accept-process-output nil 0.01)
      (let ((now (parley-transcript-test--cell buffer)))
        (unless (equal now last)
          (setq changes (1+ changes)
                last now))))
    changes))

(ert-deftest parley-transcript-test-shows-the-status-in-front-of-the-prompt ()
  "The cell before the prompt mark shows what the session is doing, in four states.
A frame of the spinner while it is working, a steady mark while
it waits for the operator, and a blank while it is idle or
nothing is known about it.  The mark that wants him does not
move, because motion says wait: it is no frame of the spinner, so
a spinner stopped on its last frame cannot be read for a session
asking him something.

The cell stands between the rule that opens the zone and the
prompt mark, on the prompt's own line, and it is the whole marker
that is compared in every one of the four states: the cell on its
own leaves the state where the marker is put together free to
show something else.  The frames are the operator's here, so what
a working session's marker has to be is a string this test names
rather than one it works out the way the code does -- and the
second of them says the counter is what chooses between them."
  (with-temp-buffer
    (setq-local parley-transcript-status 'working)
    (should (member (substring-no-properties (parley-transcript--status-cell))
                    parley-input-spinner-frames))
    (setq-local parley-transcript--spinner-frame
                (1+ parley-transcript--spinner-frame))
    (should (member (substring-no-properties (parley-transcript--status-cell))
                    parley-input-spinner-frames))
    (should-not (member parley-transcript--input-waiting-mark
                        parley-input-spinner-frames))
    (let ((parley-input-spinner-frames '("1" "2")))
      (setq-local parley-transcript--spinner-frame 0)
      (pcase-dolist (`(,status . ,cell)
                     `((working . "1")
                       (waiting . ,parley-transcript--input-waiting-mark)
                       (idle . " ")
                       (unknown . " ")))
        (setq-local parley-transcript-status status)
        (should (equal cell (substring-no-properties
                             (parley-transcript--status-cell))))
        (should (equal (parley-transcript--input-marker)
                       (concat parley-transcript--input-rule-above "\n"
                               cell parley-transcript--quote-marker))))
      (setq-local parley-transcript-status 'working)
      (setq-local parley-transcript--spinner-frame 1)
      (should (equal (parley-transcript--input-marker)
                     (concat parley-transcript--input-rule-above "\n"
                             "2" parley-transcript--quote-marker))))))

(ert-deftest parley-transcript-test-keeps-the-prompt-mark-in-one-column ()
  "Every cell the prompt can be headed by is one column, so the mark never moves.
A marker that came out shorter when a turn ended would move the
`❯' under the operator's hands at the moment he starts typing at
it.

Asserted over the frames `parley-input-spinner-frames' is
declared with and not over whatever it holds now: the variable is
the operator's to set, and what this pins is the set parley
ships."
  (let ((frames (eval (car (get 'parley-input-spinner-frames 'standard-value))
                      t)))
    (should frames)
    (dolist (cell (append frames (list parley-transcript--input-waiting-mark)))
      (should (= 1 (string-width cell))))
    (let ((parley-input-spinner-frames frames)
          (widths nil))
      (with-temp-buffer
        (dolist (status '(working waiting idle unknown))
          (setq-local parley-transcript-status status)
          (should (= 1 (string-width (parley-transcript--status-cell))))
          (push (string-width (car (last (split-string
                                          (parley-transcript--input-marker)
                                          "\n"))))
                widths)))
      (should (equal widths (make-list 4 (1+ (string-width
                                              parley-transcript--quote-marker))))))))

(ert-deftest parley-transcript-test-animates-the-cell-while-the-session-works ()
  "The spinner advances on its own while the session works, and stops when it does.
Nothing redraws it: the cell is animated by a tick of the
buffer's own, started on the status tick that finds the session
working and cancelled on the one that finds it doing anything
else.  A session that has stopped therefore leaves a mark that
has stopped too, and not a spinner turning over nothing."
  (skip-unless (executable-find "jq"))
  (parley-transcript-test--with-sessions-directory
    (parley-transcript-test--with-session parley-transcript-test--lines
      (should (parley-transcript-test--settled buffer))
      (parley-transcript-test--write-status buffer "busy")
      (set-window-buffer (selected-window) buffer)
      (should (parley-transcript-test--wait
               (lambda () (timerp (buffer-local-value
                                   'parley-transcript--spinner-timer buffer)))))
      (should (member (parley-transcript-test--cell buffer)
                      parley-input-spinner-frames))
      ;; Counted and not merely waited for, so that the tick reading the
      ;; status cannot stand in for the animation: that one runs once a
      ;; second and redraws the whole marker, which changes the cell
      ;; about twice over the window below where the animation changes
      ;; it about fifteen times.
      (should (>= (parley-transcript-test--cell-changes buffer 1.5) 5))
      (parley-transcript-test--write-status buffer "idle")
      (should (parley-transcript-test--wait
               (lambda () (null (buffer-local-value
                                 'parley-transcript--spinner-timer buffer)))))
      (should (equal " " (parley-transcript-test--cell buffer)))
      ;; And it stays stopped across the status ticks that follow.  A
      ;; tick that started one over a session doing nothing would leave
      ;; a timer that cancels itself on its own first fire, which polling
      ;; for a nil finds stopped nine times out of ten.
      (let ((deadline (+ (float-time) 2.5)))
        (while (< (float-time) deadline)
          (accept-process-output nil 0.05)
          (should-not (buffer-local-value 'parley-transcript--spinner-timer
                                          buffer)))))))

(ert-deftest parley-transcript-test-animates-only-where-it-can-be-seen ()
  "A buffer no window is showing animates nothing.
A frame redrawn where nobody is looking is a redisplay bought for
no one, and a timer doing it in every transcript ever opened in
this Emacs buys nothing at all.

The status tick cannot be what stops it: it reads nothing for a
buffer nobody is showing, so the status it left behind still says
`working' after the window has gone."
  (skip-unless (executable-find "jq"))
  (parley-transcript-test--with-sessions-directory
    (parley-transcript-test--with-session parley-transcript-test--lines
      (should (parley-transcript-test--settled buffer))
      (parley-transcript-test--write-status buffer "busy")
      (set-window-buffer (selected-window) buffer)
      (should (parley-transcript-test--wait
               (lambda () (timerp (buffer-local-value
                                   'parley-transcript--spinner-timer buffer)))))
      (set-window-buffer (selected-window) (get-buffer-create "*scratch*"))
      (should (parley-transcript-test--wait
               (lambda () (null (buffer-local-value
                                 'parley-transcript--spinner-timer buffer)))))
      (should (eq (parley-transcript-test--status buffer) 'working)))))

(ert-deftest parley-transcript-test-animates-only-on-a-frame-that-is-up ()
  "A window on a frame that is not on screen is no window showing the buffer.
A frame goes down without its windows going anywhere: it can be
made invisible and it can be iconified, and either way
`get-buffer-window' with t hands back the window it still holds.
That is how a transcript nobody can see keeps a timer redrawing
it, so the frame is asked whether it is up.

Batch Emacs has one frame and nothing that puts it down --
`make-frame' finds no terminal type it can use, and
`make-frame-invisible' over a frame opened on a pty leaves
`frame-visible-p' answering t (Emacs 28.2).  So the answer is
stubbed, which is that same question and the only way this Emacs
can be made to give it.

The window stays on the buffer throughout and the session stays
at work: what stops the animation is the frame, and the tick that
reads the status is not what stopped it.  A window coming back up
starts it again, which is what the second round waits for."
  (skip-unless (executable-find "jq"))
  (parley-transcript-test--with-sessions-directory
    (parley-transcript-test--with-session parley-transcript-test--lines
      (should (parley-transcript-test--settled buffer))
      (parley-transcript-test--write-status buffer "busy")
      (set-window-buffer (selected-window) buffer)
      (dolist (down '(nil icon))
        (should (parley-transcript-test--wait
                 (lambda () (timerp (buffer-local-value
                                     'parley-transcript--spinner-timer buffer)))))
        (cl-letf (((symbol-function 'frame-visible-p) (lambda (_frame) down)))
          (should (parley-transcript-test--wait
                   (lambda () (null (buffer-local-value
                                     'parley-transcript--spinner-timer buffer)))))
          (should (get-buffer-window buffer t))
          (should (eq (parley-transcript-test--status buffer) 'working)))))))

(ert-deftest parley-transcript-test-animates-across-a-mode-reentry ()
  "A major mode reentered over the buffer leaves the cell animating, with no gap.
`kill-all-local-variables' clears every buffer-local binding whose
symbol does not carry `permanent-local', and entering the mode
again changes neither which session the buffer follows nor what
that session is doing.  So nothing the animation stands on is
lost -- not the record, not the status, not the frame the spinner
has got to, not the timer, and not the overlay, which belongs to
the buffer and would be left on screen with nothing naming it.
Each of the five is what one of the assertions below comes to.

What is asserted here is the animation and not any one of those.
The frame after the reentry is drawn the way the timer draws it
and before anything else can have run, because that is where a
cleared binding shows: the animation fires 0.1 s after the
reentry and the tick that would put a value back is a second
away, so a frame that has to wait for that tick is a spinner
stopped for most of a second under a session that never stopped
working.  Then the status is read again, from the session's own
file, which a buffer that has forgotten its session cannot do.
Then the cell is counted really changing -- a timer on
`timer-list' is not the animation reaching the screen.

Then the session says something, which is what puts the zone back
over the end of the buffer: that is the one path that would make
an overlay again, and after it there is still exactly one drawing
a marker.  Two would draw the rule and the prompt twice."
  (skip-unless (executable-find "jq"))
  (parley-transcript-test--with-sessions-directory
    (parley-transcript-test--with-session parley-transcript-test--lines
      (should (parley-transcript-test--settled buffer))
      (parley-transcript-test--write-status buffer "busy")
      (set-window-buffer (selected-window) buffer)
      (should (parley-transcript-test--wait
               (lambda () (timerp (buffer-local-value
                                   'parley-transcript--spinner-timer buffer)))))
      (with-current-buffer buffer
        ;; On a frame of its own first, so that a spinner snapped back
        ;; to the head of its list by the reentry cannot be read for one
        ;; that carried on from where it was.
        (setq parley-transcript--spinner-frame 5)
        (parley-transcript--draw-input-marker))
      (let ((overlay (buffer-local-value 'parley-transcript--input-overlay
                                         buffer)))
        (should (overlayp overlay))
        (with-current-buffer buffer (parley-transcript-mode))
        ;; Nothing has waited for anything since the reentry, so no
        ;; timer has run: this is the next frame the animation's own
        ;; timer would draw, drawn here instead.  It is the frame after
        ;; the one that was up, and the animation goes on being a timer
        ;; the buffer can still name.
        (parley-transcript--advance-marker buffer)
        (should (equal (parley-transcript-test--cell buffer)
                       (nth 6 parley-input-spinner-frames)))
        (should (timerp (buffer-local-value 'parley-transcript--spinner-timer
                                            buffer)))
        (should (eq overlay (buffer-local-value
                             'parley-transcript--input-overlay buffer)))
        ;; And the first read of the file after the reentry is a read of
        ;; this buffer's own session.
        (parley-transcript--read-status buffer)
        (should (eq (parley-transcript-test--status buffer) 'working))
        (should (>= (parley-transcript-test--cell-changes buffer 1.5) 5))
        (parley-transcript-test--write
         file (list (parley-transcript-test--text-turn "and one thing more")))
        (should (parley-transcript-test--wait
                 (lambda () (member "and one thing more"
                                    (parley-transcript-test--shown buffer)))))
        (should (eq overlay (buffer-local-value
                             'parley-transcript--input-overlay buffer)))
        (should (equal (list overlay)
                       (with-current-buffer buffer
                         (seq-filter
                          (lambda (o) (overlay-get o 'before-string))
                          (overlays-in (point-min) (point-max))))))))))

(ert-deftest parley-transcript-test-kill-stops-the-animation ()
  "Killing the buffer cancels the timer animating its cell, reentered mode or not.
The animation is stopped by a buffer-local `kill-buffer-hook',
put on the buffer by whatever started the timer.  Both survive a
major mode reentered over this buffer -- the timer because
`parley-transcript--spinner-timer' is declared permanent, and the
hook because `kill-buffer-hook' carries `permanent-local' itself
(Emacs 28.2) -- so the kill reaches whichever timer is running by
then.

A reentry is where one would be left behind, so the buffer goes
through one while the session works: the spinner has to be
running again by the time the buffer is killed, and nothing of
either generation may be left on `timer-list' afterwards."
  (skip-unless (executable-find "jq"))
  (parley-transcript-test--with-sessions-directory
    (parley-transcript-test--with-session parley-transcript-test--lines
      (should (parley-transcript-test--settled buffer))
      (parley-transcript-test--write-status buffer "busy")
      (set-window-buffer (selected-window) buffer)
      (should (parley-transcript-test--wait
               (lambda () (timerp (buffer-local-value
                                   'parley-transcript--spinner-timer buffer)))))
      (let ((first (buffer-local-value 'parley-transcript--spinner-timer buffer)))
        (with-current-buffer buffer (parley-transcript-mode))
        (should (parley-transcript-test--wait
                 (lambda () (timerp (buffer-local-value
                                     'parley-transcript--spinner-timer buffer)))))
        (let ((second (buffer-local-value
                       'parley-transcript--spinner-timer buffer)))
          (kill-buffer buffer)
          (should-not (memq first timer-list))
          (should-not (memq second timer-list)))))))

(ert-deftest parley-transcript-test-leaves-a-rendered-turn-without-a-cell ()
  "No line of a turn already taken carries the cell, and none of it is buffer text.
`parley-transcript--quote-marker' heads every line of every turn
of the operator's and the input zone alike, and the cell is added
to the mark at the head of the zone and not to that constant: a
cell on the constant would put a spinner down the whole
conversation, and `parley-transcript--old-input' strips it with a
`^' anchored regexp to send a past turn again.

Nothing the zone's mark draws is in the buffer either --
`comint-send-input' sends the buffer text from the process mark
on, so a cell written there is a cell typed into the session --
which is what the buffer holding no frame of a running spinner
comes to."
  (skip-unless (executable-find "jq"))
  (parley-transcript-test--with-session parley-transcript-test--lines
    (should (parley-transcript-test--settled buffer))
    (should (equal "❯ " parley-transcript--quote-marker))
    (with-current-buffer buffer
      (setq parley-transcript-status 'working)
      (parley-transcript--draw-input-marker)
      (should (member (parley-transcript-test--cell buffer)
                      parley-input-spinner-frames))
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        (dolist (cell (cons parley-transcript--input-waiting-mark
                            parley-input-spinner-frames))
          (should-not (string-search cell text))))
      (should (member (concat parley-transcript--quote-marker "what is here")
                      (parley-transcript-test--shown buffer)))
      (goto-char (point-min))
      (should (search-forward "what is here" nil t))
      (should (equal "what is here" (parley-transcript--old-input))))))


;;; Aligning a table

(defconst parley-transcript-test--table
  (concat "| name | what it does |\n"
          "|---|---|\n"
          "| a | short |\n"
          "| bbbbbb | a much longer cell |")
  "A table as an agent writes one, whose columns do not line up.
Its aligned form is 31 columns wide and the text itself is 30, so
a window of 20 has room for neither and the cells have to be
wrapped to fit one.")

(defun parley-transcript-test--tables (buffer)
  "Return the overlays over a table in BUFFER, in buffer order."
  (with-current-buffer buffer
    (sort (seq-filter (lambda (overlay) (overlay-get overlay 'parley-table))
                      (overlays-in (point-min) (point-max)))
          (lambda (one other) (< (overlay-start one) (overlay-start other))))))

(defun parley-transcript-test--form (overlay)
  "Return the buffer text OVERLAY covers, which is the form parley rendered."
  (with-current-buffer (overlay-buffer overlay)
    (buffer-substring-no-properties (overlay-start overlay)
                                    (overlay-end overlay))))

(defun parley-transcript-test--source (overlay)
  "Return the table OVERLAY carries, which is the table the agent wrote."
  (overlay-get overlay 'parley-table))

(defun parley-transcript-test--text (buffer)
  "Return the whole of BUFFER's text, properties and all dropped."
  (with-current-buffer buffer
    (buffer-substring-no-properties (point-min) (point-max))))

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

(defun parley-transcript-test--resize (buffer width)
  "Give the selected frame WIDTH columns and render BUFFER's tables again.
BUFFER has to be in the selected window, which is the window
`parley-transcript--width' reads.

Batch Emacs never redisplays and
`parley-transcript--realign-tables' runs during redisplay, so the
hook it is on is run here by hand.  What is under test is what
the hook does; that `parley-transcript-mode' puts it on the
buffer's own value is what makes it the hook Emacs will call."
  (set-frame-width (selected-frame) width)
  (with-current-buffer buffer
    (run-hooks 'window-configuration-change-hook)))

(defun parley-transcript-test--cells (line)
  "Return the cells LINE holds, trimmed, one for each column of the table.
What stands between two bars, less the two outer ones, which are
the edges of the grid and not cells.  A line of a wrapped row
answers this with as many cells as any other line of the table,
and with an empty one wherever that row's cell has run out of
words before its neighbours have."
  (mapcar #'string-trim (butlast (cdr (split-string line "|")))))

(ert-deftest parley-transcript-test-renders-a-table-as-the-buffers-own-text ()
  "A table stands in the buffer as the text of the form parley rendered.

The buffer is a rendering throughout and a table is no exception:
what stands there is the aligned form as text, with no `display'
property over any of it.  A form shown through one is not text --
the buffer's own machinery never looks inside it, so nothing in
such a table could ever be a button, which `button-at' and
`next-button' find by walking buffer positions.

The table the agent wrote is on the overlay instead, and is gone
from the buffer: a rendering that left the text alone fails the
alignment, and one that kept the source under the form fails the
last assertion.

The faces are in `font-lock-face' and nothing carries `face'.
`font-lock-defaults' is `(nil t)' in a comint buffer, so global
font lock turns on there with no keywords at all and stripping
`face' is the only thing left for it to do.

Two turns, each with a table in it, because where a table is is
an offset into what the render pass returned: the second table's
is one the length of the first turn's block into that string, and
a pass that forgot to count the turns before it would render over
the wrong text and pass everything else here.

The rows of that second one end without the closing bar the first
one's have, which is the other way an agent writes a table, and
its last cell is one column wide -- which is the cell the aligner
drops when no bar closes it, unless the copy it is given has that
bar put back.  Every cell of it is read out of what was rendered
for that reason, and each of those one-column cells is a
character the rest of the table does not hold."
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
             (forms (mapcar #'parley-transcript-test--form overlays)))
        (should (= 2 (length overlays)))
        (should (equal (list parley-transcript-test--table other)
                       (mapcar #'parley-transcript-test--source overlays)))
        (dolist (form forms)
          (should (= 1 (length (seq-uniq (parley-transcript-test--bars form))))))
        (should (< 1 (length (seq-uniq (parley-transcript-test--bars
                                        parley-transcript-test--table)))))
        (dolist (cell '("name" "what it does" "bbbbbb" "a much longer cell"))
          (should (string-search cell (car forms))))
        (dolist (cell '("id" "flag" "1" "x" "22" "q"))
          (should (string-search cell (cadr forms))))
        (dolist (overlay overlays)
          (should-not (overlay-get overlay 'display))
          (with-current-buffer buffer
            (let ((start (overlay-start overlay))
                  (end (overlay-end overlay)))
              (should-not (text-property-not-all start end 'display nil))
              (should-not (text-property-not-all start end 'face nil))
              (should-not (text-property-not-all start end 'font-lock-face
                                                 'markdown-table-face)))))
        (should-not (string-search parley-transcript-test--table
                                   (parley-transcript-test--text buffer)))))))

(ert-deftest parley-transcript-test-renders-a-table-that-needs-no-aligning ()
  "A table the agent had already aligned is the buffer's own text like any other.

Its form is the characters he wrote, so nothing but the
properties tells the form from the table -- and the text the
render pass delivers carries markdown-mode's own: `x^2^' in a
cell is a superscript, and what hides the markers around one is a
`display' property.  A render that compared the two as text would
leave that text standing as the table and the `display' in it,
where a table here is the form, its face, and nothing else.

That the aligner leaves this table alone is asserted first, so a
fixture it would have rewritten anyway could not pass this by
being rewritten."
  (skip-unless (executable-find "jq"))
  (let ((text (concat "| name | power |\n"
                      "|------|-------|\n"
                      "| a    | x^2^  |")))
    (should (equal text (parley-transcript--alignment text)))
    (parley-transcript-test--with-session
        (list (parley-transcript-test--text-turn text))
      (let ((overlay (car (parley-transcript-test--wait
                           (lambda ()
                             (parley-transcript-test--tables buffer))))))
        (should (equal text (parley-transcript-test--source overlay)))
        (should (equal text (parley-transcript-test--form overlay)))
        (with-current-buffer buffer
          (let ((start (overlay-start overlay))
                (end (overlay-end overlay)))
            (should-not (text-property-not-all start end 'display nil))
            (should-not (text-property-not-all start end 'invisible nil))
            (should-not (text-property-not-all start end 'font-lock-face
                                               'markdown-table-face))))))))

(ert-deftest parley-transcript-test-renders-a-table-again-at-a-new-width ()
  "A table is rendered again for the width of the window, from the agent's table.

Wide enough and it is aligned; too narrow for the aligned form
and its cells are wrapped into the window instead, over as many
lines as they need.  Widened again it comes back to exactly the
form it had before, and that is what says the render reads the
table off the overlay and not the grid out of the buffer: every
line of a wrapped row reads back as a row of its own, so a table
parsed out of the wrapped form would come back aligned to
something the agent never wrote.

The table on the overlay is asserted unchanged through all three
widths.  It is what a render is computed from and the text is
what a render throws away, which is the trade this rendering
makes: the source is the overlay's and no longer the buffer's."
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
              (parley-transcript-test--resize buffer 100)
              (setq aligned (parley-transcript-test--form overlay))
              (should (= 1 (length (seq-uniq
                                    (parley-transcript-test--bars aligned)))))
              (should (equal parley-transcript-test--table
                             (parley-transcript-test--source overlay)))
              (parley-transcript-test--resize buffer 20)
              (let ((wrapped (parley-transcript-test--form overlay))
                    (narrow (window-body-width (selected-window))))
                (should (> (parley-transcript--columns aligned) narrow))
                (should (<= (parley-transcript--columns wrapped) narrow))
                (should (< (length (split-string aligned "\n"))
                           (length (split-string wrapped "\n"))))
                (should (= 1 (length (seq-uniq
                                      (parley-transcript-test--bars wrapped)))))
                (should (string-search wrapped
                                       (parley-transcript-test--text buffer)))
                (should (equal parley-transcript-test--table
                               (parley-transcript-test--source overlay))))
              (parley-transcript-test--resize buffer 100)
              (should (equal aligned (parley-transcript-test--form overlay))))
            (should (equal parley-transcript-test--table
                           (parley-transcript-test--source overlay)))))
      (set-frame-width (selected-frame) columns))))

(ert-deftest parley-transcript-test-wraps-a-cell-of-prose-into-the-width ()
  "A table a cell of prose takes past the width is wrapped into it.

Aligning a wide table makes it wider: the cell of prose sets its
column's width and the table runs off the window.  Wrapping that
cell over several lines and growing the row to match is what
makes it fit, and the aligned form is measured here too so that a
rendering which merely stopped aligning would fail rather than
pass by having done nothing.

Every line of the wrapped row stands in the same columns as the
rest of the table, which is asserted three ways: the bars of
every line are in one place, the row of short cells is still one
line with each cell in its own column, and the lines the prose
wrapped over carry an empty first cell rather than stopping
short.

The prose is read back out of the column it was wrapped in and
joined, because a wrap that dropped a word or put one in the
wrong column would leave the grid as square as ever.

The table is written with its first column marked left and its
second right, because the marks are the agent's and the wrapped
form has to carry them: a column he marked is one he meant to be
read that way."
  (let* ((prose "a cell of prose long enough to run past the edge of the window")
         (text (concat "| step | what it does |\n"
                       "|:---|---:|\n"
                       "| one | " prose " |\n"
                       "| two | short |"))
         (width 40)
         (form (parley-transcript--aligned text width))
         (rows (mapcar #'parley-transcript-test--cells (split-string form "\n"))))
    (should form)
    (should (> (parley-transcript--columns (parley-transcript--alignment text))
               width))
    (should (<= (parley-transcript--columns form) width))
    (should (= 1 (length (seq-uniq (parley-transcript-test--bars form)))))
    (should (member '("step" "what it does") rows))
    (should (member '("two" "short") rows))
    (let ((delimiter (seq-find #'markdown--is-delimiter-row
                               (split-string form "\n"))))
      (should (string-prefix-p "|:" delimiter))
      (should (string-suffix-p ":|" delimiter)))
    (let ((wrapped (seq-take-while
                    (lambda (row) (member (car row) '("one" "")))
                    (seq-drop-while (lambda (row) (not (equal (car row) "one")))
                                    rows))))
      (should (< 1 (length wrapped)))
      (should (equal "one" (car (car wrapped))))
      (should (seq-every-p (lambda (row) (equal "" (car row))) (cdr wrapped)))
      (should (equal prose (string-join (mapcar #'cadr wrapped) " "))))))

(ert-deftest parley-transcript-test-leaves-a-table-nothing-narrows-too-wide ()
  "A table holding a word longer than the window stays wider than the window.

Wrapping packs words and never breaks one, so a column holding a
word that will not fit gives nothing and the table settles wider
than the width it was rendered for.  That is the honest outcome:
a table past the edge is one the operator can still read back,
where a word broken across two lines costs him the word.

The width it settles at is what this pins, and 45 is that width
by arithmetic: 34 columns for the word, 4 for `step', and 7 for
the bars and the spaces a grid of two columns spends.  The floor
under the incompressible column is what puts it there -- without
one the packing would narrow both columns to nothing, the word
would stand past its column's edge anyway, and the bars of the
line it stands on would land nowhere near the bars of the rest.
Both assertions fail then, which is the case the floor is for:
the word stands whole at any width and asserting that alone would
pass however the columns were computed.

The packing is then asked directly for a cell at a width the
floor would never hand it, because the floor is exactly what
keeps it from being asked: a packing that broke a word is
unreachable through the table and is pinned here instead."
  (let* ((word "supercalifragilisticexpialidocious")
         (text (concat "| step | note |\n"
                       "|---|---|\n"
                       "| one | " word " |\n"
                       "| two | a cell of prose that wrapping can narrow |"))
         (form (parley-transcript--aligned text 20))
         (rows (mapcar #'parley-transcript-test--cells (split-string form "\n"))))
    (should form)
    (should (member (list "one" word) rows))
    (should (= 45 (parley-transcript--columns form)))
    (should (= 1 (length (seq-uniq (parley-transcript-test--bars form)))))
    (should (equal (list word "and")
                   (parley-transcript--wrapped-cell (concat word " and") 5)))))

(ert-deftest parley-transcript-test-wraps-a-cell-of-cjk-by-the-columns-it-takes ()
  "A table of CJK text is wrapped by the columns it displays in, not its characters.

A CJK character is one character and two columns, so a grid
padded to the character is a grid that lines up in none: every
line would carry the same number of characters and each a
different number of columns.  What that costs is the grid
itself, which is the whole of what a table is for.

The lines are measured in columns for that reason, and against
each other rather than against the width alone -- padding by the
character leaves a line short of the width rather than past it,
so a table that merely fits says nothing about it.

Two widths, because the column is measured twice over and each
measurement binds at one of them.  At 30 it is the packing that
decides, which fills a column it is given; at 14 there is no
width left to give and it is the floor under the column, which is
the widest word standing in it.  A floor counted in characters
sits under a CJK column at half the height it needs, the word it
was meant to keep room for stands past the edge of its column,
and the grid the other width asserts goes with it."
  (let* ((text (concat "| id | note |\n"
                       "|---|---|\n"
                       "| 1 | 日本語 の テキスト が ここ に あります |\n"
                       "| 22 | short |"))
         (wide (parley-transcript--aligned text 30))
         (narrow (parley-transcript--aligned text 14)))
    (should (> (parley-transcript--columns (parley-transcript--alignment text))
               30))
    (should (<= (parley-transcript--columns wide) 30))
    (dolist (form (list wide narrow))
      (should form)
      (should (= 1 (length (seq-uniq (mapcar #'string-width
                                             (split-string form "\n")))))))))

(ert-deftest parley-transcript-test-keeps-a-bar-inside-a-cell-out-of-the-grid ()
  "A bar standing inside a cell is not a column boundary, and a wrap leaves it none.

The bar inside a wiki link is one markdown-mode reads over, so
`[[target|link words]]' is one cell and not two -- and it is read
over only while the link is whole.  A wrap that broke the link at
its space would leave `[[target|link' standing on a line of its
own, where that bar is a boundary again: the row reads as three
columns where the table has two, and the line the wrap produced
is the one line of the table whose grid is gone.

So the link is one piece of the wrap, and every line of the
wrapped form is read back here with markdown-mode's own
`markdown--table-line-to-columns' -- the reader
`markdown-table-align' measures the cells with, and the one whose
answer decides whether a bar is a boundary at all.  Every line
has to hold the two columns the table has, and the link has to
come back whole in one of them.

A word stands before the link in that cell, and it is what makes
the packing the thing under test rather than the width: a wrap
which packed words would fit `[[target|link' onto the line that
word begins and break the link there, where one packing the link
whole starts a line for it.  Without that word the link begins
its column's first line either way and no packing can be told
from another.

That the table was wrapped at all is asserted beside it, because
a rendering which stopped wrapping this table would keep its
columns too: the link and the prose after it each stand on a line
of their own, in the column they were written in, under a first
cell left empty.

At 25 the link is a piece nothing can narrow, exactly as a long
word is, and the table settles at 30: 21 columns for the link, 2
for `id', and 7 for the bars and the spaces a grid of two columns
spends.  Wider than the window is the honest outcome -- the other
way out is a bar put where the grid has none.

The floor under that column is what puts it there, and what says
so is the grid asserted at 25 beside the width: narrow the column
past the link and the link stands over the edge of it, so the
line it is on comes out longer than every other line of the table
and the widest line is 30 either way.

Wiki links are markdown-mode's own and off by default, so they
are turned on here: with them off that bar is a boundary, what
stands either side of it is a cell of its own, and there is
nothing here to hold together."
  (let* ((markdown-enable-wiki-links t)
         (link "[[target|link words]]")
         (text (concat "| id | note |\n"
                       "|---|---|\n"
                       "| 1 | first " link " more prose all fit |"))
         (form (parley-transcript--aligned text 34))
         (rows (mapcar #'markdown--table-line-to-columns
                       (split-string form "\n"))))
    (should form)
    (should (<= (parley-transcript--columns form) 34))
    (should (= 1 (length (seq-uniq (mapcar #'string-width
                                           (split-string form "\n"))))))
    (should (seq-every-p (lambda (row) (= 2 (length row))) rows))
    (should (member (list "1" "first") rows))
    (should (member (list "" link) rows))
    (should (member (list "" "more prose all fit") rows))
    (let* ((tight (parley-transcript--aligned text 25))
           (lines (split-string tight "\n")))
      (should (= 30 (parley-transcript--columns tight)))
      (should (= 1 (length (seq-uniq (mapcar #'string-width lines)))))
      (should (member (list "" link)
                      (mapcar #'markdown--table-line-to-columns lines))))))

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
assertion rather than passing this test by having done nothing.
The fenced one is the only copy left standing as the agent wrote
it, because the other has been replaced by the form parley rendered
-- so the search that finds it is the search that says so."
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
                     (parley-transcript-test--source (car overlays))))
      (with-current-buffer buffer
        (save-excursion
          (goto-char (point-min))
          (should (search-forward parley-transcript-test--table nil t))
          (let ((begin (match-beginning 0))
                (end (match-end 0)))
            (should-not (seq-find (lambda (overlay)
                                    (overlay-get overlay 'parley-table))
                                  (overlays-in begin end)))
            (goto-char end)
            (should-not (search-forward parley-transcript-test--table
                                        nil t))))))))

(ert-deftest parley-transcript-test-leaves-a-truncated-table-as-it-stands ()
  "A table `comint-truncate-buffer' cut the head off is left as it stands.

Truncation is how a comint buffer is kept from growing without
end and it takes the top of the conversation away, which can be
the first lines of a table.  What is left there is not the form
parley wrote, and rendering the table again over it would put back
lines the operator watched go -- so the overlay is dropped and
what is left of the table is never touched again.

That the cut landed inside the table is asserted rather than
assumed: what the overlay covers afterwards has to be the end of
the form and not the whole of it.

The width is changed after the cut, from one the aligned form
fits to one it does not, so a render that went ahead would have
wrapped the table into text nothing here could mistake for what
stands there."
  (skip-unless (executable-find "jq"))
  (let ((columns (frame-width)))
    (unwind-protect
        (parley-transcript-test--with-session
            (list (parley-transcript-test--text-turn parley-transcript-test--table))
          (let ((overlay (car (parley-transcript-test--wait
                               (lambda ()
                                 (parley-transcript-test--tables buffer))))))
            (save-window-excursion
              (set-window-buffer (selected-window) buffer)
              (parley-transcript-test--resize buffer 100)
              (let ((form (parley-transcript-test--form overlay))
                    (left nil))
                (with-current-buffer buffer
                  ;; Cut to the lines from the table's second line on,
                  ;; which is the head of the conversation going and
                  ;; the head of the table with it.
                  (let ((comint-buffer-maximum-size
                         (count-lines (save-excursion
                                        (goto-char (overlay-start overlay))
                                        (forward-line 1)
                                        (point))
                                      (point-max))))
                    (comint-truncate-buffer))
                  (setq left (parley-transcript-test--text buffer)))
                (should (string-suffix-p (parley-transcript-test--form overlay)
                                         form))
                (should (< (length (parley-transcript-test--form overlay))
                           (length form)))
                (parley-transcript-test--resize buffer 20)
                (should-not (parley-transcript-test--tables buffer))
                (should (equal left (parley-transcript-test--text buffer)))))))
      (set-frame-width (selected-frame) columns))))

(ert-deftest parley-transcript-test-leaves-a-table-the-operator-edited ()
  "A table the operator has edited is left as he left it.

This is his buffer and he can type in it.  What stands in a
region he has changed is not the form parley wrote there and is
not parley's to write over: the overlay is dropped and the table
is never rendered again, where a render that went ahead would take
his edit back out at the next resize.

The character goes inside the region and not at either end of it,
which is where an overlay takes nothing in: the table is what he
edited, not the text around it."
  (skip-unless (executable-find "jq"))
  (let ((columns (frame-width)))
    (unwind-protect
        (parley-transcript-test--with-session
            (list (parley-transcript-test--text-turn parley-transcript-test--table))
          (let ((overlay (car (parley-transcript-test--wait
                               (lambda ()
                                 (parley-transcript-test--tables buffer))))))
            (save-window-excursion
              (set-window-buffer (selected-window) buffer)
              (parley-transcript-test--resize buffer 100)
              (let ((form (parley-transcript-test--form overlay))
                    (left nil))
                (with-current-buffer buffer
                  (let ((inhibit-read-only t))
                    (save-excursion
                      (goto-char (+ 2 (overlay-start overlay)))
                      (insert "!")))
                  (setq left (parley-transcript-test--text buffer)))
                (should-not (equal form (parley-transcript-test--form overlay)))
                (parley-transcript-test--resize buffer 20)
                (should-not (parley-transcript-test--tables buffer))
                (should (equal left (parley-transcript-test--text buffer)))))))
      (set-frame-width (selected-frame) columns))))

(ert-deftest parley-transcript-test-renders-a-table-and-disturbs-nothing ()
  "Rendering a table again leaves his undo, his point and comint its mark.

The replacement is parley's and is none of his: `undo' reaches
past it to his own last change, so the buffer's undo list carries
no entry for it at all.

Point stands where he left it.  comint reads point back off the
buffer once its output filters have run -- it is the operator's,
and a render that moved it would have moved his -- so it is
pinned on the text it was on and not on a number.

Point inside the table is pinned too, and separately: the
deletion takes the text it stands in, so a marker is not what
keeps it and `save-excursion' alone brings it to the head of the
grid.  It stands the same distance into the form, which the
table's own start is measured from because that start does not
move.  And from a distance the next form is too short for --
point at the end of a wrapped form, widened to an aligned one 19
characters shorter -- it stands at the end of the table and not
in the sentence after it.

The process mark is where comint left it, which is where the
next output the session writes goes in.

The width is changed from one the aligned form fits to one it
does not, and the buffer really does change length across it: a
render that did nothing at all would pass every other assertion
here."
  (skip-unless (executable-find "jq"))
  (let ((columns (frame-width)))
    (unwind-protect
        (parley-transcript-test--with-session
            (list (parley-transcript-test--text-turn
                   (concat parley-transcript-test--table "\n\nand that is all")))
          (let ((overlay (car (parley-transcript-test--wait
                               (lambda ()
                                 (parley-transcript-test--tables buffer))))))
            (save-window-excursion
              (set-window-buffer (selected-window) buffer)
              (parley-transcript-test--resize buffer 100)
              (with-current-buffer buffer
                (let ((mark (process-mark (get-buffer-process (current-buffer))))
                      (size (buffer-size)))
                  (should (= (marker-position mark) (point-max)))
                  (buffer-enable-undo)
                  (setq buffer-undo-list nil)
                  (goto-char (point-min))
                  (should (search-forward "and that is all" nil t))
                  (goto-char (match-beginning 0))
                  (parley-transcript-test--resize buffer 20)
                  (should (/= size (buffer-size)))
                  (should (null buffer-undo-list))
                  (should (looking-at-p "and that is all"))
                  (should (= (marker-position mark) (point-max)))
                  (goto-char (+ 5 (overlay-start overlay)))
                  (parley-transcript-test--resize buffer 100)
                  (should (= (point) (+ 5 (overlay-start overlay))))
                  (parley-transcript-test--resize buffer 20)
                  (goto-char (overlay-end overlay))
                  (parley-transcript-test--resize buffer 100)
                  (should (= (point) (overlay-end overlay)))
                  (should (null buffer-undo-list)))))))
      (set-frame-width (selected-frame) columns))))


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
                     "❯ what is here")))
    ;; And an entry is something imenu can act on, not merely something
    ;; shaped like one: the command itself is what has to land on the
    ;; prompt.
    (with-current-buffer buffer
      (goto-char (point-min))
      (imenu "what is here")
      (should (looking-at-p "❯ what is here")))))

(ert-deftest parley-transcript-test-indexes-no-injected-turn ()
  "A turn the transcript marked as injected takes no imenu entry.

The site that records an entry is reached only for a record the
transcript did not mark, so nothing indexes an injection whether
or not it reaches the buffer -- the skill load here does reach
it, as the line naming the skill, and the index still holds only
the prompt under it.  An injection is not a prompt, and the
operator jumping through the index is looking for what he
typed."
  (skip-unless (executable-find "jq"))
  (parley-transcript-test--with-session
      (list (parley-transcript-test--meta-turn
             (parley-transcript-test--skill-load
              "/home/x/.claude/skills/commit-messages"
              "A commit message is one line"))
            (parley-transcript-test--user-turn "and now commit it"))
    (should (parley-transcript-test--wait
             (lambda ()
               (equal (parley-transcript-test--shown buffer)
                      (list "● Loaded skill \"A commit message is one line\""
                            "❯ and now commit it")))))
    (should (equal (mapcar #'car (parley-transcript-test--index buffer))
                   (list "and now commit it")))))

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
                     (list "❯ what is here"
                           "❯ first line of it"
                           (concat "❯ " (make-string 100 ?x))))))))

(ert-deftest parley-transcript-test-labels-a-command-turn-by-what-is-shown ()
  "A command turn is indexed under the line the buffer shows, not the wrapper.

The index is recorded from the record's text in the render pass,
so a turn indexed before it was unwrapped would be labelled
`<command-message>one</command-message>' -- one label for every
slash command of that name, and two of them told apart by a
number rather than by what he asked."
  (skip-unless (executable-find "jq"))
  (parley-transcript-test--with-session
      (list (parley-transcript-test--command-turn "/one" "what is here")
            (parley-transcript-test--command-turn "/one" "and what is there")
            (parley-transcript-test--command-turn "/plugin" ""))
    (should (parley-transcript-test--wait
             (lambda () (= 3 (length (parley-transcript-test--shown buffer))))))
    (should (equal (mapcar #'car (parley-transcript-test--index buffer))
                   (list "/one what is here" "/one and what is there"
                         "/plugin")))))

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
             (lambda () (member "❯ with the third"
                                (parley-transcript-test--shown buffer)))))
    (let ((imenu-max-item-length nil))
      (should (equal (mapcar #'car (parley-transcript-test--index buffer))
                     '("what is here" "continue" "continue<2>" "continue<3>"))))
    (with-current-buffer buffer
      (dolist (entry '(("continue" . "❯ with the first")
                       ("continue<2>" . "❯ with the second")
                       ("continue<3>" . "❯ with the third")))
        (goto-char (point-min))
        (imenu (car entry))
        (should (looking-at-p "❯ continue"))
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
               (lambda () (member "❯ the second of them"
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
          (should (looking-at-p "❯ the second of them")))))))

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
             (lambda () (member "❯ and fix it"
                                (parley-transcript-test--shown buffer)))))
    ;; The blank lines the prompt opened with are not quoted into the
    ;; buffer, which is what leaves the label and the entry on one line.
    (should-not (member "❯ " (parley-transcript-test--shown buffer)))
    (let ((entry (assoc "find the bug"
                        (parley-transcript-test--index buffer))))
      (should entry)
      (should (equal (parley-transcript-test--at buffer entry)
                     "❯ find the bug")))))

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
                     "❯ ask it something")))))

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
    (should-not (member "❯ " (parley-transcript-test--shown buffer)))
    (let ((entry (assoc "ask it something"
                        (parley-transcript-test--index buffer))))
      (should entry)
      (should (equal (parley-transcript-test--at buffer entry)
                     "❯ ask it something")))))

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
             (lambda () (member "❯ the last word"
                                (parley-transcript-test--shown buffer)))))
    (with-current-buffer buffer
      (let ((comint-buffer-maximum-size 4))
        (comint-truncate-buffer))
      (should-not (member "❯ what is here" (parley-transcript-test--shown buffer))))
    (let ((index (parley-transcript-test--index buffer)))
      (should (equal (mapcar #'car index) '("the last word")))
      (should (equal (parley-transcript-test--at buffer (car index))
                     "❯ the last word")))))

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
             (lambda () (member "❯ and one more thing"
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
             (lambda () (member "● 2 tool calls"
                                (parley-transcript-test--shown buffer)))))
    (parley-transcript-test--write
     file (list (parley-transcript-test--user-turn "after the run")
                (parley-transcript-test--tool-turn 3)))
    (should (parley-transcript-test--wait
             (lambda () (member "● 3 tool calls"
                                (parley-transcript-test--shown buffer)))))
    (let ((index (parley-transcript-test--index buffer)))
      (should (equal (mapcar #'car index)
                     '("what is here" "after the run")))
      (should (equal (parley-transcript-test--at buffer (cadr index))
                     "❯ after the run")))))

(provide 'parley-transcript-test)
;;; parley-transcript-test.el ends here
