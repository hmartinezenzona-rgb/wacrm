"""Guard tests for aplicar_candidato.py. The eval and deploy scripts are fakes."""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "aplicar_candidato.py"


class AplicarCandidatoTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.evals = self.dir / "evals"
        self.evals.mkdir()
        self.log = self.dir / "calls.log"
        self.estado = self.dir / "estado.json"
        self.candidato = self.dir / "candidato.txt"
        self.candidato.write_text("Sí. Atiendo remesas.\n", encoding="utf-8")
        self.eval_code = 0
        (self.evals / "evaluar.py").write_text(
            "import sys\n"
            f"open(r'{self.log}','a').write('EVAL '+' '.join(sys.argv[1:])+'\\n')\n"
            f"sys.exit({self.eval_code})\n",
            encoding="utf-8",
        )
        (self.evals / "desplegar_prompt.py").write_text(
            "import sys\n"
            f"open(r'{self.log}','a').write('DEPLOY '+' '.join(sys.argv[1:])+'\\n')\n"
            "print('COINCIDE')\n",
            encoding="utf-8",
        )

    def tearDown(self):
        self.tmp.cleanup()

    def run_apply(self, *extra):
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--candidato", str(self.candidato),
             "--riesgo", "bajo", "--evals-dir", str(self.evals),
             "--estado", str(self.estado), "--etiqueta", "test-night",
             "--reps", "5", *extra],
            capture_output=True, text=True,
        )

    def calls(self):
        return self.log.read_text(encoding="utf-8") if self.log.exists() else ""

    def test_green_eval_without_apply_only_records_ready(self):
        p = self.run_apply()
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("EVAL --casos", self.calls())
        self.assertNotIn("DEPLOY", self.calls())
        self.assertEqual(json.loads(self.estado.read_text())["estado"], "listo")

    def test_green_eval_with_apply_deploys_and_records_rollback(self):
        p = self.run_apply("--aplicar")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("DEPLOY --candidato", self.calls())
        state = json.loads(self.estado.read_text())
        self.assertEqual(state["estado"], "aplicado")
        self.assertIn("ROLLBACK-v2-antes-test-night.json", state["rollback"])

    def test_red_eval_never_deploys(self):
        (self.evals / "evaluar.py").write_text(
            "import sys\n"
            f"open(r'{self.log}','a').write('EVAL '+' '.join(sys.argv[1:])+'\\n')\n"
            "sys.exit(1)\n",
            encoding="utf-8",
        )
        p = self.run_apply("--aplicar")
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("EVAL", self.calls())
        self.assertNotIn("DEPLOY", self.calls())
        self.assertEqual(json.loads(self.estado.read_text())["estado"], "rechazado")

    def test_high_risk_never_runs_eval_or_deploy(self):
        p = subprocess.run(
            [sys.executable, str(SCRIPT), "--candidato", str(self.candidato),
             "--riesgo", "alto", "--evals-dir", str(self.evals),
             "--estado", str(self.estado), "--etiqueta", "test-night", "--aplicar"],
            capture_output=True, text=True,
        )
        self.assertNotEqual(p.returncode, 0)
        self.assertNotIn("EVAL", self.calls())
        self.assertNotIn("DEPLOY", self.calls())

    def test_uses_the_subset_casos_path(self):
        subset = self.dir / "subconjunto.json"
        subset.write_text('{"version":1,"casos":[]}', encoding="utf-8")
        p = self.run_apply("--casos", str(subset))
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn(f"--casos {subset}", self.calls())


if __name__ == "__main__":
    unittest.main()
