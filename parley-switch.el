;;; parley-switch.el --- Pick a live Claude Code or Codex session -*- lexical-binding: t -*-

;; Copyright (C) 2026 Matúš Goljer <matus.goljer@gmail.com>

;; Author: Matúš Goljer <matus.goljer@gmail.com>
;; Maintainer: Matúš Goljer <matus.goljer@gmail.com>
;; Created: 9th September 2026
;; Keywords: convenience, processes

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

;; `parley-switch' picks one of the sessions `parley-sessions' found
;; and hands it to `parley-transcript', which is what owns the buffer
;; a session is read in and the pipeline that fills it.  Nothing here
;; makes a buffer of its own: this file is the picker and that one is
;; the view.  A dozen or two sessions is the whole list, so nothing
;; here is asynchronous.
;;
;; The picker is built on sallet because a session is listed by
;; columns and a sallet source can match one column at a time: each
;; word typed goes to the column it names, so a word aimed at a name
;; does not also match every session whose status or window happens
;; to hold it.  Every session in one status shares its word, and a
;; window is digits a name can hold too, so a word matched against a
;; whole row can match rows it was not aimed at.
;;
;; The Claude Code sessions and the Codex sessions are two sources in
;; that one view, and sallet draws each under a header naming its
;; CLI, so a row says which CLI its session runs by the header it is
;; drawn under and carries no mark saying it again.
;;
;; Only the picker gains from sallet, so parley does not require it.
;; Without sallet `parley-switch' picks with `parley-read-session', a
;; `completing-read' over one row per session, and what it loses is
;; the aim: a word is matched against the whole of a row.

;;; Code:

(require 'parley)
(require 'parley-transcript)
(require 'seq)

;; A soft requirement, and the only one in the package: with sallet
;; missing `parley-switch' reads the session with `completing-read'.
(require 'sallet nil t)

(declare-function sallet "sallet" (sources))
(declare-function sallet-candidate-aref "sallet-core" (candidates index))
(declare-function sallet-make-candidate-indices "sallet-core" (candidates))
(declare-function sallet-state-get-prompt "sallet-state" (state))
(declare-function sallet-compose-filters-by-pattern "sallet-filters"
                  (filter-alist candidates indices pattern))


;;; With sallet: the columns kept apart

(defvar parley-switch--sessions 'unasked
  "The live sessions, ordered by status, while `parley-switch' is open.
Both sallet sources take their candidates from this one list, so
opening the switcher discovers the sessions once and not once per
source.  It is `unasked' anywhere else, and a source used outside
`parley-switch' discovers the sessions itself.")

(defun parley-switch--candidates (vendor)
  "Return one sallet candidate per live session whose `:vendor' is VENDOR.
A candidate is the cons of the fields plist and the record it
was built from: the fields are what sallet matches and renders,
the record is what the action needs.  Nothing looks a session up
by name afterwards, which is what keeps two sessions sharing one
from being confused.

The sessions are the list `parley-switch' binds
`parley-switch--sessions' to, and outside that command what
`parley-sessions-by-status' returns.  Both are in status order."
  (mapcar (lambda (session) (cons (parley-session-fields session) session))
          (seq-filter (lambda (session)
                        (eq (plist-get session :vendor) vendor))
                      (if (eq parley-switch--sessions 'unasked)
                          (parley-sessions-by-status)
                        parley-switch--sessions))))

(defun parley-switch--field-filter (key)
  "Return a sallet filter matching its pattern against the column KEY.
KEY is a keyword of the fields plist of a candidate, so this is
what makes the columns matchable one at a time."
  (lambda (candidates indices pattern)
    (let ((regexp (regexp-quote pattern)))
      (seq-filter
       (lambda (index)
         (string-match-p
          regexp (plist-get (sallet-candidate-aref candidates index) key)))
       indices))))

(defun parley-switch--matcher (candidates state)
  "Match session CANDIDATES against the prompt of STATE, column by column.
A token is matched against the session name, unless it begins
with @ for the WINDOW.PANE of the session's pane or : for the
status.  The @ and the : are sigils the operator types to name a
column and are stripped before matching: a WINDOW.PANE is the one
the row's last column shows, and a status is the word its status
column shows.  Any other token is a word of the name, one
beginning with / included, and is matched against the whole name
and not the part of it a row has room for.  Tokens are matched in
sequence, so `orc @3.1' is the session named orc in that window
and pane."
  (sallet-compose-filters-by-pattern
   `(("\\`@\\(.*\\)" 1 ,(parley-switch--field-filter :window))
     ("\\`:\\(.*\\)" 1 ,(parley-switch--field-filter :status))
     (t ,(parley-switch--field-filter :name)))
   candidates
   (sallet-make-candidate-indices candidates)
   (sallet-state-get-prompt state)))

(defun parley-switch--renderer (candidate _state _user-data)
  "Render session CANDIDATE as its row of columns.
Its name is drawn open when `parley-session-buffer' finds a
buffer for its session, as the `completing-read' fallback draws
it."
  (parley-session-row (car candidate) (parley-session-buffer (cdr candidate))))

(defun parley-switch--action (_source candidate)
  "Show the transcript buffer of the session CANDIDATE was built for."
  (parley-transcript (cdr candidate)))

;; `sallet-defsource' is a macro, so the sources cannot be written as
;; plain top-level forms: with sallet absent from the load path there
;; is nothing to expand them and byte compiling this file would fail.
;; Left as data for `eval' they cost nothing when sallet is not there.
(when (featurep 'sallet)
  (eval '(progn
           (sallet-defsource parley-claude nil
             "Live Claude Code sessions."
             (candidates (lambda () (parley-switch--candidates 'claude)))
             (matcher parley-switch--matcher)
             (renderer parley-switch--renderer)
             (action parley-switch--action)
             (header "Claude Code sessions"))
           (sallet-defsource parley-codex nil
             "Live Codex sessions."
             (candidates (lambda () (parley-switch--candidates 'codex)))
             (matcher parley-switch--matcher)
             (renderer parley-switch--renderer)
             (action parley-switch--action)
             (header "Codex sessions")))
        t))


;;; Switching to a session

;;;###autoload
(defun parley-switch ()
  "Switch to the transcript buffer of a live Claude Code or Codex session.
The sessions are the ones `parley-sessions' finds, ordered by
status, and the one picked is shown by `parley-transcript': the
same buffer, with the same pipeline in it, that calling that
command with the record would have reached.

With sallet installed the pick is one sallet session over two
sources, `sallet-source-parley-claude' and then
`sallet-source-parley-codex', which match and render the sessions
as columns.  Each lists the sessions of its own CLI under a
header naming it, which is what says which CLI a row runs.  The
sessions are discovered once, here, and both sources take theirs
from that one list.

Without sallet the pick is a `completing-read' over one row per
session, beginning with its name.  The sources are what the
sallet frontend needs and they exist only if sallet was there
when this file was loaded, so that -- and not the feature -- is
what decides."
  (interactive)
  (let ((sources '(sallet-source-parley-claude sallet-source-parley-codex)))
    (if (seq-every-p #'fboundp sources)
        (let ((parley-switch--sessions (parley-sessions-by-status)))
          (sallet sources))
      (parley-transcript (parley-read-session)))))

(provide 'parley-switch)
;;; parley-switch.el ends here
