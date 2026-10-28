# Production Cerebro snapshots

Full exports of the production Cerebro workflow (`jEzlVLCLUaJhVwzs`) at known-good points, so the
bot can be restored together with the code of the same commit. Exports carry credential ids and
names only, never secret values.

| File | versionId | Decisor md5 | Nodes | Point |
|---|---|---|---|---|
| `produccion-cerebro-8faa133b-20261028.json` | `8faa133b` | `7909d4f8` | 128 | Oct-19 bot restored on 2026-10-27 + multi-Zelle, shortfall note, `repartir_envio`, saldo fixes 343-347, away notice and brevity (2026-10-28). Git tag `punto-bueno-2026-10-28`. |

Restore (backup first, then owner go-ahead):

```bash
python3 infra/n8n/cerebro_n8n.py estado produccion
python3 infra/n8n/cerebro_n8n.py respaldo produccion
python3 infra/n8n/cerebro_n8n.py restaurar produccion infra/n8n/snapshots/<file> --esperado <live versionId prefix>
```
