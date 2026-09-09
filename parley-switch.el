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
;; and shows its transcript buffer, creating that buffer the first
;; time.  A dozen or two sessions is the whole list, so nothing here
;; is asynchronous.
;;
;; A session is listed by four columns: the name `claude agents' gives
;; it, its status, its working directory and the tmux pane it lives
;; in.  With sallet those four are a vector the source matches and
;; renders column by column, which is the reason to reach for it here.
;; `completing-read' matches one flat string, so the fallback bakes
;; the same four into one row with the name first.  Both frontends
;; order the sessions by status and both build the list with
;; `parley-switch--sessions': there is one way of building it.
;;
;; The names are not unique -- two sessions in sibling worktrees come
;; back under the same one -- so the fourth column doubles as the tag
;; that tells them apart, in either frontend and in the buffer name.
;;
;; sallet is optional.  It is required with noerror and its functions
;; are declared, so nothing in the package headers names it.

;;; Code:

(require 'parley)
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


;;; The list, and the columns a session is listed by

(defconst parley-switch-status-order '("idle" "busy")
  "The statuses sessions are listed in, first to last.
An idle session is the one that will read what you type now, so
it comes first.  A status this list does not name sorts after
every status it does.")

(defun parley-switch--status-rank (session)
  "Return the rank of SESSION in `parley-switch-status-order'.
A status the order does not name -- including the nil `claude
agents' reports for a session it knows no status for -- ranks
after every status it does."
  (or (seq-position parley-switch-status-order (plist-get session :status))
      (length parley-switch-status-order)))

(defun parley-switch--sessions ()
  "Return the live sessions ordered by status.
This is the one place the switcher list is built: both frontends
read it, so neither can disagree with the other about what is
running or in what order.  `sort' is stable, so sessions sharing
a status stay in the order `parley-sessions' discovered them in."
  (sort (parley-sessions)
        (lambda (a b) (< (parley-switch--status-rank a)
                         (parley-switch--status-rank b)))))

(defun parley-switch--tag (session)
  "Return what tells SESSION apart from another of the same name.
That is the pane it lives in, and the head of its session id when
it lives outside tmux and has no pane.  Something in the row has
to be unique: two sessions in sibling worktrees come back under
one name, and a switcher that cannot tell them apart lands in the
wrong buffer."
  (or (plist-get session :pane)
      (let ((id (or (plist-get session :session-id) "")))
        (substring id 0 (min 8 (length id))))))

(defun parley-switch--fields (session)
  "Return the columns SESSION is listed and matched by.
A vector of four strings: its name, its status, its working
directory and its tag -- the pane it lives in, or the head of its
session id when it has none, see `parley-switch--tag'.

Nothing in a session record is guaranteed to be there, so the
placeholders for a name and a status `claude agents' did not
report are chosen once here rather than by each frontend."
  (vector (or (plist-get session :name) "unnamed")
          (or (plist-get session :status) "unknown")
          (abbreviate-file-name (plist-get session :cwd))
          (parley-switch--tag session)))

(defun parley-switch--row (fields)
  "Return FIELDS as one row of columns, the name first.
FIELDS is a vector from `parley-switch--fields'.  A row is what
`completing-read' completes over, because it matches one flat
string and the annotation has to be inside it; the sallet
renderer draws the same row from the same fields."
  (apply #'format "%-16s  %-7s  %-40s  %s" (append fields nil)))


;;; The buffer

(defvar-local parley-session nil
  "The session record the buffer follows, nil in a buffer that follows none.
It is the plist `parley-sessions' returned for that session.")

(defun parley-switch--buffer-name (session)
  "Return the name of the transcript buffer of SESSION.
The name carries the same name and tag the switcher listed the
session under -- the first and last of `parley-switch--fields' --
because names repeat and one buffer per session is the point."
  (let ((fields (parley-switch--fields session)))
    (format "*parley %s %s*" (aref fields 0) (aref fields 3))))

(defun parley-switch--buffer (session)
  "Return the transcript buffer of SESSION, creating it if there is none.
A buffer created here is empty: filling it is the transcript
pipeline's business, and what is settled here is the buffer's
identity -- its name, the record in `parley-session' and the
session's own working directory.  Switching to a session again
finds the same buffer and refreshes the record in it, because
what `claude agents' says about a session goes stale."
  (with-current-buffer (get-buffer-create (parley-switch--buffer-name session))
    (setq parley-session session)
    (setq default-directory
          (file-name-as-directory (plist-get session :cwd)))
    (current-buffer)))

(defun parley-switch-to-session (session)
  "Show the transcript buffer of SESSION, creating it if there is none."
  (pop-to-buffer (parley-switch--buffer session)))


;;; Without sallet: one flat row per session

(defun parley-switch--read-session ()
  "Read one of the live sessions in the minibuffer and return its record.
The candidates are the rows of `parley-switch--row', so each
begins with the session name and carries its tag.  The completion
metadata keeps them in the order `parley-switch--sessions' put
them in; the default would sort them alphabetically and lose the
status order."
  (let ((rows (mapcar (lambda (session)
                        (cons (parley-switch--row
                               (parley-switch--fields session))
                              session))
                      (parley-switch--sessions))))
    (unless rows
      (user-error "No live Claude Code session to switch to"))
    (cdr (assoc (completing-read
                 "Session: "
                 (lambda (string predicate action)
                   (if (eq action 'metadata)
                       '(metadata (display-sort-function . identity)
                                  (cycle-sort-function . identity))
                     (complete-with-action action rows string predicate)))
                 nil t)
                rows))))


;;; With sallet: the four columns kept apart

(defun parley-switch--candidates ()
  "Return one sallet candidate per live session.
A candidate is the cons of the fields vector and the record it
was built from: the fields are what sallet matches and renders,
the record is what the action needs.  Nothing looks a session up
by name afterwards, which is what keeps two sessions sharing one
from being confused."
  (mapcar (lambda (session) (cons (parley-switch--fields session) session))
          (parley-switch--sessions)))

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
   `(("\\`/.*" ,(parley-switch--field-filter 2))
     ("\\`%.*" ,(parley-switch--field-filter 3))
     ("\\`:\\(.*\\)" 1 ,(parley-switch--field-filter 1))
     (t ,(parley-switch--field-filter 0)))
   candidates
   (sallet-make-candidate-indices candidates)
   (sallet-state-get-prompt state)))

(defun parley-switch--renderer (candidate _state _user-data)
  "Render session CANDIDATE as its row of columns."
  (parley-switch--row (car candidate)))

(defun parley-switch--action (_source candidate)
  "Show the transcript buffer of the session CANDIDATE was built for."
  (parley-switch-to-session (cdr candidate)))

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

;;;###autoload
(defun parley-switch ()
  "Switch to the transcript buffer of a live Claude Code session.
The sessions are the ones `parley-sessions' finds, ordered by
status, and the buffer is created if it does not exist yet.

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
    (parley-switch-to-session (parley-switch--read-session))))

(provide 'parley-switch)
;;; parley-switch.el ends here
