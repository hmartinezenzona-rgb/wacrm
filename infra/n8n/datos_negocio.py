#!/usr/bin/env python3
"""Drift check for the business data the bot gives to customers.

The deposit account, its holder, the Pay Merchant number and the business name are typed by hand
in more than one production n8n workflow:

  * Cerebro (reference): node "Datos del negocio", read by the agent, the Decisor and vision.
  * Verificar comprobante (lectura) - produccion: its own copy of "Datos del negocio".
  * Tool - Tutorial Pay Merchant: the Pay Merchant number written inside a message.

If one copy is changed and another is forgotten, the bot states one account and checks receipts
against another. This command reads the workflows (GET only) and exits 1 when the copies differ.
Account numbers are printed masked (last two digits).

Usage:
    python3 infra/n8n/datos_negocio.py verificar
"""
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import cerebro_n8n as c  # noqa: E402

NODO = "Datos del negocio"
REFERENCIA = ("Cerebro produccion", "jEzlVLCLUaJhVwzs")
# Workflows that carry their own "Datos del negocio" node.
COPIAS = {
    "Verificar comprobante produccion": "5rzWWVJBquDpRkUl",
}
# Workflows that carry one value as text: label -> (workflow id, dotted field of the reference).
LITERALES = {
    "Tutorial Pay Merchant": ("5zVu4JWsIe9LkrJ9", "app.pay_merchant"),
}


def leer_datos(workflow: dict):
    """The parsed JSON of the "Datos del negocio" node, or None when the workflow has no such node."""
    for n in workflow.get("nodes", []):
        if n.get("name") == NODO:
            return json.loads(n["parameters"]["jsonOutput"])
    return None


def enmascarar(valor) -> str:
    """Numbers keep their last two digits; names are shown as they are."""
    s = str(valor)
    if re.fullmatch(r"[\d\s+\-]{4,}", s):
        return "*" * (len(s) - 2) + s[-2:]
    return s


def _hojas(d: dict, prefijo=""):
    for k, v in d.items():
        if isinstance(v, dict):
            yield from _hojas(v, f"{prefijo}{k}.")
        else:
            yield f"{prefijo}{k}", v


def _campo(d: dict, ruta: str):
    for parte in ruta.split("."):
        if not isinstance(d, dict) or parte not in d:
            return None
        d = d[parte]
    return d


def comparar(referencia: dict, copias: dict, literales: dict) -> list:
    """Differences against the reference, as printable lines. Empty list = every copy matches.

    copias:    label -> workflow that should carry a "Datos del negocio" node. Only the fields the
               copy has are compared (a copy may hold fewer fields than the reference).
    literales: label -> (workflow, dotted field) whose reference value must appear in the workflow.
    """
    difs = []
    for etiqueta, wf in copias.items():
        datos = leer_datos(wf)
        if datos is None:
            difs.append(f"{etiqueta}: no tiene el nodo «{NODO}»")
            continue
        for ruta, valor in _hojas(datos):
            esperado = _campo(referencia, ruta)
            if esperado != valor:
                difs.append(f"{etiqueta}: {ruta} = {enmascarar(valor)}, "
                            f"la referencia tiene {enmascarar(esperado) if esperado is not None else '(nada)'}")
    for etiqueta, (wf, ruta) in literales.items():
        esperado = _campo(referencia, ruta)
        if esperado is None:
            difs.append(f"{etiqueta}: la referencia no tiene {ruta}")
        elif str(esperado) not in json.dumps([n.get("parameters", {}) for n in wf.get("nodes", [])],
                                             ensure_ascii=False):
            difs.append(f"{etiqueta}: no contiene {ruta} de la referencia ({enmascarar(esperado)})")
    return difs


def cmd_verificar() -> int:
    base, key = c.get_base_url(), c.load_api_key()

    def bajar(wid):
        return c.api_request("GET", f"/api/v1/workflows/{wid}", base, key)

    ref_wf = bajar(REFERENCIA[1])
    referencia = leer_datos(ref_wf)
    if referencia is None:
        print(f"ERROR: {REFERENCIA[0]} no tiene el nodo «{NODO}»")
        return 1
    copias = {k: bajar(v) for k, v in COPIAS.items()}
    literales = {k: (bajar(wid), ruta) for k, (wid, ruta) in LITERALES.items()}
    print(f"referencia: {REFERENCIA[0]}")
    for ruta, valor in _hojas(referencia):
        print(f"  {ruta}: {enmascarar(valor)}")
    for etiqueta, wf in list(copias.items()) + [(k, v[0]) for k, v in literales.items()]:
        print(f"copia: {etiqueta} (activo: {str(wf.get('active', False)).lower()})")
    difs = comparar(referencia, copias, literales)
    if difs:
        print("DIFERENCIAS:")
        for d in difs:
            print(f"  - {d}")
        return 1
    print("OK: todas las copias coinciden con la referencia")
    return 0


if __name__ == "__main__":
    if sys.argv[1:] != ["verificar"]:
        print(__doc__)
        sys.exit(2)
    sys.exit(cmd_verificar())
