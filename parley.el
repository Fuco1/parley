;;; parley.el --- Read and drive local Claude Code sessions -*- lexical-binding: t -*-

;; Copyright (C) 2026 Matúš Goljer <matus.goljer@gmail.com>

;; Author: Matúš Goljer <matus.goljer@gmail.com>
;; Maintainer: Matúš Goljer <matus.goljer@gmail.com>
;; Version: 0.0.1
;; Created: 9th September 2026
;; Package-Requires: ((emacs "28.1") (markdown-mode "2.3"))
;; Keywords: convenience, processes
;; URL: https://github.com/Fuco1/parley

;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License
;; as published by the Free Software Foundation; either version 3
;; of the License, or (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; A conversation view for the Claude Code sessions running on this
;; machine.  Every session writes an append-only JSONL transcript, and
;; every session started inside tmux carries the pane it lives in.
;; Parley reads the first and types into the second.
;;
;; What you get is the conversation and nothing else: the tool calls an
;; agent makes on its way to an answer collapse to a single line saying
;; how many there were.
;;
;; Sessions are discovered with `claude agents --json' and are not
;; parley's to start or stop -- tmux owns them, whether they were
;; launched by hand or by something like orc.

;;; Code:

(require 'seq)

(defgroup parley nil
  "A conversation view for local Claude Code sessions."
  :group 'tools
  :prefix "parley-")

(defcustom parley-claude-program "claude"
  "The `claude' executable session discovery asks for the live sessions."
  :type 'string)

(defcustom parley-projects-directory "~/.claude/projects"
  "Directory Claude Code keeps session transcripts under.
Each session's transcript is SESSION-ID.jsonl in the
subdirectory named after the session's working directory."
  :type 'directory)


;;; Discovery

;; `claude agents --json' needs no terminal and prints one entry per
;; live session, but its `kind' field does not say what parley needs to
;; know: a worker lane running `claude -p --input-format stream-json'
;; is reported as interactive too.  Standard input is the discriminator
;; that holds -- a session someone types at has a terminal on fd 0, a
;; headless child has a pipe.

(defun parley--agents-json ()
  "Return the raw output of `claude agents --json'."
  (with-temp-buffer
    (let ((status (call-process parley-claude-program nil t nil
                                "agents" "--json")))
      (unless (eq status 0)
        (error "`%s agents --json' failed (%S): %s" parley-claude-program
               status (buffer-string)))
      (buffer-string))))

(defun parley--agents ()
  "Return the entries of `claude agents --json' as a list of alists."
  (append (json-parse-string (parley--agents-json)
                             :object-type 'alist
                             :null-object nil)
          nil))

(defun parley--stdin-target (pid)
  "Return what standard input of PID resolves to, nil if unreadable."
  (file-symlink-p (format "/proc/%s/fd/0" pid)))

(defun parley--terminal-device-p (target)
  "Non-nil if TARGET names a terminal device.
TARGET is what `/proc/PID/fd/0' resolves to: a `/dev/pts/N' for a
session someone is typing at, and `pipe:[N]' for a headless child."
  (and (stringp target)
       (string-match-p "\\`/dev/\\(pts/[0-9]+\\|tty[A-Za-z0-9]*\\)\\'" target)
       t))

(defun parley--process-environ (pid)
  "Return the environment block of PID, nil if unreadable.
The block is the NUL-separated string `/proc/PID/environ' holds."
  (ignore-errors
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert-file-contents-literally (format "/proc/%s/environ" pid))
      (buffer-string))))

(defun parley--environ-tmux-pane (environ)
  "Return the TMUX_PANE value in ENVIRON, nil if it carries none.
ENVIRON is a NUL-separated environment block.  tmux exports
TMUX_PANE into the pane and every descendant inherits it, so the
value is there whoever started the session -- in the `%N' form
`tmux send-keys -t' takes."
  (let* ((entry (seq-find (lambda (var) (string-prefix-p "TMUX_PANE=" var))
                          (split-string (or environ "") "\0" t)))
         (pane (and entry (substring entry (length "TMUX_PANE=")))))
    (unless (equal pane "") pane)))

(defun parley--transcript-file (cwd session-id)
  "Return the absolute path of the transcript of SESSION-ID run in CWD.
Claude Code names the directory after CWD with every character
outside [A-Za-z0-9] replaced by a dash, so `/home/me/a.b' keeps
its transcripts in `-home-me-a-b'."
  (expand-file-name
   (concat session-id ".jsonl")
   (expand-file-name (replace-regexp-in-string "[^A-Za-z0-9]" "-" cwd)
                     parley-projects-directory)))

(defun parley--session (entry)
  "Return the session record for ENTRY, nil if parley cannot talk to it.
ENTRY is one element of `claude agents --json'."
  (let ((pid (alist-get 'pid entry))
        (cwd (alist-get 'cwd entry))
        (session-id (alist-get 'sessionId entry)))
    (when (and pid cwd session-id
               (parley--terminal-device-p (parley--stdin-target pid)))
      (list :pid pid
            :name (alist-get 'name entry)
            :kind (alist-get 'kind entry)
            :status (alist-get 'status entry)
            :cwd cwd
            :session-id session-id
            :pane (parley--environ-tmux-pane (parley--process-environ pid))
            :transcript (parley--transcript-file cwd session-id)))))

(defun parley-sessions ()
  "Return one record per live Claude Code session on this machine.
A record is a plist with these keys:

  :pid         the session process
  :name        the name `claude agents' gives it, or nil
  :kind        \"interactive\" or \"background\" as reported; a headless
               lane says \"interactive\" too, so this is passed on and
               not believed
  :status      \"idle\" or \"busy\" as reported, or nil
  :cwd         its working directory
  :session-id  its session id
  :pane        the tmux pane it lives in, or nil if it is outside tmux
  :transcript  the absolute path of its JSONL transcript

Sessions whose standard input is not a terminal are headless
children -- a lane running `claude -p' -- and are left out."
  (delq nil (mapcar #'parley--session (parley--agents))))

(provide 'parley)
;;; parley.el ends here
