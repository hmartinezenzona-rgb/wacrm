#!/usr/bin/env python3
"""Eval gate and (optionally) production apply for a nightly candidate.

Only a low-risk candidate may run. The gold battery must end all green
(evaluar.py exit 0); then, with --aplicar, desplegar_prompt.py writes its
own ROLLBACK first and verifies COINCIDE.

    python3 infra/ia/aplicar_candidato.py --candidato C --riesgo bajo
    python3 infra/ia/aplicar_candidato.py --candidato C --riesgo bajo --aplicar
"""
import argparse
import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

EVALS = Path.home() / "cerebro-fase1" / "pruebas" / "evals"
ESTADO = Path.home() / "cerebro-fase1" / "mejora-nocturna" / "estado.json"
ROLLBACK = Path.home() / "cerebro-fase1"


def error(msg: str) -> "NoReturn":  # noqa: F821
    print(msg, file=sys.stderr)
    raise SystemExit(2)


def escribir_estado(ruta: Path, datos: dict) -> None:
    ruta.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(ruta.parent, 0o700)
    ruta.write_text(json.dumps(datos, ensure_ascii=False, indent=1), encoding="utf-8")
    os.chmod(ruta, 0o600)


def main() -> int:
    p = argparse.ArgumentParser(description="Eval gate and apply for a nightly candidate")
    p.add_argument("--candidato", type=Path, required=True)
    p.add_argument("--riesgo", choices=["bajo", "alto"], required=True)
    p.add_argument("--evals-dir", type=Path, default=EVALS)
    p.add_argument("--casos", default="casos/casos-conversaciones.json")
    p.add_argument("--reps", type=int, default=5)
    p.add_argument("--etiqueta", default=f"nocturna-{datetime.now(timezone.utc):%Y%m%d}")
    p.add_argument("--estado", type=Path, default=ESTADO)
    p.add_argument("--timeout", type=int, default=5400)
    p.add_argument("--aplicar", action="store_true", help="deploy to production after a green eval")
    args = p.parse_args()

    if args.riesgo != "bajo":
        error("rechazado: solo un candidato de riesgo bajo puede pasar a la compuerta")
    if not args.candidato.is_file():
        error(f"falta el candidato {args.candidato}")
    if not args.evals_dir.is_dir():
        error(f"falta el arnes de evals en {args.evals_dir}")

    estado = {
        "fecha": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "etiqueta": args.etiqueta,
        "candidato": str(args.candidato.resolve()),
        "riesgo": args.riesgo,
        "reps": args.reps,
        "casos": args.casos,
        "estado": "corriendo",
    }
    escribir_estado(args.estado, estado)

    eval_log = args.estado.parent / f"eval-{args.etiqueta}.log"
    eval_cmd = [sys.executable, "evaluar.py", "--casos", args.casos,
                "--reps", str(args.reps), "--prompt", str(args.candidato.resolve())]
    try:
        r = subprocess.run(eval_cmd, cwd=args.evals_dir, capture_output=True,
                           text=True, timeout=args.timeout)
    except subprocess.TimeoutExpired:
        estado.update({"estado": "rechazado", "motivo": f"eval excedio {args.timeout}s"})
        escribir_estado(args.estado, estado)
        error("eval excedio el tiempo limite")

    eval_log.parent.mkdir(parents=True, exist_ok=True)
    eval_log.write_text((r.stdout or "") + (r.stderr or ""), encoding="utf-8")
    os.chmod(eval_log, 0o600)
    estado.update({"eval_exit": r.returncode, "eval_log": str(eval_log)})

    if r.returncode != 0:
        estado["estado"] = "rechazado"
        estado["motivo"] = "la bateria no quedo verde"
        escribir_estado(args.estado, estado)
        print(f"ok estado=rechazado eval_exit={r.returncode} log={eval_log}")
        return 1

    if not args.aplicar:
        estado["estado"] = "listo"
        escribir_estado(args.estado, estado)
        print(f"ok estado=listo eval_exit=0 log={eval_log}")
        return 0

    deploy_cmd = [sys.executable, "desplegar_prompt.py",
                  "--candidato", str(args.candidato.resolve()), "--etiqueta", args.etiqueta]
    try:
        d = subprocess.run(deploy_cmd, cwd=args.evals_dir, capture_output=True,
                           text=True, timeout=300)
    except subprocess.TimeoutExpired:
        estado.update({"estado": "error_despliegue", "motivo": "despliegue excedio 300s"})
        escribir_estado(args.estado, estado)
        error("el despliegue excedio el tiempo limite")

    ok = d.returncode == 0 and "COINCIDE" in (d.stdout or "")
    rollback = ROLLBACK / f"ROLLBACK-v2-antes-{args.etiqueta}.json"
    estado.update({
        "estado": "aplicado" if ok else "error_despliegue",
        "deploy_exit": d.returncode,
        "rollback": str(rollback),
    })
    if not ok:
        estado["motivo"] = (d.stderr or d.stdout or "").strip()[-300:]
    escribir_estado(args.estado, estado)
    if not ok:
        error("el despliegue no confirmo COINCIDE")
    print(f"ok estado=aplicado eval_exit=0 rollback={rollback}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
