#!/usr/bin/env python3
"""Nightly Cerebro review: send the day to Hermes, classify and report.

Hermes receives the two skills, the current production prompt and the day's
traffic. It must answer with one JSON block:
  {resumen, hallazgos:[{chat,problema,cita,causa,arreglo}],
   propuesta:{v1,v2}, casos_prueba, riesgo_sugerido}

The local classifier decides the real risk. Nothing is applied here: the
report and, when a low-risk candidate exists, a candidate file are written
under ~/cerebro-fase1/mejora-nocturna/ with mode 0600.

    python3 infra/ia/mejora_nocturna.py --dia dia.json --prompt-actual prompt.txt
"""
import argparse
import glob
import json
import os
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

from clasificar_riesgo import clasificar

SKILLS = ("revisar-agente-whatsapp", "prompt-crafter-pro")
DEST = Path.home() / "cerebro-fase1" / "mejora-nocturna"
SKILLS_DEFAULT = Path.home() / ".claude" / "skills" / "synced"
BUDGET = 120_000


def error(msg: str) -> "NoReturn":  # noqa: F821
    print(msg, file=sys.stderr)
    raise SystemExit(2)


def leer_skills(base: Path) -> dict[str, str]:
    out = {}
    for nombre in SKILLS:
        rutas = sorted(glob.glob(str(base / "*" / nombre / "SKILL.md")))
        if not rutas:
            error(f"no encontre la skill {nombre} bajo {base}")
        out[nombre] = Path(rutas[0]).read_text(encoding="utf-8")
    return out


def digest(dia: dict, max_conv: int, max_msgs: int, max_chars: int) -> dict:
    conversaciones = []
    for c in dia.get("conversaciones", [])[:max_conv]:
        msgs = []
        for m in c.get("mensajes", [])[-max_msgs:]:
            msgs.append({
                "remite": m.get("remite"),
                "tipo": m.get("tipo"),
                "hora": m.get("hora"),
                "texto": (m.get("texto") or "")[:max_chars],
            })
        conversaciones.append({
            "id": c.get("id"),
            "contacto": c.get("contacto"),
            "bot_pausado": c.get("bot_pausado"),
            "pausa_razon": c.get("pausa_razon"),
            "asignada": c.get("asignada"),
            "mensajes": msgs,
        })
    return {
        "desde": dia.get("desde"),
        "hasta": dia.get("hasta"),
        "conversaciones": conversaciones,
        "sin_respuesta": dia.get("sin_respuesta", []),
        "operaciones": dia.get("operaciones", []),
        "herramientas": dia.get("herramientas", {}),
    }


INSTRUCCIONES = """Eres el revisor nocturno del bot de WhatsApp de remesas.
Usa las dos skills adjuntas: revisar-agente-whatsapp y prompt-crafter-pro.
Revisa SOLO las conversaciones dadas. No inventes chats ni citas.

Devuelve UN bloque ```json con este esquema exacto y nada mas:
{
  "resumen": "una frase",
  "hallazgos": [{"chat":"id","problema":"robot|error|venta_perdida","cita":"texto exacto","causa":"que regla o dato fallo","arreglo":"que cambiar"}],
  "propuesta": {"v1": [{"buscar": "texto exacto del PROMPT ACTUAL", "reemplazar": "texto nuevo"}], "v2": "prompt completo reescrito con las 6 dimensiones"},
  "casos_prueba": ["caso 1", "caso 2", "caso 3"],
  "riesgo_sugerido": "bajo|alto"
}

Reglas:
- V1 son parches exactos sobre el prompt actual (0 a 5). NO reescribas el prompt entero. Cada "buscar" debe aparecer UNA sola vez y copiarse literal del prompt actual.
- V1 no puede cambiar precios, montos, reglas de derivacion, herramientas ni seguridad.
- Si el problema no se arregla con el prompt, dilo en causa y deja la propuesta igual al prompt actual.
- No repitas telefonos, cuentas ni datos personales en los hallazgos; usa el id del chat.
"""


def construir_prompt(dia: dict, prompt_actual: str, skills: dict[str, str]) -> str:
    for max_conv, max_msgs, max_chars in ((40, 12, 300), (20, 8, 200), (10, 6, 150)):
        datos = json.dumps(digest(dia, max_conv, max_msgs, max_chars), ensure_ascii=False)
        texto = (
            INSTRUCCIONES
            + "\n\n### SKILL: revisar-agente-whatsapp\n" + skills["revisar-agente-whatsapp"]
            + "\n\n### SKILL: prompt-crafter-pro\n" + skills["prompt-crafter-pro"]
            + "\n\n### PROMPT ACTUAL DEL BOT\n" + prompt_actual
            + "\n\n### CONVERSACIONES DEL DIA (JSON)\n" + datos
        )
        if len(texto) <= BUDGET:
            return texto
    error(f"el prompt para Hermes supera {BUDGET} caracteres incluso compactado")


def extraer_json(salida: str) -> dict:
    candidatos = []
    if "```json" in salida:
        for parte in salida.split("```json")[1:]:
            candidatos.append(parte.split("```", 1)[0])
    else:
        i, j = salida.find("{"), salida.rfind("}")
        if i >= 0 and j > i:
            candidatos.append(salida[i:j + 1])
    for c in reversed(candidatos):
        try:
            data = json.loads(c)
        except json.JSONDecodeError:
            continue
        if isinstance(data.get("propuesta"), dict) and isinstance(data.get("hallazgos"), list):
            return data
    error("Hermes no devolvio el JSON esperado")


def llamar_hermes(prompt: str, timeout: int) -> str:
    with tempfile.TemporaryDirectory() as tmp:
        r = subprocess.run(
            ["hermes", "-z", prompt, "--in", tmp],  # no toolset: `todo` is disabled on this CLI
            capture_output=True, text=True, timeout=timeout,
        )
    if r.returncode != 0:
        cola = [l for l in (r.stderr or "").strip().splitlines() if l]
        error(f"hermes fallo ({r.returncode}): {cola[-1] if cola else 'sin detalle'}")
    return r.stdout


def aplicar_parches(prompt_actual: str, parches) -> tuple[str | None, list[str], int]:
    if isinstance(parches, str):
        return parches, ["v1 vino como reescritura completa, no como parches"], 0
    if not isinstance(parches, list):
        return None, ["v1 no es una lista de parches"], 0
    texto = prompt_actual
    errores = []
    aplicados = 0
    for i, p in enumerate(parches, 1):
        if not isinstance(p, dict) or not isinstance(p.get("buscar"), str) or not isinstance(p.get("reemplazar"), str):
            errores.append(f"parche {i}: faltan buscar/reemplazar")
            continue
        buscar = p["buscar"]
        if not buscar:
            errores.append(f"parche {i}: buscar vacio")
            continue
        n = texto.count(buscar)
        if n != 1:
            errores.append(f"parche {i}: buscar aparece {n} vez/veces")
            continue
        texto = texto.replace(buscar, p["reemplazar"], 1)
        aplicados += 1
    minimo = max(0, len(prompt_actual) - max(200, int(0.1 * len(prompt_actual))))
    if not errores and len(texto) < minimo:
        errores.append(f"candidato demasiado corto ({len(texto)} vs {len(prompt_actual)} caracteres)")
    return (None if errores else texto), errores, aplicados


def clasificar_propuestas(prompt_actual: str, propuesta: dict) -> tuple[str | None, str | None, dict, list[str]]:
    resultados = {}
    notas = []
    elegido = None
    elegido_texto = None

    v1 = propuesta.get("v1")
    if isinstance(v1, list):
        if not v1:
            resultados["v1"] = {"riesgo": "sin_cambios", "motivos": [], "lineas_cambiadas": 0}
        else:
            cand, errores, aplicados = aplicar_parches(prompt_actual, v1)
            notas.append(f"v1: {aplicados}/{len(v1)} parches aplicados")
            if errores:
                resultados["v1"] = {"riesgo": "alto", "motivos": errores, "lineas_cambiadas": 0}
            elif cand is None or cand == prompt_actual:
                resultados["v1"] = {"riesgo": "sin_cambios", "motivos": [], "lineas_cambiadas": 0}
            else:
                res = clasificar(prompt_actual, cand, "prompt")
                resultados["v1"] = res
                notas.append(f"v1: {res['lineas_cambiadas']} lineas cambiadas")
                if res["riesgo"] == "bajo":
                    elegido, elegido_texto = "v1", cand
    elif isinstance(v1, str) and v1.strip():
        res = clasificar(prompt_actual, v1, "prompt")
        resultados["v1"] = res
        notas.append("v1: reescritura completa (no parches)")
        if res["riesgo"] == "bajo":
            elegido, elegido_texto = "v1", v1

    v2 = propuesta.get("v2")
    if isinstance(v2, str) and v2.strip():
        res = clasificar(prompt_actual, v2, "prompt")
        resultados["v2"] = res
        notas.append("v2: reescritura completa, solo para revision humana")

    return elegido, elegido_texto, resultados, notas


def escribir(salida_dir: Path, data: dict, prompt_actual: str, elegido: str | None,
             elegido_texto: str | None, resultados: dict,
             notas: list[str]) -> tuple[Path, Path | None]:
    salida_dir.mkdir(parents=True, exist_ok=True)
    os.chmod(salida_dir, 0o700)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    informe = salida_dir / f"informe-{stamp}.md"

    lineas = [f"# Mejora nocturna {stamp}", "", "## Resumen", str(data.get("resumen", "")), "", "## Hallazgos"]
    for h in data.get("hallazgos", []):
        lineas.append(f"- **{h.get('chat')}** ({h.get('problema')}): {h.get('causa')} — arreglo: {h.get('arreglo')}")
    lineas += ["", "## Riesgo (clasificador local)", ""]
    for nombre, res in resultados.items():
        motivos = ", ".join(res["motivos"]) if res["motivos"] else "sin motivos"
        lineas.append(f"- {nombre}: **{res['riesgo']}** ({motivos}; {res['lineas_cambiadas']} lineas)")
    lineas += ["", "## Notas"]
    lineas += [f"- {n}" for n in notas] or ["- sin notas"]
    lineas += ["", "## Casos de prueba"]
    lineas += [f"- {c}" for c in data.get("casos_prueba", [])]
    lineas += ["", "## Siguiente paso"]
    if elegido:
        lineas.append(f"Candidato {elegido} listo para la compuerta de evals. No se ha aplicado.")
    else:
        lineas.append("Ninguna propuesta es de bajo riesgo: requiere revision del dueno.")
    informe.write_text("\n".join(lineas) + "\n", encoding="utf-8")
    os.chmod(informe, 0o600)

    candidato = None
    if elegido and elegido_texto:
        candidato = salida_dir / f"candidato-{stamp}.txt"
        candidato.write_text(elegido_texto, encoding="utf-8")
        os.chmod(candidato, 0o600)
    return informe, candidato


def main() -> int:
    p = argparse.ArgumentParser(description="Nightly Cerebro review via Hermes")
    p.add_argument("--dia", type=Path, required=True)
    p.add_argument("--prompt-actual", type=Path, required=True)
    p.add_argument("--skills-dir", type=Path, default=SKILLS_DEFAULT)
    p.add_argument("--salida-dir", type=Path, default=DEST)
    p.add_argument("--timeout", type=int, default=900)
    p.add_argument("--dry", action="store_true", help="build the prompt and print its size only")
    args = p.parse_args()

    if not args.dia.is_file():
        error(f"falta {args.dia}")
    if not args.prompt_actual.is_file():
        error(f"falta {args.prompt_actual}")

    dia = json.loads(args.dia.read_text(encoding="utf-8"))
    prompt_actual = args.prompt_actual.read_text(encoding="utf-8")
    skills = leer_skills(args.skills_dir)
    prompt = construir_prompt(dia, prompt_actual, skills)

    if args.dry:
        print(f"ok prompt={len(prompt)} caracteres conversaciones={len(dia.get('conversaciones', []))}")
        return 0

    salida = llamar_hermes(prompt, args.timeout)
    args.salida_dir.mkdir(parents=True, exist_ok=True)
    os.chmod(args.salida_dir, 0o700)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    crudo = args.salida_dir / f"respuesta-{stamp}.txt"
    crudo.write_text(salida, encoding="utf-8")
    os.chmod(crudo, 0o600)
    data = extraer_json(salida)
    elegido, elegido_texto, resultados, notas = clasificar_propuestas(prompt_actual, data["propuesta"])
    informe, candidato = escribir(args.salida_dir, data, prompt_actual, elegido, elegido_texto,
                                  resultados, notas)

    riesgos = ",".join(f"{k}={v['riesgo']}" for k, v in resultados.items())
    estado = "listo" if candidato else "ninguno"
    print(f"ok informe={informe} candidato={estado} riesgos={riesgos}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
