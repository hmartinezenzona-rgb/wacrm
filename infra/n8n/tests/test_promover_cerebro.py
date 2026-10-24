"""Tests for promover_cerebro.py: staging -> production promotion transform (no real n8n is touched)."""
import copy
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import promover_cerebro as pc  # noqa: E402
from test_cerebro_n8n import KEY, PRODUCCION, STAGING, Stub, md5  # noqa: E402

SCRIPT = Path(__file__).resolve().parents[1] / "promover_cerebro.py"
SECRET = "ab" * 32  # fake 64-hex staging secret
PG_P = {"postgres": {"id": "S2CallLPSjzbVXN4", "name": "Supabase Account"}}
PG_S = {"postgres": {"id": "np3egGrAcrWkOWd4", "name": "Supabase STAGING"}}
NEW_TOOLS = ["declarar_servicio", "agregar_servicio", "modificar_operacion", "registrar_destinatario_mexico"]
ORPHAN = "DeepSeek Web Search Chat Model"


def node(name, ntype, params, creds=None, **extra):
    n = {"id": f"id-{name}", "name": name, "type": ntype, "typeVersion": 1, "position": [0, 0], "parameters": params}
    if creds:
        n["credentials"] = creds
    n.update(extra)
    return n


def make_pair():
    prod = [
        node("Webhook WaCRM", "n8n-nodes-base.webhook", {"path": "wacrm-cerebro-green-v1"}, webhookId="WH-PROD"),
        node("Decisor", "n8n-nodes-base.code", {"jsCode": "old decisor"}),
        node("Validar evento", "n8n-nodes-base.code", {"jsCode": "const S = $env.CEREBRO_WEBHOOK_SECRET;"}),
        node("Responder por WaCRM", "n8n-nodes-base.httpRequest",
             {"url": "https://wacrm.onlinefreedom.site/api/v1/messages"},
             {"httpHeaderAuth": {"id": "p8EN42saerBDHZwI", "name": "WaCRM API"}}),
        node("Despertar al enviador", "n8n-nodes-base.executeWorkflow",
             {"workflowId": {"__rl": True, "mode": "id", "value": "K4ijL3NzmY1VX7XI"}}),
        node("Agente Remesas", "x.agent", {"options": {"systemMessage": "old prompt"}}),
        node("DeepSeek sin pensamiento (comunidad)", "x.lmChatDeepSeek", {"options": {"temperature": 0.3}},
             {"deepseekApi": {"id": "cNiZzNwlP0IrAIh1", "name": "osmany_chat"}}),
        node("Contexto conversacion", "n8n-nodes-base.postgres", {"query": "SELECT 1"}, PG_P),
        node("Registrar beneficiario auto", "n8n-nodes-base.postgresTool", {"query": "q"}, PG_P),
        node("Espera extra", "n8n-nodes-base.wait", {"amount": 25}, webhookId="WAIT-PROD"),
    ]
    stg = copy.deepcopy(prod)
    by = {n["name"]: n for n in stg}
    by["Webhook WaCRM"].update(webhookId="WH-STG")
    by["Webhook WaCRM"]["parameters"]["path"] = "staging-wacrm-cerebro-green-v1"
    by["Decisor"]["parameters"]["jsCode"] = "new decisor"
    by["Validar evento"]["parameters"]["jsCode"] = f"const S = '{SECRET}';"
    by["Responder por WaCRM"]["parameters"]["url"] = "https://crm.onlinefreedom.site/api/v1/messages"
    by["Responder por WaCRM"]["credentials"] = {"httpHeaderAuth": {"id": "iHWfJCYmlenmliPM", "name": "WaCRM API STAGING"}}
    by["Despertar al enviador"]["parameters"]["workflowId"]["value"] = "WmcobAufVNWURbKc"
    by["Agente Remesas"]["parameters"]["options"]["systemMessage"] = "new prompt"
    by["DeepSeek sin pensamiento (comunidad)"]["parameters"].update(model="custom", customModel="deepseek-flash")
    by["DeepSeek sin pensamiento (comunidad)"]["credentials"] = {"deepseekApi": {"id": "2joB4BwDAiyuSMcC", "name": "stg"}}
    by["Contexto conversacion"]["parameters"]["query"] = "SELECT 2"
    by["Contexto conversacion"]["credentials"] = PG_S
    by["Registrar beneficiario auto"]["credentials"] = PG_S
    by["Registrar beneficiario auto"]["disabled"] = True
    by["Espera extra"]["webhookId"] = "WAIT-STG"
    by["Espera extra"]["id"] = "other-id-in-staging"
    for t in NEW_TOOLS:
        stg.append(node(t, "n8n-nodes-base.postgresTool", {"query": f"select {t}"}, PG_S))
    stg.append(node(ORPHAN, "x.lmChatDeepSeekWebSearch", {}, {"deepseekApi": {"id": "2joB4BwDAiyuSMcC", "name": "stg"}}))
    pconn = {"Decisor": {"main": [[{"node": "Agente Remesas", "type": "main", "index": 0}]]}}
    sconn = copy.deepcopy(pconn)
    for t in NEW_TOOLS:
        sconn[t] = {"ai_tool": [[{"node": "Agente Remesas", "type": "ai_tool", "index": 0}]]}
    sconn[ORPHAN] = {}
    wp = {"id": PRODUCCION, "name": "Cerebro prod", "versionId": "5b3159b9-x", "activeVersionId": "5b3159b9-x",
          "active": True, "nodes": prod, "connections": pconn,
          "settings": {"executionOrder": "v1", "errorWorkflow": "g3UgayrNlXBXZgnr"}}
    ws = {"id": STAGING, "name": "Cerebro stg", "versionId": "218fbd5d-x", "activeVersionId": "218fbd5d-x",
          "active": True, "nodes": stg, "connections": sconn,
          "settings": {"executionOrder": "v1", "errorWorkflow": "1Elx6fZ3z5vQI3dj"}}
    return wp, ws


def by_name(wf):
    return {n["name"]: n for n in wf["nodes"]}


class ConstruirTest(unittest.TestCase):
    def setUp(self):
        self.prod, self.stg = make_pair()
        self.prod0 = copy.deepcopy(self.prod)
        self.stg0 = copy.deepcopy(self.stg)
        self.out, self.report = pc.construir(self.prod, self.stg, modelo="produccion")
        self.n = by_name(self.out)

    def test_inputs_not_mutated(self):
        self.assertEqual(self.prod, self.prod0)
        self.assertEqual(self.stg, self.stg0)

    def test_body_has_only_put_keys_with_production_name_and_settings(self):
        self.assertEqual(set(self.out), {"name", "nodes", "connections", "settings"})
        self.assertEqual(self.out["name"], "Cerebro prod")
        self.assertEqual(self.out["settings"]["errorWorkflow"], "g3UgayrNlXBXZgnr")

    def test_changed_parameters_come_from_staging(self):
        self.assertEqual(self.n["Decisor"]["parameters"]["jsCode"], "new decisor")
        self.assertEqual(self.n["Agente Remesas"]["parameters"]["options"]["systemMessage"], "new prompt")
        self.assertEqual(self.n["Contexto conversacion"]["parameters"]["query"], "SELECT 2")

    def test_disabled_flag_comes_from_staging(self):
        self.assertTrue(self.n["Registrar beneficiario auto"]["disabled"])

    def test_environment_values_stay_production(self):
        self.assertEqual(self.n["Webhook WaCRM"]["parameters"]["path"], "wacrm-cerebro-green-v1")
        self.assertEqual(self.n["Webhook WaCRM"]["webhookId"], "WH-PROD")
        self.assertEqual(self.n["Espera extra"]["webhookId"], "WAIT-PROD")
        self.assertEqual(self.n["Espera extra"]["id"], "id-Espera extra")
        self.assertEqual(self.n["Responder por WaCRM"]["parameters"]["url"],
                         "https://wacrm.onlinefreedom.site/api/v1/messages")
        self.assertEqual(self.n["Responder por WaCRM"]["credentials"]["httpHeaderAuth"]["id"], "p8EN42saerBDHZwI")
        self.assertEqual(self.n["Despertar al enviador"]["parameters"]["workflowId"]["value"], "K4ijL3NzmY1VX7XI")
        self.assertEqual(self.n["Contexto conversacion"]["credentials"], PG_P)
        self.assertEqual(self.n["DeepSeek sin pensamiento (comunidad)"]["credentials"]["deepseekApi"]["id"],
                         "cNiZzNwlP0IrAIh1")

    def test_validar_evento_is_production_verbatim(self):
        self.assertEqual(self.n["Validar evento"]["parameters"]["jsCode"], "const S = $env.CEREBRO_WEBHOOK_SECRET;")

    def test_new_tools_added_with_production_credential_and_fresh_ids(self):
        for t in NEW_TOOLS:
            self.assertIn(t, self.n)
            self.assertEqual(self.n[t]["credentials"], PG_P)
            self.assertNotEqual(self.n[t]["id"], f"id-{t}")
            self.assertEqual(self.out["connections"][t]["ai_tool"][0][0]["node"], "Agente Remesas")
        self.assertEqual(len({x["id"] for x in self.out["nodes"]}), len(self.out["nodes"]))

    def test_orphan_excluded_everywhere(self):
        self.assertNotIn(ORPHAN, self.n)
        self.assertNotIn(ORPHAN, self.out["connections"])
        self.assertEqual(len(self.out["nodes"]), len(self.prod["nodes"]) + 4)

    def test_modelo_produccion_drops_override_and_staging_keeps_it(self):
        p = self.n["DeepSeek sin pensamiento (comunidad)"]["parameters"]
        self.assertNotIn("customModel", p)
        self.assertNotIn("model", p)
        out2, _ = pc.construir(self.prod, self.stg, modelo="staging")
        p2 = by_name(out2)["DeepSeek sin pensamiento (comunidad)"]["parameters"]
        self.assertEqual((p2["model"], p2["customModel"]), ("custom", "deepseek-flash"))
        self.assertEqual(by_name(out2)["DeepSeek sin pensamiento (comunidad)"]["credentials"]["deepseekApi"]["id"],
                         "cNiZzNwlP0IrAIh1")

    def test_connections_keep_production_and_add_new_sources(self):
        self.assertEqual(self.out["connections"]["Decisor"], self.prod["connections"]["Decisor"])

    def test_report_lists_added_and_changed(self):
        self.assertEqual(sorted(self.report["agregados"]), sorted(NEW_TOOLS))
        self.assertIn("Decisor", self.report["cambiados"])
        self.assertNotIn("Validar evento", self.report["cambiados"])
        self.assertNotIn("Webhook WaCRM", self.report["cambiados"])


class VerificarTest(unittest.TestCase):
    def setUp(self):
        self.prod, self.stg = make_pair()
        self.out, _ = pc.construir(self.prod, self.stg, modelo="produccion")
        self.dec_md5 = md5("new decisor")

    def check(self, out=None, nodos=14):
        return pc.verificar(out or self.out, self.prod, self.stg, nodos_esperados=nodos, decisor_md5=self.dec_md5)

    def test_clean_build_passes_every_assert(self):
        res = self.check()
        self.assertTrue(all(ok for _, ok in res), res)

    def test_wrong_node_count_fails(self):
        self.assertFalse(all(ok for _, ok in self.check(nodos=131)))

    def test_staging_credential_fails(self):
        bad = copy.deepcopy(self.out)
        by_name(bad)["Contexto conversacion"]["credentials"] = PG_S
        self.assertFalse(all(ok for _, ok in self.check(bad)))

    def test_staging_host_fails(self):
        bad = copy.deepcopy(self.out)
        by_name(bad)["Responder por WaCRM"]["parameters"]["url"] = "https://crm.onlinefreedom.site/x"
        self.assertFalse(all(ok for _, ok in self.check(bad)))

    def test_literal_secret_fails_without_printing_it(self):
        bad = copy.deepcopy(self.out)
        by_name(bad)["Validar evento"]["parameters"]["jsCode"] = f"x='{SECRET}'"
        res = self.check(bad)
        self.assertFalse(all(ok for _, ok in res))
        self.assertNotIn(SECRET, json.dumps(res))

    def test_decisor_md5_mismatch_fails(self):
        self.assertFalse(all(ok for _, ok in pc.verificar(
            self.out, self.prod, self.stg, nodos_esperados=14, decisor_md5="0" * 32)))


class DependenciasTest(unittest.TestCase):
    def test_finds_function_calls_and_tables(self):
        wf = {"nodes": [node("q", "n8n-nodes-base.postgres",
                             {"query": "SELECT cerebro_catalogo_servicios(), lower('X') FROM remittance_operations r "
                                       "JOIN contacts c ON true"}, PG_P)]}
        deps = pc.dependencias_bd(wf)
        self.assertIn("cerebro_catalogo_servicios", deps["funciones"])
        self.assertIn("lower", deps["funciones"])
        self.assertEqual(deps["tablas"], {"remittance_operations", "contacts"})

    def test_cte_names_are_not_dependencies(self):
        wf = {"nodes": [node("q", "n8n-nodes-base.postgres",
                             {"query": "WITH t AS (SELECT 1 AS n), aviso AS (SELECT now() AS a) "
                                       "SELECT * FROM t LEFT JOIN aviso ON true"}, PG_P)]}
        deps = pc.dependencias_bd(wf)
        self.assertEqual(deps["tablas"], set())
        self.assertNotIn("t", deps["funciones"])
        self.assertNotIn("aviso", deps["funciones"])

    def test_insert_into_with_column_list_is_a_table(self):
        wf = {"nodes": [node("q", "n8n-nodes-base.postgres",
                             {"query": "INSERT INTO session_events (conversation_id, tipo) VALUES (1, 2)"}, PG_P)]}
        deps = pc.dependencias_bd(wf)
        self.assertEqual(deps["tablas"], {"session_events"})
        self.assertNotIn("session_events", deps["funciones"])
        self.assertNotIn("values", deps["funciones"])

    def test_n8n_expressions_are_ignored(self):
        wf = {"nodes": [node("q", "n8n-nodes-base.postgres",
                             {"query": "SELECT {{ JSON.parse($json.x).params.id }} FROM messages"}, PG_P)]}
        deps = pc.dependencias_bd(wf)
        self.assertEqual(deps["funciones"], set())
        self.assertEqual(deps["tablas"], {"messages"})

    def test_extract_and_alias_column_list_are_not_dependencies(self):
        wf = {"nodes": [node("q", "n8n-nodes-base.postgres",
                             {"query": "SELECT EXTRACT(hour FROM abre), 1 FROM (SELECT 1, 2) AS t(a, b)"}, PG_P)]}
        deps = pc.dependencias_bd(wf)
        self.assertEqual(deps["funciones"], set())
        self.assertEqual(deps["tablas"], set())

    def test_non_postgres_nodes_are_ignored(self):
        wf = {"nodes": [node("c", "n8n-nodes-base.code", {"jsCode": "cerebro_no_existe()"})]}
        deps = pc.dependencias_bd(wf)
        self.assertEqual(deps["funciones"], set())
        self.assertEqual(deps["tablas"], set())


class CatalogoTest(unittest.TestCase):
    def test_faltantes_lists_missing_sorted(self):
        deps = {"funciones": {"b_fn", "a_fn", "ok_fn"}, "tablas": {"t_missing", "contacts"}}
        cat = {"funciones": {"ok_fn"}, "tablas": {"contacts"}}
        self.assertEqual(pc.faltantes(deps, cat),
                         [("funcion", "a_fn"), ("funcion", "b_fn"), ("tabla", "t_missing")])

    def test_catalogo_from_file_lowercases(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "cat.json"
            p.write_text(json.dumps({"funciones": ["NOW", "Cerebro_X"], "tablas": ["Contacts"]}), encoding="utf-8")
            cat = pc.catalogo_destino(str(p))
        self.assertEqual(cat["funciones"], {"now", "cerebro_x"})
        self.assertEqual(cat["tablas"], {"contacts"})

    def test_missing_token_fails_without_printing_anything(self):
        with self.assertRaises(RuntimeError):
            pc.catalogo_destino(None, token_file=Path("/nonexistent/supabase-token.env"))

    def test_live_catalog_queries_functions_and_relations(self):
        vistos = []

        def consulta(sql):
            vistos.append(sql)
            return ["NOW", "cerebro_x"] if "pg_proc" in sql else ["Contacts"]

        cat = pc.catalogo_destino(None, consulta=consulta)
        self.assertEqual(cat["funciones"], {"now", "cerebro_x"})
        self.assertEqual(cat["tablas"], {"contacts"})
        self.assertEqual(len(vistos), 2)


class CliTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.home = root / "home"
        self.home.mkdir()
        (self.home / ".n8n-api-key").write_text(KEY + "\n")
        self.backups = root / "backups"
        self.backups.mkdir()
        self.decisor_file = root / "decisor.jscode"
        self.decisor_file.write_text("new decisor", encoding="utf-8")
        self.catalogo = root / "catalogo.json"
        self.catalogo.write_text(json.dumps({
            "funciones": ["cerebro_catalogo_servicios", "now", "lower", "count"],
            "tablas": ["session_events", "messages", "contacts", "remittance_operations"],
        }), encoding="utf-8")
        self.stub = Stub(self.backups)
        self.addCleanup(self.stub.close)
        prod, stg = make_pair()
        self.stub.workflows[PRODUCCION] = {**prod, "versionId": "5b3159b9-x"}
        self.stub.workflows[STAGING] = {**stg, "versionId": "218fbd5d-x"}
        self.env = dict(os.environ, HOME=str(self.home), CEREBRO_N8N_BASE=self.stub.url,
                        CEREBRO_N8N_BACKUPS=str(self.backups), CEREBRO_DECISOR_FILE=str(self.decisor_file),
                        CEREBRO_PROMOVER_NODOS="14", CEREBRO_CATALOGO=str(self.catalogo))

    def run_cli(self, *args):
        r = subprocess.run([sys.executable, str(SCRIPT), *args], capture_output=True, text=True,
                           env=self.env, timeout=30)
        self.assertNotIn(KEY, r.stdout + r.stderr)
        self.assertNotIn(SECRET, r.stdout + r.stderr)
        return r

    def test_ensayo_prints_summary_and_never_writes(self):
        r = self.run_cli("--ensayo")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.stub.puts, [])
        self.assertIn("nodes: 10 -> 14", r.stdout)
        self.assertIn("added: " + ", ".join(sorted(NEW_TOOLS)), r.stdout)
        self.assertIn("changed: ", r.stdout)
        self.assertIn("PASS", r.stdout)
        self.assertNotIn("FAIL", r.stdout)
        self.assertEqual(list(self.backups.glob("*.json")), [])

    def test_ensayo_fails_when_assert_fails(self):
        self.env["CEREBRO_PROMOVER_NODOS"] = "131"
        r = self.run_cli("--ensayo")
        self.assertEqual(r.returncode, 1)
        self.assertIn("FAIL", r.stdout)

    def test_ensayo_reports_the_catalog_check(self):
        r = self.run_cli("--ensayo")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("PASS: every DB dependency exists in the target DB", r.stdout)

    def _hacer_faltante(self):
        for n in self.stub.workflows[STAGING]["nodes"]:
            if n["name"] == "Contexto conversacion":
                n["parameters"]["query"] = "SELECT cerebro_no_existe()"

    def test_ensayo_fails_when_a_dependency_is_missing(self):
        self._hacer_faltante()
        r = self.run_cli("--ensayo")
        self.assertEqual(r.returncode, 1)
        self.assertIn("cerebro_no_existe", r.stdout)
        self.assertIn("FAIL: every DB dependency", r.stdout)

    def test_aplicar_refuses_when_a_dependency_is_missing(self):
        self._hacer_faltante()
        r = self.run_cli("--aplicar", "--esperado", "5b31")
        self.assertEqual(r.returncode, 1)
        self.assertEqual(self.stub.puts, [])
        self.assertIn("cerebro_no_existe", r.stdout)

    def test_unreadable_catalog_refuses(self):
        self.catalogo.unlink()
        r = self.run_cli("--ensayo")
        self.assertEqual(r.returncode, 1)
        self.assertIn("could not read the target DB catalog", r.stdout)

    def test_requires_a_mode(self):
        self.assertNotEqual(self.run_cli().returncode, 0)
        self.assertNotEqual(self.run_cli("--aplicar").returncode, 0)  # missing --esperado

    def test_aplicar_refuses_on_version_mismatch(self):
        r = self.run_cli("--aplicar", "--esperado", "zzzz")
        self.assertEqual(r.returncode, 2)
        self.assertIn("REFUSED", r.stdout)
        self.assertEqual(self.stub.puts, [])

    def test_aplicar_backs_up_then_puts_and_verifies(self):
        r = self.run_cli("--aplicar", "--esperado", "5b31")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(len(self.stub.puts), 1)
        wid, body, backups_at_put = self.stub.puts[0]
        self.assertEqual(wid, PRODUCCION)
        self.assertEqual(len(backups_at_put), 1)  # backup existed before the PUT
        self.assertEqual(len(body["nodes"]), 14)
        self.assertIn("OK", r.stdout)

    def test_aplicar_refuses_when_asserts_fail(self):
        self.env["CEREBRO_PROMOVER_NODOS"] = "131"
        r = self.run_cli("--aplicar", "--esperado", "5b31")
        self.assertEqual(r.returncode, 1)
        self.assertEqual(self.stub.puts, [])


if __name__ == "__main__":
    unittest.main()
