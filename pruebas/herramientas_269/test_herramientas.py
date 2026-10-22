"""269 / M5: the agent tools that declare, change and add a service (staging Cerebro).

Offline checks over the pure builders in herramientas.py (no n8n, no database).
Run: python3 -m unittest discover -s pruebas/herramientas_269
"""
import copy
import json
import os
import re
import sys
import unittest

sys.path.insert(0, os.path.dirname(__file__))
import herramientas as h  # noqa: E402


def flujo_base():
    """A minimal workflow with the nodes the builders clone or touch."""
    cred = {"postgres": {"id": "np3egGrAcrWkOWd4", "name": "Supabase STAGING"}}

    def pg(name, query, repl):
        return {"id": "id-" + name, "name": name, "type": "n8n-nodes-base.postgresTool", "position": [100, 100],
                "credentials": cred,
                "parameters": {"operation": "executeQuery", "query": query,
                               "options": {"queryReplacement": repl}, "descriptionType": "manual",
                               "toolDescription": "old"}}

    return {
        "name": "wf", "settings": {},
        "nodes": [
            pg("cambiar_servicio", "SELECT cerebro_cambiar_servicio($1::uuid, $2::text, $3::text) AS resultado;", "=old"),
            pg("registrar_numeros_recarga",
               "SELECT crm_registrar_numeros_recarga($1::uuid, $2, p_abrir => true) AS resultado;", "=old"),
            {"id": "agent", "name": "Agente Remesas", "type": "@n8n/n8n-nodes-langchain.agent", "position": [0, 0],
             "parameters": {"options": {"systemMessage": "x"}}},
        ],
        "connections": {"cambiar_servicio": {"ai_tool": [[{"node": "Agente Remesas", "type": "ai_tool", "index": 0}]]}},
    }


class TestConsultas(unittest.TestCase):
    def test_cambiar_usa_aplicar_con_intencion_y_actor(self):
        q = h.consulta("cambiar")
        self.assertIn("cerebro_aplicar_servicio(", q)
        self.assertIn("'cambiar'", q)
        self.assertIn("'agent:cambiar_servicio'", q)

    def test_agregar_usa_aplicar_con_intencion_y_actor(self):
        q = h.consulta("agregar")
        self.assertIn("cerebro_aplicar_servicio(", q)
        self.assertIn("'agregar'", q)
        self.assertIn("'agent:agregar_servicio'", q)

    def test_declarar_solo_registra_la_intencion(self):
        q = h.consulta("declarar")
        self.assertIn("cerebro_declarar_servicio(", q)
        self.assertIn("'agent:declarar_servicio'", q)
        self.assertNotIn("cerebro_aplicar_servicio", q)  # the resolver refuses the intent 'declarar' (265 R0)

    def test_las_tres_devuelven_el_mensaje_de_la_base(self):
        for modo in ("cambiar", "agregar", "declarar"):
            self.assertIn("mensaje", h.consulta(modo))

    def test_numeros_pasan_abrir_y_actor(self):
        q = h.consulta_numeros()
        self.assertIn("p_abrir => true", q)
        self.assertIn("p_actor => 'agent:registrar_numeros_recarga'", q)

    def test_parametros_posicionales_cuadran_con_el_reemplazo(self):
        for modo in ("cambiar", "agregar", "declarar"):
            q = h.consulta(modo)
            usados = {int(n) for n in re.findall(r"\$(\d)", q)}
            n_repl = h.reemplazo(modo).count("$fromAI") + h.reemplazo(modo).count("$execution.id") \
                + h.reemplazo(modo).count("conversation_id")
            self.assertEqual(usados, set(range(1, n_repl + 1)), modo)

    def test_los_servicios_ofrecidos_incluyen_mexico_y_los_rieles(self):
        for modo in ("cambiar", "agregar", "declarar"):
            d = h.reemplazo(modo) + h.descripcion(modo)
            for clave in ("recarga", "combo", "visa", "saldo", "cuban_card", "clasica", "tropical", "zelle",
                          "efectivo_usd", "mexico"):
                self.assertIn(clave, d, (modo, clave))


class TestFlujo(unittest.TestCase):
    def setUp(self):
        self.wf = flujo_base()
        self.antes = copy.deepcopy(self.wf)
        self.nuevo = h.aplicar_herramientas(copy.deepcopy(self.wf))

    def nodo(self, nombre):
        return next(n for n in self.nuevo["nodes"] if n["name"] == nombre)

    def test_tres_herramientas_conectadas_al_agente(self):
        for nombre in ("declarar_servicio", "cambiar_servicio", "agregar_servicio"):
            self.nodo(nombre)
            destino = self.nuevo["connections"][nombre]["ai_tool"][0][0]
            self.assertEqual(destino["node"], "Agente Remesas")

    def test_credencial_heredada_y_ids_distintos(self):
        cred = self.antes["nodes"][0]["credentials"]
        ids = set()
        for nombre in ("declarar_servicio", "cambiar_servicio", "agregar_servicio"):
            self.assertEqual(self.nodo(nombre)["credentials"], cred)
            ids.add(self.nodo(nombre)["id"])
        self.assertEqual(len(ids), 3)
        self.assertEqual(self.nodo("cambiar_servicio")["id"], "id-cambiar_servicio")  # edited in place

    def test_numeros_cambia_solo_la_consulta(self):
        a = self.antes["nodes"][1]["parameters"]
        n = self.nodo("registrar_numeros_recarga")["parameters"]
        self.assertEqual(n["options"], a["options"])
        self.assertEqual(n["toolDescription"], a["toolDescription"])
        self.assertIn("p_actor", n["query"])

    def test_el_resto_del_flujo_no_se_toca(self):
        self.assertEqual(self.nodo("Agente Remesas"), self.antes["nodes"][2])

    def test_idempotente(self):
        otra = h.aplicar_herramientas(copy.deepcopy(self.nuevo))
        self.assertEqual(json.dumps(otra, sort_keys=True), json.dumps(self.nuevo, sort_keys=True))


class TestPrompt(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        ruta = os.path.join(os.path.dirname(__file__), "prompt_base_staging.txt")
        cls.base = open(ruta, encoding="utf-8").read()
        cls.nuevo = h.editar_prompt(cls.base)

    def test_declara_antes_de_pagar_y_nunca_adivina_por_el_comprobante(self):
        n = self.nuevo
        self.assertIn("declarar_servicio(servicio)", n)
        self.assertIn("agregar_servicio(servicio)", n)
        self.assertRegex(n, r"(?i)ANTES de que deposite")
        self.assertRegex(n, r"(?i)NUNCA adivines el servicio por el comprobante")

    def test_la_seccion_vieja_de_cambio_de_via_se_reemplaza(self):
        self.assertNotIn("## CAMBIO DE VIA", self.nuevo)
        self.assertNotIn("destination_currency", self.nuevo)
        self.assertNotIn("reason=por_debajo_del_minimo", self.nuevo)

    def test_las_referencias_a_la_seccion_vieja_no_quedan_colgando(self):
        self.assertNotIn("Ver CAMBIO DE VIA", self.nuevo)
        self.assertNotIn("(ver CAMBIO DE VIA)", self.nuevo)

    def test_sin_restos_de_albo(self):
        self.assertNotRegex(self.nuevo, r"(?i)albo|123456781232456700|spei")

    def test_idempotente(self):
        self.assertEqual(h.editar_prompt(self.nuevo), self.nuevo)

    def test_no_pierde_otras_secciones(self):
        for marca in ("## ESTILO", "## VIA USD", "## NEGOCIO", "registrar_beneficiario_zelle(nombre,cuenta)"):
            self.assertIn(marca, self.nuevo)


if __name__ == "__main__":
    unittest.main()
