#!/usr/bin/env node
// ============================================================
// 90-day retention for chat media.
//
//   node --experimental-strip-types infra/media/retention-media.mts \
//     --env ~/.config/wacrm/staging-service.env --dry-run
//
// Flags:
//   --env <file>              env file with NEXT_PUBLIC_SUPABASE_URL and
//                             SUPABASE_SERVICE_ROLE_KEY (never printed)
//   --dry-run                 count only, delete nothing
//   --older-than-days <n>     window (default 90)
//   --batch <n>               objects per list page (default 200)
//   --cap <n>                 objects deleted per run (default 500)
//   --sleep-ms <n>            pause between accounts (default 0)
//
// Deletion is irreversible. Message rows and media_url are never touched:
// the panel renders the media as unavailable instead.
// ============================================================

import { readFileSync } from 'node:fs';
import { createClient } from '@supabase/supabase-js';

import {
  runRetention,
  type RetentionDb,
  type RetentionStorage,
} from '../../src/lib/storage/media-retention.ts';

const BUCKET = 'chat-media';

interface Args {
  env: string;
  dryRun: boolean;
  olderThanDays: number;
  batch: number;
  cap: number;
  sleepMs: number;
}

function parseArgs(argv: string[]): Args {
  const args: Args = {
    env: '',
    dryRun: false,
    olderThanDays: 90,
    batch: 200,
    cap: 500,
    sleepMs: 0,
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const next = () => {
      const v = argv[++i];
      if (v === undefined) {
        console.error(`falta el valor de ${a}`);
        process.exit(2);
      }
      return v;
    };
    switch (a) {
      case '--env': args.env = next(); break;
      case '--dry-run': args.dryRun = true; break;
      case '--older-than-days': args.olderThanDays = Number(next()); break;
      case '--batch': args.batch = Number(next()); break;
      case '--cap': args.cap = Number(next()); break;
      case '--sleep-ms': args.sleepMs = Number(next()); break;
      case '--help':
        console.log(
          'uso: retention-media.mts --env <file> [--dry-run] [--older-than-days 90] [--batch 200] [--cap 500] [--sleep-ms 0]',
        );
        process.exit(0);
        break;
      default:
        console.error(`argumento desconocido: ${a}`);
        process.exit(2);
    }
  }
  if (!args.env) {
    console.error('falta --env <file>');
    process.exit(2);
  }
  return args;
}

function readEnvFile(path: string): Record<string, string> {
  let raw: string;
  try {
    raw = readFileSync(path, 'utf8');
  } catch {
    console.error(`no se pudo leer el fichero de entorno: ${path}`);
    process.exit(2);
  }
  const out: Record<string, string> = {};
  for (const line of raw.split('\n')) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const eq = trimmed.indexOf('=');
    if (eq <= 0) continue;
    const key = trimmed.slice(0, eq).replace(/^export\s+/, '').trim();
    out[key] = trimmed.slice(eq + 1).trim().replace(/^["']|["']$/g, '');
  }
  return out;
}

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));
  const env = readEnvFile(args.env);
  const url = env.NEXT_PUBLIC_SUPABASE_URL;
  const key = env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !key) {
    console.error('el fichero de entorno no tiene NEXT_PUBLIC_SUPABASE_URL y SUPABASE_SERVICE_ROLE_KEY');
    process.exit(2);
  }

  const client = createClient(url, key, { auth: { persistSession: false } });
  const bucket = client.storage.from(BUCKET);

  const db: RetentionDb = {
    async listAccountPrefixes() {
      const { data, error } = await client.from('accounts').select('id');
      if (error) throw error;
      return (data ?? []).map((row) => `account-${(row as { id: string }).id}`);
    },
  };

  const storage: RetentionStorage = {
    async list(prefix, { limit, offset }) {
      const { data, error } = await bucket.list(prefix, { limit, offset });
      if (error) return { entries: [], hasMore: false, error: error.message };
      const entries = (data ?? [])
        .filter((entry) => entry.id !== null)
        .map((entry) => ({
          name: entry.name,
          createdAt: entry.created_at ?? entry.updated_at ?? null,
        }));
      return { entries, hasMore: (data ?? []).length === limit };
    },
    async remove(paths) {
      const { error } = await bucket.remove(paths);
      return error ? { error: error.message } : {};
    },
  };

  console.log(
    `retención ${args.dryRun ? '(dry run)' : ''} ventana=${args.olderThanDays}d cap=${args.cap}`,
  );
  const result = await runRetention(storage, db, {
    olderThanDays: args.olderThanDays,
    batchSize: args.batch,
    cap: args.cap,
    dryRun: args.dryRun,
  });
  console.log(JSON.stringify(result, null, 2));
}

main().catch((err) => {
  console.error('retención falló:', err instanceof Error ? err.message : err);
  process.exit(1);
});
