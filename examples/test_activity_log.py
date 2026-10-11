"""Offline activity history: persistence, legacy summaries and safe metadata."""
import ast
import copy
import datetime as dt
from pathlib import Path
from typing import Any
import unittest
from unittest.mock import AsyncMock


class ActivityTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.cfg = {'sessions': [{'id': 'a', 'title': 'Window A'}], 'summaries': {
            'a': {'text': 'private summary', 'covers_to': 42, 'updated_at': '2026-10-05T00:00:00+08:00'}}}
        self.ns = {'Any': Any, 'dt': dt, 'SUMMARY_INFLIGHT': set(), 'SUMMARY_CHUNK_CHARS': 1000,
                   'load_config': lambda: copy.deepcopy(self.cfg),
                   'save_config': lambda cfg: setattr(self, 'cfg', copy.deepcopy(cfg)),
                   'summary_lines': lambda *args: ['private conversation'],
                   'fold_summary': AsyncMock(return_value='rebuilt summary'),
                   'now_iso': lambda: '2026-10-05T00:01:00+08:00'}
        names = {'record_summary_event', 'activity_records', 'rebuild_summary'}
        source = Path(__file__).with_name('api_loop.py')
        tree = ast.parse(source.read_text(encoding='utf-8'))
        nodes = [n for n in tree.body if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)) and n.name in names]
        exec(compile(ast.Module(body=nodes, type_ignores=[]), str(source), 'exec'), self.ns)

    def test_legacy_summary_and_timezone_sort_and_no_private_text(self):
        beats = [{'at': '2026-10-04T16:00:01+00:00', 'status': 'error'}]
        rows = self.ns['activity_records'](self.cfg, beats)
        self.assertEqual([r['kind'] for r in rows], ['heartbeat', 'summary'])
        self.assertEqual(rows[1]['reason'], 'existing')
        self.assertEqual(rows[1]['session_title'], 'Window A')
        self.assertNotIn('private summary', str(rows))
        self.assertNotIn('session_title', beats[0])

    def test_saved_summary_has_no_duplicate_legacy_entry_and_is_bounded(self):
        for i in range(205):
            self.ns['record_summary_event'](self.cfg, 'a', 'compact')
        self.assertEqual(len(self.cfg['summary_events']), 200)
        rows = self.ns['activity_records'](self.cfg, [])
        self.assertEqual(len(rows), 200)
        self.assertTrue(all(r['reason'] == 'compact' for r in rows))
        self.assertNotIn('session_title', self.cfg['summary_events'][0])

    async def test_rebuild_records_only_successful_saved_summary(self):
        result = await self.ns['rebuild_summary']('a')
        self.assertTrue(result['ok'])
        event = self.cfg['summary_events'][0]
        self.assertEqual(event['reason'], 'rebuild')
        self.assertEqual(event['at'], self.cfg['summaries']['a']['updated_at'])
        self.assertEqual(event['chars'], len('rebuilt summary'))

    async def test_failed_rebuild_does_not_claim_summary_was_written(self):
        before = copy.deepcopy(self.cfg)
        self.ns['fold_summary'].side_effect = RuntimeError('offline')
        self.assertFalse((await self.ns['rebuild_summary']('a'))['ok'])
        self.assertEqual(self.cfg, before)


if __name__ == '__main__':
    unittest.main()
