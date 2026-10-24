#!/usr/bin/env python3
"""Build and apply the staging -> production promotion of the Cerebro n8n workflow.

Base = PRODUCTION workflow (so every environment value stays production by construction),
plus staging's changed and new nodes and connections. Rollback: cerebro_n8n.py restaurar.
  --ensayo                          build, print a summary and the safety asserts, write nothing
  --aplicar --esperado <prefix>     guarded PUT of the built workflow (production versionId prefix)
"""

import argparse
import copy
import hashlib
import json
import os
import re
import sys
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import cerebro_n8n as cn  # noqa: E402

EXCLUIDOS = ("DeepSeek Web Search Chat Model",)  # orphan experiment: needs a community package, connected to nothing
NODOS_ESPERADOS = 131
PG_PRODUCCION = {"postgres": {"id": "S2CallLPSjzbVXN4", "name": "Supabase Account"}}
MODELO_NODE = "DeepSeek sin pensamiento (comunidad)"
MODELO_KEYS = ("model", "customModel")
# node name -> parameter paths whose PRODUCTION value is kept ([] = the whole parameters object)
ENTORNO = {
    "Webhook WaCRM": [["path"]],
    "Responder por WaCRM": [["url"]],
    "Avisar espera al cliente": [["url"]],
    "Confirmar al admin": [["url"]],
    "Despertar al enviador": [["workflowId"]],
    "Validar evento": [[]],
}
# Literals that must never reach production (staging ids/hosts); "//crm." because wacrm.* contains "crm.".
PROHIBIDOS = ("np3egGrAcrWkOWd4", "iHWfJCYmlenmliPM", "f0K27ImOFO3QdL34", "2joB4BwDAiyuSMcC", "1Elx6fZ3z5vQI3dj",
              "WmcobAufVNWURbKc", "//crm.onlinefreedom", "staging-wacrm")
SECRETO_RE = re.compile(r"(?<![0-9a-fA-F])[0-9a-fA-F]{64}(?![0-9a-fA-F])")


def _by_name(wf: dict) -> dict:
    return {n["name"]: n for n in wf["nodes"]}


def _copiar_ruta(origen: dict, destino: dict, ruta: list) -> None:
    """Copy origen[ruta] into destino[ruta] (production value wins). Empty path = whole object."""
    if not ruta:
        destino.clear()
        destino.update(copy.deepcopy(origen))
        return
    for k in ruta[:-1]:
        origen, destino = origen.get(k, {}), destino.setdefault(k, {})
    if ruta[-1] in origen:
        destino[ruta[-1]] = copy.deepcopy(origen[ruta[-1]])
    else:
        destino.pop(ruta[-1], None)


def _sin_posicion(n: dict) -> dict:
    return {k: v for k, v in n.items() if k not in ("position", "id")}


def construir(prod: dict, stg: dict, modelo: str = "produccion"):
    """Return (body for PUT, report). Inputs are not mutated."""
    pn = _by_name(prod)
    nodos = []
    cambiados, agregados = [], []
    for sn in stg["nodes"]:
        name = sn["name"]
        if name in EXCLUIDOS:
            continue
        n = copy.deepcopy(sn)
        if name in pn:
            p = pn[name]
            n["id"] = p["id"]
            for campo in ("credentials", "webhookId"):
                if campo in p:
                    n[campo] = copy.deepcopy(p[campo])
                else:
                    n.pop(campo, None)
            for ruta in ENTORNO.get(name, []):
                _copiar_ruta(p.get("parameters", {}), n["parameters"], ruta)
            if name == MODELO_NODE and modelo == "produccion":
                for k in MODELO_KEYS:
                    _copiar_ruta(p.get("parameters", {}), n["parameters"], [k])
            if _sin_posicion(n) != _sin_posicion(p):
                cambiados.append(name)
        else:
            n["id"] = str(uuid.uuid4())
            n.pop("webhookId", None)
            if n.get("type", "").startswith("n8n-nodes-base.postgres"):
                n["credentials"] = copy.deepcopy(PG_PRODUCCION)
            agregados.append(name)
        nodos.append(n)
    # nodes only in production stay untouched (none expected)
    presentes = {n["name"] for n in nodos}
    for p in prod["nodes"]:
        if p["name"] not in presentes:
            nodos.append(copy.deepcopy(p))
            presentes.add(p["name"])

    conexiones = copy.deepcopy(prod["connections"])
    conn_cambiadas = []
    for src, tipos in stg["connections"].items():
        if src in EXCLUIDOS or src not in presentes:
            continue
        nuevo = {t: [[d for d in rama if d["node"] not in EXCLUIDOS] for rama in ramas] for t, ramas in tipos.items()}
        if nuevo != prod["connections"].get(src):
            conexiones[src] = nuevo
            conn_cambiadas.append(src)

    body = {"name": prod["name"], "nodes": nodos, "connections": conexiones,
            "settings": copy.deepcopy(prod.get("settings", {}))}
    return body, {"agregados": agregados, "cambiados": cambiados, "conexiones": conn_cambiadas}


def _creds(wf: dict) -> set:
    return {c.get("id") for n in wf["nodes"] for c in (n.get("credentials") or {}).values()}


def verificar(out: dict, prod: dict, stg: dict, nodos_esperados: int, decisor_md5: str):
    """Safety asserts. Returns [(description, ok)]; never includes secret values."""
    texto = json.dumps(out, ensure_ascii=False)
    res = [(f"node count == {nodos_esperados} (got {len(out['nodes'])})", len(out["nodes"]) == nodos_esperados)]

    prohibidos = set(PROHIBIDOS) | (_creds(stg) - _creds(prod))
    prohibidos.add(stg.get("settings", {}).get("errorWorkflow"))
    sw = _by_name(stg).get("Webhook WaCRM", {})
    prohibidos.update({sw.get("webhookId"), sw.get("parameters", {}).get("path")})
    prohibidos.discard(None)
    prohibidos -= {pn_v for pn_v in (prod.get("settings", {}).get("errorWorkflow"),)}
    hallados = sorted(x for x in prohibidos if x and x in texto)
    res.append((f"no staging credential id / host / path / workflow id (found {len(hallados)})", not hallados))

    res.append(("no staging credential id in any node", not ((_creds(out) - _creds(prod)) - {None})))
    res.append(("no literal 64-hex secret", not SECRETO_RE.search(texto)))
    res.append(("errorWorkflow is production's",
                out["settings"].get("errorWorkflow") == prod.get("settings", {}).get("errorWorkflow")))
    res.append(("excluded orphan nodes absent", not any(n["name"] in EXCLUIDOS for n in out["nodes"])))
    on = _by_name(out)
    vp = _by_name(prod).get("Validar evento")
    res.append(("Validar evento code is production's verbatim",
                bool(vp) and on.get("Validar evento", {}).get("parameters") == vp["parameters"]))
    dec = on.get("Decisor")
    ok = bool(dec) and hashlib.md5(dec["parameters"]["jsCode"].encode("utf-8")).hexdigest() == decisor_md5
    res.append(("Decisor md5 matches the repo file", ok))
    return res


def _cargar(path: str) -> dict:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def _imprimir(prod, out, report, checks) -> bool:
    print(f"production {prod['id']} versionId {prod['versionId']}")
    print(f"nodes: {len(prod['nodes'])} -> {len(out['nodes'])}")
    print("added: " + ", ".join(sorted(report["agregados"])))
    print("changed: " + ", ".join(sorted(report["cambiados"])))
    print("connections changed/added for: " + ", ".join(sorted(report["conexiones"])))
    pn = _by_name(prod)
    for name in sorted(report["cambiados"]):
        a, b = pn[name].get("parameters", {}), _by_name(out)[name].get("parameters", {})
        keys = sorted(k for k in set(a) | set(b) if a.get(k) != b.get(k))
        extra = [k for k in ("disabled", "notes", "typeVersion") if pn[name].get(k) != _by_name(out)[name].get(k)]
        print(f"  {name}: parameters {keys or '-'}; other {extra or '-'}")
    todo = True
    for desc, ok in checks:
        print(f"{'PASS' if ok else 'FAIL'}: {desc}")
        todo = todo and ok
    return todo


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Promote the staging Cerebro workflow to production")
    ap.add_argument("--ensayo", action="store_true", help="build and report; write nothing")
    ap.add_argument("--aplicar", action="store_true", help="guarded PUT to production")
    ap.add_argument("--esperado", help="production versionId prefix (required with --aplicar)")
    ap.add_argument("--modelo", choices=("produccion", "staging"), default="produccion",
                    help="deepseek-flash override: produccion = none (default), staging = keep staging's")
    ap.add_argument("--nodos-esperados", type=int,
                    default=int(os.environ.get("CEREBRO_PROMOVER_NODOS", NODOS_ESPERADOS)))
    ap.add_argument("--produccion-respaldo", help="(ensayo only) production backup file instead of the live GET")
    ap.add_argument("--staging-respaldo", help="(ensayo only) staging backup file instead of the live GET")
    args = ap.parse_args(argv)

    if args.ensayo == args.aplicar:
        print("error: choose exactly one of --ensayo or --aplicar", file=sys.stderr)
        return 2
    if args.aplicar:
        if not args.esperado:
            print("error: --aplicar requires --esperado", file=sys.stderr)
            return 2
        cn.check_esperado(args.esperado)
        if args.produccion_respaldo or args.staging_respaldo:
            print("error: backup files are only allowed with --ensayo", file=sys.stderr)
            return 2

    base, key = None, None
    if not (args.produccion_respaldo and args.staging_respaldo):
        key, base = cn.load_api_key(), cn.get_base_url()
    wp, ws = cn.WORKFLOWS["produccion"], cn.WORKFLOWS["staging"]
    prod = _cargar(args.produccion_respaldo) if args.produccion_respaldo else cn.api_request(
        "GET", f"/api/v1/workflows/{wp}", base, key)
    if args.aplicar and not prod["versionId"].startswith(args.esperado):
        print(f"REFUSED: live versionId '{prod['versionId']}' does not start with '{args.esperado}'")
        return 2
    stg = _cargar(args.staging_respaldo) if args.staging_respaldo else cn.api_request(
        "GET", f"/api/v1/workflows/{ws}", base, key)

    out, report = construir(prod, stg, args.modelo)
    repo_md5 = hashlib.md5(cn.get_decisor_file().read_bytes()).hexdigest()
    checks = verificar(out, prod, stg, args.nodos_esperados, repo_md5)
    ok = _imprimir(prod, out, report, checks)
    if not ok:
        print("REFUSED: safety asserts failed" if args.aplicar else "ensayo: asserts FAILED")
        return 1
    if args.ensayo:
        print("ensayo: nothing was written")
        return 0

    cn.write_backup(prod, "produccion", cn.get_backups_dir())
    cn.api_request("PUT", f"/api/v1/workflows/{wp}", base, key, body=out)
    wf2 = cn.api_request("GET", f"/api/v1/workflows/{wp}", base, key)
    errores = []
    if wf2["versionId"] != wf2["activeVersionId"]:
        errores.append(f"activeVersionId mismatch: versionId={wf2['versionId']} activeVersionId={wf2['activeVersionId']}")
    if len(wf2.get("nodes", [])) != len(out["nodes"]):
        errores.append("node count differs after apply")
    if errores:
        for e in errores:
            print(f"error: {e}", file=sys.stderr)
        return 1
    print(f"versionId: {wf2['versionId']}")
    print("OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
