#!/usr/bin/env python3
"""Deterministic risk gate for the nightly Cerebro auto-apply.

A change is low-risk only when it edits prompt text and none of the changed
lines touches money, decisions/handoff, tools, security or arithmetic.
Everything else is high-risk and needs the owner.

    python3 infra/ia/clasificar_riesgo.py --tipo prompt --antes A --despues B
    exit 0: bajo | sin_cambios      exit 3: alto
"""
import argparse
import json
import re
import sys
import unicodedata
from difflib import unified_diff

# Group -> terms. A changed line containing any term makes the change high-risk.
PROTECTED = {
    "precio": [
        "precio", "tasa", "monto", "costo", "comision", "descuento",
        "cotizacion", "pago", "pagar", "deposito", "saldo", "recarga",
        "divisa", "usd", "eur", "mlc", "cup", "gyd", "mxn", "zelle",
    ],
    "humano": [
        "humano", "deriv", "asignar", "asignacion", "cerrar", "cancelar",
        "completar", "verificar", "confirmar", "aprobar", "rechazar",
        "entregar",
    ],
    "herramienta": [
        "registrar_", "cancelar_", "crear_", "modificar_", "consultar_",
        "herramienta", "tool", "funcion", "rpc",
    ],
    "seguridad": [
        "contrasena", "token", "secreto", "admin", "permiso",
        "autorizacion", "seguridad", "instrucciones internas",
    ],
    "calculo": [
        "sumar", "restar", "multiplicar", "dividir", "formula", "calculo",
        "total", "subtotal",
    ],
}


def normalizar(texto: str) -> str:
    """Lowercase and strip accents so 'depósito' and 'deposito' match."""
    plano = unicodedata.normalize("NFKD", texto)
    return "".join(c for c in plano if not unicodedata.combining(c)).lower()


def lineas_cambiadas(antes: str, despues: str) -> list[str]:
    cambios = []
    for linea in unified_diff(antes.splitlines(), despues.splitlines(), lineterm=""):
        if linea.startswith(("+++", "---", "@@")):
            continue
        if linea.startswith(("+", "-")):
            cambios.append(normalizar(linea[1:]))
    return cambios


def clasificar(antes: str, despues: str, tipo: str) -> dict:
    if tipo != "prompt":
        return {
            "riesgo": "alto",
            "motivos": [f"{tipo}: solo se auto-aplican cambios del prompt"],
            "lineas_cambiadas": len(lineas_cambiadas(antes, despues)),
        }

    if antes == despues:
        return {"riesgo": "sin_cambios", "motivos": [], "lineas_cambiadas": 0}

    cambios = lineas_cambiadas(antes, despues)
    if not cambios:
        return {
            "riesgo": "alto",
            "motivos": ["texto distinto sin lineas de contenido comparables"],
            "lineas_cambiadas": 0,
        }

    motivos = []
    for grupo, terminos in PROTECTED.items():
        for termino in terminos:
            patron = re.compile(r"\b" + re.escape(termino))
            if any(patron.search(linea) for linea in cambios):
                motivos.append(f"{grupo}: {termino}")

    return {
        "riesgo": "alto" if motivos else "bajo",
        "motivos": sorted(set(motivos)),
        "lineas_cambiadas": len(cambios),
    }


def main() -> int:
    p = argparse.ArgumentParser(description="Risk gate for nightly prompt changes")
    p.add_argument("--tipo", default="prompt", choices=["prompt", "decisor", "codigo"])
    p.add_argument("--antes", required=True)
    p.add_argument("--despues", required=True)
    args = p.parse_args()

    antes = open(args.antes, encoding="utf-8").read()
    despues = open(args.despues, encoding="utf-8").read()
    resultado = clasificar(antes, despues, args.tipo)
    json.dump(resultado, sys.stdout, ensure_ascii=False, sort_keys=True)
    sys.stdout.write("\n")
    return 3 if resultado["riesgo"] == "alto" else 0


if __name__ == "__main__":
    sys.exit(main())
