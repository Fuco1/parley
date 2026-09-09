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

(provide 'parley)
;;; parley.el ends here
