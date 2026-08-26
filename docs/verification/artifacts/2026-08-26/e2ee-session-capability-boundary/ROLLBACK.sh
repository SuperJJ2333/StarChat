#!/usr/bin/env sh
set -eu
git -C "D:\pythonProject\outsource\StarChat\.worktrees\e2ee-session-continuity" apply --reverse --check "D:\pythonProject\outsource\StarChat\.worktrees\e2ee-session-continuity\docs\verification\artifacts\2026-08-26\e2ee-session-capability-boundary\DIFF_FILE.patch"
git -C "D:\pythonProject\outsource\StarChat\.worktrees\e2ee-session-continuity" apply --reverse "D:\pythonProject\outsource\StarChat\.worktrees\e2ee-session-continuity\docs\verification\artifacts\2026-08-26\e2ee-session-capability-boundary\DIFF_FILE.patch"