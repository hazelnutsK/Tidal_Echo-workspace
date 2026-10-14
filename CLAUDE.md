# Tidal Echo code workspace

Read `docs/github-workflow.md` before editing this project.

This development repository is hazelnutsK/Tidal_Echo-workspace. It began as a
private snapshot on 2026-10-12 and became public with the owner's approval on
2026-10-15. The running relay, API loop, SQLite data, uploads and voice services
still live on the Windows computer. This checkout is for development.

Use a new `cc/<task>` branch for each change. Check the working tree before
switching branches; preserve existing changes. Make the requested change, run
relevant offline checks, commit it and push that branch to this origin.
Report the branch, commit, changed files and validation results.

The owner requires timely GitHub synchronization for future changes. Source
pushes do not trigger iOS builds. Run iOS Build manually in this same repository,
selecting the pushed task branch, only when compilation is requested. There is
no required export to hazelnutsK/Tidal_Echo. Read docs/public-ios-build.md.
If she says to hold compilation, still push source unless she also asks to hold
the push. The existing VPS deploy key remains scoped to this repository; workflow
dispatch needs an account credential with Actions write permission.

Do not copy credentials, user conversations, persona files, databases or uploads
into Git. Do not start companion channel consumers from this checkout. The
existing chat channel is running separately; starting another one causes duplicate
replies. A commit or push does not deploy code to the Windows installation.

The repository includes Windows launch scripts and local integrations. Linux can
edit these files but cannot validate Windows software or build iOS with Xcode.
Preserve those integrations unless the requested task requires changing them.

Quick checks:
- `node check-inline-scripts.js`
- `python3 -m unittest discover -s backend -p test_stream_paragraphs.py`
- `python3 -m unittest discover -s examples -p test_history_cache.py`
- `python3 -m unittest discover -s examples -p test_conversation_memory.py`
- `node --test wechat/bridge.test.mjs`

`AGENTS.md` contains the upstream deployment SOP. For this existing installation,
use the current architecture above and do not redeploy services merely to edit code.
