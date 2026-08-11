#!/usr/bin/env python3
"""
BANCO DE PRUEBAS DEL CEREBRO — nada llega a produccion sin pasar por aqui.

Prueba un cambio en un nodo Code del Cerebro ANTES de desplegarlo, de dos
formas a la vez:

  1. BATERIA DE CASOS   — entradas fijas con su salida esperada (JSON aparte).
  2. HISTORICO COMPLETO — los mensajes reales que ha enviado el bot, pasados
                          por la version de produccion y por la candidata,
                          comparando una a una.

Y comprueba lo que de verdad puede hacer dano:
  - que no se altere NINGUN digito (una cifra de dinero mal partida es dinero
    mal leido por el cliente),
  - que no se pierda ni se anada contenido,
  - que no se toquen los bloques de datos (*Titular:* / *Cuenta MMG:*), que
    llevan saltos simples A PROPOSITO.

CLAVE, y es la leccion que costo 27 minutos de produccion el 10-ago:
el banco NO usa una copia retecleada del codigo. Se BAJA el nodo de produccion
por API y se compara contra el fichero candidato. Lo que se prueba es
exactamente lo que hay y exactamente lo que se va a subir.

USO
  python3 banco.py --nodo "Normalizar formato" \
                   --candidato candidato-normalizar-formato.js \
                   --casos casos-normalizar-formato.json
  ... y si sale verde:
  python3 banco.py ... --desplegar

`--desplegar` guarda antes una copia ROLLBACK-* y se niega a subir nada si
alguna prueba falla.
"""

import argparse, base64, json, os, sys, time, urllib.request, uuid

N8N = "https://automatizaciones-n8n.ttjgax.easypanel.host"
CEREBRO = "T3v07IQqtMs6AKJ4"
CRED_PG = {"postgres": {"id": "S2CallLPSjzbVXN4", "name": "Supabase Account"}}
CORPUS = ("SELECT content_text AS texto FROM messages "
          "WHERE sender_type='agent' AND ai_generated AND content_text IS NOT NULL")


def api(path, metodo="GET", cuerpo=None):
    clave = open(os.path.expanduser("~/.n8n-api-key")).read().strip()
    req = urllib.request.Request(
        N8N + path,
        data=json.dumps(cuerpo).encode() if cuerpo else None,
        headers={"X-N8N-API-KEY": clave, "Content-Type": "application/json"},
        method=metodo)
    return json.load(urllib.request.urlopen(req))


def codigo_en_produccion(wf, nodo):
    for n in wf["nodes"]:
        if n["name"] == nodo:
            if n["type"] != "n8n-nodes-base.code":
                sys.exit(f"'{nodo}' no es un nodo Code, es {n['type']}")
            return n["parameters"]["jsCode"]
    sys.exit(f"No existe el nodo '{nodo}' en el Cerebro")


# El comparador corre DENTRO de n8n a proposito: mismo motor de JS que
# produccion. Probarlo en Node del portatil no demuestra lo mismo.
COMPARADOR = r"""
const filas  = $input.all().map(i => i.json).filter(f => typeof f.texto === 'string');
const CASOS  = __CASOS__;
// El nodo real aplica LAS DOS: limpia el razonamiento y luego formatea.
const PROD   = (function(){ __PROD__ ; return t => normalizar(quitarRazonamiento(t)); })();
const CAND   = (function(){ __CAND__ ; return t => normalizar(quitarRazonamiento(t)); })();

const sinEsp   = s => String(s).replace(/\s+/g, ' ').trim();
const digitos  = s => (String(s).match(/[0-9]/g) || []).join('');

// --- 1) BATERIA DE CASOS ---
const bateria = CASOS.map(c => {
  let obtenido;
  try { obtenido = CAND(c.entrada); }
  catch (e) { return { caso: c.nombre, ok: false, motivo: 'excepcion: ' + e.message }; }

  if (c.prohibido_partir) {
    const rotos = c.prohibido_partir.filter(x => !String(obtenido).includes(x));
    return { caso: c.nombre, ok: rotos.length === 0,
             motivo: rotos.length ? 'se partieron: ' + rotos.join(', ') : 'ok',
             obtenido: String(obtenido).slice(0, 120) };
  }
  const ok = obtenido === c.esperado;
  return { caso: c.nombre, ok,
           motivo: ok ? 'ok' : 'no coincide con lo esperado',
           obtenido: String(obtenido).slice(0, 120),
           esperado: String(c.esperado).slice(0, 120) };
});

// --- 2) HISTORICO COMPLETO ---
let cambian = 0, digitosRotos = 0, contenidoRoto = 0, bloquesTocados = 0;
const muestras = [], regresiones = [];
for (const f of filas) {
  const t = f.texto;
  let a, b;
  try { a = PROD(t); b = CAND(t); }
  catch (e) { regresiones.push({ motivo: 'excepcion', texto: t.slice(0, 80) }); continue; }
  if (a === b) continue;
  cambian++;
  if (digitos(a) !== digitos(b)) { digitosRotos++; regresiones.push({ motivo: 'digitos', antes: a, despues: b }); }
  if (sinEsp(a) !== sinEsp(b))   { contenidoRoto++; regresiones.push({ motivo: 'contenido', antes: a, despues: b }); }
  if (/\*Cuenta MMG:\*|\*Titular:\*/.test(t)) { bloquesTocados++; regresiones.push({ motivo: 'bloque de datos', antes: a, despues: b }); }
  if (muestras.length < 10) muestras.push({ antes: a, despues: b });
}

const fallosBateria = bateria.filter(b => !b.ok).length;
return [{ json: {
  verde: fallosBateria === 0 && regresiones.length === 0,
  bateria, fallos_bateria: fallosBateria,
  analizados: filas.length, cambian,
  digitos_alterados: digitosRotos, contenido_alterado: contenidoRoto,
  bloques_de_datos_tocados: bloquesTocados,
  regresiones: regresiones.slice(0, 10), muestras
}}];
"""


def montar_y_ejecutar(prod, cand, casos):
    ruta = "banco-" + uuid.uuid4().hex[:10]
    codigo = (COMPARADOR
              .replace("__CASOS__", json.dumps(casos, ensure_ascii=False))
              .replace("__PROD__", solo_normalizar(prod))
              .replace("__CAND__", solo_normalizar(cand)))
    nodos = [
        {"id": "a", "name": "Disparo", "type": "n8n-nodes-base.webhook",
         "typeVersion": 2, "position": [0, 0], "webhookId": str(uuid.uuid4()),
         "parameters": {"httpMethod": "POST", "path": ruta,
                        "responseMode": "lastNode", "options": {}}},
        {"id": "b", "name": "Traer historico", "type": "n8n-nodes-base.postgres",
         "typeVersion": 2.6, "position": [220, 0], "credentials": CRED_PG,
         "parameters": {"operation": "executeQuery", "query": CORPUS, "options": {}}},
        {"id": "c", "name": "Comparar", "type": "n8n-nodes-base.code",
         "typeVersion": 2, "position": [440, 0], "parameters": {"jsCode": codigo}},
    ]
    con = {"Disparo": {"main": [[{"node": "Traer historico", "type": "main", "index": 0}]]},
           "Traer historico": {"main": [[{"node": "Comparar", "type": "main", "index": 0}]]}}
    wf = api("/api/v1/workflows", "POST",
             {"name": "ZZ BANCO temporal (se borra solo)", "nodes": nodos,
              "connections": con, "settings": {"executionOrder": "v1"}})
    try:
        api(f"/api/v1/workflows/{wf['id']}/activate", "POST")
        time.sleep(2)
        req = urllib.request.Request(f"{N8N}/webhook/{ruta}", data=b"{}",
                                     headers={"Content-Type": "application/json"},
                                     method="POST")
        with urllib.request.urlopen(req, timeout=120) as r:
            d = json.load(r)
        return d.get("json", d)
    finally:
        try:
            api(f"/api/v1/workflows/{wf['id']}/deactivate", "POST")
            api(f"/api/v1/workflows/{wf['id']}", "DELETE")
        except Exception:
            print("  (aviso: no se pudo borrar el banco temporal", wf["id"], ")")


def solo_normalizar(codigo):
    """Devuelve las funciones del nodo, sin el `return $input.all()...` final.

    OJO: se queda con TODO lo que define el nodo, no solo `normalizar`. Una
    primera version recortaba en `quitarRazonamiento` y el banco probaba media
    funcion: daba dos falsos fallos y habria dado por buenos cambios que rompen
    el filtro de razonamiento. El banco tiene que ejercitar el nodo COMPLETO,
    igual que produccion.
    """
    i = codigo.index("function normalizar")
    j = codigo.index("return $input.all()")
    return codigo[i:j]


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--nodo", required=True)
    p.add_argument("--candidato", required=True)
    p.add_argument("--casos", required=True)
    p.add_argument("--desplegar", action="store_true")
    a = p.parse_args()

    wf = api(f"/api/v1/workflows/{CEREBRO}")
    prod = codigo_en_produccion(wf, a.nodo)
    cand = open(a.candidato).read()
    casos = json.load(open(a.casos))

    if prod == cand:
        print("El candidato es identico a produccion. Nada que probar.")
        return 0

    print(f"Nodo: {a.nodo}")
    print(f"Casos: {len(casos)}   Candidato: {a.candidato}\n")
    r = montar_y_ejecutar(prod, cand, casos)

    print("--- BATERIA DE CASOS ---")
    for b in r["bateria"]:
        print(f"  {'OK  ' if b['ok'] else 'FALLA'}  {b['caso']}")
        if not b["ok"]:
            print(f"         motivo:   {b['motivo']}")
            print(f"         obtenido: {b.get('obtenido','')!r}")
            if "esperado" in b:
                print(f"         esperado: {b['esperado']!r}")

    print("\n--- HISTORICO COMPLETO ---")
    for k in ("analizados", "cambian", "digitos_alterados",
              "contenido_alterado", "bloques_de_datos_tocados"):
        print(f"  {k:28} {r[k]}")

    if r["muestras"]:
        print("\n--- QUE CAMBIA (muestra) ---")
        for m in r["muestras"][:5]:
            print(f"  antes:   {m['antes']!r}")
            print(f"  despues: {m['despues']!r}\n")

    if r["regresiones"]:
        print("--- REGRESIONES ---")
        for x in r["regresiones"]:
            print(" ", x)

    if not r["verde"]:
        print("\nROJO: hay fallos. NO se despliega.")
        return 1

    print("\nVERDE: bateria completa y cero regresiones sobre el historico.")
    if not a.desplegar:
        print("Para subirlo:  vuelve a lanzar con --desplegar")
        return 0

    copia = os.path.expanduser(
        f"~/cerebro-fase1/ROLLBACK-v2-antes-{a.nodo.lower().replace(' ', '-')}.json")
    json.dump(wf, open(copia, "w"), ensure_ascii=False, indent=1)
    print(f"Copia de seguridad: {copia}")

    for n in wf["nodes"]:
        if n["name"] == a.nodo:
            n["parameters"]["jsCode"] = cand
    api(f"/api/v1/workflows/{CEREBRO}", "PUT",
        {"name": wf["name"], "nodes": wf["nodes"],
         "connections": wf["connections"], "settings": wf.get("settings", {})})
    print("Desplegado. (Cambio de parametros: se aplica solo, sin reactivar.)")

    despues = codigo_en_produccion(api(f"/api/v1/workflows/{CEREBRO}"), a.nodo)
    print("Comprobado en produccion:", "coincide" if despues == cand else "NO COINCIDE — revisar")
    return 0


if __name__ == "__main__":
    sys.exit(main())
