#!/usr/bin/env python3
"""Trae el resultado de una consulta de SOLO LECTURA a un fichero local.

Existe por una limitacion tonta y real: el MCP de Supabase devuelve los datos a
la conversacion, no al disco, y para parchear una funcion de la base hay que
tener su texto EXACTO en un fichero. Copiarlo a mano de la pantalla es
justamente lo que prohibe metodo-verificar-antes-de-desplegar-cerebro.

Corre la consulta dentro de n8n, con la credencial que ya existe, y escribe el
resultado. El workflow temporal se borra solo, pase lo que pase.

USO
  python3 traer-sql.py "SELECT prosrc FROM pg_proc WHERE proname='x'" salida.txt
"""
import json, os, sys, time, urllib.request, uuid

N8N = "https://automatizaciones-n8n.ttjgax.easypanel.host"
CRED_PG = {"postgres": {"id": "S2CallLPSjzbVXN4", "name": "Supabase Account"}}


def api(path, metodo="GET", cuerpo=None):
    clave = open(os.path.expanduser("~/.n8n-api-key")).read().strip()
    req = urllib.request.Request(
        N8N + path, data=json.dumps(cuerpo).encode() if cuerpo else None,
        headers={"X-N8N-API-KEY": clave, "Content-Type": "application/json"}, method=metodo)
    return json.load(urllib.request.urlopen(req))


def traer(consulta):
    ruta = "traer-" + uuid.uuid4().hex[:10]
    nodos = [
        {"id": "a", "name": "Disparo", "type": "n8n-nodes-base.webhook", "typeVersion": 2,
         "position": [0, 0], "webhookId": str(uuid.uuid4()),
         "parameters": {"httpMethod": "POST", "path": ruta, "responseMode": "lastNode",
                        "options": {}}},
        {"id": "b", "name": "Consulta", "type": "n8n-nodes-base.postgres", "typeVersion": 2.6,
         "position": [220, 0], "credentials": CRED_PG, "alwaysOutputData": True,
         "onError": "continueRegularOutput",
         "parameters": {"operation": "executeQuery", "query": consulta, "options": {}}},
    ]
    con = {"Disparo": {"main": [[{"node": "Consulta", "type": "main", "index": 0}]]}}
    wf = api("/api/v1/workflows", "POST",
             {"name": "ZZ traer-sql temporal (se borra solo)", "nodes": nodos,
              "connections": con, "settings": {"executionOrder": "v1"}})
    try:
        api(f"/api/v1/workflows/{wf['id']}/activate", "POST")
        time.sleep(2)
        urllib.request.urlopen(urllib.request.Request(
            f"{N8N}/webhook/{ruta}", data=b"{}",
            headers={"Content-Type": "application/json"}, method="POST"), timeout=120).read()
        time.sleep(2)
        eid = api(f"/api/v1/executions?workflowId={wf['id']}&limit=1")["data"][0]["id"]
        d = api(f"/api/v1/executions/{eid}?includeData=true")
        filas = []
        for r in d["data"]["resultData"]["runData"].get("Consulta", []):
            if r.get("error"):
                sys.exit("ERROR en la consulta: " + str(r["error"])[:300])
            for b in r.get("data", {}).get("main", []):
                filas += [i["json"] for i in (b or [])]
        return filas
    finally:
        try:
            api(f"/api/v1/workflows/{wf['id']}/deactivate", "POST")
            api(f"/api/v1/workflows/{wf['id']}", "DELETE")
        except Exception:
            print("  (aviso: no se pudo borrar el temporal", wf["id"], ")", file=sys.stderr)


if __name__ == "__main__":
    filas = traer(sys.argv[1])
    if not filas:
        sys.exit("sin resultados")
    valor = list(filas[0].values())[0]
    destino = sys.argv[2] if len(sys.argv) > 2 else None
    if destino:
        open(destino, "w").write(valor if isinstance(valor, str) else json.dumps(valor))
        print(f"escrito en {destino}: {len(valor) if isinstance(valor,str) else '?'} chars")
    else:
        print(valor)
