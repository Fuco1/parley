;;; parley-switch.el --- Pick a live Claude Code session -*- lexical-binding: t -*-

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
;; sallet is what this file is for.  The five columns of
;; `parley-session-fields' are a vector it matches and renders one
;; column at a time, which is the reason to reach for it here; without
;; it the pick is `parley-read-session', which matches the same five
;; baked into one flat row.  Both offer the sessions
;; `parley-sessions-by-status' ordered.
;;
;; The list, the columns and that reader are in `parley' because
;; `parley-transcript' reads a session too -- it is a command as well,
;; and one called with no session in hand has to ask for one.  The
;; requiring goes one way only: the picker knows the view, the view
;; knows nothing of the picker, so what both need is below both.
;;
;; sallet is optional.  It is required with noerror and its functions
;; are declared, so nothing in the package headers names it.

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

(defun parley-switch--candidates ()
  "Return one sallet candidate per live session.
A candidate is the cons of the fields vector and the record it
was built from: the fields are what sallet matches and renders,
the record is what the action needs.  Nothing looks a session up
by name afterwards, which is what keeps two sessions sharing one
from being confused."
  (mapcar (lambda (session) (cons (parley-session-fields session) session))
          (parley-sessions-by-status)))

(defun parley-switch--field-filter (field)
  "Return a sallet filter matching its pattern against FIELD.
FIELD is an index into the fields vector of a candidate, so this
is what makes the columns matchable one at a time."
  (lambda (candidates indices pattern)
    (let ((regexp (regexp-quote pattern)))
      (seq-filter
       (lambda (index)
         (string-match-p
          regexp (aref (sallet-candidate-aref candidates index) field)))
       indices))))

(defun parley-switch--matcher (candidates state)
  "Match session CANDIDATES against the prompt of STATE, column by column.
A token is matched against the session name, unless it begins
with / for the working directory or % for the pane, in which case
the prefix is part of the pattern -- a path and a pane id really
do begin with those.  A token beginning with : matches the status
without it.  Tokens are matched in sequence, so `orc /worker-2'
is the session named orc in that worktree."
  (sallet-compose-filters-by-pattern
   `(("\\`/.*" ,(parley-switch--field-filter 3))
     ("\\`%.*" ,(parley-switch--field-filter 4))
     ("\\`:\\(.*\\)" 1 ,(parley-switch--field-filter 1))
     (t ,(parley-switch--field-filter 0)))
   candidates
   (sallet-make-candidate-indices candidates)
   (sallet-state-get-prompt state)))

(defun parley-switch--renderer (candidate _state _user-data)
  "Render session CANDIDATE as its row of columns."
  (parley-session-row (car candidate)))

(defun parley-switch--action (_source candidate)
  "Show the transcript buffer of the session CANDIDATE was built for."
  (parley-transcript (cdr candidate)))

;; `sallet-defsource' is a macro, so the source cannot be written as a
;; plain top-level form: with sallet absent from the load path there
;; is nothing to expand it and byte compiling this file would fail.
;; Left as data for `eval' it costs nothing when sallet is not there.
(when (featurep 'sallet)
  (eval '(sallet-defsource parley nil
           "Live Claude Code sessions."
           (candidates parley-switch--candidates)
           (matcher parley-switch--matcher)
           (renderer parley-switch--renderer)
           (action parley-switch--action)
           (header "Claude Code sessions"))
        t))


;;; Switching to a session

;;;###autoload
(defun parley-switch ()
  "Switch to the transcript buffer of a live Claude Code session.
The sessions are the ones `parley-sessions' finds, ordered by
status, and the one picked is shown by `parley-transcript': the
same buffer, with the same pipeline in it, that calling that
command with the record would have reached.

With sallet installed the pick is a sallet session over the
source `sallet-source-parley', which matches and renders the
sessions as columns.  Without it the pick is a `completing-read'
over one row per session, beginning with its name.  The source is
what the sallet frontend needs and it exists only if sallet was
there when this file was loaded, so that -- and not the feature
-- is what decides."
  (interactive)
  (if (fboundp 'sallet-source-parley)
      (sallet (list 'sallet-source-parley))
    (parley-transcript (parley-read-session))))

(provide 'parley-switch)
;;; parley-switch.el ends here
