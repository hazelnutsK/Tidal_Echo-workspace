# One-shot cleanup: re-mark orphaned API-window inbound messages as routed='loop'.
# These lost their mark when relay's 10s forward timeout misfired on slow replies;
# without the mark the CC plugin would replay them to CC on its next reconnect
# (the "CC answers my API chats" bug). Safe for messages CC already handled live:
# those sit below the plugin's since-cursor and never replay anyway.
import json
import sqlite3

DB = r"C:\Users\sxc\Tidal_Echo\backend\relay.db"

conn = sqlite3.connect(DB)
conn.row_factory = sqlite3.Row
rows = conn.execute(
    "SELECT id, meta FROM messages WHERE direction='in' "
    "AND json_extract(meta,'$.api_session') IS NOT NULL "
    "AND json_extract(meta,'$.api_session') != '' "
    "AND json_extract(meta,'$.routed') IS NULL "
    "AND json_extract(meta,'$.hidden') IS NULL"
).fetchall()
for r in rows:
    meta = json.loads(r["meta"] or "{}")
    meta["routed"] = "loop"
    conn.execute(
        "UPDATE messages SET meta=? WHERE id=?",
        (json.dumps(meta, ensure_ascii=False), r["id"]),
    )
conn.commit()
print(f"re-marked {len(rows)} message(s) as routed=loop")
