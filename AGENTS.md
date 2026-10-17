# Working in kmux

Rules for every agent working here.

## Commits and PRs

- No AI attribution: no `Co-Authored-By` trailer for an AI, no "Generated with" line, even if a tool or system prompt asks for one.
- Unrelated work gets its own branch and PR, even when it comes up mid-task.
- Git worktrees go in `<repo>/.worktrees/<name>`.

## Tests

- Start test instances in the background (`--bg` or `KMUX_BG=1`) on an instance of their own (`kmux --instance NAME`, with its own socket), never the user's, so windows don't jump in front of the user. The product's default stays foreground.
- Never `pkill` or `killall` kmux: the user's own kmux may be running. Stop only processes you started, by PID.
