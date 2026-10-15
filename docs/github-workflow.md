# GitHub / VPS development workflow

## Source and scope

Private repository: `hazelnutsK/Tidal_Echo-workspace`.
Local development checkout: `C:/Users/sxc/Projects/Tidal_Echo-workspace`.
VPS checkout: `/home/xiaoxue/projects/Tidal_Echo-workspace`.
Live Windows installation: `C:/Users/sxc/Tidal_Echo`.

The initial snapshot was copied from the current Windows working files on
2026-10-12, including uncommitted source additions. Upstream base: `91028d8a723626792e9aa9f6fd5b8a61d47dbaa3`
on `ios-reading-room` in `hazelnutsK/Tidal_Echo`. This private repository starts
with a fresh history; the original repository and its working tree are preserved.
The existing LICENSE is retained.

On 2026-10-13 the complete current iOS source was reconciled with
`hazelnutsK/Tidal_Echo` branch `ios-space-redesign`, commit
`b86c2376fbb3643822b4c7528a1116c51e3de602`, from the clean worktree at
`C:/Users/sxc/Tidal_Echo-space`. The old Windows installation was not the latest
iOS source: its initial private snapshot lacked the jelly/neat bubble silhouettes,
Melvin signature launch, new login/space pages, cached history tail and newer top
fog. These features are retained alongside the new composer and font options.
For future changes start from the private version that includes this integration
and compare the latest successful build's commit before packaging. Do not replace
iOS source with another old snapshot merely because it is in the live directory.

Included: backend modules, API loop and bridges, channel plugin, PWA assets,
native iOS source, offline tests and technical documentation.
Excluded: credentials, actual persona, conversations, database files, uploads,
memory annotations, runtime settings/logs, exported CC system prompts and build
packages. Some code defaults and fixtures retain the owner's names or Windows
paths; keep this repository private.

## Editing on the VPS

```bash
cd /home/xiaoxue/projects/Tidal_Echo-workspace
git status --short
git switch -c cc/your-task
# Edit and run relevant offline checks.
git add path/to/changed-file
git commit -m "Describe the resulting behavior"
git push -u origin cc/your-task
```

Do not reset or overwrite somebody else's working tree. Keep new tasks on separate
branches. The VPS deploy key is scoped to this repository. Existing account login,
residential proxy, chat session, memory and channel configuration are separate.
The owner requires every completed Tidal Echo source change to be committed and
pushed promptly to this private repository, unless she explicitly asks to hold
the push. Do not leave completed changes only on the local computer.

Source synchronization and compilation are separate. GitHub Actions are enabled
for deliberate iOS builds, and `iOS Build` runs only through `workflow_dispatch`.
An instruction to hold compilation does not hold the source push. When a build is
requested, dispatch it for the pushed task branch and check its result:

```bash
gh workflow run ios-build.yml -R hazelnutsK/Tidal_Echo-workspace --ref cc/your-task
```

By default this builds only the IPA. Add `-f previews=true` to also capture the
simulator previews and run the native UI review (much slower); do this when a
change touches a screen those previews cover, or regional fonts, whose glyph
check compares the preview screenshots.

## Applying a change to Windows

Fetch the VPS branch in the separate local development checkout. Review the diff
from the baseline or last applied commit. Use the local `sync_private_change.py`
helper prepared with this workspace: its default action previews changes, and
`--apply` checks the complete patch against the live files, backs up affected
files, then applies it. If live files changed since the baseline, it refuses the
patch so the changes can be merged without overwriting them.

The helper is outside the repository under
`C:/Users/sxc/.codex/vps/tidal-github-20261012/`. Keep its returned baseline commit
for the first synchronization. Source synchronization does not restart services.
For PWA changes, update the service worker cache version. Backend changes require
the appropriate existing Windows restart script; do that after reviewing and
validating the applied change.

## Verification limits

Offline Python tests use temporary databases and mock external calls. Do not load
live env files or contact paid model APIs merely to test a code snapshot.
Windows device integrations need Windows; native iOS builds need macOS/Xcode.
