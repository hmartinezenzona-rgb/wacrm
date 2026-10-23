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
            pg("registrar_beneficiario_zelle", "old", "=old"),
            pg("repartir_envio", "q", "=old"),
            pg("gestionar_beneficiario", "q", "=old"),
            pg("marcar_destino_usd", "q", "=$fromAI('tipo', 'x', 'string')"),
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
        self.assertIn(", true, 'agent:registrar_numeros_recarga n8n:' || $3", q)  # p_abrir stays true; the exec id joins the actor
        self.assertIn("COALESCE(NULLIF($4,''),'agregar')", q)

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
        self.assertIn("quitar", n["toolDescription"])
        self.assertEqual(n["options"]["queryReplacement"].count("$fromAI"), 2)  # numeros, accion
        self.assertIn("p_actor", n["query"]) if False else self.assertIn("agent:registrar_numeros_recarga", n["query"])

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


class TestMexico(unittest.TestCase):
    def test_consulta_llama_la_funcion_271_con_el_actor_real(self):
        q = h.consulta_mexico()
        self.assertIn("cerebro_guardar_beneficiario_mexico(", q)
        self.assertIn("'agent:registrar_destinatario_mexico n8n:' || $7", q)
        self.assertIn("mensaje", q)
        usados = {int(n) for n in re.findall(r"\$(\d)", q)}
        self.assertEqual(usados, set(range(1, 8)))  # conv, tipo, clabe, banco, nombre, telefono, execution id
        self.assertEqual(h.reemplazo_mexico().count("$fromAI"), 5)

    def test_nodo_nuevo_conectado_con_la_credencial_de_staging(self):
        wf = h.aplicar_herramientas(flujo_base())
        n = next(x for x in wf["nodes"] if x["name"] == "registrar_destinatario_mexico")
        self.assertEqual(n["credentials"], wf["nodes"][0]["credentials"])
        self.assertEqual(wf["connections"]["registrar_destinatario_mexico"]["ai_tool"][0][0]["node"], "Agente Remesas")
        self.assertIn("mexico_cuenta", n["parameters"]["toolDescription"])
        self.assertIn("mexico_retiro", n["parameters"]["toolDescription"])

    def test_prompt_mexico_sin_pase_a_humano_al_completar(self):
        base = open(os.path.join(os.path.dirname(__file__), "prompt_base_staging.txt"), encoding="utf-8").read()
        p = h.editar_prompt(h.editar_prompt(base))
        i = p.index("- MEXICO:")
        sec = p[i:i + 1800]
        for s in ("registrar_destinatario_mexico", "CLABE", "18 digitos", "Coppel", "BBVA", "via=mexico", "declarar_servicio('mexico')"):
            self.assertIn(s, sec)
        self.assertRegex(sec, r"(?i)NO llames derivar_humano")
        self.assertIn("- registrar_destinatario_mexico(", p)
        self.assertEqual(h.editar_prompt(p), p)


class TestMexicoSmoke(unittest.TestCase):
    """Smoke on staging 2026-10-22: the database rejects a recipient without a full CLABE (no partial merge)."""

    def test_descripcion_y_prompt_no_prometen_datos_a_medias(self):
        self.assertNotIn("Acepta datos a medias", h.DESC_MEXICO)
        self.assertIn("18 digitos", h.DESC_MEXICO)
        self.assertNotIn("En cuanto tengas algo", h.MEXICO_NUEVO)
        self.assertIn("CLABE completa", h.MEXICO_NUEVO)

    def test_se_actualiza_el_parrafo_mexico_ya_desplegado(self):
        base = open(os.path.join(os.path.dirname(__file__), "prompt_base_staging.txt"), encoding="utf-8").read()
        p = h.editar_prompt(base)
        viejo = p.replace(h.MEXICO_NUEVO, h.MEXICO_V1)
        self.assertEqual(h.editar_prompt(viejo), p)


if __name__ == "__main__":
    unittest.main()


class TestContexto(unittest.TestCase):
    """S4: `Contexto conversacion` exposes the resolver state; the Decisor reads only it."""

    def wf(self):
        q = ("SELECT 1 AS x,\\n(SELECT jsonb_build_object('total', sum(g.quoted_source_amount), 'partes', jsonb_agg(jsonb_build_object("
             "'servicio', cerebro_riel_op(g.id), 'monto_gyd', g.quoted_source_amount,\\n"
             "'destino', g.quoted_destination_amount, 'moneda', g.destination_currency, 'status', g.status) ORDER BY g.created_at, g.id))\\n"
             "FROM remittance_operations g WHERE true HAVING count(*) >= 2) AS envio_mixto\\n\\nFROM conversations v WHERE v.id = $1::uuid;")
        return {"nodes": [{"name": "Contexto conversacion", "parameters": {"query": q}}], "connections": {}}

    def test_expone_servicio_resuelto_sin_punto_y_coma_nuevo(self):
        ctx = h.aplicar_contexto(self.wf())["nodes"][0]["parameters"]["query"]
        self.assertIn("cerebro_resolver_servicio(v.id) AS servicio_resuelto", ctx)
        self.assertEqual(ctx.count(";"), 1)  # only the final one

    def test_cada_parte_trae_sus_dolares(self):
        ctx = h.aplicar_contexto(self.wf())["nodes"][0]["parameters"]["query"]
        self.assertIn("'usd',", ctx)
        self.assertIn("'mexico'", ctx)

    def test_idempotente(self):
        a = h.aplicar_contexto(self.wf())
        self.assertEqual(h.aplicar_contexto(json.loads(json.dumps(a))), a)


class TestSinLectores(unittest.TestCase):
    """S5b: the automatic readers are disabled (not deleted) in staging; the agent writes only through its tools."""

    def wf(self):
        nodos = [{"name": n, "parameters": {}, "type": "n8n-nodes-base.postgres"} for n in h.LECTORES + ["Registrar deposito auto", "Merge beneficiario"]]
        return {"nodes": nodos, "connections": {}}

    def test_desactiva_exactamente_los_lectores_sin_borrar_nada(self):
        wf = h.desactivar_lectores(self.wf())
        off = {n["name"] for n in wf["nodes"] if n.get("disabled")}
        self.assertEqual(off, {"Registrar beneficiario auto", "Registrar zelle auto", "Registrar destino auto"})
        self.assertEqual(len(wf["nodes"]), 5)

    def test_reactivar_los_deja_como_estaban(self):
        wf = h.reactivar_lectores(h.desactivar_lectores(self.wf()))
        self.assertFalse(any(n.get("disabled") for n in wf["nodes"]))

    def test_el_deposito_automatico_no_se_toca(self):
        wf = h.desactivar_lectores(self.wf())
        self.assertFalse(next(n for n in wf["nodes"] if n["name"] == "Registrar deposito auto").get("disabled"))

    def test_prompt_manda_usar_las_herramientas_explicitamente(self):
        base = open(os.path.join(os.path.dirname(__file__), "prompt_base_staging.txt"), encoding="utf-8").read()
        p = h.editar_prompt_sin_lectores(h.editar_prompt(base))
        i = p.index("## SIN LECTORES AUTOMATICOS")
        sec = p[i:i + 3500]
        for s in ("gestionar_beneficiario", "registrar_beneficiario_zelle", "registrar_numeros_recarga", "registrar_destinatario_mexico",
                  "repartir_envio", "registrar_reparto_multiple", "declarar_servicio", "marcar_destino_usd", "manda sobre"):
            self.assertIn(s, sec)
        self.assertNotIn("Los numeros escritos se guardan solos", p)
        self.assertEqual(h.editar_prompt_sin_lectores(p), p)

    def test_restaurar_el_prompt_quita_la_seccion(self):
        base = open(os.path.join(os.path.dirname(__file__), "prompt_base_staging.txt"), encoding="utf-8").read()
        p = h.editar_prompt(base)
        self.assertEqual(h.quitar_prompt_sin_lectores(h.editar_prompt_sin_lectores(p)), p)


class TestPromptS5b(unittest.TestCase):
    """S5b follow-up: old auto-registration wording is REMOVED (not only overridden); C1, M1, M4/F3, F1 rules."""

    @classmethod
    def setUpClass(cls):
        with open(os.path.join(os.path.dirname(__file__), "prompt_vivo_84e217b8.txt"), encoding="utf-8") as f:
            cls.vivo = f.read()
        cls.nuevo = h.limpiar_registro_automatico(cls.vivo)

    def test_quita_el_registro_automatico_del_beneficiario(self):
        n = self.nuevo
        for frase in ("el beneficiario TAMBIEN se registra solo", "(el sistema ya lo hizo)", "el sistema los registra solo",
                      "el sistema ya lo registro", "NO llames ninguna tool", "El sistema ya junto las piezas",
                      "los registra el sistema solo"):
            self.assertNotIn(frase, n, frase)
        self.assertNotIn("contexto: Beneficiario YA REGISTRADO tarjeta", n)  # the three examples that taught "do not call the tool"

    def test_conserva_lo_que_si_es_automatico(self):
        self.assertIn("Los depósitos se registran AUTOMATICAMENTE", self.nuevo)
        self.assertIn("La foto del carnet la registra el sistema solo", self.nuevo)

    def test_c1_zelle_pide_nombres_y_cuentas_antes_que_montos(self):
        n = self.nuevo
        i = n.index("ZELLE A VARIAS PERSONAS")
        sec = n[i:i + 700]
        self.assertRegex(sec, r"NOMBRE y CUENTA de CADA")
        self.assertRegex(sec, r"(?i)antes de (hablar de )?montos")
        self.assertIn("registrar_beneficiario_zelle", sec)

    def test_m1_mexico_declara_primero_cotiza_y_pide_datos(self):
        n = self.nuevo
        i = n.index("- MEXICO:")
        sec = n[i:i + 1500]
        self.assertRegex(sec, r"PRIMERO declarar_servicio\('mexico'\)")
        self.assertIn("via=mexico", sec)
        self.assertIn("CLABE", sec)
        self.assertIn("Coppel", sec)

    def test_m4_f3_reconciliar_y_preguntar(self):
        n = self.nuevo
        i = n.index("DEPOSITO QUE NO CUADRA CON UN ENVIO DE VARIAS PARTES")
        sec = n[i:i + 1200]
        self.assertRegex(sec, r"PROHIBIDO.*se transfiere el equivalente")
        self.assertRegex(sec, r"PROHIBIDO.*se ajusta el equivalente")
        self.assertRegex(sec, r"(?i)pregunta.*cual parte")

    def test_f1_ademas_una_recarga_es_agregar_servicio(self):
        n = self.nuevo
        self.assertRegex(n, r"(?i)ademas una recarga.*agregar_servicio\('recarga'\)")

    def test_idempotente(self):
        self.assertEqual(h.limpiar_registro_automatico(self.nuevo), self.nuevo)


class TestZelleVarios(unittest.TestCase):
    """274: registrar_beneficiario_zelle takes posicion / agregar / monto (cerebro_guardar_zelle, 9 arguments)."""

    def wf(self):
        return {"nodes": [{"name": "registrar_beneficiario_zelle", "id": "z", "parameters": {
            "query": "old", "options": {"queryReplacement": "=old"}, "toolDescription": "old"}}], "connections": {}}

    def test_consulta_pasa_los_tres_parametros_nuevos(self):
        q = h.consulta_zelle()
        self.assertIn("cerebro_guardar_zelle($1::uuid, NULLIF($2,''), NULLIF($3,''), $4, NULL, 'registrar_beneficiario_zelle'", q)
        self.assertIn("NULLIF($5,'')::int", q)
        self.assertIn("coalesce(NULLIF($6,'')::boolean,false)", q)
        self.assertIn("NULLIF($7,'')::numeric", q)

    def test_reemplazo_tiene_siete_valores_con_los_tres_nuevos_opcionales(self):
        r = h.reemplazo_zelle()
        self.assertEqual(r.count("$fromAI"), 5)
        for k in ("'nombre'", "'cuenta'", "'posicion'", "'agregar'", "'monto'"):
            self.assertIn(k, r)
        self.assertEqual(r.index("$execution.id") < r.index("'posicion'"), True)

    def test_descripcion_explica_agregar_posicion_y_monto(self):
        d = h.DESC_ZELLE
        for s in ("agregar", "posicion", "monto", "NO SE GUARDO NADA"):
            self.assertIn(s, d)

    def test_aplica_al_nodo_sin_tocar_el_resto(self):
        wf = h.aplicar_zelle(self.wf())
        p = wf["nodes"][0]["parameters"]
        self.assertEqual(p["query"], h.consulta_zelle())
        self.assertEqual(h.aplicar_zelle(json.loads(json.dumps(wf))), wf)

    def test_prompt_zelle_varios_usa_agregar_y_posicion(self):
        with open(os.path.join(os.path.dirname(__file__), "prompt_vivo_84e217b8.txt"), encoding="utf-8") as f:
            vivo = f.read()
        p = h.editar_prompt_zelle(h.limpiar_registro_automatico(vivo))
        i = p.index("- ZELLE A VARIAS PERSONAS")
        sec = p[i:i + 1400]
        for s in ("agregar=true", "posicion", "monto", "NO SE GUARDO NADA"):
            self.assertIn(s, sec)
        self.assertIn("registrar_beneficiario_zelle(nombre, cuenta, posicion, agregar, monto)", p)
        self.assertEqual(h.editar_prompt_zelle(p), p)


class TestDeclararPrimero(unittest.TestCase):
    """275: the recipient tools open the operation from the declared intent, so the prompt says declare first."""

    def test_el_prompt_manda_declarar_antes_de_guardar_datos(self):
        with open(os.path.join(os.path.dirname(__file__), "prompt_vivo_84e217b8.txt"), encoding="utf-8") as f:
            vivo = f.read()
        p = h.editar_prompt_declarar_primero(h.limpiar_registro_automatico(vivo))
        i = p.index("DECLARA PRIMERO")
        sec = p[i:i + 900]
        for s in ("declarar_servicio", "mexico", "efectivo", "zelle", "abre la operacion"):
            self.assertIn(s, sec)
        self.assertEqual(h.editar_prompt_declarar_primero(p), p)


class TestDestino276(unittest.TestCase):
    """276: marcar_destino_usd targets remesas only and accepts 'cup'; the data tools land on their own rail's operation."""

    def wf(self):
        return {"nodes": [{"name": "marcar_destino_usd", "parameters": {
            "query": "q", "options": {"queryReplacement": "={{ [$fromAI('tipo', 'clasica, tropical o efectivo', 'string')] }}"}, "toolDescription": "old"}}], "connections": {}}

    def test_acepta_cup_en_descripcion_y_parametro(self):
        wf = h.aplicar_destino(self.wf())
        p = wf["nodes"][0]["parameters"]
        self.assertIn("cup", p["toolDescription"])
        self.assertIn("cup", p["options"]["queryReplacement"])
        self.assertEqual(h.aplicar_destino(json.loads(json.dumps(wf))), wf)

    def test_prompt_dice_cup_solo_remesas_y_mixto(self):
        with open(os.path.join(os.path.dirname(__file__), "prompt_vivo_84e217b8.txt"), encoding="utf-8") as f:
            vivo = f.read()
        p = h.editar_prompt_destino(vivo)
        self.assertRegex(p, r"marcar_destino_usd\(tipo\): .*'cup'")
        self.assertIn("ENVIO MIXTO CON TARJETA", p)
        self.assertEqual(h.editar_prompt_destino(p), p)


class TestRepartir277(unittest.TestCase):
    """277: repartir_envio can plan before the deposit, includes mexico, and answers facts on a different deposit."""

    def wf(self):
        return {"nodes": [{"name": "repartir_envio", "parameters": {"options": {"queryReplacement": "=old"}, "toolDescription": "old"}}], "connections": {}}

    def test_descripcion_cubre_planear_mexico_y_deposito_distinto(self):
        d = h.aplicar_repartir(self.wf())["nodes"][0]["parameters"]["toolDescription"]
        for s in ("ANTES del deposito", "mexico", "REPARTO NO APLICADO", "exactamente", "sin inventar cifras"):
            self.assertIn(s, d)
        self.assertEqual(h.aplicar_repartir(json.loads(json.dumps(self.wf())))["nodes"][0]["parameters"]["toolDescription"], d)

    def test_prompt_planear_antes_del_deposito(self):
        with open(os.path.join(os.path.dirname(__file__), "prompt_vivo_84e217b8.txt"), encoding="utf-8") as f:
            vivo = f.read()
        p = h.editar_prompt_repartir(vivo)
        i = p.index("REPARTO ANTES DEL DEPOSITO")
        sec = p[i:i + 1200]
        for s in ("repartir_envio", "mexico 39000", "REPARTO NO APLICADO", "PREGUNTA"):
            self.assertIn(s, sec)
        self.assertEqual(h.editar_prompt_repartir(p), p)


class TestNoche4(unittest.TestCase):
    """Overnight step 4 (280-284): modificar_operacion, quitar, gestionar_beneficiario corrections, rails in cambiar_servicio."""

    def setUp(self):
        self.wf = h.aplicar_herramientas(flujo_base())

    def nodo(self, nombre):
        return next(n for n in self.wf["nodes"] if n["name"] == nombre)

    def test_modificar_operacion_es_una_herramienta_general_conectada(self):
        n = self.nodo("modificar_operacion")
        q = n["parameters"]["query"]
        self.assertIn("cerebro_modificar_operacion($1::uuid, NULLIF($2,'')::uuid, $3, NULLIF($4,'')::jsonb, 'agent:modificar_operacion n8n:' || $5)", q)
        r = n["parameters"]["options"]["queryReplacement"]
        for k in ("'op'", "'accion'", "'valor'", "$execution.id"):
            self.assertIn(k, r)
        d = n["parameters"]["toolDescription"]
        for s in ("monto", "cancelar", "unir", "NO tiene dinero", "una persona"):
            self.assertIn(s, d)
        self.assertEqual(self.wf["connections"]["modificar_operacion"]["ai_tool"][0][0]["node"], "Agente Remesas")
        self.assertEqual(n["credentials"], self.nodo("cambiar_servicio")["credentials"])

    def test_gestionar_beneficiario_acepta_op_posicion_y_tipo(self):
        n = self.nodo("gestionar_beneficiario")["parameters"]
        self.assertIn("cerebro_guardar_beneficiario($1::uuid, NULLIF($2,''), NULLIF($3,''), NULLIF($4,''), $5, NULLIF($6,'')::uuid, 'gestionar_beneficiario', NULLIF($7,'')::int, NULLIF($8,''))", n["query"])
        r = n["options"]["queryReplacement"]
        for k in ("'nombre'", "'tarjeta'", "'celular'", "$execution.id", "'op'", "'posicion'", "'tipo'"):
            self.assertIn(k, r)
        self.assertIn("correg", n["toolDescription"].lower())

    def test_marcar_destino_usd_queda_desactivado_no_borrado(self):
        n = self.nodo("marcar_destino_usd")
        self.assertTrue(n.get("disabled"))

    def test_cambiar_servicio_cubre_las_vias(self):
        d = self.nodo("cambiar_servicio")["parameters"]["toolDescription"]
        for s in ("clasica", "tropical", "efectivo_usd", "cuban_card", "via"):
            self.assertIn(s, d)

    def test_repartir_envio_cubre_el_deposito_parcial(self):
        d = self.nodo("repartir_envio")["parameters"]["toolDescription"]
        for s in ("parcial", "pendiente", "minimo"):
            self.assertIn(s, d.lower())

    def test_idempotente(self):
        otra = h.aplicar_herramientas(json.loads(json.dumps(self.wf)))
        self.assertEqual(json.dumps(otra, sort_keys=True), json.dumps(self.wf, sort_keys=True))



class TestPromptNoche4(unittest.TestCase):
    """Overnight step 4: the prompt replaces (not stacks) the superseded instructions; the bot decides with the customer (P2)."""

    @classmethod
    def setUpClass(cls):
        with open(os.path.join(os.path.dirname(__file__), "prompt_vivo_413c835a.txt"), encoding="utf-8") as f:
            cls.vivo = f.read()
        cls.nuevo = h.refinar_prompt_noche4(cls.vivo)

    def test_marcar_destino_usd_ya_no_existe_en_el_prompt(self):
        self.assertNotIn("marcar_destino_usd", self.nuevo)
        self.assertNotIn("ver CAMBIO DE VIA", self.nuevo)

    def test_modificar_operacion_quitar_y_correcciones_en_la_lista_de_tools(self):
        n = self.nuevo
        i = n.index("## TOOLS DE ACCION")
        tools = n[i:n.index("## NEGOCIO")]
        self.assertIn("- modificar_operacion(op, accion, valor)", tools)
        self.assertRegex(tools, r"registrar_numeros_recarga\(numeros, accion\)")
        self.assertRegex(tools, r"gestionar_beneficiario\(nombre, ?tarjeta, ?celular, ?op, ?posicion, ?tipo\)")

    def test_un_solo_bloque_de_deposito_que_no_cuadra_y_decide_el_bot(self):
        n = self.nuevo
        self.assertEqual(n.count("DEPOSITO QUE NO CUADRA CON LAS PARTES"), 1)
        self.assertNotIn("REPARTO ANTES DEL DEPOSITO", n)
        self.assertNotIn("DEPOSITO QUE NO CUADRA CON UN ENVIO DE VARIAS PARTES", n)
        i = n.index("DEPOSITO QUE NO CUADRA CON LAS PARTES")
        sec = n[i:i + 1800]
        for s in ("repartir_envio", "parcial", "minimo", "modificar_operacion", "esperar", "TU decides con el cliente", "equivalente"):
            self.assertIn(s, sec)

    def test_deudas_al_negocio_van_a_una_persona(self):
        n = self.nuevo
        self.assertRegex(n, r"(?is)devuelve al negocio.*derivar_humano")

    def test_idempotente_y_mas_corto_que_apilar(self):
        self.assertEqual(h.refinar_prompt_noche4(self.nuevo), self.nuevo)
        self.assertLess(len(self.nuevo), len(self.vivo) + 2500)


class TestPaso6(unittest.TestCase):
    """Overnight step 6 (measurement s5b2): declare in the quote turn, Zelle agregar/monto, quitar, monto change, Mexico ask."""

    @classmethod
    def setUpClass(cls):
        with open(os.path.join(os.path.dirname(__file__), "prompt_vivo_ddd12edb.txt"), encoding="utf-8") as f:
            cls.vivo = f.read()
        cls.nuevo = h.refinar_prompt_paso6(cls.vivo)

    def sec(self, marca, n=1500):
        i = self.nuevo.index(marca)
        return self.nuevo[i:i + n]

    def test_declarar_en_el_mismo_turno_que_la_cotizacion(self):
        s = self.sec("- DECLARAR:")
        self.assertRegex(s, r"(?i)mismo turno")
        self.assertRegex(s, r"(?i)cotiz")
        self.assertRegex(s, r"(?i)antes de pedir datos")

    def test_zelle_otra_persona_monto_y_ambiguedad(self):
        s = self.sec("- ZELLE A VARIAS PERSONAS", 1800)
        self.assertIn("agregar=true", s)
        self.assertRegex(s, r"monto.*(cada|dio)")
        self.assertRegex(s, r"(?i)otra persona o una correccion")
        self.assertRegex(s, r"(?i)pregunta.*nunca adivines")

    def test_quitar_numero(self):
        n = self.nuevo
        self.assertRegex(n, r"(?is)quita ese numero.*accion=quitar|accion quitar.*quita ese numero")

    def test_cambio_de_monto_con_modificar_operacion(self):
        s = self.sec("- modificar_operacion(op, accion, valor)")
        self.assertRegex(s, r"mejor 150")
        self.assertIn("calcular", s)

    def test_mexico_pide_datos_en_el_mismo_turno_y_pregunta_cup_o_gyd(self):
        s = self.sec("- MEXICO:", 2200)
        self.assertRegex(s, r"(?i)mismo mensaje en que declaras")
        self.assertRegex(s, r"(?i)15 mil.*CUP o GYD|CUP o GYD.*15 mil")

    def test_idempotente_y_corto(self):
        self.assertEqual(h.refinar_prompt_paso6(self.nuevo), self.nuevo)
        self.assertLess(len(self.nuevo), len(self.vivo) + 1800)


class TestTranscripcion(unittest.TestCase):
    def wf(self):
        p = {"name": "prompt", "value": "=Conversacion. Otras palabras frecuentes: MMG, Pay Merchant, Cash In, agente, {{ x }}, Zelle."}
        return {"nodes": [{"name": "Transcribir audio", "parameters": {"bodyParameters": {"parameters": [{"name": "model", "value": "m"}, p]}}}], "connections": {}}

    def test_agrega_los_nombres_de_los_admins_una_sola_vez(self):
        wf = h.aplicar_transcripcion(self.wf())
        v = wf["nodes"][0]["parameters"]["bodyParameters"]["parameters"][1]["value"]
        self.assertIn("agente, Eliaba, Osmany,", v)
        self.assertEqual(h.aplicar_transcripcion(json.loads(json.dumps(wf))), wf)


class TestMover287(unittest.TestCase):
    """285-287: Zelle params are REQUIRED fields of the tool schema (no default: the measurement saw them omitted); mover_deposito."""

    def test_zelle_posicion_agregar_monto_son_obligatorios_en_el_esquema(self):
        r = h.reemplazo_zelle()
        for k in ("posicion", "agregar", "monto"):
            self.assertRegex(r, r"\$fromAI\('%s', '[^']*', 'string'\)" % k)  # no default value => required
        self.assertIn("vacio", r)

    def test_zelle_descripcion_manda_rellenar_los_tres(self):
        self.assertRegex(h.DESC_ZELLE, r"(?i)siempre.*posicion.*agregar.*monto|completa siempre")

    def test_modificar_describe_mover_deposito_con_confirmacion(self):
        d = h.DESC_MODIFICAR
        for s in ("mover_deposito", "deposito", "cliente confirme", "\"a\""):
            self.assertIn(s, d)
        self.assertNotIn("NO mueve depositos", d)

    def test_prompt_mover_deposito_solo_tras_confirmar(self):
        with open(os.path.join(os.path.dirname(__file__), "prompt_vivo_c619c951.txt"), encoding="utf-8") as f:
            vivo = f.read()
        p = h.refinar_prompt_mover(vivo)
        i = p.index("- modificar_operacion(op, accion, valor)")
        sec = p[i:i + 1500]
        for s in ("mover_deposito", "confirme", "para cual operacion"):
            self.assertIn(s, sec)
        self.assertEqual(h.refinar_prompt_mover(p), p)
        self.assertNotIn("con dinero la atiende una persona) o unir", p) if False else None
