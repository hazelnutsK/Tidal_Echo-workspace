"""Offline checks for the public source boundary and manual build trigger."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("export_public_ios", Path(__file__).with_name("export_public_ios.py"))
exporter = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(exporter)

class ExportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "source"
        self.root.mkdir()
        self.old_root = exporter.ROOT
        exporter.ROOT = self.root
        self.addCleanup(setattr, exporter, "ROOT", self.old_root)
        self.secrets = patch.object(exporter, "private_values", return_value=set())
        self.secrets.start()
        self.addCleanup(self.secrets.stop)
        self.git("init", "-b", "main")
        self.git("config", "user.name", "Offline check")
        self.git("config", "user.email", "offline@example.invalid")
        self.put("LICENSE", "test license\n")
        self.put(exporter.WORKFLOW, "name: iOS Build\non:\n  workflow_dispatch:\npermissions:\n  contents: read\njobs:\n  build:\n    runs-on: macos-26\n")
        self.put("ios/project.yml", "name: App\n")
        self.put("ios/scripts/prepare-assets.sh", "#!/bin/sh\n")
        self.put("ios/Assets/AppIconSource.png", b"fake image")
        self.put("ios/App.swift", "let version = 1\n")
        self.put("backend/relay.env", "RELAY_SECRET=private-backend-value\n")
        self.put("docs/private.md", "private context\n")
        self.commit()

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.root, stderr=subprocess.PIPE, text=True).strip()

    def put(self, name, value):
        p = self.root / name
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(value if isinstance(value, bytes) else value.encode())

    def commit(self):
        self.git("add", "--all")
        self.git("commit", "-m", "fixture")
        return self.git("rev-parse", "HEAD")

    def export(self):
        target = Path(self.temp.name) / "export"
        target.mkdir()
        return target, exporter.export("HEAD", target)

    def test_only_committed_ios_workflow_license_are_exported(self):
        self.put("ios/App.swift", "uncommitted version\n")
        target, record = self.export()
        self.assertEqual((target / "ios/App.swift").read_text(), "let version = 1\n")
        self.assertFalse((target / "backend").exists())
        self.assertFalse((target / "docs").exists())
        self.assertEqual(record["ios_tree"], self.git("rev-parse", "HEAD:ios"))

    def test_credentials_in_ios_stop_export(self):
        self.put("ios/App.swift", 'let key = "sk-ant-' + "a" * 32 + '"\n')
        self.commit()
        with self.assertRaisesRegex(RuntimeError, "Possible credential"):
            self.export()

    def test_known_private_value_stops_export_without_printing_value(self):
        self.put("ios/App.swift", "actual-local-secret-value\n")
        self.commit()
        with patch.object(exporter, "private_values", return_value={b"actual-local-secret-value"}):
            with self.assertRaisesRegex(RuntimeError, "Possible credential") as error:
                self.export()
            self.assertNotIn("actual-local-secret-value", str(error.exception))

    def test_tracked_database_is_refused(self):
        self.put("ios/runtime.db", b"database")
        self.commit()
        with self.assertRaisesRegex(RuntimeError, "Runtime, private or build data"):
            self.export()

    def test_automatic_workflow_is_refused(self):
        self.put(exporter.WORKFLOW, "name: iOS Build\non:\n  push:\n  workflow_dispatch:\njobs:\n  build:\n    runs-on: macos-26\n")
        self.commit()
        with self.assertRaisesRegex(RuntimeError, "manual-only"):
            self.export()

    def test_dirty_head_requires_explicit_ref(self):
        self.put("ios/App.swift", "uncommitted version\n")
        with patch("sys.argv", ["export_public_ios.py"]):
            with self.assertRaisesRegex(RuntimeError, "uncommitted"):
                exporter.main()

    def test_unsupported_modes_and_paths_are_refused(self):
        for name, mode in [("backend/app.py", "100644"), ("ios/../relay.env", "100644"), ("ios/link", "120000")]:
            with self.assertRaises(RuntimeError):
                exporter.validate_path(name, mode)

if __name__ == "__main__":
    unittest.main()

