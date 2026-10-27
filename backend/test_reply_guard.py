"""Synthetic SQLite checks for deferred-message reply recovery."""
import ast
import json
from pathlib import Path
import sqlite3
import unittest


class ReplyGuardTests(unittest.TestCase):
    def setUp(self):
        self.conn = sqlite3.connect(":memory:")
        self.conn.row_factory = sqlite3.Row
        self.addCleanup(self.conn.close)
        self.conn.execute("CREATE TABLE messages (id INTEGER PRIMARY KEY, ts TEXT, "
                          "direction TEXT, kind TEXT, text TEXT, meta TEXT)")
        source = Path(__file__).with_name("app.py")
        nodes = [n for n in ast.parse(source.read_text(encoding="utf-8")).body
                 if isinstance(n, ast.FunctionDef) and n.name == "unanswered_inbound"]
        self.assertEqual(len(nodes), 1)
        ns = {"db": lambda: self.conn, "json": json}
        exec(compile(ast.Module(body=nodes, type_ignores=[]), str(source), "exec"), ns)
        self.unanswered = ns["unanswered_inbound"]

    def message(self, meta, direction="in", kind="user"):
        cur = self.conn.execute("INSERT INTO messages (ts,direction,kind,text,meta) "
                                "VALUES ('fixture',?,?, 'synthetic',?)",
                                (direction, kind, json.dumps(meta)))
        return cur.lastrowid

    def test_deferred_message_only_becomes_eligible_after_release(self):
        mid = self.message({"reply_deferred": True, "reply_bundle_id": "fixture"})
        self.assertIsNone(self.unanswered())
        self.conn.execute("UPDATE messages SET meta=? WHERE id=?",
                          (json.dumps({"reply_deferred": False}), mid))
        self.assertEqual(self.unanswered()["id"], mid)

    def test_normal_unanswered_message_still_recovers(self):
        mid = self.message({})
        self.assertEqual(self.unanswered()["id"], mid)
        self.message({}, direction="out", kind="reply")
        self.assertIsNone(self.unanswered())

    def test_reaction_and_hidden_message_do_not_trigger_recovery(self):
        self.message({"reactions": {"ai": ["heart"]}})
        self.message({"hidden": True})
        self.assertIsNone(self.unanswered())


if __name__ == "__main__":
    unittest.main()
