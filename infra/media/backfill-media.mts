#!/usr/bin/env node
// ============================================================
// Backfill of message media metadata (migration 400) for history.
//
//   node --experimental-strip-types infra/media/backfill-media.mts \
//     --env ~/.config/wacrm/staging-service.env --dry-run
//
// Flags:
//   --env <file>     env file with NEXT_PUBLIC_SUPABASE_URL and
//                    SUPABASE_SERVICE_ROLE_KEY (required; never printed)
//   --dry-run        count only, write nothing
//   --batch <n>      rows per batch (default 200)
//   --sleep-ms <n>   pause between batches (default 0)
//   --limit <n>      stop after n rows
//   --after <id>     resume after this message id (created_at is read from
//                    the row, so a resume never re-processes a batch)
//
// Node must be >= 22.6 for --experimental-strip-types; the script checks and
// refuses to run otherwise. Originals are never re-encoded: the only writes
// are the new WebP siblings and migration 400's columns.
// ============================================================

import { readFileSync } from 'node:fs';
import { createClient } from '@supabase/supabase-js';

import {
  runBackfill,
  type BackfillDb,
  type BackfillRow,
  type BackfillStorage,
  type Cursor,
} from '../../src/lib/storage/media-backfill.ts';

const MIN_NODE = [22, 6] as const;

function checkNode(): void {
  const [major = 0, minor = 0] = process.versions.node.split('.').map(Number);
  const ok =
    major > MIN_NODE[0] || (major === MIN_NODE[0] && minor >= MIN_NODE[1]);
  if (!ok) {
    console.error(
      `Node ${process.versions.node} no sirve: hace falta >= ${MIN_NODE.join('.')} para --experimental-strip-types`,
    );
    process.exit(2);
  }
}

interface Args {
  env: string;
  dryRun: boolean;
  batch: number;
  sleepMs: number;
  limit?: number;
  after?: string;
}

function parseArgs(argv: string[]): Args {
  const args: Args = { env: '', dryRun: false, batch: 200, sleepMs: 0 };
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
      case '--batch': args.batch = Number(next()); break;
      case '--sleep-ms': args.sleepMs = Number(next()); break;
      case '--limit': args.limit = Number(next()); break;
      case '--after': args.after = next(); break;
      case '--help':
        console.log(
          'uso: backfill-media.mts --env <file> [--dry-run] [--batch n] [--sleep-ms n] [--limit n] [--after <message id>]',
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

/** Minimal KEY=value reader; the file is never echoed. */
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

const BUCKET = 'chat-media';

function buildDeps(url: string, key: string) {
  const client = createClient(url, key, { auth: { persistSession: false } });
  const bucket = client.storage.from(BUCKET);

  const db: BackfillDb = {
    async selectBatch(after: Cursor | null, limit: number): Promise<BackfillRow[]> {
      let query = client
        .from('messages')
        .select('id, media_url, content_type, created_at')
        .is('media_status', null)
        .like('media_url', '%/chat-media/%')
        .order('created_at', { ascending: true })
        .order('id', { ascending: true })
        .limit(limit);
      if (after) {
        query = query.or(
          `created_at.gt.${after.createdAt},and(created_at.eq.${after.createdAt},id.gt.${after.id})`,
        );
      }
      const { data, error } = await query;
      if (error) throw error;
      return (data ?? []) as BackfillRow[];
    },
    async markReady(id, values) {
      const { error } = await client.from('messages').update(values)
        .eq('id', id)
        .is('media_status', null);
      if (error) throw error;
    },
    async markFailed(id, message) {
      const { error } = await client
        .from('messages')
        .update({ media_status: 'failed', media_error: message })
        .eq('id', id)
        .is('media_status', null);
      if (error) throw error;
    },
  };

  const storage: BackfillStorage = {
    async list(prefix, { limit, offset }) {
      const { data, error } = await bucket.list(prefix, { limit, offset });
      if (error) return { names: [], hasMore: false, error: error.message };
      const names = (data ?? [])
        .filter((entry) => entry.id !== null)
        .map((entry) => entry.name);
      return { names, hasMore: (data ?? []).length === limit };
    },
    async download(path) {
      const { data, error } = await bucket.download(path);
      if (error || !data) return null;
      return Buffer.from(await data.arrayBuffer());
    },
    async upload(path, bytes, options) {
      const { error } = await bucket.upload(path, bytes, {
        contentType: options.contentType,
        upsert: options.upsert,
      });
      return error ? { error: error.message } : {};
    },
  };

  return { db, storage, client };
}

async function main(): Promise<void> {
  checkNode();
  const args = parseArgs(process.argv.slice(2));
  const env = readEnvFile(args.env);
  const url = env.NEXT_PUBLIC_SUPABASE_URL;
  const key = env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !key) {
    console.error('el fichero de entorno no tiene NEXT_PUBLIC_SUPABASE_URL y SUPABASE_SERVICE_ROLE_KEY');
    process.exit(2);
  }

  const { db, storage, client } = buildDeps(url, key);

  // Resume: the cursor is (created_at, id), so the row is looked up by id.
  let after: Cursor | null = null;
  if (args.after) {
    const { data: resumed } = await client
      .from('messages')
      .select('created_at')
      .eq('id', args.after)
      .maybeSingle();
    if (!resumed) {
      console.error(`--after ${args.after}: no existe ese mensaje`);
      process.exit(2);
    }
    after = { createdAt: (resumed as { created_at: string }).created_at, id: args.after };
  }

  console.log(
    `backfill ${args.dryRun ? '(dry run)' : ''} batch=${args.batch} sleep=${args.sleepMs}ms`,
  );

  const result = await runBackfill(
    { db, storage, dryRun: args.dryRun },
    {
      batchSize: args.batch,
      sleepMs: args.sleepMs,
      limit: args.limit,
      after,
      onBatch: (batch, total) => {
        console.log(
          `  lote: ${batch.scanned} filas | ${JSON.stringify(batch.counters)}`,
        );
        void total;
      },
    },
  );

  console.log(JSON.stringify({ ...result, dryRun: args.dryRun }, null, 2));
}

main().catch((err) => {
  console.error('backfill falló:', err instanceof Error ? err.message : err);
  process.exit(1);
});
