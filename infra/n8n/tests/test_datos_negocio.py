"""Tests for the business-data drift check (synthetic data only)."""
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import datos_negocio as dn  # noqa: E402


def wf(datos=None, extra_nodes=()):
    nodes = list(extra_nodes)
    if datos is not None:
        nodes.append({"name": "Datos del negocio", "type": "n8n-nodes-base.set",
                      "parameters": {"mode": "raw", "jsonOutput": json.dumps(datos)}})
    return {"name": "wf", "nodes": nodes}


REF = {"agente": {"titular": "Titular Uno", "cuenta": "1112233"},
       "app": {"titular": "Titular App", "pay_merchant": "4445566"},
       "negocio": {"nombre": "Negocio"}}


class LeerDatos(unittest.TestCase):
    def test_reads_the_node(self):
        self.assertEqual(dn.leer_datos(wf(REF)), REF)

    def test_missing_node_is_none(self):
        self.assertIsNone(dn.leer_datos(wf()))


class Comparar(unittest.TestCase):
    def test_equal_copies_have_no_differences(self):
        parcial = {"agente": dict(REF["agente"]), "negocio": dict(REF["negocio"])}
        self.assertEqual(dn.comparar(REF, {"verificar": wf(parcial)}, {}), [])

    def test_a_different_account_is_reported_masked(self):
        otra = {"agente": {"titular": "Titular Uno", "cuenta": "9998877"}, "negocio": {"nombre": "Negocio"}}
        difs = dn.comparar(REF, {"verificar": wf(otra)}, {})
        self.assertEqual(len(difs), 1)
        self.assertIn("verificar", difs[0])
        self.assertIn("agente.cuenta", difs[0])
        self.assertNotIn("9998877", difs[0])
        self.assertNotIn("1112233", difs[0])

    def test_a_copy_without_the_node_is_reported(self):
        difs = dn.comparar(REF, {"verificar": wf()}, {})
        self.assertEqual(len(difs), 1)
        self.assertIn("Datos del negocio", difs[0])

    def test_literal_present_passes(self):
        tut = wf(extra_nodes=[{"name": "Enviar paso 2", "parameters": {"jsonBody": "cuenta *4445566* ok"}}])
        self.assertEqual(dn.comparar(REF, {}, {"tutorial": (tut, "app.pay_merchant")}), [])

    def test_literal_missing_is_reported(self):
        tut = wf(extra_nodes=[{"name": "Enviar paso 2", "parameters": {"jsonBody": "cuenta *0000000* ok"}}])
        difs = dn.comparar(REF, {}, {"tutorial": (tut, "app.pay_merchant")})
        self.assertEqual(len(difs), 1)
        self.assertIn("tutorial", difs[0])
        self.assertNotIn("4445566", difs[0])


class Enmascarar(unittest.TestCase):
    def test_digits_keep_only_the_last_two(self):
        self.assertEqual(dn.enmascarar("1112233"), "*****33")

    def test_names_are_not_masked(self):
        self.assertEqual(dn.enmascarar("Titular Uno"), "Titular Uno")


if __name__ == "__main__":
    unittest.main()
