# Tidal Echo shared development

Read docs/github-workflow.md and AGENTS.md before editing. The public repository
is hazelnutsK/Tidal_Echo-workspace; **origin/main is the only integrated mainline**.
Windows Codex and VPS CC follow the same rules (owner-approved 2026-10-27).

- Inspect the working tree and fetch before starting. Start every new task from
  current origin/main, not the last active feature branch. Preserve unfinished
  changes and other tasks; use an isolated worktree if needed. Never switch
  another active task's checkout.
- Develop on cc/<task> (or codex/<task>), run relevant offline checks, review
  explicitly staged source files, commit and push promptly.
- A branch push alone is not completion: fetch again, integrate concurrent main
  changes, validate, then merge the completed work into main and push without
  force. A rejected push means reconcile newer main, not overwrite it. Honor an
  explicit request to hold pushing/merging or keep an experiment separate.
- Finish on main in a clean idle checkout. Report the main commit, validation,
  runtime deployment and iOS build status separately.
- Development: /home/xiaoxue/projects/Tidal_Echo-workspace on VPS;
  C:/Users/sxc/Projects/Tidal_Echo-workspace on Windows. Runtime directories are
  not development bases. Preserve their private data and uncommitted source;
  apply only backed-up, checked patches when deploying.
- Never publish real credentials, conversations, actual persona, databases,
  attachments, logs or machine configuration. Never start a second companion
  consumer. Source synchronization alone must not restart the chat session.
- iOS builds remain manual and require a user request. Default to integrated
  main and verify the run's commit. Never use old Windows runtime iOS source.
  Read docs/public-ios-build.md; no cross-repository export is required.

Linux cannot validate Windows integrations or run Xcode. Keep these limitations
explicit. The full procedure and relevant offline checks are documented in
docs/github-workflow.md; use synthetic fixtures, not live chat.
