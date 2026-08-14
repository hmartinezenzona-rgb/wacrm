#!/usr/bin/env python3
"""
BANCO DE PRUEBAS SQL — el hermano de banco.py para los nodos Postgres.

banco.py solo cubre nodos Code (lo dice 23-el-banco-de-pruebas.md). Los nodos
Postgres del Cerebro se quedaban sin red, y son justo los que mueven dinero.

QUE HACE
  Aplica un reemplazo de TEXTO EXACTO sobre las queries de los nodos Postgres
  del Cerebro y valida cada query resultante con PREPARE contra la base real.
  PREPARE compila, planifica y comprueba tipos SIN EJECUTAR NADA: ni un INSERT,
  ni un UPDATE. Y de paso `pg_prepared_statements.parameter_types` demuestra que
  la firma de parametros NO cambio — n8n los pasa por POSICION, asi que cambiar
  la firma rompe la tool aunque el SQL sea valido.

LAS DOS REGLAS QUE COSTARON PRODUCCION (ver metodo-verificar-antes-de-desplegar)
  1. La query NO se retéclea: se baja del JSON de produccion por API y se parchea
     por programa. El 10-ago se valido una version y se desplego otra: 27 minutos
     sin Cerebro.
  2. Se validan TODAS, no una representativa. El 9-ago se valido una de cinco
     "porque la transformacion es identica" y reventó otra: la transformacion era
     la misma pero el contexto de tipos de cada query NO.

Y se valida DENTRO de n8n, no con psql: lo que hay que probar es el texto tal y
como lo manda el nodo, que es donde se deforman las barras invertidas.

USO
  python3 banco-sql.py --buscar "<texto exacto>" --reemplazar "<texto nuevo>"
  ... y solo si sale VERDE:
  python3 banco-sql.py --buscar ... --reemplazar ... --desplegar

--desplegar guarda ROLLBACK-v2-antes-<etiqueta>.json antes de tocar, se niega a
subir si algo esta en rojo, hace el ciclo desactivar/activar y al final RELEE lo
desplegado y lo compara byte a byte con lo validado.
"""

import argparse, json, os, re, sys, time, urllib.request, uuid

N8N = "https://automatizaciones-n8n.ttjgax.easypanel.host"
CEREBRO = "T3v07IQqtMs6AKJ4"
CRED_PG = {"postgres": {"id": "S2CallLPSjzbVXN4", "name": "Supabase Account"}}
AQUI = os.path.dirname(os.path.abspath(__file__))


def api(path, metodo="GET", cuerpo=None):
    clave = open(os.path.expanduser("~/.n8n-api-key")).read().strip()
    req = urllib.request.Request(
        N8N + path,
        data=json.dumps(cuerpo).encode() if cuerpo else None,
        headers={"X-N8N-API-KEY": clave, "Content-Type": "application/json"},
        method=metodo)
    return json.load(urllib.request.urlopen(req))


# Las tools del agente son `postgresTool`, no `postgres`. Son el MISMO SQL y
# cuatro de los seis nodos de este flujo son de ese tipo: dejarlas fuera del
# filtro validaba dos y desplegaba seis.
TIPOS_PG = ("n8n-nodes-base.postgres", "n8n-nodes-base.postgresTool")


def nodos_postgres_afectados(wf, buscar):
    """Nodos Postgres cuya query contiene el texto buscado. Del JSON, no a mano."""
    salida = []
    for n in wf["nodes"]:
        if n.get("type") not in TIPOS_PG:
            continue
        q = n.get("parameters", {}).get("query")
        if q and buscar in q:
            salida.append((n["name"], q, q.count(buscar)))
    return salida


def sql_de_validacion(etiqueta, prod, cand):
    """PREPARE de las dos versiones y comparacion de firmas, en una sola tanda.

    DEALLOCATE ALL primero: la conexion viene de un pool y puede traer nombres
    de una pasada anterior. Nada de esto ejecuta el cuerpo de la query.
    """
    return (
        "DEALLOCATE ALL;\n"
        f"PREPARE prod_{etiqueta} AS {prod};\n"
        f"PREPARE cand_{etiqueta} AS {cand};\n"
        "SELECT "
        f"(SELECT parameter_types::text FROM pg_prepared_statements WHERE name='prod_{etiqueta}') AS firma_prod, "
        f"(SELECT parameter_types::text FROM pg_prepared_statements WHERE name='cand_{etiqueta}') AS firma_cand;"
    )


def validar(afectados, buscar, reemplazar):
    """Monta un banco temporal en n8n, lo ejecuta y lo borra pase lo que pase."""
    ruta = "banco-sql-" + uuid.uuid4().hex[:10]
    nodos = [{"id": "disparo", "name": "Disparo", "type": "n8n-nodes-base.webhook",
              "typeVersion": 2, "position": [0, 0], "webhookId": str(uuid.uuid4()),
              "parameters": {"httpMethod": "POST", "path": ruta,
                             "responseMode": "lastNode", "options": {}}}]
    con, previo, candidatas = {}, "Disparo", {}

    for i, (nombre, prod, _) in enumerate(afectados):
        cand = prod.replace(buscar, reemplazar)
        candidatas[nombre] = cand
        nn = f"chk {i} {nombre}"[:60]
        nodos.append({
            "id": f"chk{i}", "name": nn, "type": "n8n-nodes-base.postgres",
            "typeVersion": 2.6, "position": [220 + 220 * i, 0], "credentials": CRED_PG,
            "onError": "continueRegularOutput", "alwaysOutputData": True,
            "parameters": {"operation": "executeQuery",
                           "query": sql_de_validacion(f"v{i}", prod, cand),
                           "options": {}}})
        con[previo] = {"main": [[{"node": nn, "type": "main", "index": 0}]]}
        previo = nn

    wf = api("/api/v1/workflows", "POST",
             {"name": "ZZ BANCO SQL temporal (se borra solo)", "nodes": nodos,
              "connections": con, "settings": {"executionOrder": "v1"}})
    try:
        api(f"/api/v1/workflows/{wf['id']}/activate", "POST")
        time.sleep(2)
        req = urllib.request.Request(f"{N8N}/webhook/{ruta}", data=b"{}",
                                     headers={"Content-Type": "application/json"},
                                     method="POST")
        urllib.request.urlopen(req, timeout=180).read()
        time.sleep(2)
        ejec = api(f"/api/v1/executions?workflowId={wf['id']}&limit=1")["data"][0]
        datos = api(f"/api/v1/executions/{ejec['id']}?includeData=true")
        return candidatas, datos["data"]["resultData"]
    finally:
        try:
            api(f"/api/v1/workflows/{wf['id']}/deactivate", "POST")
            api(f"/api/v1/workflows/{wf['id']}", "DELETE")
        except Exception:
            print("  (aviso: no se pudo borrar el banco temporal", wf["id"], ")")


def leer_resultados(afectados, resultado):
    """Un veredicto por nodo. Verde = PREPARE de las dos y MISMA firma."""
    run = resultado.get("runData", {})
    fallo_global = resultado.get("error", {}).get("message")
    veredictos = []
    for i, (nombre, _, n_ocurrencias) in enumerate(afectados):
        nn = f"chk {i} {nombre}"[:60]
        corridas = run.get(nn, [])
        if not corridas:
            veredictos.append((nombre, "ROJO", "el nodo no llego a ejecutarse", n_ocurrencias))
            continue
        r = corridas[0]
        if r.get("error"):
            veredictos.append((nombre, "ROJO", str(r["error"].get("message"))[:200], n_ocurrencias))
            continue
        items = [it["json"] for b in r.get("data", {}).get("main", []) for it in (b or [])]
        if not items:
            veredictos.append((nombre, "ROJO", "sin resultado", n_ocurrencias))
            continue
        j = items[0]
        if j.get("error"):
            veredictos.append((nombre, "ROJO", str(j["error"])[:200], n_ocurrencias))
            continue
        fp, fc = j.get("firma_prod"), j.get("firma_cand")
        if not fp or not fc:
            veredictos.append((nombre, "ROJO", f"PREPARE no dejo firma (prod={fp} cand={fc})", n_ocurrencias))
        elif fp != fc:
            veredictos.append((nombre, "ROJO", f"la firma CAMBIA: {fp} -> {fc}", n_ocurrencias))
        else:
            veredictos.append((nombre, "VERDE", f"firma intacta {fc}", n_ocurrencias))
    if fallo_global and all(v[1] == "VERDE" for v in veredictos):
        veredictos.append(("(workflow)", "ROJO", fallo_global[:200], 0))
    return veredictos


def desplegar(wf, candidatas, etiqueta):
    copia = os.path.join(AQUI, "..", f"ROLLBACK-v2-antes-{etiqueta}.json")
    with open(copia, "w") as f:
        json.dump(wf, f, ensure_ascii=False, indent=1)
    print(f"\n  respaldo guardado en {os.path.normpath(copia)}")

    nuevo = json.loads(json.dumps(wf))
    for n in nuevo["nodes"]:
        if n["name"] in candidatas:
            n["parameters"]["query"] = candidatas[n["name"]]

    api(f"/api/v1/workflows/{CEREBRO}", "PUT",
        {"name": nuevo["name"], "nodes": nuevo["nodes"],
         "connections": nuevo["connections"], "settings": nuevo.get("settings", {})})
    api(f"/api/v1/workflows/{CEREBRO}/deactivate", "POST")
    api(f"/api/v1/workflows/{CEREBRO}/activate", "POST")

    vivo = api(f"/api/v1/workflows/{CEREBRO}")
    malas = [n["name"] for n in vivo["nodes"]
             if n["name"] in candidatas
             and n["parameters"].get("query") != candidatas[n["name"]]]
    if malas:
        sys.exit(f"  DESPLEGADO != VALIDADO en: {malas}. Restaura {copia} YA.")
    print(f"  desplegado y verificado byte a byte en {len(candidatas)} nodos. Activo: {vivo['active']}")


def revertir(fichero):
    """Vuelta atras completa desde un ROLLBACK-*.json. Tampoco esto a mano:
    restaurar tecleando, y encima con prisa, es como se rompe dos veces."""
    ruta = fichero if os.path.isabs(fichero) else os.path.join(AQUI, "..", fichero)
    w = json.load(open(ruta))
    api(f"/api/v1/workflows/{CEREBRO}", "PUT",
        {"name": w["name"], "nodes": w["nodes"],
         "connections": w["connections"], "settings": w.get("settings", {})})
    api(f"/api/v1/workflows/{CEREBRO}/deactivate", "POST")
    api(f"/api/v1/workflows/{CEREBRO}/activate", "POST")

    vivo = api(f"/api/v1/workflows/{CEREBRO}")
    guardadas = {n["name"]: n.get("parameters", {}).get("query")
                 for n in w["nodes"] if n.get("type") in TIPOS_PG}
    malas = [n["name"] for n in vivo["nodes"]
             if n["name"] in guardadas
             and n["parameters"].get("query") != guardadas[n["name"]]]
    if malas:
        sys.exit(f"  RESTAURADO != RESPALDO en: {malas}. Revisa a mano YA.")
    print(f"  restaurado desde {os.path.normpath(ruta)} y verificado "
          f"byte a byte en {len(guardadas)} nodos. Activo: {vivo['active']}")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--revertir", metavar="ROLLBACK.json",
                   help="restaura el Cerebro desde un respaldo y sale")
    p.add_argument("--buscar")
    p.add_argument("--reemplazar")
    p.add_argument("--etiqueta", default=None, help="nombre del fichero ROLLBACK")
    p.add_argument("--desplegar", action="store_true")
    a = p.parse_args()

    if a.revertir:
        revertir(a.revertir)
        return

    if not a.buscar or not a.reemplazar:
        sys.exit("hacen falta --buscar y --reemplazar (o --revertir <fichero>)")
    if a.buscar == a.reemplazar:
        sys.exit("buscar y reemplazar son iguales: no hay cambio que probar")

    wf = api(f"/api/v1/workflows/{CEREBRO}")
    print(f"Cerebro: {wf['name']}  (activo: {wf['active']})")

    afectados = nodos_postgres_afectados(wf, a.buscar)
    if not afectados:
        sys.exit("ningun nodo Postgres contiene ese texto. Nada que hacer.")

    print(f"\nNodos afectados ({len(afectados)}):")
    for nombre, _, n in afectados:
        print(f"  - {nombre}   ({n} vez/veces)")

    print("\nValidando con PREPARE dentro de n8n (no ejecuta ningun cuerpo)...")
    candidatas, resultado = validar(afectados, a.buscar, a.reemplazar)
    veredictos = leer_resultados(afectados, resultado)

    print()
    for nombre, estado, detalle, _ in veredictos:
        print(f"  [{estado}] {nombre}: {detalle}")

    rojos = [v for v in veredictos if v[1] != "VERDE"]
    if rojos:
        sys.exit(f"\n{len(rojos)} en ROJO. NO se despliega nada.")

    print(f"\nVERDE: {len(veredictos)}/{len(veredictos)} nodos compilan y ninguna firma cambia.")

    if not a.desplegar:
        print("\n(no se ha tocado produccion. Anade --desplegar cuando toque.)")
        return

    etiqueta = a.etiqueta or "cambio-sql"
    desplegar(wf, candidatas, etiqueta)
    print("\nFALTA LO QUE NINGUN BANCO DEMUESTRA: mandar un mensaje real y leer\n"
          "la ejecucion. Una rama que no se ha visto producir un efecto real no\n"
          "esta probada.")


if __name__ == "__main__":
    main()
