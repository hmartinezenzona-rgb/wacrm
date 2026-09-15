#!/usr/bin/env python3
"""
Despliegue del nodo `Contexto conversacion` para la 102 (pausa humana caduca).

Mismo metodo que banco-sql.py, parametrizado por entorno porque aquel apunta
a un Cerebro retirado (T3v07IQqtMs6AKJ4):
  1. La query se BAJA del workflow vivo y se parchea por programa (reemplazos
     de texto exacto que deben casar UNA sola vez). Nunca se reteclea.
  2. Se valida DENTRO de n8n con PREPARE (compila y comprueba tipos sin
     ejecutar) y se exige la MISMA firma de parametros que la version viva.
     La funcion de la 102 tiene que existir ya en esa base.
  3. --desplegar guarda ~/backups/wacrm-n8n/ROLLBACK-v2-antes-pausa-humana-caduca-<entorno>-<fecha>.json,
     sube, hace el ciclo desactivar/activar y RELEE lo desplegado para
     compararlo byte a byte con lo validado.

USO
  python3 desplegar-pausa-humana.py staging            # solo valida
  python3 desplegar-pausa-humana.py staging --desplegar
  python3 desplegar-pausa-humana.py produccion --desplegar
  python3 desplegar-pausa-humana.py <entorno> --revertir <ROLLBACK-...json>
"""

import argparse, json, os, sys, time, urllib.request, uuid

N8N = "https://automatizaciones-n8n.ttjgax.easypanel.host"
ENTORNOS = {
    "staging": {"cerebro": "U52y1kSNvhgxvWeb",
                "cred": {"postgres": {"id": "np3egGrAcrWkOWd4", "name": "Supabase STAGING"}}},
    "produccion": {"cerebro": "jEzlVLCLUaJhVwzs",
                   "cred": {"postgres": {"id": "S2CallLPSjzbVXN4", "name": "Supabase Account"}}},
}
NODO = "Contexto conversacion"
ETIQUETA = "pausa-humana-caduca"
AQUI = os.path.dirname(os.path.abspath(__file__))

PARCHES = [
    (
        "WITH liberar_ambiguo AS (\n"
        "  -- Solo recupera handoffs por operación ambigua ya resuelta. Los handoffs\n"
        "  -- humanos, MLC y abuso no pasan por esta puerta.\n"
        "  SELECT id FROM cerebro_liberar_derivacion_ambigua($1::uuid)\n"
        "),\n",
        "WITH liberar_ambiguo AS (\n"
        "  -- Solo recupera handoffs por operación ambigua ya resuelta. Los handoffs\n"
        "  -- humanos, MLC y abuso no pasan por esta puerta.\n"
        "  SELECT id FROM cerebro_liberar_derivacion_ambigua($1::uuid)\n"
        "),\n"
        "caducar_pausa AS (\n"
        "  -- La pausa que deja un envio desde el panel (agent_replied) caduca tras\n"
        "  -- N minutos sin actividad humana (102, decision del 15-sep). Libera de\n"
        "  -- VERDAD para que la bandeja deje de mostrarlo pausado. La pausa manual\n"
        "  -- y las derivaciones del bot NO pasan por aqui.\n"
        "  SELECT id FROM cerebro_caducar_pausa_humana($1::uuid)\n"
        "),\n",
    ),
    (
        "(COALESCE(v.ai_autoreply_disabled, false)\n"
        " AND NOT EXISTS (SELECT 1 FROM liberar_ambiguo)) AS bot_pausado",
        "(COALESCE(v.ai_autoreply_disabled, false)\n"
        " AND NOT EXISTS (SELECT 1 FROM liberar_ambiguo)\n"
        " AND NOT EXISTS (SELECT 1 FROM caducar_pausa)) AS bot_pausado",
    ),
]


def api(path, metodo="GET", cuerpo=None):
    clave = open(os.path.expanduser("~/.n8n-api-key")).read().strip()
    req = urllib.request.Request(
        N8N + path,
        data=json.dumps(cuerpo).encode() if cuerpo else None,
        headers={"X-N8N-API-KEY": clave, "Content-Type": "application/json"},
        method=metodo)
    return json.load(urllib.request.urlopen(req))


def parchear(viva):
    query = viva
    for buscar, reemplazar in PARCHES:
        n = query.count(buscar)
        if n != 1:
            sys.exit(f"ROJO: un parche casa {n} veces (se exige 1). Nada tocado.")
        query = query.replace(buscar, reemplazar)
    # Los parches no pueden traer punto y coma ni barras invertidas nuevas
    # (ver las notas del propio nodo sobre el 10-ago).
    if query.count(";") != viva.count(";") or query.count("\\") != viva.count("\\"):
        sys.exit("ROJO: los parches añaden punto y coma o barras invertidas.")
    return query


def validar(cred, viva, cand):
    ruta = "pausa-humana-" + uuid.uuid4().hex[:10]
    viva, cand = viva.rstrip().rstrip(";"), cand.rstrip().rstrip(";")
    sql = ("DEALLOCATE ALL;\n"
           f"PREPARE viva_ph AS {viva};\n"
           f"PREPARE cand_ph AS {cand};\n"
           "SELECT (SELECT parameter_types::text FROM pg_prepared_statements WHERE name='viva_ph') AS firma_viva, "
           "(SELECT parameter_types::text FROM pg_prepared_statements WHERE name='cand_ph') AS firma_cand, "
           # PREPARE no comprueba EXECUTE: se mira aparte con el rol real de la credencial.
           "current_user AS rol, "
           "has_function_privilege('public.cerebro_caducar_pausa_humana(uuid)', 'EXECUTE') AS puede_ejecutar;")
    nodos = [
        {"id": "disparo", "name": "Disparo", "type": "n8n-nodes-base.webhook",
         "typeVersion": 2, "position": [0, 0], "webhookId": str(uuid.uuid4()),
         "parameters": {"httpMethod": "POST", "path": ruta, "responseMode": "lastNode", "options": {}}},
        {"id": "chk", "name": "chk", "type": "n8n-nodes-base.postgres", "typeVersion": 2.6,
         "position": [220, 0], "credentials": cred, "onError": "continueRegularOutput",
         "alwaysOutputData": True,
         "parameters": {"operation": "executeQuery", "query": sql, "options": {}}},
    ]
    wf = api("/api/v1/workflows", "POST",
             {"name": "ZZ BANCO SQL pausa humana (se borra solo)", "nodes": nodos,
              "connections": {"Disparo": {"main": [[{"node": "chk", "type": "main", "index": 0}]]}},
              "settings": {"executionOrder": "v1"}})
    try:
        api(f"/api/v1/workflows/{wf['id']}/activate", "POST")
        time.sleep(2)
        req = urllib.request.Request(f"{N8N}/webhook/{ruta}", data=b"{}",
                                     headers={"Content-Type": "application/json"}, method="POST")
        urllib.request.urlopen(req, timeout=180).read()
        time.sleep(2)
        ejec = api(f"/api/v1/executions?workflowId={wf['id']}&includeData=true&limit=1")["data"]
        if not ejec:
            sys.exit("ROJO: el banco no dejo ejecucion")
        run = ejec[0]["data"]["resultData"]["runData"].get("chk", [])
        if not run:
            sys.exit("ROJO: el nodo de validacion no llego a ejecutarse")
        if run[0].get("error"):
            sys.exit(f"ROJO: {run[0]['error'].get('message')}")
        j = run[0]["data"]["main"][0][0]["json"]
        if j.get("error"):
            e = j["error"]
            sys.exit(f"ROJO: {e.get('description') or e.get('message') if isinstance(e, dict) else e}")
        if not j.get("firma_viva") or j.get("firma_viva") != j.get("firma_cand"):
            sys.exit(f"ROJO: firma viva={j.get('firma_viva')} candidata={j.get('firma_cand')}")
        if j.get("puede_ejecutar") is not True:
            sys.exit(f"ROJO: el rol {j.get('rol')} de la credencial no puede ejecutar la funcion")
        print(f"VERDE: PREPARE de las dos versiones, firma intacta {j['firma_cand']}, "
              f"rol {j['rol']} con EXECUTE")
    finally:
        try:
            api(f"/api/v1/workflows/{wf['id']}/deactivate", "POST")
        finally:
            api(f"/api/v1/workflows/{wf['id']}", "DELETE")


def subir(cerebro, w):
    api(f"/api/v1/workflows/{cerebro}", "PUT",
        {"name": w["name"], "nodes": w["nodes"],
         "connections": w["connections"], "settings": w.get("settings", {})})
    api(f"/api/v1/workflows/{cerebro}/deactivate", "POST")
    api(f"/api/v1/workflows/{cerebro}/activate", "POST")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("entorno", choices=ENTORNOS)
    ap.add_argument("--desplegar", action="store_true")
    ap.add_argument("--revertir")
    a = ap.parse_args()
    env = ENTORNOS[a.entorno]

    if a.revertir:
        w = json.load(open(a.revertir))
        subir(env["cerebro"], w)
        vivo = api(f"/api/v1/workflows/{env['cerebro']}")
        esperado = next(n for n in w["nodes"] if n["name"] == NODO)["parameters"]["query"]
        actual = next(n for n in vivo["nodes"] if n["name"] == NODO)["parameters"]["query"]
        print("revertido y verificado" if actual == esperado else "REVERTIDO != RESPALDO, revisa YA",
              "| activo:", vivo["active"])
        return

    wf = api(f"/api/v1/workflows/{env['cerebro']}")
    nodo = next(n for n in wf["nodes"] if n["name"] == NODO)
    viva = nodo["parameters"]["query"]
    if "cerebro_caducar_pausa_humana" in viva:
        sys.exit("El nodo ya lleva el cambio. Nada que hacer.")
    cand = parchear(viva)
    validar(env["cred"], viva, cand)

    if not a.desplegar:
        return

    # FUERA del repo: el workflow de staging lleva secretos literales.
    respaldos = os.path.expanduser("~/backups/wacrm-n8n")
    os.makedirs(respaldos, exist_ok=True)
    copia = os.path.join(respaldos, f"ROLLBACK-v2-antes-{ETIQUETA}-{a.entorno}-{time.strftime('%Y%m%d-%H%M%S')}.json")
    with open(os.open(copia, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as f:
        json.dump(wf, f, ensure_ascii=False, indent=1)
    print(f"respaldo: {os.path.normpath(copia)}")

    nuevo = json.loads(json.dumps(wf))
    next(n for n in nuevo["nodes"] if n["name"] == NODO)["parameters"]["query"] = cand
    subir(env["cerebro"], nuevo)

    vivo = api(f"/api/v1/workflows/{env['cerebro']}")
    desplegada = next(n for n in vivo["nodes"] if n["name"] == NODO)["parameters"]["query"]
    if desplegada != cand:
        sys.exit(f"DESPLEGADO != VALIDADO. Revierte con --revertir {copia} YA.")
    print(f"desplegado y verificado byte a byte. Activo: {vivo['active']}")


if __name__ == "__main__":
    main()
