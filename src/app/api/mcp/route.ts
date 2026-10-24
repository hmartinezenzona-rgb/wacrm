// ============================================================
// POST /api/mcp — read-only MCP endpoint for Hermes
//
// Hermes (the admin business assistant) connects here with
// `hermes mcp add` and gets the six read-only CRM tools registered in
// src/lib/hermes/mcp-tools.ts. Streamable HTTP, stateless (one server per
// request), JSON responses. Auth: a bearer token compared in constant time
// against cerebro_config.notify_secret for v1.
// ============================================================

import { timingSafeEqual } from 'node:crypto';

import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { WebStandardStreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/webStandardStreamableHttp.js';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { NextResponse } from 'next/server';

import { buildHermesServer } from '@/lib/hermes/mcp-tools';

export const runtime = 'nodejs';
export const maxDuration = 60;

function adminClient(): SupabaseClient {
  return createClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.SUPABASE_SERVICE_ROLE_KEY!,
    { auth: { persistSession: false } },
  );
}

function sameSecret(given: string, expected: string): boolean {
  const a = Buffer.from(given, 'utf8');
  const b = Buffer.from(expected, 'utf8');
  if (!a.length || a.length !== b.length) return false;
  return timingSafeEqual(a, b);
}

export async function POST(request: Request): Promise<Response> {
  const db = adminClient();
  const bearer = (request.headers.get('authorization') ?? '').replace(/^Bearer\s+/i, '').trim();

  const { data: config, error: configError } = await db
    .from('cerebro_config')
    .select('valor')
    .eq('clave', 'notify_secret')
    .maybeSingle();
  if (configError) {
    console.error('[hermes mcp] secret read failed:', configError);
    return NextResponse.json({ error: 'secret read failed' }, { status: 500 });
  }
  if (!config?.valor || !sameSecret(bearer, config.valor)) {
    return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
  }

  const server: McpServer = buildHermesServer(db);
  const transport = new WebStandardStreamableHTTPServerTransport({
    sessionIdGenerator: undefined,
    enableJsonResponse: true,
  });
  await server.connect(transport);
  return transport.handleRequest(request);
}

export function GET(): Response {
  return NextResponse.json(
    { error: 'Use POST (MCP streamable HTTP, stateless).' },
    { status: 405, headers: { Allow: 'POST' } },
  );
}
