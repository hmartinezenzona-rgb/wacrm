"""Guard tests for mejora_nocturna.py. Hermes is replaced by a fake on PATH."""
import http.server
import json
import os
import stat
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "mejora_nocturna.py"

LOW = {
    "resumen": "1 chat con muletilla",
    "hallazgos": [{"chat": "c1", "problema": "muletilla", "cita": "¡Claro!",
                   "causa": "tono", "arreglo": "quitarla"}],
    "propuesta": {
        "v1": [{"buscar": "¡Claro! Atiendo remesas.\n", "reemplazar": "Sí. Atiendo remesas.\n"}],
        "v2": "Atiendo remesas a Cuba.\n",
    },
    "casos_prueba": ["cliente saluda"],
    "familias_afectadas": ["comprobante"],
    "riesgo_sugerido": "bajo",
}
HIGH = {
    "resumen": "precio cambiado",
    "hallazgos": [{"chat": "c1", "problema": "precio", "cita": "100", "causa": "regla", "arreglo": "120"}],
    "propuesta": {
        "v1": [{"buscar": "El precio es 100 GYD.\n", "reemplazar": "El precio es 120 GYD.\n"}],
        "v2": "El precio es 150 GYD.\n",
    },
    "casos_prueba": ["precio"],
    "familias_afectadas": ["comprobante"],
    "riesgo_sugerido": "alto",
}


class MejoraNocturnaTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.bin = self.dir / "bin"
        self.bin.mkdir()
        self.salida = self.dir / "salida"
        self.skills = self.dir / "skills"
        for name in ("revisar-agente-whatsapp", "prompt-crafter-pro"):
            d = self.skills / "one" / name
            d.mkdir(parents=True)
            (d / "SKILL.md").write_text(f"# {name}\nReglas de prueba.\n", encoding="utf-8")
        self.dia = self.dir / "dia.json"
        self.dia.write_text(json.dumps({"conversaciones": [{"id": "c1", "mensajes": [{"texto": "hola"}]}]}), encoding="utf-8")
        self.prompt = self.dir / "prompt.txt"
        self.prompt.write_text("¡Claro! Atiendo remesas.\n", encoding="utf-8")
        self.casos_file = self.dir / "casos.json"
        self.casos_file.write_text(json.dumps({
            "version": 1,
            "descripcion": "test",
            "casos": [
                {"id": "c1", "familia": "comprobante"},
                {"id": "c2", "familia": "comprobante"},
                {"id": "c3", "familia": "saldo-envio"},
                {"id": "c4", "familia": "otros"},
            ],
        }), encoding="utf-8")
        self.answer = self.dir / "answer.txt"
        fake = self.bin / "hermes"
        fake.write_text(
            "#!/bin/sh\n"
            f"cat '{self.answer}'\n"
        )
        fake.chmod(fake.stat().st_mode | stat.S_IXUSR)

    def tearDown(self):
        self.tmp.cleanup()

    def run_review(self, payload=None):
        if payload is not None:
            self.answer.write_text("```json\n" + json.dumps(payload, ensure_ascii=False) + "\n```\n", encoding="utf-8")
        env = dict(os.environ)
        env["PATH"] = f"{self.bin}:{env['PATH']}"
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--dia", str(self.dia),
             "--prompt-actual", str(self.prompt), "--skills-dir", str(self.skills),
             "--salida-dir", str(self.salida), "--backend", "cli",
             "--casos-file", str(self.casos_file)],
            capture_output=True, text=True, env=env,
        )

    def test_low_risk_produces_report_and_candidate(self):
        p = self.run_review(LOW)
        self.assertEqual(p.returncode, 0, p.stderr)
        reports = list(self.salida.glob("informe-*.md"))
        candidates = list(self.salida.glob("candidato-*.txt"))
        self.assertEqual(len(reports), 1)
        self.assertEqual(len(candidates), 1)
        self.assertEqual(stat.S_IMODE(reports[0].stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(candidates[0].stat().st_mode), 0o600)
        self.assertIn("bajo", reports[0].read_text(encoding="utf-8"))
        self.assertIn("candidato=listo", p.stdout)
        self.assertNotIn("¡Claro!", p.stdout)
        subsets = list(self.salida.glob("subconjunto-*.json"))
        self.assertEqual(len(subsets), 1)
        subset = json.loads(subsets[0].read_text(encoding="utf-8"))
        self.assertEqual([c["id"] for c in subset["casos"]], ["c1", "c2"])

    def test_high_risk_reports_without_candidate(self):
        self.prompt.write_text("El precio es 100 GYD.\n", encoding="utf-8")
        p = self.run_review(HIGH)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(len(list(self.salida.glob("candidato-*.txt"))), 0)
        report = list(self.salida.glob("informe-*.md"))[0].read_text(encoding="utf-8")
        self.assertIn("alto", report)
        self.assertIn("candidato=ninguno", p.stdout)

    def test_patch_not_found_reports_without_candidate(self):
        malo = {
            "resumen": "parche invalido",
            "hallazgos": [],
            "propuesta": {
                "v1": [{"buscar": "texto que no existe", "reemplazar": "otra cosa"}],
                "v2": "Atiendo remesas.\n",
            },
            "casos_prueba": [],
            "familias_afectadas": ["comprobante"],
            "riesgo_sugerido": "bajo",
        }
        p = self.run_review(malo)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(len(list(self.salida.glob("candidato-*.txt"))), 0)
        report = list(self.salida.glob("informe-*.md"))[0].read_text(encoding="utf-8")
        self.assertIn("buscar aparece 0", report)
        self.assertIn("candidato=ninguno", p.stdout)

    def test_invalid_families_blocks_candidate(self):
        payload = json.loads(json.dumps(LOW))
        payload["familias_afectadas"] = ["no-existe"]
        p = self.run_review(payload)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(len(list(self.salida.glob("candidato-*.txt"))), 0)
        self.assertEqual(len(list(self.salida.glob("subconjunto-*.json"))), 0)
        report = list(self.salida.glob("informe-*.md"))[0].read_text(encoding="utf-8")
        self.assertIn("familias", report.lower())
        self.assertIn("candidato=ninguno", p.stdout)

    def test_malformed_hermes_output_fails_without_report(self):
        self.answer.write_text("no es json\n", encoding="utf-8")
        env = dict(os.environ)
        env["PATH"] = f"{self.bin}:{env['PATH']}"
        p = subprocess.run(
            [sys.executable, str(SCRIPT), "--dia", str(self.dia),
             "--prompt-actual", str(self.prompt), "--skills-dir", str(self.skills),
             "--salida-dir", str(self.salida), "--backend", "cli",
             "--casos-file", str(self.casos_file)],
            capture_output=True, text=True, env=env,
        )
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(len(list(self.salida.glob("informe-*.md"))), 0)

    def test_control_chars_and_missing_proposal_reports_only(self):
        raw = (
            '```json\n'
            '{"resumen":"x","hallazgos":[{"chat":"c1","problema":"error",'
            '"cita":"linea1\nlinea2","causa":"c","arreglo":"a"}],'
            '"familias_afectadas":["comprobante"],"riesgo_sugerido":"alto"}\n'
            '```\n'
        )
        self.answer.write_text(raw, encoding="utf-8")
        p = self.run_review(None)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(len(list(self.salida.glob("candidato-*.txt"))), 0)
        self.assertEqual(len(list(self.salida.glob("informe-*.md"))), 1)
        self.assertIn("candidato=ninguno", p.stdout)

    def test_crm_timeout_retries_with_a_compact_prompt(self):
        import time
        prompts = []

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                n = int(self.headers.get('Content-Length', '0'))
                body = json.loads(self.rfile.read(n))
                prompts.append(body.get('prompt', ''))
                if len(prompts) == 1:
                    time.sleep(1.5)  # longer than --timeout 1: the client gives up
                ans = "```json\n" + json.dumps(LOW, ensure_ascii=False) + "\n```\n"
                payload = json.dumps({"content": ans}).encode()
                try:
                    self.send_response(200)
                    self.send_header('Content-Type', 'application/json')
                    self.send_header('Content-Length', str(len(payload)))
                    self.end_headers()
                    self.wfile.write(payload)
                except (BrokenPipeError, ConnectionResetError):
                    pass

            def log_message(self, *args):
                pass

        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            url = f"http://127.0.0.1:{server.server_address[1]}/review"
            env = dict(os.environ)
            env["CRM_REVIEW_SECRET"] = "s3"
            p = subprocess.run(
                [sys.executable, str(SCRIPT), "--dia", str(self.dia),
                 "--prompt-actual", str(self.prompt), "--skills-dir", str(self.skills),
                 "--salida-dir", str(self.salida), "--backend", "crm", "--crm-url", url,
                 "--casos-file", str(self.casos_file), "--timeout", "1"],
                capture_output=True, text=True, env=env,
            )
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertGreaterEqual(len(prompts), 2)
            self.assertIn("reintento compacto", p.stderr)
            self.assertEqual(len(list(self.salida.glob("candidato-*.txt"))), 1)
        finally:
            server.shutdown()
            server.server_close()

    def test_crm_backend_posts_prompt_and_parses_content(self):
        captured = {}

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                n = int(self.headers.get('Content-Length', '0'))
                body = json.loads(self.rfile.read(n))
                captured['secret'] = self.headers.get('x-cerebro-secret')
                captured['prompt'] = body.get('prompt')
                ans = "```json\n" + json.dumps(LOW, ensure_ascii=False) + "\n```\n"
                payload = json.dumps({"content": ans}).encode()
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def log_message(self, *args):
                pass

        server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            url = f"http://127.0.0.1:{server.server_address[1]}/review"
            env = dict(os.environ)
            env["CRM_REVIEW_SECRET"] = "s3"
            p = subprocess.run(
                [sys.executable, str(SCRIPT), "--dia", str(self.dia),
                 "--prompt-actual", str(self.prompt), "--skills-dir", str(self.skills),
                 "--salida-dir", str(self.salida), "--backend", "crm", "--crm-url", url,
                 "--casos-file", str(self.casos_file)],
                capture_output=True, text=True, env=env,
            )
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertEqual(captured["secret"], "s3")
            self.assertIn("### CONVERSACIONES DEL DIA", captured["prompt"])
            self.assertEqual(len(list(self.salida.glob("candidato-*.txt"))), 1)
        finally:
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    unittest.main()
