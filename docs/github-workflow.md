# Shared source workflow (2026-10-27)

`hazelnutsK/Tidal_Echo-workspace` is public. **`origin/main` is the single integrated
source of truth** for completed work, whether authored on Windows or the VPS.
Pushing a task branch alone does not complete synchronization. After relevant
checks, merge completed work into main and push it, unless the owner explicitly
asks to hold publication/integration or keep an experiment separate.

## Locations and boundaries

| Location | Purpose |
| --- | --- |
| `C:/Users/sxc/Projects/Tidal_Echo-workspace` | Windows development |
| `/home/xiaoxue/projects/Tidal_Echo-workspace` | VPS development |
| `C:/Users/sxc/Tidal_Echo` | Running Windows installation; reviewed patches only |
| `/home/xiaoxue/workspace/Tidal_Echo` | VPS runtime tools/configuration, not a source checkout |

Keep credentials, databases, conversations, actual persona, attachments, logs and
machine state out of Git. Never copy an entire runtime directory into this public
checkout. Never start a second companion consumer from a development checkout.
Source publication, backend deployment and iOS packaging are separate actions.

## Start every task from current main

1. Read this file, AGENTS.md and CLAUDE.md. Inspect `git status --short`, the
   current branch and worktrees. Preserve existing work; do not reset or stash
   someone else's changes just to make the checkout clean.
2. Run `git fetch origin`. Inspect commits on the current branch absent from
   origin/main. Resume them only when they belong to this task; otherwise leave
   them intact and start from integrated main in a clean checkout.
3. For a clean checkout:

   ```bash
   git switch main
   git merge --ff-only origin/main
   git switch -c codex/your-task  # VPS CC may use cc/your-task
   ```

   If local main diverges, inspect and reconcile it; never force reset. Do not
   use the last active feature branch or latest commit date as a substitute for
   origin/main. Use an isolated worktree if another task owns this checkout.
   Check for active work before switching a remote checkout.

## Finish by integrating, not just pushing a branch

1. Run checks appropriate to the change. Stage explicit source paths and inspect
   the staged diff for unintended/private files. Commit on the task branch.
2. Fetch again. Merge origin/main into the task branch if it advanced. Resolve
   conflicts preserving both intended behaviors, then rerun affected checks.
   Never blindly select an entire side of a source conflict.
3. Push the task branch for traceability, then fast-forward remote main:

   ```bash
   git push -u origin codex/your-task
   git push origin HEAD:main
   ```

   **Never force-push main.** A normal push rejects concurrent updates. Fetch,
   integrate the new main, validate and retry. If branch protection requires a
   PR, follow that path and report integration pending until merged; never weaken
   protection to push.
4. Finish on main in the working machine's clean checkout, fast-forwarded to
   origin/main. A clean, idle checkout on the other machine may also be updated;
   preserve any active or unfinished work there. Every new task must still fetch.
5. Report integrated main commit, checks, backend deployment and iOS build status
   separately. A pushed task branch is not the latest full version until merged.
   Preserve old branches during routine work.

## Apply source to the running Windows installation

The runtime checkout has historical uncommitted changes and old iOS files.
Never reset it, blanket-copy over it, or treat its HEAD as its deployed version.
Inspect actual files against the source baseline first.

The local `sync_private_change.py` under
`C:/Users/sxc/.codex/vps/tidal-github-20261012/` previews baseline-compatible
patches; `--apply` checks and backs up affected files. If live files differ,
review and reconcile those edits instead of bypassing the conflict. A reviewed
non-overlapping patch may be applied after backing up the actual files and running
`git apply --check`. Keep a private manifest of the deployed source commit,
affected scopes and file hashes; record deliberately different/deferred scopes.
The consolidation manifest is `runtime-source-state.json` in that same private
helper directory. Do not infer deployment from the legacy helper's last-applied
record or the old runtime Git HEAD alone.

Backend fixes need the existing relay restart script after validation, when
applying the fix is within the user's authorized scope. Use hidden launcher
windows and check `/relay/healthz` afterwards. PWA changes must update the cache
version in web/sw.js. Source synchronization alone must not restart chat consumers.

## iOS builds

The full iOS baseline was restored from ios-space-redesign commit b86c237 on
2026-10-13. Preserve its jelly/neat bubbles, launch/login/space pages and cached
history tail, plus subsequent features. Before packaging, compare the target
with the latest successful build; never use the old runtime iOS directory.

Build only when requested. Default to integrated main; use a specific feature
branch only for an explicitly requested preview/experimental build. Confirm the
run's headSha matches the intended commit.

```bash
gh workflow run ios-build.yml -R hazelnutsK/Tidal_Echo-workspace --ref main
```

The workflow uses workflow_dispatch only. Add `-f previews=true` for simulator
previews and UI review; omit for IPA-only builds. Holding compilation does not
hold source synchronization. See docs/public-ios-build.md. The old repository
and export tool remain historical options, not the normal build path.

## Offline verification

Use synthetic fixtures and temporary databases, not live configuration or paid
model/TTS calls. Select checks according to affected code:

```bash
python -X utf8 -m unittest discover -s backend -p 'test_*.py'
python -X utf8 -m unittest discover -s examples -p 'test_*.py'
python -X utf8 -m unittest discover -s tools -p 'test_*.py'
node check-inline-scripts.js
node --test wechat/bridge.test.mjs
```

Windows integrations need Windows; native iOS builds need macOS/Xcode. Do not
report syntax checks as a successful native build.
