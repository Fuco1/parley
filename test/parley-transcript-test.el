;;; parley-transcript-test.el --- Tests for parley-transcript -*- lexical-binding: t -*-

;;; Commentary:

;; What is worth testing here is not the elisp, which is a dozen lines,
;; but the pipeline: whether jq really drops the payloads, whether a
;; line appended after the history has arrived really shows up, and
;; whether killing the buffer really takes `tail' and `jq' with it.
;; None of those can be established by reading the code, so every test
;; below runs the real `parley-transcript' over a real temporary
;; transcript and looks at what came out.
;;
;; The tests need `jq' on PATH and are skipped without it.

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

;; Eight lines in the shapes a Claude Code transcript really holds: a
;; user turn whose content is a bare string, an assistant turn that
;; spoke and then made two tool calls, the `tool_result' turn that came
;; back, an assistant turn that was only thinking, a `system' line, a
;; `summary' line, an assistant turn whose text spans two lines, and a
;; user turn with no content at all.
(defconst parley-transcript-test--lines
  '("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"what is here\"}}"
    "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"Let me look.\"},{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"Bash\",\"input\":{\"command\":\"ls PAYLOAD-MUST-NOT-REACH-EMACS\"}},{\"type\":\"tool_use\",\"id\":\"toolu_2\",\"name\":\"Read\",\"input\":{\"file_path\":\"/PAYLOAD-MUST-NOT-REACH-EMACS\"}}]}}"
    "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"toolu_1\",\"content\":\"PAYLOAD-MUST-NOT-REACH-EMACS\"}]},\"toolUseResult\":{\"stdout\":\"PAYLOAD-MUST-NOT-REACH-EMACS\"}}"
    "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"PAYLOAD-MUST-NOT-REACH-EMACS\"}]}}"
    "{\"type\":\"system\",\"content\":\"PAYLOAD-MUST-NOT-REACH-EMACS\",\"level\":\"info\"}"
    "{\"type\":\"summary\",\"summary\":\"PAYLOAD-MUST-NOT-REACH-EMACS\"}"
    "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"first line\\nsecond line\"}]}}"
    "{\"type\":\"user\",\"message\":{\"role\":\"user\"}}")
  "The transcript the tests project, one JSONL line per element.")

;; What the eight lines above project to.  Three objects: the two turns
;; that said something and the one that only made tool calls.  The
;; tool result, the thinking, the two non-message lines and the empty
;; turn are all dropped, and the text spanning two lines is still one.
(defconst parley-transcript-test--projection
  '("{\"role\":\"user\",\"text\":\"what is here\",\"tools\":0}"
    "{\"role\":\"assistant\",\"text\":\"Let me look.\",\"tools\":2}"
    "{\"role\":\"assistant\",\"text\":\"first line\\nsecond line\",\"tools\":0}")
  "The objects `parley-transcript-test--lines' must reach Emacs as.")


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

(defun parley-transcript-test--objects (buffer)
  "Return the non-empty lines of BUFFER."
  (split-string (with-current-buffer buffer
                  (buffer-substring-no-properties (point-min) (point-max)))
                "\n" t))

(defun parley-transcript-test--group (pgid)
  "Return the commands of the live processes in process group PGID.
Each is what `pgrep -a' printed with its pid dropped, so that
`tail' names the process and not the shell whose -c argument
merely mentions it."
  (mapcar (lambda (line) (replace-regexp-in-string "\\`[0-9]+ " "" line))
          (split-string (shell-command-to-string (format "pgrep -a -g %d" pgid))
                        "\n" t)))

(defun parley-transcript-test--running (pgid program)
  "Return the command of PROGRAM in process group PGID, nil if it has none."
  (seq-find (lambda (command) (string-prefix-p (concat program " ") command))
            (parley-transcript-test--group pgid)))

(defmacro parley-transcript-test--with-session (lines &rest body)
  "Run BODY over a transcript buffer following a file holding LINES.
BODY sees `file', the transcript, and `buffer', the buffer
`parley-transcript' opened for a session record naming it.  Both
the buffer and the file are gone afterwards, and so -- this being
the point of the last test -- is the pipeline."
  (declare (indent 1) (debug (form body)))
  `(let* ((file (make-temp-file "parley-transcript-test-" nil ".jsonl"))
          (session (list :name "test" :session-id "test" :transcript file))
          (buffer nil))
     (unwind-protect
         (progn
           (parley-transcript-test--write file ,lines)
           (save-window-excursion (parley-transcript session))
           (setq buffer (get-buffer (parley-transcript-buffer-name session)))
           (should buffer)
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

(ert-deftest parley-transcript-projects-the-history ()
  "The whole history reaches Emacs, projected and one object per line."
  (skip-unless (executable-find "jq"))
  (parley-transcript-test--with-session parley-transcript-test--lines
    (should (equal (parley-transcript-test--wait
                    (lambda ()
                      (let ((objects (parley-transcript-test--objects buffer)))
                        (and (= (length objects)
                                (length parley-transcript-test--projection))
                             objects))))
                   parley-transcript-test--projection))))

(ert-deftest parley-transcript-drops-the-tool-payloads ()
  "Nothing a tool sent or received reaches the Emacs process."
  (skip-unless (executable-find "jq"))
  (parley-transcript-test--with-session parley-transcript-test--lines
    (parley-transcript-test--wait
     (lambda ()
       (= (length (parley-transcript-test--objects buffer))
          (length parley-transcript-test--projection))))
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
    (should (parley-transcript-test--wait
             (lambda ()
               (= (length (parley-transcript-test--objects buffer))
                  (length parley-transcript-test--projection)))))
    (parley-transcript-test--write
     file '("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"and now this\"}}"))
    (should (equal (parley-transcript-test--wait
                    (lambda ()
                      (let ((objects (parley-transcript-test--objects buffer)))
                        (and (> (length objects)
                                (length parley-transcript-test--projection))
                             (car (last objects))))))
                   "{\"role\":\"user\",\"text\":\"and now this\",\"tools\":0}"))))

(ert-deftest parley-transcript-kill-stops-the-pipeline ()
  "Killing the buffer leaves no `tail' and no `jq' behind.
The pipeline runs on a pty, so its shell heads its own process
group and every process in it is what `pgrep -g' below lists."
  (skip-unless (executable-find "jq"))
  (parley-transcript-test--with-session parley-transcript-test--lines
    (let ((pgid (process-id (get-buffer-process buffer))))
      (should (parley-transcript-test--wait
               (lambda () (parley-transcript-test--running pgid "tail"))))
      (should (parley-transcript-test--running pgid "jq"))
      (kill-buffer buffer)
      (should (parley-transcript-test--wait
               (lambda () (null (parley-transcript-test--group pgid))))))))

(provide 'parley-transcript-test)
;;; parley-transcript-test.el ends here
