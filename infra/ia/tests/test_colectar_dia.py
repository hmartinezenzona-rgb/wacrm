"""Guard tests for colectar_dia.py. Docker is replaced by a fake on PATH."""
import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "colectar_dia.py"

PAYLOAD = {
    "desde": "2026-11-22T00:00:00Z",
    "hasta": "2026-11-23T00:00:00Z",
    "conversaciones": [{"id": "c1", "mensajes": [{"texto": "hola"}]}, {"id": "c2", "mensajes": []}],
    "sin_respuesta": [],
    "operaciones": [],
    "herramientas": {},
}


class ColectarDiaTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.bin = self.dir / "bin"
        self.bin.mkdir()
        self.log = self.dir / "docker.log"
        fake = self.bin / "docker"
        fake.write_text(
            "#!/bin/sh\n"
            f"cat > '{self.log}'\n"
            f"cat <<'EOF_JSON'\n{json.dumps(PAYLOAD)}\nEOF_JSON\n"
        )
        fake.chmod(fake.stat().st_mode | stat.S_IXUSR)
        self.envfile = self.dir / "prod.env"
        self.envfile.write_text("PROD_DATABASE_URL=postgresql://fake\n")
        self.out = self.dir / "dia.json"

    def tearDown(self):
        self.tmp.cleanup()

    def run_script(self, *extra):
        env = dict(os.environ)
        env["PATH"] = f"{self.bin}:{env['PATH']}"
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--env-file", str(self.envfile),
             "--salida", str(self.out), "--horas", "24", *extra],
            capture_output=True, text=True, env=env,
        )

    def test_writes_private_file_without_printing_messages(self):
        p = self.run_script()
        self.assertEqual(p.returncode, 0, p.stderr)
        data = json.loads(self.out.read_text())
        self.assertEqual(len(data["conversaciones"]), 2)
        self.assertEqual(stat.S_IMODE(self.out.stat().st_mode), 0o600)
        self.assertIn(str(self.out), p.stdout)
        self.assertNotIn("hola", p.stdout)

    def test_sql_is_read_only(self):
        self.assertEqual(self.run_script().returncode, 0)
        sql = self.log.read_text().lower()
        self.assertIn("begin read only", sql)
        self.assertIn("rollback", sql)
        self.assertIn("make_interval", sql)
        self.assertNotIn("insert ", sql)
        self.assertNotIn("update ", sql)
        self.assertNotIn("delete ", sql)
        for term in ("ai_generated", "is_panel_action", "autor", "etiquetas", "contact_tags"):
            self.assertIn(term, sql)

    def test_missing_env_file_fails_without_running_docker(self):
        self.envfile.unlink()
        p = self.run_script()
        self.assertNotEqual(p.returncode, 0)
        self.assertFalse(self.log.exists())


if __name__ == "__main__":
    unittest.main()
