# Production Cerebro snapshots

Full exports of the production Cerebro workflow (`jEzlVLCLUaJhVwzs`) at known-good points, so the
bot can be restored together with the code of the same commit. Exports carry credential ids and
names only, never secret values.

| File | versionId | Decisor md5 | Nodes | Point |
|---|---|---|---|---|
| `produccion-cerebro-8faa133b-20261028.json` | `8faa133b` | `7909d4f8` | 128 | Oct-19 bot restored on 2026-10-27 + multi-Zelle, shortfall note, `repartir_envio`, saldo fixes 343-347, away notice and brevity (2026-10-28). Git tag `punto-bueno-2026-10-28`. |
| `produccion-cerebro-bb175eda-20261028.json` | `bb175eda` | `a6ae5ae5` | 128 | The point above + fixed `Liberar chat` (tasas view) and `Registrar deposito auto` (310 admin wrapper), written TransID verification, and phase 1 format (no MMG app, no time promises, currency, usted). Published without the gold battery at the owner's request: watch real conversations before treating it as known-good. |
| `produccion-cerebro-0922ab9f-20261028.json` | `0922ab9f` | `0a31fc73` | 128 | Phase 2 format: one datum per line, one question last, bold only amounts/states, no emojis, grouped multi-recipient confirmation, group link once to new customers (`Contexto conversacion.grupo_enviado`), "5 mil pesos" as GYD, mandatory hours line on closed deposit turns. Published without the battery at the owner's request. Prompt copy `prompt-agente-remesas-0922ab9f-20261028.txt`. |
| `produccion-cerebro-6feb0fd1-20261028.json` | `6feb0fd1` | `982b147c` | 128 | Phase 2 + fixes from the first real reply: confirmations carry the exact data lines (Zelle, card/phone) and no "una vez hecha su remesa" while a recipient datum is missing (also in the duplicate-receipt note). |

Restore (backup first, then owner go-ahead):

```bash
python3 infra/n8n/cerebro_n8n.py estado produccion
python3 infra/n8n/cerebro_n8n.py respaldo produccion
python3 infra/n8n/cerebro_n8n.py restaurar produccion infra/n8n/snapshots/<file> --esperado <live versionId prefix>
```
