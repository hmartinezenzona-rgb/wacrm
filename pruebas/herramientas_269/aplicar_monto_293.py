#!/usr/bin/env python3
"""293: add the optional monto_gyd to declarar/agregar/cambiar_servicio on the STAGING Cerebro workflow only (backup first, verify after).

    python3 pruebas/herramientas_269/aplicar_monto_293.py --esperado <live versionId prefix>

Never executes the workflow. The Decisor is published separately with cerebro_n8n.py publicar-decisor.
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
    a = ap.parse_args()
    c.check_esperado(a.esperado)
    wid = c.resolve_env("staging")
    key, base = c.load_api_key(), c.get_base_url()
    wf = c.api_request("GET", f"/api/v1/workflows/{wid}", base, key)
    if not wf["versionId"].startswith(a.esperado):
        print(f"REFUSED: live versionId {wf['versionId'][:8]} does not start with '{a.esperado}'")
        return 2
    print("backup:", c.write_backup(wf, "staging", c.get_backups_dir()))
    h.aplicar_monto_293(wf)
    c.api_request("PUT", f"/api/v1/workflows/{wid}", base, key, body={
        "name": wf["name"], "nodes": wf["nodes"], "connections": wf["connections"], "settings": wf.get("settings", {})})
    w2 = c.api_request("GET", f"/api/v1/workflows/{wid}", base, key)
    print("versionId:", w2["versionId"], "activeVersionId:", w2["activeVersionId"], "nodes:", len(w2["nodes"]))
    return 0 if w2["versionId"] == w2["activeVersionId"] else 1


if __name__ == "__main__":
    sys.exit(main())
