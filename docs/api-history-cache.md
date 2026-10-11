# API history and cache paging

API history is counted in conversation turns. An inbound message bundle and its
response form one turn; an unsolicited assistant generation forms one turn too.
All bubbles sharing `stream_parent` count together. Prompt text, bubble order,
and stored messages are unchanged by this accounting.

`history_turns` in `/loop/config` is the number of recent turns retained after
compaction. Compaction is due at twice that number. If it is absent, the legacy
`history_n` setting (or `HISTORY_N`) is converted with `(n + 1) // 2`, preserving
the approximate capacity of ordinary user/assistant pairs. Thus `HISTORY_N=48`
retains 24 turns and compacts at 48 turns. Zero disables raw history.

Only real ingests prepare compaction. Heartbeats and `/loop/chat` previews read
the current page without moving its anchor or launching summary work. Before a
real chat request, the loop awaits the summary, refreshes the page's handoff, and
publishes the summary and anchor together. No post-response summary task changes
the prefix a second time. Summary failure/timeout keeps the old page for retry;
legacy `pending_summary` entries are handled before the next real request.

Compaction can add up to 180 seconds of preparation on a paging turn (configurable
with `SUMMARY_TIMEOUT_SECONDS`). After a failure, that session skips summary
attempts for 600 seconds (`SUMMARY_RETRY_COOLDOWN_SECONDS`), retaining the complete
old context for chat. The next real ingest after cooldown may retry; there is no
background retry. Cooldown is per process and resets on restart. Successful
compaction still changes the prompt and can require one cache rebuild. Provider
expiry, model/tool/persona changes, and routing remain independent cache factors.

Offline verification:

```powershell
backend/.venv/Scripts/python.exe -X utf8 -m unittest discover -s examples -p test_history_cache.py
```

`/healthz` reports `history_cache_version: 2` and `history_turns` once the fixed
process is running. `/loop/keepalive` reports `history_busy` during preparation.
