"""Offline quota, proxy-policy, dispatch and memory-replay regressions."""
import ast
import asyncio
import copy
from contextlib import closing
import json
from pathlib import Path
import sqlite3
import tempfile
from types import SimpleNamespace
from typing import Any
import unittest
from unittest.mock import AsyncMock

import httpx
from breath_profile import normalize_profile, collect_breath, render_breath, pools
from conversation_memory import ConversationMemory


def bucket(bid, **changes):
    return {"id": bid, "name": bid, "type": "dynamic", "created": "2026-10-01T00:00:00Z",
            "last_active": "2026-10-03T00:00:00Z", "score": 5, "importance": 5,
            "pinned": False, "resolved": False, "raw_content": f"完整正文 [[{bid}]]",
            "surfacing_policy_version": 1, **changes}


def functions(path, names, ns):
    tree = ast.parse(path.read_text(encoding="utf-8"))
    nodes = [n for n in tree.body if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)) and n.name in names]
    assert {n.name for n in nodes} == names
    exec(compile(ast.Module(body=nodes, type_ignores=[]), str(path), "exec"), ns)


class BreathTests(unittest.IsolatedAsyncioTestCase):
    async def collect(self, rows, profile=None, details=None):
        self.calls = []
        detail_map = {b["id"]: b for b in (details or rows)}
        async def get(path):
            self.calls.append(path)
            if "/buckets?" in path:
                return {"items": rows, "cache_age": 15}
            return detail_map.get(path.rsplit("/", 1)[-1])
        return await collect_breath(get, normalize_profile(profile))

    async def test_exact_quotas_and_dedup_across_recent_high_score(self):
        rows = [bucket(f"p{i}", pinned=True) for i in range(3)]
        rows += [bucket(f"n{i}", created=f"2026-10-{i+2:02d}T00:00:00Z", score=100-i) for i in range(8)]
        rows += [bucket(f"h{i}", created="2026-09-01T00:00:00Z", score=80-i) for i in range(5)]
        chosen, _ = await self.collect(rows)
        self.assertEqual({k: len(v) for k, v in chosen.items()}, {"recent": 8, "pinned": 3, "score": 3})
        ids = [b["id"] for items in chosen.values() for b in items]
        self.assertEqual(len(ids), len(set(ids)))
        self.assertEqual([b["id"] for b in chosen["score"]], ["h0", "h1", "h2"])
        text, report = render_breath(chosen, normalize_profile())
        self.assertIn("[[n7]]", text)
        self.assertEqual(report["omitted"], [])

    async def test_recent_uses_creation_not_reactivation_and_includes_completed_events(self):
        rows = [bucket("old", created="2025-01-01", last_active="2099-01-01"),
                bucket("new", created="2026-10-03", resolved=True)]
        chosen, _ = await self.collect(rows, {"recent": 1, "pinned": 0, "score": 0})
        self.assertEqual(chosen["recent"][0]["id"], "new")

    async def test_detail_policy_overrides_listing_and_refills(self):
        rows = [bucket("blocked", created="2026-10-03"), bucket("fine", created="2026-10-02")]
        details = [bucket("blocked", anchor=True), bucket("fine")]
        chosen, _ = await self.collect(rows, {"recent": 1, "pinned": 0, "score": 0}, details)
        self.assertEqual(chosen["recent"][0]["id"], "fine")
        self.assertEqual(len(self.calls), 3)

    async def test_private_deleted_forgotten_archived_are_not_surfaced(self):
        rows = [bucket("good")]
        for key, value in (("dont_surface", True), ("anchor", True), ("tombstone", True), ("deleted_at", "today")):
            rows.append(bucket(key, **{key: value}))
        rows += [bucket(t, type=t) for t in ("feel", "plan", "letter", "self", "i", "archived", "tombstone")]
        chosen, _ = await self.collect(rows)
        self.assertEqual([b["id"] for lane in chosen.values() for b in lane], ["good"])

    async def test_old_proxy_schema_cannot_silently_bypass_policy(self):
        with self.assertRaisesRegex(ValueError, "complete surfacing"):
            await self.collect([bucket("x", surfacing_policy_version=0)])

    async def test_long_pinned_does_not_starve_recent_and_no_body_is_truncated(self):
        profile = normalize_profile({"pinned": 1, "score": 1, "recent": 2})
        chosen = {"pinned": [bucket("long", raw_content="P" * 9000)],
                  "score": [bucket("score", raw_content="H" * 300)],
                  "recent": [bucket("recent1", raw_content="R" * 500), bucket("recent2", raw_content="S" * 500)]}
        text, report = render_breath(chosen, profile, 3000)
        self.assertLessEqual(len(text), 3000)
        self.assertEqual(report["selected"]["recent"], ["recent1", "recent2"])
        self.assertIn("long", report["omitted"])
        self.assertNotIn("PPP", text)
        self.assertIn("R" * 500, text)

    async def test_empty_or_disabled_lanes_and_invalid_settings(self):
        profile = normalize_profile({"pinned": 0, "score": 0, "recent": 1})
        chosen, _ = await self.collect([], profile)
        text, _ = render_breath(chosen, profile)
        self.assertIn("候选不足", text)
        self.assertEqual(self.calls, ["/app/ombre/buckets?sort=score"])
        for raw in ({"recent": -1}, {"score": 21}, {"recent": 1.5}, {"pinned": True}, {"enabled": "false"},
                    {"pinned": 0, "score": 0, "recent": 0}):
            with self.assertRaises(ValueError):
                normalize_profile(raw)
        self.assertFalse(normalize_profile({"enabled": False, "pinned": 0, "score": 0, "recent": 0})["enabled"])

    async def test_dispatch_only_intercepts_unparameterized_breath(self):
        mcp = SimpleNamespace(call=AsyncMock(return_value="original"))
        ns = {"Any": Any, "MCP": mcp, "normalize_profile": normalize_profile,
              "load_config": lambda: {}, "profiled_breath": AsyncMock(return_value="profiled"),
              "MOMENTS_TOOL_NAMES": set(), "MUSIC_TOOL_NAMES": set()}
        functions(Path(__file__).with_name("api_loop.py"), {"call_tool"}, ns)
        self.assertEqual(await ns["call_tool"]("breath", {}), "profiled")
        for name, args in (("breath_search", {"query": "记忆"}), ("breath_advanced", {}), ("breath", {"query": "旧客户端"})):
            self.assertEqual(await ns["call_tool"](name, args), "original")
        ns["load_config"] = lambda: {"breath_profile": {"enabled": False}}
        self.assertEqual(await ns["call_tool"]("breath", {}), "original")

    async def test_profile_failure_falls_back_explicitly_and_uses_auth(self):
        requests = []
        def respond(request):
            requests.append(request)
            return httpx.Response(503, json={"error": "offline"})
        ns = {"Any": Any, "asyncio": asyncio, "httpx": httpx,
              "new_client": lambda **kwargs: httpx.AsyncClient(transport=httpx.MockTransport(respond), **kwargs),
              "MCP": SimpleNamespace(call=AsyncMock(return_value="OB 原始结果")),
              "RELAY_URL": "http://offline.invalid/relay", "RELAY_SECRET": "test",
              "collect_breath": collect_breath, "render_breath": render_breath,
              "load_config": lambda: {}, "memory_settings": lambda _: {"read_chars": 16000}, "MCP_RESULT_MAX": 20000}
        functions(Path(__file__).with_name("api_loop.py"), {"profiled_breath"}, ns)
        text = await ns["profiled_breath"](normalize_profile())
        self.assertIn("回退", text)
        self.assertIn("OB 原始结果", text)
        self.assertEqual(requests[0].headers["authorization"], "Bearer test")

    async def test_profile_success_uses_full_details_and_does_not_call_mcp(self):
        rows = [bucket("p", pinned=True), bucket("r"), bucket("h", created="2025-01-01")]
        def respond(request):
            self.assertEqual(request.headers["authorization"], "Bearer test")
            if request.url.path.endswith("/buckets"):
                return httpx.Response(200, json={"items": rows})
            return httpx.Response(200, json=next(b for b in rows if request.url.path.endswith("/" + b["id"])))
        ns = {"asyncio": asyncio, "httpx": httpx,
              "new_client": lambda **kwargs: httpx.AsyncClient(transport=httpx.MockTransport(respond), **kwargs),
              "MCP": SimpleNamespace(call=AsyncMock()),
              "RELAY_URL": "http://offline.invalid/relay", "RELAY_SECRET": "test",
              "collect_breath": collect_breath, "render_breath": render_breath,
              "load_config": lambda: {}, "memory_settings": lambda _: {"read_chars": 16000}, "MCP_RESULT_MAX": 20000}
        functions(Path(__file__).with_name("api_loop.py"), {"profiled_breath"}, ns)
        result = await ns["profiled_breath"](normalize_profile({"pinned": 1, "recent": 1, "score": 1}))
        self.assertTrue(result.startswith("[配额呼吸]"))
        for b in rows:
            self.assertIn(b["raw_content"], result)
        ns["MCP"].call.assert_not_called()

    async def test_candidate_checks_are_bounded(self):
        rows = [bucket("p", pinned=True)] + [bucket(str(i)) for i in range(100)]
        details = [rows[0]] + [dict(b, anchor=True) for b in rows[1:]]
        chosen, info = await self.collect(rows, {"pinned": 1, "recent": 20, "score": 0}, details)
        self.assertEqual(info["detail_requests"], 80)
        self.assertTrue(info["candidate_limit_reached"])
        self.assertEqual(len(self.calls), 81)
        self.assertEqual(len(chosen["pinned"]), 1)
        self.assertEqual(chosen["recent"], [])

    async def test_next_turn_does_not_cut_profile_to_old_6000_limit(self):
        with tempfile.TemporaryDirectory() as tmp:
            memory = ConversationMemory(Path(tmp)/"memory.db", Path(tmp)/"relay.db", Path(tmp))
            content = "[配额呼吸]\n" + "近期" * 3200 + "\n[钉选]末尾重要约定"
            memory.record("a", 1, "breath", content)
            _, events = memory.context("a", {}, 2)
            self.assertIn("末尾重要约定", str(events))

    async def test_proxy_normalization_preserves_policy_and_verbatim(self):
        ns = {"re": __import__("re")}
        path = Path(__file__).resolve().parents[1] / "backend/ombre_dash.py"
        functions(path, {"normalize", "_list", "_num", "_bool"}, ns)
        ns["_strip_wikilinks"] = lambda s: s.replace("[[", "").replace("]]", "")
        row = ns["normalize"]({"id": "a", "metadata": {"anchor": True, "dont_surface": True, "protected": True},
                               "content": "原文 [[链接]]", "display_content": "原文 链接"})
        self.assertEqual(row["raw_content"], "原文 [[链接]]")
        self.assertTrue(row["anchor"] and row["dont_surface"] and row["protected"])
        self.assertEqual(row["surfacing_policy_version"], 1)
        self.assertEqual(ns["normalize"]({"id": "a", "content_preview": "preview"})["surfacing_policy_version"], 0)


if __name__ == "__main__":
    unittest.main()
