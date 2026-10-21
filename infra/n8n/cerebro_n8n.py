#!/usr/bin/env python3
"""CLI to back up, inspect, compare, publish, and restore the Cerebro n8n workflow."""

import argparse
import hashlib
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime
from pathlib import Path

# Environment name -> workflow ID
WORKFLOWS = {
    "staging": "U52y1kSNvhgxvWeb",
    "produccion": "jEzlVLCLUaJhVwzs",
}

DEFAULT_BASE_URL = "https://automatizaciones-n8n.ttjgax.easypanel.host"
HTTP_TIMEOUT = 30
MIN_ESPERADO_LEN = 4
LOCAL_HOSTS = ("127.0.0.1", "localhost")


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Never follow redirects: urllib would resend the API key header to the new location."""

    def redirect_request(self, *args, **kwargs):
        return None


_OPENER = urllib.request.build_opener(_NoRedirect)


def check_esperado(value: str) -> None:
    """Refuse an empty or too-short guard prefix (an empty prefix matches everything)."""
    if len(value) < MIN_ESPERADO_LEN:
        print(f"REFUSED: --esperado needs at least {MIN_ESPERADO_LEN} characters", file=sys.stderr)
        sys.exit(2)


def get_base_url() -> str:
    """Return the n8n base URL from env var or default."""
    base = os.environ.get("CEREBRO_N8N_BASE", DEFAULT_BASE_URL).rstrip("/")
    host = urllib.parse.urlsplit(base).hostname
    if not base.startswith("https://") and host not in LOCAL_HOSTS:
        print("error: the n8n base URL must use https (plain http only for localhost)", file=sys.stderr)
        sys.exit(2)
    return base


def get_backups_dir() -> Path:
    """Return the backups directory path, creating it with parents if needed."""
    raw = os.environ.get(
        "CEREBRO_N8N_BACKUPS",
        str(Path.home() / "cerebro-fase1" / "respaldos-n8n"),
    )
    d = Path(raw)
    d.mkdir(parents=True, exist_ok=True)
    return d


def get_decisor_file() -> Path:
    """Return the path to the repo Decisor source file."""
    env_val = os.environ.get("CEREBRO_DECISOR_FILE")
    if env_val:
        return Path(env_val)
    # Default: repo root (two dirs above this script) / pruebas/decisor/decisor.jscode
    script_dir = Path(__file__).resolve().parent
    repo_root = script_dir.parent.parent
    return repo_root / "pruebas" / "decisor" / "decisor.jscode"


def load_api_key() -> str:
    """Read the n8n API key from ~/.n8n-api-key. Exit 1 if missing."""
    key_path = Path.home() / ".n8n-api-key"
    if not key_path.exists():
        print("error: API key file not found at ~/.n8n-api-key", file=sys.stderr)
        sys.exit(1)
    return key_path.read_text().strip()


def resolve_env(env_name: str) -> str:
    """Map environment name to workflow ID. Exit 2 for unknown names."""
    if env_name not in WORKFLOWS:
        print(
            f"error: unknown environment '{env_name}'; valid: {', '.join(sorted(WORKFLOWS))}",
            file=sys.stderr,
        )
        sys.exit(2)
    return WORKFLOWS[env_name]


def api_request(method: str, path: str, base_url: str, api_key: str, body=None) -> dict:
    """Perform an HTTP request to the n8n API and return parsed JSON.

    Never includes the API key in error messages or URLs.
    """
    url = f"{base_url}{path}"
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("X-N8N-API-KEY", api_key)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with _OPENER.open(req, timeout=HTTP_TIMEOUT) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        print(f"error: HTTP {exc.code} on {method} {path}", file=sys.stderr)
        sys.exit(1)
    except urllib.error.URLError as exc:
        print(f"error: connection failed: {exc.reason}", file=sys.stderr)
        sys.exit(1)
    except (ValueError, TimeoutError) as exc:
        print(f"error: bad or slow response on {method} {path}: {type(exc).__name__}", file=sys.stderr)
        sys.exit(1)


def find_decisor_node(workflow: dict) -> dict:
    """Return the single node named 'Decisor'. Exit 1 if not exactly one."""
    matches = [n for n in workflow.get("nodes", []) if n.get("name") == "Decisor"]
    if len(matches) != 1:
        print(
            f"error: expected exactly one 'Decisor' node, found {len(matches)}",
            file=sys.stderr,
        )
        sys.exit(1)
    return matches[0]


def md5_text(text: str) -> str:
    """Return the md5 hex digest of a UTF-8 string."""
    return hashlib.md5(text.encode("utf-8")).hexdigest()


def write_backup(workflow: dict, env_name: str, backups_dir: Path) -> Path:
    """Write a workflow as a timestamped JSON backup. Returns the file path."""
    wid = workflow["id"]
    vid = workflow["versionId"]
    ts = datetime.now().strftime("%Y%m%d-%H%M%S")
    filename = f"{env_name}-{wid}-{vid}-{ts}.json"
    path = backups_dir / filename
    # Backups contain prompts and credential ids: owner-only, never overwrite an existing file.
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(workflow, fh, indent=1, ensure_ascii=False)
    return path


def node_fingerprint(node: dict) -> str:
    """Compute the 8-char md5 fingerprint used for node comparison."""
    params = node.get("parameters", {})
    ntype = node.get("type", "")
    if ntype == "n8n-nodes-base.code":
        return md5_text(params.get("jsCode", ""))[:8]
    if ntype == "n8n-nodes-base.postgres":
        return md5_text(params.get("query", ""))[:8]
    canonical = json.dumps(params, sort_keys=True)
    return md5_text(canonical)[:8]


# --- Command handlers ---


def cmd_respaldo(args) -> int:
    """Download and save a workflow backup."""
    wid = resolve_env(args.env)
    api_key = load_api_key()
    base = get_base_url()
    wf = api_request("GET", f"/api/v1/workflows/{wid}", base, api_key)
    backups_dir = get_backups_dir()
    path = write_backup(wf, args.env, backups_dir)
    print(f"backup: {path}")
    print(f"versionId: {wf['versionId']}")
    return 0


def cmd_estado(args) -> int:
    """Print workflow status including version info and Decisor md5."""
    wid = resolve_env(args.env)
    api_key = load_api_key()
    base = get_base_url()
    wf = api_request("GET", f"/api/v1/workflows/{wid}", base, api_key)

    decisor = find_decisor_node(wf)
    dec_md5 = md5_text(decisor["parameters"]["jsCode"])

    decisor_file = get_decisor_file()
    repo_md5 = hashlib.md5(decisor_file.read_bytes()).hexdigest()

    print(f"versionId: {wf['versionId']}")
    print(f"activeVersionId: {wf['activeVersionId']}")
    print(f"active: {str(wf.get('active', False)).lower()}")
    print(f"nodes: {len(wf.get('nodes', []))}")
    print(f"decisor_md5: {dec_md5[:8]}")
    print(f"repo_md5_match: {'yes' if dec_md5 == repo_md5 else 'no'}")
    if wf["versionId"] != wf["activeVersionId"]:
        print("WARNING: versionId != activeVersionId — MISMATCH")
    return 0


def cmd_comparar(_args) -> int:
    """Compare staging and produccion node-by-node (read-only)."""
    api_key = load_api_key()
    base = get_base_url()

    stg = api_request("GET", f"/api/v1/workflows/{WORKFLOWS['staging']}", base, api_key)
    prod = api_request("GET", f"/api/v1/workflows/{WORKFLOWS['produccion']}", base, api_key)

    stg_nodes = {n["name"]: n for n in stg.get("nodes", [])}
    prod_nodes = {n["name"]: n for n in prod.get("nodes", [])}

    lines: list[str] = []

    for name in sorted(set(stg_nodes) - set(prod_nodes)):
        lines.append(f"only staging: {name}")
    for name in sorted(set(prod_nodes) - set(stg_nodes)):
        lines.append(f"only produccion: {name}")

    for name in sorted(set(stg_nodes) & set(prod_nodes)):
        sn, pn = stg_nodes[name], prod_nodes[name]
        if sn.get("parameters") != pn.get("parameters"):
            sf = node_fingerprint(sn)
            pf = node_fingerprint(pn)
            lines.append(f"differs: {name} staging={sf} produccion={pf}")

    if lines:
        for line in sorted(lines):
            print(line)
    else:
        print("no differences")
    return 0


def cmd_publicar_decisor(args) -> int:
    """Publish the repo Decisor code to a workflow after safety checks."""
    wid = resolve_env(args.env)
    check_esperado(args.esperado)
    api_key = load_api_key()
    base = get_base_url()

    wf = api_request("GET", f"/api/v1/workflows/{wid}", base, api_key)
    decisor = find_decisor_node(wf)
    live_md5 = md5_text(decisor["parameters"]["jsCode"])

    if not live_md5.startswith(args.esperado):
        print(f"REFUSED: live Decisor md5 {live_md5[:8]} does not start with '{args.esperado}'")
        return 2

    # Backup BEFORE the PUT
    backups_dir = get_backups_dir()
    write_backup(wf, args.env, backups_dir)

    # Read repo Decisor source
    repo_code = get_decisor_file().read_text(encoding="utf-8")
    repo_md5 = md5_text(repo_code)

    # Replace only the Decisor jsCode
    for node in wf["nodes"]:
        if node["name"] == "Decisor":
            node["parameters"]["jsCode"] = repo_code

    # PUT with only the allowed keys
    body = {
        "name": wf["name"],
        "nodes": wf["nodes"],
        "connections": wf["connections"],
        "settings": wf.get("settings", {}),
    }
    api_request("PUT", f"/api/v1/workflows/{wid}", base, api_key, body=body)

    # Verify
    wf2 = api_request("GET", f"/api/v1/workflows/{wid}", base, api_key)
    decisor2 = find_decisor_node(wf2)
    new_md5 = md5_text(decisor2["parameters"]["jsCode"])

    errors: list[str] = []
    if wf2["versionId"] != wf2["activeVersionId"]:
        errors.append(
            f"activeVersionId mismatch: versionId={wf2['versionId']} "
            f"activeVersionId={wf2['activeVersionId']}"
        )
    if new_md5 != repo_md5:
        errors.append("Decisor md5 does not match repo file after publish")
    if len(wf2.get("nodes", [])) != len(wf.get("nodes", [])):
        errors.append("node count changed after publish")

    if errors:
        for err in errors:
            print(f"error: {err}", file=sys.stderr)
        return 1

    print(f"versionId: {wf2['versionId']}")
    print("OK")
    return 0


def cmd_restaurar(args) -> int:
    """Restore a workflow from a backup file after safety checks."""
    wid = resolve_env(args.env)
    check_esperado(args.esperado)

    # Validate backup file existence and JSON validity
    backup_path = Path(args.backup)
    if not backup_path.exists():
        print(f"error: backup file not found: {backup_path}", file=sys.stderr)
        return 1
    try:
        backup_wf = json.loads(backup_path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        print(f"error: invalid backup file: {exc}", file=sys.stderr)
        return 1

    missing = [k for k in ("name", "nodes", "connections") if k not in backup_wf]
    if missing:
        print(f"error: backup file lacks keys: {', '.join(missing)}", file=sys.stderr)
        return 1

    # Verify backup belongs to the target workflow
    if backup_wf.get("id") != wid:
        print(f"REFUSED: backup id '{backup_wf.get('id')}' does not match env workflow '{wid}'")
        return 2

    api_key = load_api_key()
    base = get_base_url()

    # GET live workflow to check version prefix
    wf = api_request("GET", f"/api/v1/workflows/{wid}", base, api_key)
    if not wf["versionId"].startswith(args.esperado):
        print(f"REFUSED: live versionId '{wf['versionId']}' does not start with '{args.esperado}'")
        return 2

    # Backup the live state before restoring
    backups_dir = get_backups_dir()
    write_backup(wf, args.env, backups_dir)

    # PUT from backup
    body = {
        "name": backup_wf["name"],
        "nodes": backup_wf["nodes"],
        "connections": backup_wf["connections"],
        "settings": backup_wf.get("settings", {}),
    }
    api_request("PUT", f"/api/v1/workflows/{wid}", base, api_key, body=body)

    # Verify
    wf2 = api_request("GET", f"/api/v1/workflows/{wid}", base, api_key)
    errors: list[str] = []
    if wf2["versionId"] != wf2["activeVersionId"]:
        errors.append(
            f"activeVersionId mismatch after restore: "
            f"versionId={wf2['versionId']} activeVersionId={wf2['activeVersionId']}"
        )
    if len(wf2.get("nodes", [])) != len(backup_wf["nodes"]):
        errors.append("node count differs from the backup after restore")
    backup_decisor = [n for n in backup_wf["nodes"] if n.get("name") == "Decisor"]
    if backup_decisor and md5_text(find_decisor_node(wf2)["parameters"]["jsCode"]) != md5_text(
        backup_decisor[0]["parameters"]["jsCode"]
    ):
        errors.append("Decisor code differs from the backup after restore")
    if errors:
        for err in errors:
            print(f"error: {err}", file=sys.stderr)
        return 1

    print("OK")
    return 0


# --- CLI entry point ---


def main(argv=None) -> int:
    """Parse arguments and dispatch to the appropriate command."""
    parser = argparse.ArgumentParser(description="Cerebro n8n workflow manager")
    sub = parser.add_subparsers(dest="command")

    p_respaldo = sub.add_parser("respaldo", help="Backup a workflow")
    p_respaldo.add_argument("env", help="staging or produccion")

    p_estado = sub.add_parser("estado", help="Show workflow status")
    p_estado.add_argument("env", help="staging or produccion")

    sub.add_parser("comparar", help="Compare staging and produccion")

    p_pub = sub.add_parser("publicar-decisor", help="Publish Decisor code to env")
    p_pub.add_argument("env", help="staging or produccion")
    p_pub.add_argument("--esperado", required=True, help="Expected md5 prefix of live Decisor")

    p_res = sub.add_parser("restaurar", help="Restore workflow from backup")
    p_res.add_argument("env", help="staging or produccion")
    p_res.add_argument("backup", help="Path to backup JSON file")
    p_res.add_argument("--esperado", required=True, help="Expected versionId prefix")

    args = parser.parse_args(argv)

    if args.command is None:
        parser.print_help(sys.stderr)
        return 2

    handlers = {
        "respaldo": cmd_respaldo,
        "estado": cmd_estado,
        "comparar": cmd_comparar,
        "publicar-decisor": cmd_publicar_decisor,
        "restaurar": cmd_restaurar,
    }
    return handlers[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
