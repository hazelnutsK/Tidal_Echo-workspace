"""Persisted API call invitations using the relay's existing messages table."""
import json


def pending(conn, session=None):
    sql = """SELECT * FROM messages WHERE direction='out' AND kind='call'
             AND json_extract(meta, '$.source')='api_loop'
             AND json_extract(meta, '$.call_status')='ringing'
             AND julianday(ts) > julianday('now', '-120 seconds')"""
    args = ()
    if session is not None:
        sql += " AND json_extract(meta, '$.api_session')=?"
        args = (session,)
    return conn.execute(sql + " ORDER BY id DESC LIMIT 1", args).fetchone()


def repeated(conn, request_id):
    return conn.execute("""SELECT * FROM messages WHERE direction='out' AND kind='call'
        AND json_extract(meta, '$.call_request_id')=? ORDER BY id DESC LIMIT 1""", (request_id,)).fetchone()


def transition(conn, message_id, status, call_id=""):
    row = conn.execute("SELECT * FROM messages WHERE id=? AND direction='out' AND kind='call'",
                       (message_id,)).fetchone()
    if row is None:
        return None, False
    meta = json.loads(row["meta"] or "{}")
    old = meta.get("call_status", "ringing")
    allowed = {"ringing": {"accepted", "missed"}, "accepted": {"ended"}}
    if status not in allowed.get(old, set()):
        return row, False
    meta["call_status"] = status
    if call_id:
        meta["call_id"] = call_id
    conn.execute("UPDATE messages SET meta=? WHERE id=?", (json.dumps(meta, ensure_ascii=False), message_id))
    conn.commit()
    return conn.execute("SELECT * FROM messages WHERE id=?", (message_id,)).fetchone(), True


def for_call(conn, call_id):
    if not call_id:
        return None
    return conn.execute("""SELECT * FROM messages WHERE direction='out' AND kind='call'
        AND json_extract(meta, '$.source')='api_loop'
        AND json_extract(meta, '$.call_id')=? ORDER BY id DESC LIMIT 1""", (call_id,)).fetchone()


def expired(conn):
    return conn.execute("""SELECT id FROM messages WHERE direction='out' AND kind='call'
        AND json_extract(meta, '$.source')='api_loop'
        AND json_extract(meta, '$.call_status')='ringing'
        AND julianday(ts) <= julianday('now', '-120 seconds')""").fetchall()
