"""Guard tests for clasificar_riesgo.py (nightly low-risk auto-apply gate)."""
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "clasificar_riesgo.py"


class ClasificarRiesgoTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def run_clf(self, antes, despues, tipo="prompt"):
        a = self.dir / "a.txt"
        b = self.dir / "b.txt"
        a.write_text(antes, encoding="utf-8")
        b.write_text(despues, encoding="utf-8")
        p = subprocess.run(
            [sys.executable, str(SCRIPT), "--tipo", tipo, "--antes", str(a), "--despues", str(b)],
            capture_output=True, text=True,
        )
        return p.returncode, json.loads(p.stdout)

    def test_wording_cleanup_is_low_risk(self):
        antes = "¡Claro! Quedo atento a cualquier duda.\nAtiendo remesas a Cuba.\n"
        despues = "Sí.\nAtiendo remesas a Cuba.\n"
        rc, out = self.run_clf(antes, despues)
        self.assertEqual(rc, 0)
        self.assertEqual(out["riesgo"], "bajo", out)

    def test_price_change_is_high_risk(self):
        rc, out = self.run_clf("El precio es 100 GYD.\n", "El precio es 120 GYD.\n")
        self.assertEqual(rc, 3)
        self.assertEqual(out["riesgo"], "alto")
        self.assertTrue(any("precio" in m for m in out["motivos"]), out)

    def test_handoff_rule_is_high_risk(self):
        rc, out = self.run_clf("Si pide persona, responde amable.\n", "Si pide persona, deriva a un humano.\n")
        self.assertEqual(rc, 3)
        self.assertTrue(any("humano" in m or "deriv" in m for m in out["motivos"]), out)

    def test_tool_name_is_high_risk(self):
        rc, out = self.run_clf("Usa la herramienta de registro.\n", "Usa registrar_beneficiario.\n")
        self.assertEqual(rc, 3)
        self.assertTrue(any("herramienta" in m for m in out["motivos"]), out)

    def test_decisor_change_is_high_risk(self):
        rc, out = self.run_clf("return 'a';", "return 'b';", tipo="decisor")
        self.assertEqual(rc, 3)
        self.assertTrue(any("decisor" in m.lower() for m in out["motivos"]), out)

    def test_identical_text_has_no_change(self):
        rc, out = self.run_clf("Texto igual.\n", "Texto igual.\n")
        self.assertEqual(rc, 0)
        self.assertEqual(out["riesgo"], "sin_cambios", out)

    def test_accented_deposit_is_high_risk(self):
        rc, out = self.run_clf("El deposito se registra solo.\n", "El depósito se registra solo.\n")
        self.assertEqual(rc, 3)
        self.assertTrue(any("deposito" in m for m in out["motivos"]), out)


if __name__ == "__main__":
    unittest.main()
