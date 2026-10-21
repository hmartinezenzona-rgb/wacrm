"""Guard tests for delegar_hermes.py. Hermes is replaced by a fake executable on PATH."""
import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "delegar_hermes.py"

ANSWER = "FILE: out/hola.py\n```python\nprint('hola')\n```\n\nFILE: out/sub/dos.txt\n```\ndos\n```\n"


class DelegarHermesTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.bin = self.dir / "bin"
        self.bin.mkdir()
        self.prompt_log = self.dir / "prompt.log"
        fake = self.bin / "hermes"
        fake.write_text(
            "#!/bin/sh\n"
            f"printf '%s' \"$2\" > '{self.prompt_log}'\n"
            f"cat <<'EOF_ANSWER'\n{ANSWER}EOF_ANSWER\n"
        )
        fake.chmod(fake.stat().st_mode | stat.S_IXUSR)
        self.task = self.dir / "task.md"
        self.task.write_text("Write hola.py")
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}")

    def tearDown(self):
        self.tmp.cleanup()

    def run_cli(self, *args):
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--task", str(self.task), *args],
            capture_output=True, text=True, env=self.env, cwd=self.dir,
        )

    def test_secret_path_refused(self):
        for name in (".env", "prod.env", "my_token.txt", "api-key.py", "secret.md", "credentials.json"):
            f = self.dir / name
            f.write_text("harmless")
            r = self.run_cli("--context", str(f))
            self.assertNotEqual(r.returncode, 0, name)
            self.assertIn("REFUSED", r.stderr)
        self.assertFalse(self.prompt_log.exists(), "hermes must not run")

    def test_secret_content_refused(self):
        for payload in ("x = 'sbp_abc123'", "jwt eyJhbGciOiJIUzI1", "X-N8N-API-KEY: zzz",
                        "url postgres://user:pw@host:5432/db"):
            f = self.dir / "ctx.py"
            f.write_text(payload)
            r = self.run_cli("--context", str(f))
            self.assertNotEqual(r.returncode, 0, payload)
            self.assertIn("REFUSED", r.stderr)
        self.assertFalse(self.prompt_log.exists())

    def test_postgres_url_without_password_is_allowed(self):
        f = self.dir / "ctx.py"
        f.write_text("url = 'postgres://host:5432/db'")
        self.assertEqual(self.run_cli("--context", str(f)).returncode, 0)

    def test_path_escape_refused(self):
        evil = "FILE: ../evil.txt\n```\nx\n```\n"
        (self.bin / "hermes").write_text(
            f"#!/bin/sh\ncat <<'E'\n{evil}E\n")
        target = self.dir / "target"
        target.mkdir()
        r = self.run_cli("--apply-to", str(target))
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("REFUSED", r.stderr)
        self.assertFalse((self.dir / "evil.txt").exists())

    def test_absolute_path_refused(self):
        (self.bin / "hermes").write_text(
            "#!/bin/sh\ncat <<'E'\nFILE: /tmp/zz_abs.txt\n```\nx\n```\nE\n")
        target = self.dir / "target"
        target.mkdir()
        r = self.run_cli("--apply-to", str(target))
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse(Path("/tmp/zz_abs.txt").exists())

    def test_apply_writes_files_and_prints_summary(self):
        ctx = self.dir / "ctx.py"
        ctx.write_text("def f(): pass")
        target = self.dir / "target"
        target.mkdir()
        out = self.dir / "answer.md"
        r = self.run_cli("--context", str(ctx), "--apply-to", str(target), "--out", str(out))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual((target / "out/hola.py").read_text(), "print('hola')\n")
        self.assertEqual((target / "out/sub/dos.txt").read_text(), "dos\n")
        self.assertIn("FILE: out/hola.py", out.read_text())
        summary = json.loads(r.stdout.strip().splitlines()[-1])
        self.assertEqual(summary["files"], ["out/hola.py", "out/sub/dos.txt"])
        self.assertEqual(summary["exit"], 0)
        self.assertIn("seconds", summary)
        prompt = self.prompt_log.read_text()
        self.assertIn("Write hola.py", prompt)
        self.assertIn("def f(): pass", prompt)
        self.assertIn(str(ctx), prompt)
        self.assertIn("FILE: <relative path>", prompt)

    def test_hermes_failure_is_reported(self):
        (self.bin / "hermes").write_text("#!/bin/sh\necho boom >&2\nexit 3\n")
        r = self.run_cli()
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(json.loads(r.stdout.strip().splitlines()[-1])["exit"], 3)


if __name__ == "__main__":
    unittest.main()
