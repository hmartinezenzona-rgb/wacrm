"""Guard tests for mejora_nocturna.py. Hermes is replaced by a fake on PATH."""
import json
import os
import stat
import subprocess
import sys
import tempfile
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
        self.answer = self.dir / "answer.txt"
        fake = self.bin / "hermes"
        fake.write_text(
            "#!/bin/sh\n"
            f"cat '{self.answer}'\n"
        )
        fake.chmod(fake.stat().st_mode | stat.S_IXUSR)

    def tearDown(self):
        self.tmp.cleanup()

    def run_review(self, payload):
        self.answer.write_text("```json\n" + json.dumps(payload, ensure_ascii=False) + "\n```\n", encoding="utf-8")
        env = dict(os.environ)
        env["PATH"] = f"{self.bin}:{env['PATH']}"
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--dia", str(self.dia),
             "--prompt-actual", str(self.prompt), "--skills-dir", str(self.skills),
             "--salida-dir", str(self.salida)],
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
            "riesgo_sugerido": "bajo",
        }
        p = self.run_review(malo)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(len(list(self.salida.glob("candidato-*.txt"))), 0)
        report = list(self.salida.glob("informe-*.md"))[0].read_text(encoding="utf-8")
        self.assertIn("buscar aparece 0", report)
        self.assertIn("candidato=ninguno", p.stdout)

    def test_malformed_hermes_output_fails_without_report(self):
        self.answer.write_text("no es json\n", encoding="utf-8")
        env = dict(os.environ)
        env["PATH"] = f"{self.bin}:{env['PATH']}"
        p = subprocess.run(
            [sys.executable, str(SCRIPT), "--dia", str(self.dia),
             "--prompt-actual", str(self.prompt), "--skills-dir", str(self.skills),
             "--salida-dir", str(self.salida)],
            capture_output=True, text=True, env=env,
        )
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(len(list(self.salida.glob("informe-*.md"))), 0)


if __name__ == "__main__":
    unittest.main()
