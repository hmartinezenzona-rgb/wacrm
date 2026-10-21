"""Tests for cerebro_n8n.py against a local stub of the n8n public API (no real n8n is touched)."""
import copy
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "cerebro_n8n.py"
KEY = "SECRETKEY-do-not-print-12345"
STAGING = "U52y1kSNvhgxvWeb"
PRODUCCION = "jEzlVLCLUaJhVwzs"
REPO_CODE = "return [{json: {repo: true}}];\n"


def md5(text):
    return hashlib.md5(text.encode("utf-8")).hexdigest()


def make_workflow(wid, decisor_code, ctx_query, extra_nodes=()):
    nodes = [
        {"id": "n1", "name": "Decisor", "type": "n8n-nodes-base.code", "parameters": {"jsCode": decisor_code}},
        {"id": "n2", "name": "Contexto conversacion", "type": "n8n-nodes-base.postgres",
         "parameters": {"query": ctx_query}},
        {"id": "n3", "name": "Agente Remesas", "type": "x.agent", "parameters": {"text": "same"}},
        *extra_nodes,
    ]
    return {
        "id": wid, "name": f"Cerebro {wid}", "active": True, "versionId": f"v1-{wid[:4]}",
        "activeVersionId": f"v1-{wid[:4]}", "createdAt": "2026-01-01", "updatedAt": "2026-01-02",
        "nodes": nodes, "connections": {"Decisor": {"main": []}}, "settings": {"executionOrder": "v1"},
        "staticData": None, "tags": [],
    }


class Stub:
    """In-memory n8n: GET/PUT /api/v1/workflows/{id}. Records every PUT."""

    def __init__(self, backups_dir):
        self.backups_dir = Path(backups_dir)
        self.workflows = {
            STAGING: make_workflow(STAGING, "return 'staging-old';", "SELECT 1 /* staging extra */",
                                   [{"id": "n9", "name": "solo_staging", "type": "t", "parameters": {"q": "x"}}]),
            PRODUCCION: make_workflow(PRODUCCION, "return 'prod-old';", "SELECT 1",
                                      [{"id": "n8", "name": "solo_produccion", "type": "t", "parameters": {}}]),
        }
        self.puts = []  # (wid, body, backup_files_at_put_time)
        self.activate_on_put = True
        self.requests = 0
        self.redirect_to = None
        self.drop_nodes_on_put = False
        stub = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def _wid(self):
                m = re.fullmatch(r"/api/v1/workflows/([A-Za-z0-9]+)", self.path)
                return m.group(1) if m else None

            def _send(self, code, obj):
                data = json.dumps(obj).encode()
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def _auth(self):
                if self.headers.get("X-N8N-API-KEY") != KEY:
                    self._send(401, {"message": "unauthorized"})
                    return False
                return True

            def do_GET(self):
                stub.requests += 1
                if stub.redirect_to:
                    self.send_response(302)
                    self.send_header("Location", stub.redirect_to)
                    self.end_headers()
                    return
                if not self._auth():
                    return
                wid = self._wid()
                if wid in stub.workflows:
                    self._send(200, copy.deepcopy(stub.workflows[wid]))
                else:
                    self._send(404, {"message": "not found"})

            def do_PUT(self):
                stub.requests += 1
                if not self._auth():
                    return
                wid = self._wid()
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                stub.puts.append((wid, body, sorted(p.name for p in stub.backups_dir.glob("*.json"))))
                wf = stub.workflows[wid]
                for k in ("name", "nodes", "connections", "settings"):
                    wf[k] = body[k]
                if stub.drop_nodes_on_put:
                    wf["nodes"] = wf["nodes"][:1]
                wf["versionId"] = f"v{len(stub.puts) + 1}-{wid[:4]}"
                if stub.activate_on_put:
                    wf["activeVersionId"] = wf["versionId"]
                self._send(200, copy.deepcopy(wf))

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.server.server_port}"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()


class CerebroTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.home = root / "home"
        self.home.mkdir()
        (self.home / ".n8n-api-key").write_text(KEY + "\n")
        self.backups = root / "backups"
        self.backups.mkdir()
        self.decisor_file = root / "decisor.jscode"
        self.decisor_file.write_text(REPO_CODE, encoding="utf-8")
        self.stub = Stub(self.backups)
        self.addCleanup(self.stub.close)
        self.addCleanup(self.tmp.cleanup)
        self.env = dict(os.environ, HOME=str(self.home), CEREBRO_N8N_BASE=self.stub.url,
                        CEREBRO_N8N_BACKUPS=str(self.backups), CEREBRO_DECISOR_FILE=str(self.decisor_file))

    def run_cli(self, *args):
        r = subprocess.run([sys.executable, str(SCRIPT), *args], capture_output=True, text=True,
                           env=self.env, timeout=30)
        self.assertNotIn(KEY, r.stdout + r.stderr, "API key leaked")
        return r

    def live_md5(self, wid):
        dec = next(n for n in self.stub.workflows[wid]["nodes"] if n["name"] == "Decisor")
        return md5(dec["parameters"]["jsCode"])

    # --- respaldo ---
    def test_respaldo_writes_backup_and_prints_path_and_version(self):
        r = self.run_cli("respaldo", "staging")
        self.assertEqual(r.returncode, 0, r.stderr)
        files = list(self.backups.glob("*.json"))
        self.assertEqual(len(files), 1)
        self.assertRegex(files[0].name, rf"^staging-{STAGING}-v1-U52y-\d{{8}}-\d{{6}}\.json$")
        self.assertEqual(json.loads(files[0].read_text())["id"], STAGING)
        self.assertIn(str(files[0]), r.stdout)
        self.assertIn("versionId: v1-U52y", r.stdout)

    def test_unknown_env_is_rejected(self):
        r = self.run_cli("respaldo", "desarrollo")
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.stub.requests, 0)

    def test_wrong_api_key_fails_without_leaking_it(self):
        (self.home / ".n8n-api-key").write_text("WRONG-KEY-777\n")
        r = self.run_cli("estado", "staging")
        self.assertNotEqual(r.returncode, 0)
        self.assertNotIn("WRONG-KEY-777", r.stdout + r.stderr)

    # --- estado ---
    def test_estado_reports_versions_nodes_and_decisor_md5(self):
        r = self.run_cli("estado", "produccion")
        self.assertEqual(r.returncode, 0, r.stderr)
        out = r.stdout
        self.assertIn("versionId: v1-jEzl", out)
        self.assertIn("activeVersionId: v1-jEzl", out)
        self.assertIn("active: true", out)
        self.assertIn("nodes: 4", out)
        self.assertIn(f"decisor_md5: {self.live_md5(PRODUCCION)[:8]}", out)
        self.assertIn("repo_md5_match: no", out)

    def test_estado_detects_repo_match(self):
        dec = next(n for n in self.stub.workflows[STAGING]["nodes"] if n["name"] == "Decisor")
        dec["parameters"]["jsCode"] = REPO_CODE
        r = self.run_cli("estado", "staging")
        self.assertIn("repo_md5_match: yes", r.stdout)
        self.assertIn(f"decisor_md5: {md5(REPO_CODE)[:8]}", r.stdout)

    def test_estado_flags_version_mismatch(self):
        self.stub.workflows[STAGING]["activeVersionId"] = "old-version"
        r = self.run_cli("estado", "staging")
        self.assertIn("versionId: v1-U52y", r.stdout)
        self.assertIn("activeVersionId: old-version", r.stdout)
        self.assertIn("MISMATCH", r.stdout)

    # --- comparar ---
    def test_comparar_lists_only_and_differing_nodes(self):
        stg = self.stub.workflows[STAGING]["nodes"]
        stg.append({"id": "c1", "name": "Calc", "type": "n8n-nodes-base.code", "parameters": {"jsCode": "a"}})
        stg.append({"id": "q1", "name": "Consulta", "type": "n8n-nodes-base.postgres", "parameters": {"query": "Q1"}})
        prod = self.stub.workflows[PRODUCCION]["nodes"]
        prod.append({"id": "c2", "name": "Calc", "type": "n8n-nodes-base.code", "parameters": {"jsCode": "b"}})
        prod.append({"id": "q2", "name": "Consulta", "type": "n8n-nodes-base.postgres", "parameters": {"query": "Q2"}})
        r = self.run_cli("comparar")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("only staging: solo_staging", r.stdout)
        self.assertIn("only produccion: solo_produccion", r.stdout)
        self.assertRegex(r.stdout, rf"differs: Contexto conversacion .*{md5('SELECT 1 /* staging extra */')[:8]}"
                                   rf".*{md5('SELECT 1')[:8]}")
        self.assertIn("differs: Decisor", r.stdout)
        self.assertRegex(r.stdout, rf"differs: Calc .*{md5('a')[:8]}.*{md5('b')[:8]}")
        self.assertRegex(r.stdout, rf"differs: Consulta .*{md5('Q1')[:8]}.*{md5('Q2')[:8]}")
        self.assertNotIn("differs: Agente Remesas", r.stdout)
        self.assertEqual([], self.stub.puts)

    # --- publicar-decisor ---
    def test_publicar_refuses_when_esperado_does_not_match(self):
        r = self.run_cli("publicar-decisor", "staging", "--esperado", "00000000")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("REFUSED", r.stdout + r.stderr)
        self.assertEqual(self.stub.puts, [])
        self.assertEqual(list(self.backups.glob("*.json")), [])

    def test_publicar_backs_up_first_puts_allowed_keys_and_verifies(self):
        expected = self.live_md5(STAGING)[:8]
        r = self.run_cli("publicar-decisor", "staging", "--esperado", expected)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(len(self.stub.puts), 1)
        wid, body, backups_at_put = self.stub.puts[0]
        self.assertEqual(wid, STAGING)
        self.assertEqual(set(body), {"name", "nodes", "connections", "settings"})
        self.assertEqual(len(backups_at_put), 1, "backup must exist before the PUT")
        names = {n["name"]: n for n in body["nodes"]}
        self.assertEqual(names["Decisor"]["parameters"]["jsCode"], REPO_CODE)
        self.assertEqual(len(body["nodes"]), 4)  # nothing else added or removed
        self.assertEqual(self.live_md5(STAGING), md5(REPO_CODE))
        self.assertIn("OK", r.stdout)
        # backup holds the pre-change workflow
        saved = json.loads((self.backups / backups_at_put[0]).read_text())
        self.assertEqual(saved["nodes"][0]["parameters"]["jsCode"], "return 'staging-old';")

    def test_publicar_fails_when_active_version_not_updated(self):
        self.stub.activate_on_put = False
        r = self.run_cli("publicar-decisor", "staging", "--esperado", self.live_md5(STAGING)[:8])
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("activeVersionId", r.stdout + r.stderr)

    def test_publicar_requires_esperado(self):
        r = self.run_cli("publicar-decisor", "staging")
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.stub.puts, [])

    # --- restaurar ---
    def make_backup(self, wid, code="return 'restored';"):
        wf = make_workflow(wid, code, "SELECT 1")
        path = self.backups.parent / f"manual-{wid}.json"
        path.write_text(json.dumps(wf))
        return path

    def test_restaurar_refuses_backup_of_other_workflow(self):
        path = self.make_backup(PRODUCCION)
        r = self.run_cli("restaurar", "staging", str(path), "--esperado", "v1-U52y")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("REFUSED", r.stdout + r.stderr)
        self.assertEqual(self.stub.puts, [])

    def test_restaurar_refuses_when_live_version_does_not_match(self):
        path = self.make_backup(STAGING)
        r = self.run_cli("restaurar", "staging", str(path), "--esperado", "zzz")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("REFUSED", r.stdout + r.stderr)
        self.assertEqual(self.stub.puts, [])

    def test_restaurar_backs_up_then_puts_allowed_keys_and_verifies(self):
        path = self.make_backup(STAGING)
        r = self.run_cli("restaurar", "staging", str(path), "--esperado", "v1-U52")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        wid, body, backups_at_put = self.stub.puts[0]
        self.assertEqual(wid, STAGING)
        self.assertEqual(set(body), {"name", "nodes", "connections", "settings"})
        self.assertEqual(len(backups_at_put), 1, "pre-restore backup must exist before the PUT")
        self.assertEqual(self.live_md5(STAGING), md5("return 'restored';"))

    def test_restaurar_rejects_missing_backup_file(self):
        r = self.run_cli("restaurar", "staging", str(self.backups / "nope.json"), "--esperado", "v1")
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.stub.puts, [])

    # --- hardening found in review of the Hermes draft ---
    def test_empty_or_short_esperado_is_refused(self):
        for cmd in (("publicar-decisor", "staging", "--esperado", ""),
                    ("publicar-decisor", "staging", "--esperado", "ab")):
            r = self.run_cli(*cmd)
            self.assertEqual(r.returncode, 2, cmd)
            self.assertIn("REFUSED", r.stdout + r.stderr)
        path = self.make_backup(STAGING)
        r = self.run_cli("restaurar", "staging", str(path), "--esperado", "")
        self.assertEqual(r.returncode, 2)
        self.assertEqual(self.stub.puts, [])

    def test_backup_file_is_private(self):
        self.run_cli("respaldo", "staging")
        f = next(self.backups.glob("*.json"))
        self.assertEqual(f.stat().st_mode & 0o077, 0)

    def test_remote_plain_http_base_is_refused(self):
        self.env["CEREBRO_N8N_BASE"] = "http://example.com"
        r = self.run_cli("estado", "staging")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("https", r.stderr)

    def test_redirect_is_not_followed(self):
        self.stub.redirect_to = "http://127.0.0.1:9/elsewhere"
        r = self.run_cli("estado", "staging")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("302", r.stderr)

    def test_restaurar_rejects_backup_without_nodes(self):
        path = self.backups.parent / "bad.json"
        path.write_text(json.dumps({"id": STAGING, "name": "x"}))
        r = self.run_cli("restaurar", "staging", str(path), "--esperado", "v1-U52")
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.stub.puts, [])

    def test_restaurar_verifies_node_count_and_decisor(self):
        path = self.make_backup(STAGING)
        self.stub.drop_nodes_on_put = True
        r = self.run_cli("restaurar", "staging", str(path), "--esperado", "v1-U52")
        self.assertNotEqual(r.returncode, 0)


if __name__ == "__main__":
    unittest.main()
