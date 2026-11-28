#!/usr/bin/env python3
"""Apply the 269 tools and prompt to the STAGING Cerebro workflow only (backup first, verify after).

    python3 pruebas/herramientas_269/aplicar_staging.py --esperado <live versionId prefix>

Refuses any other environment. Never executes the workflow.
"""
import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "..", "infra", "n8n"))
import cerebro_n8n as c  # noqa: E402
import herramientas as h  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--esperado", required=True)
    ap.add_argument("--lectores", choices=["off", "on"], help="S5b: disable (off) or re-enable (on) the automatic readers + prompt section")
    ap.add_argument("--contexto", action="store_true", help="S4: add servicio_resuelto to Contexto conversacion")
    ap.add_argument("--cotizar", action="store_true", help="289: the four quote tools call cerebro_cotizar")
    ap.add_argument("--prompt289", action="store_true", help="289: shorter prompt without the repeated declare reminders")
    a = ap.parse_args()
    c.check_esperado(a.esperado)
    wid = c.resolve_env("staging")
    key, base = c.load_api_key(), c.get_base_url()
    wf = c.api_request("GET", f"/api/v1/workflows/{wid}", base, key)
    if not wf["versionId"].startswith(a.esperado):
        print(f"REFUSED: live versionId {wf['versionId'][:8]} does not start with '{a.esperado}'")
        return 2
    print("backup:", c.write_backup(wf, "staging", c.get_backups_dir()))
    h.aplicar_herramientas(wf)
    h.aplicar_transcripcion(wf)
    h.aplicar_via(wf)
    if a.cotizar:
        h.aplicar_cotizar(wf)
    if a.contexto:
        h.aplicar_contexto(wf)
    if a.lectores == "off":
        h.desactivar_lectores(wf)
    elif a.lectores == "on":
        h.reactivar_lectores(wf)
    for n in wf["nodes"]:
        if n["name"] == "Agente Remesas":
            sm = h.editar_prompt(n["parameters"]["options"]["systemMessage"])
            if a.lectores == "off":
                sm = h.limpiar_registro_automatico(h.editar_prompt_sin_lectores(sm))
            elif a.lectores == "on":
                sm = h.quitar_prompt_sin_lectores(sm)
            sm = h.refinar_prompt_mover(h.refinar_prompt_paso6(h.refinar_prompt_noche4(h.editar_prompt_repartir(h.editar_prompt_destino(h.editar_prompt_declarar_primero(h.editar_prompt_zelle(sm)))))))
            n["parameters"]["options"]["systemMessage"] = h.refinar_prompt_289(sm) if a.prompt289 else sm
    c.api_request("PUT", f"/api/v1/workflows/{wid}", base, key, body={
        "name": wf["name"], "nodes": wf["nodes"], "connections": wf["connections"], "settings": wf.get("settings", {})})
    w2 = c.api_request("GET", f"/api/v1/workflows/{wid}", base, key)
    print("versionId:", w2["versionId"], "activeVersionId:", w2["activeVersionId"], "nodes:", len(w2["nodes"]))
    return 0 if w2["versionId"] == w2["activeVersionId"] else 1


if __name__ == "__main__":
    sys.exit(main())
