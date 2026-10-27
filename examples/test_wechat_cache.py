"""Offline regression tests: real relay delivery + API prompt assembly.

Extract only the tested functions to avoid loading private .env/persona/config,
starting the API service, or making any network/model requests.
"""
from __future__ import annotations

import ast
import copy
import datetime as dt
import json
from pathlib import Path
from types import SimpleNamespace
from typing import Any
import unittest
import urllib.request


ROOT = Path(__file__).resolve().parent.parent


def load_functions(path, names, namespace):
    tree = ast.parse(path.read_text(encoding="utf-8-sig"))
    nodes = [n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name in names]
    assert {n.name for n in nodes} == set(names)
    exec(compile(ast.Module(body=nodes, type_ignores=[]), str(path), "exec"), namespace)
    return tree


class WechatCacheTests(unittest.TestCase):
    def setUp(self):
        self.rows = []
        self.sent = []
        self.loop = {
            "Any": Any, "json": json, "dt": dt,
            "_WEEKDAYS": ["周一", "周二", "周三", "周四", "周五", "周六", "周日"],
            "PERSONA": "Fixed persona", "MEMORY_BRIEF_HEADER": "Memory:\n",
            "session_summary": lambda _: "Fixed summary",
            "memory_brief": lambda _: "Fixed memory",
            "MEMORY": SimpleNamespace(context=lambda *_: ("", [])),
            "load_config": lambda: {},
            "data_message": lambda text: {"role": "user", "content": text},
            "history_turns": lambda: 100,
            "_assistant_trace": lambda _: "",
            "relay_rows": lambda before, session, _: [
                r for r in self.rows if r["id"] < before and r["session"] == session
            ],
            "relay_row_meta": lambda msg_id: self.row(msg_id).get("meta"),
            "relay_msg_ts": lambda msg_id: self.row(msg_id).get("ts", ""),
        }
        load_functions(ROOT / "examples/api_loop.py", {
            "_parse_meta", "inbound_source_prefix", "time_context", "_wrap_content", "build_messages",
        }, self.loop)
        # Pixel data is fixed; the test checks that source/caption handling does
        # not change either text or image blocks when moving into history.
        self.loop["_image_parts_from_meta"] = lambda meta: copy.deepcopy(
            self.loop["_parse_meta"](meta).get("test_images", [])
        )
        self.relay = {
            "json": json, "LOOP_INGEST_URL": "http://offline.invalid/loop/ingest",
            "xhs_note_block": lambda _: "",
            "urllib": SimpleNamespace(request=SimpleNamespace(
                Request=urllib.request.Request, urlopen=self.capture_request,
            )),
        }
        tree = load_functions(ROOT / "backend/app.py", {
            "_forward_to_loop_sync", "ai_delivery_text", "quote_line",
        }, self.relay)
        self.relay["INBOUND_VIAS"] = next(
            ast.literal_eval(n.value) for n in tree.body
            if isinstance(n, ast.Assign) and any(
                isinstance(t, ast.Name) and t.id == "INBOUND_VIAS" for t in n.targets
            )
        )

    def capture_request(self, request, timeout):
        self.sent.append(json.loads(request.data))
        return SimpleNamespace(read=lambda: b"{}")

    def row(self, msg_id):
        return next((r for r in self.rows if r["id"] == msg_id), {})

    def add_user(self, text, via=None, images=None, session="api-a"):
        meta = {"api_session": session}
        if via:
            meta["via"] = via
        if images:
            meta["test_images"] = images
        msg_id = len(self.rows) + 1
        row = {
            "id": msg_id, "direction": "in", "text": text, "meta": meta,
            "ts": f"2026-10-03T01:{msg_id:02d}:00+00:00", "session": session,
        }
        self.rows.append(row)
        self.relay["_forward_to_loop_sync"](row)
        delivered = self.sent[-1]
        return self.loop["build_messages"](
            delivered["text"].strip(), before_id=msg_id, session_id=delivered["session_id"],
        )

    def test_wechat_then_app_keeps_entire_previous_prompt_prefix(self):
        first = self.add_user("在微信里说一句", "wechat")
        second = self.add_user("回 App 继续")
        self.assertEqual(first, second[:len(first)])
        self.assertEqual(first[-1]["content"].count("[她从微信发来的]"), 1)
        self.assertNotIn("[她从微信发来的]", second[-1]["content"])

    def test_repeated_entrance_switches_preserve_all_previous_messages(self):
        previous = []
        for index, via in enumerate([None, "wechat", None, "wechat", "wechat", None]):
            current = self.add_user(f"第 {index} 句", via)
            self.assertEqual(previous, current[:len(previous)])
            previous = current

    def test_image_with_and_without_caption_stays_identical(self):
        images = [{"type": "image_url", "image_url": {"url": "data:image/png;base64,dGVzdA=="}}]
        for caption in ("", "看看这张图"):
            with self.subTest(caption=caption):
                first = self.add_user(caption, "wechat", images)
                second = self.add_user("回 App")
                self.assertEqual(first, second[:len(first)])
                self.assertEqual(first[-1]["content"][1:], images)

    def test_stored_json_meta_and_other_sessions(self):
        first = self.add_user("微信消息", "wechat")
        self.rows[-1]["meta"] = json.dumps(self.rows[-1]["meta"], ensure_ascii=False)
        self.add_user("另一个窗口", "wechat", session="api-b")
        second = self.add_user("同一窗口继续")
        self.assertEqual(first, second[:len(first)])
        self.assertNotIn("另一个窗口", str(second))

    def test_plain_app_and_unknown_sources_are_unchanged(self):
        for via in (None, "unknown"):
            with self.subTest(via=via):
                first = self.add_user("普通消息", via)
                second = self.add_user("下一句")
                self.assertEqual(first, second[:len(first)])
                self.assertNotIn("[她从微信发来的]", first[-1]["content"])

    def test_literal_marker_in_user_text_is_not_removed(self):
        first = self.add_user("[她从微信发来的]\n这是我自己打的", "wechat")
        second = self.add_user("回 App")
        self.assertEqual(first, second[:len(first)])
        self.assertEqual(first[-1]["content"].count("[她从微信发来的]"), 2)

    def test_source_contract_matches_relay(self):
        self.assertEqual(self.loop["inbound_source_prefix"]({"via": "wechat"}),
                         self.relay["INBOUND_VIAS"]["wechat"])
        for raw in (None, "invalid json", {}, {"via": "unknown"}):
            self.assertEqual(self.loop["inbound_source_prefix"](raw), "")


if __name__ == "__main__":
    unittest.main()
