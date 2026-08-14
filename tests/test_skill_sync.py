from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT = REPO_ROOT / "skills" / "codex-skill-sync" / "scripts" / "skill_sync.py"


class RefreshManifestTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.repo = Path(self.temporary.name) / "example-repo"
        self.skill = self.repo / "skills" / "example-skill"
        self.skill.mkdir(parents=True)
        (self.skill / "SKILL.md").write_text(
            "---\nname: example-skill\ndescription: Example.\n---\n\n# Example\n",
            encoding="utf-8",
        )
        self.manifest = self.repo / "skills" / "manifest.json"
        self.manifest.write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "repository": "example-repo",
                    "skills": [
                        {
                            "name": "example-skill",
                            "path": "skills/example-skill",
                            "category": "general",
                            "deploy": True,
                            "source_sha256": "0" * 64,
                        }
                    ],
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )

    def tearDown(self):
        self.temporary.cleanup()

    def run_sync(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(SCRIPT), *arguments],
            check=False,
            capture_output=True,
            text=True,
            encoding="utf-8",
        )

    def test_refresh_is_dry_run_by_default(self):
        before = self.manifest.read_bytes()
        result = self.run_sync("refresh", "--manifest", str(self.manifest))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("REFRESH_DRY_RUN\texample-skill", result.stdout)
        self.assertEqual(self.manifest.read_bytes(), before)

    def test_refresh_apply_updates_hash_and_becomes_stable(self):
        applied = self.run_sync(
            "refresh", "--manifest", str(self.manifest), "--apply"
        )
        self.assertEqual(applied.returncode, 0, applied.stderr)
        updated = json.loads(self.manifest.read_text(encoding="utf-8"))
        digest = updated["skills"][0]["source_sha256"]
        self.assertRegex(digest, r"^[A-F0-9]{64}$")

        stable = self.run_sync(
            "refresh", "--manifest", str(self.manifest), "--strict"
        )
        self.assertEqual(stable.returncode, 0, stable.stderr)
        self.assertIn("REFRESH\tNO_CHANGES", stable.stdout)

    def test_strict_dry_run_reports_pending_update(self):
        result = self.run_sync(
            "refresh", "--manifest", str(self.manifest), "--strict"
        )
        self.assertEqual(result.returncode, 2, result.stderr)


if __name__ == "__main__":
    unittest.main()
