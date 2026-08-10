/**
 * GUIA-HERMES-webhook-tira-mensajes.md — sección 5.
 *
 * Un webhook cuyo remitente llega sin perfil (contacts vacío o sin
 * `profile`) NO puede tumbar el lote: el contacto se crea con el
 * teléfono como nombre y el mensaje se guarda. Y un mensaje malo no
 * puede tumbar a los demás (try/catch por mensaje).
 */
import crypto from "node:crypto";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { encrypt } from "@/lib/whatsapp/encryption";

// --- Registro de llamadas al cliente fake -------------------------------
// `inserts[tabla]` acumula los payloads insertados; `updates[tabla]`
// acumula { payload, eqs } de los .update(). Los tests lo leen para
// comprobar qué se guardó (y qué no) y el contrato del log.
const inserts: Record<string, unknown[]> = {};
const updates: Record<string, { payload: unknown; eqs: string[] }[]> = {};
let logSeq = 0;

const CONFIG_ROW = {
  id: "cfg1",
  account_id: "acc1",
  user_id: "u1",
  phone_number_id: "1244814475383839",
  access_token: encrypt("fake-token"),
};

vi.mock("next/server", () => ({
  NextResponse: {
    json: (body: unknown, init?: { status?: number }) => ({
      status: init?.status ?? 200,
      body,
    }),
  },
  // Ejecuta el callback en un microtask: el test espera un tick y el
  // procesamiento del webhook ya ha corrido.
  after: (fn: () => unknown) => {
    void Promise.resolve().then(fn);
  },
}));

// normalizePhone lanza SOLO para el teléfono malformado de la prueba 3.
// El resto pasa tal cual (más fácil de verificar en los inserts).
vi.mock("@/lib/whatsapp/phone-utils", () => ({
  normalizePhone: (from: string) => {
    if (from === "5920000000") throw new Error("boom: telefono malformado");
    return from;
  },
}));

vi.mock("@/lib/contacts/dedupe", () => ({
  findExistingContact: vi.fn(async () => null),
  isUniqueViolation: vi.fn(() => false),
}));

vi.mock("@/lib/flows/engine", () => ({
  // Contrato real: siempre { consumed: boolean } — nunca undefined.
  dispatchInboundToFlows: vi.fn(async () => ({ consumed: false })),
}));
vi.mock("@/lib/ai/auto-reply", () => ({
  dispatchInboundToAiReply: vi.fn(async () => undefined),
}));
vi.mock("@/lib/automations/engine", () => ({
  runAutomationsForTrigger: vi.fn(async () => undefined),
}));
vi.mock("@/lib/webhooks/deliver", () => ({
  dispatchWebhookEvent: vi.fn(async () => undefined),
}));
vi.mock("@/lib/whatsapp/template-webhook", () => ({
  handleTemplateWebhookChange: vi.fn(async () => undefined),
  isTemplateWebhookField: vi.fn(() => false),
}));

// --- Cliente supabase fake -------------------------------------------------
function makeBuilder(table: string) {
  const result: { data: unknown[] | null; error: unknown } = {
    data: table === "whatsapp_config" ? [CONFIG_ROW] : null,
    error: null,
  };
  const builder: Record<string, unknown> = {};
  builder.__table = table;
  builder.select = vi.fn(() => builder);
  builder.eq = vi.fn((_col: string, val: unknown) => {
    // Correlacionar updates con su filtro (p.ej. eq('id', logId)).
    const last = updates[table]?.[updates[table].length - 1];
    if (last) last.eqs.push(String(val));
    return builder;
  });
  builder.order = vi.fn(() => builder);
  builder.limit = vi.fn(() => builder);
  builder.onConflict = vi.fn(() => builder);
  builder.single = vi.fn(() => {
    const rows = Array.isArray(result.data) ? result.data : null;
    return Promise.resolve({
      data: rows?.[0] ?? null,
      error:
        result.error ??
        (rows && rows.length > 0 ? null : { code: "PGRST116", message: "no rows" }),
    });
  });
  builder.maybeSingle = vi.fn(() =>
    Promise.resolve({ data: result.data, error: result.error }),
  );
  builder.insert = vi.fn((payload: unknown) => {
    let row = payload;
    if (table === "whatsapp_webhook_log") {
      // La tabla del log devuelve su id — el contrato depende de él.
      row = Array.isArray(payload)
        ? payload.map((p) => ({ ...(p as object), id: `log-${++logSeq}` }))
        : { ...(payload as object), id: `log-${++logSeq}` };
    }
    inserts[table] = [...(inserts[table] ?? []), row];
    result.data = Array.isArray(row) ? row : [row];
    return builder;
  });
  builder.upsert = vi.fn((payload: unknown) => {
    inserts[table] = [...(inserts[table] ?? []), payload];
    result.data = Array.isArray(payload) ? payload : [payload];
    return builder;
  });
  builder.update = vi.fn((payload: unknown) => {
    updates[table] = [...(updates[table] ?? []), { payload, eqs: [] }];
    return builder;
  });
  builder.then = (resolve: (v: unknown) => unknown) =>
    Promise.resolve({ data: result.data, error: result.error }).then(resolve);
  return builder;
}

const builders: Record<string, ReturnType<typeof makeBuilder>> = {};

vi.mock("@supabase/supabase-js", () => ({
  createClient: vi.fn(() => ({
    from: (table: string) =>
      builders[table] ?? (builders[table] = makeBuilder(table)),
  })),
}));

// --- Helpers ----------------------------------------------------------------
const SECRET = process.env.META_APP_SECRET!;

function signedHeader(body: string): string {
  const hex = crypto
    .createHmac("sha256", SECRET)
    .update(body)
    .digest("hex");
  return `sha256=${hex}`;
}

function webhookBody(messages: unknown[], contacts: unknown[] = []): string {
  return JSON.stringify({
    object: "whatsapp_business_account",
    entry: [
      {
        id: "wbiz",
        changes: [
          {
            value: {
              messaging_product: "whatsapp",
              metadata: {
                display_phone_number: "5926990225",
                phone_number_id: "1244814475383839",
              },
              contacts,
              messages,
            },
          },
        ],
      },
    ],
  });
}

function textMessage(from: string, id: string): Record<string, unknown> {
  return { from, id, timestamp: "1754300000", type: "text", text: { body: "Hola" } };
}

async function post(body: string) {
  const { POST } = await import("./route");
  const req = new Request("https://wacrm.test/api/whatsapp/webhook", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-hub-signature-256": signedHeader(body),
    },
    body,
  });
  const res = await POST(req);
  // Deja correr el after() que procesa el webhook.
  await new Promise((r) => setTimeout(r, 50));
  return res;
}

function insertPayloads(table: string): unknown[] {
  return inserts[table] ?? [];
}

// --- Pruebas ----------------------------------------------------------------
describe("webhook route — mensajes sin perfil de remitente", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    Object.keys(inserts).forEach((k) => delete inserts[k]);
    Object.keys(updates).forEach((k) => delete updates[k]);
    logSeq = 0;
  });

  it("1. contacts vacio: crea el contacto con el telefono como nombre y guarda el mensaje", async () => {
    const res = await post(webhookBody([textMessage("5926731279", "wamid.A")], []));

    expect(res.status).toBe(200);
    const contactInserts = insertPayloads("contacts");
    expect(contactInserts).toHaveLength(1);
    expect(contactInserts[0]).toMatchObject({
      account_id: "acc1",
      phone: "5926731279",
      name: "5926731279", // teléfono como nombre
    });
    expect(insertPayloads("messages")).toHaveLength(1);
  });

  it("2. contacts sin profile: mismo resultado", async () => {
    const res = await post(
      webhookBody([textMessage("5926731279", "wamid.B")], [{ wa_id: "5926731279" }]),
    );

    expect(res.status).toBe(200);
    expect(insertPayloads("contacts")).toHaveLength(1);
    expect(insertPayloads("contacts")[0]).toMatchObject({
      phone: "5926731279",
      name: "5926731279",
    });
    expect(insertPayloads("messages")).toHaveLength(1);
  });

  it("3. dos mensajes, el primero malformado: el segundo se guarda igual", async () => {
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    const res = await post(
      webhookBody(
        [
          textMessage("5920000000", "wamid.BAD"), // normalizePhone lanza
          textMessage("5921111111", "wamid.GOOD"),
        ],
        [],
      ),
    );
    // Extraer las llamadas ANTES de restaurar el spy (restore las borra).
    const descartado = errorSpy.mock.calls.find((c) =>
      String(c[0]).includes("mensaje descartado"),
    );
    errorSpy.mockRestore();

    expect(res.status).toBe(200);
    // El malo se descartó con rastro…
    expect(descartado).toBeTruthy();
    expect(JSON.stringify(descartado)).toContain("wamid.BAD");
    // …y el bueno se guardó (message_id identifica el remitente).
    const msgInserts = insertPayloads("messages");
    expect(msgInserts).toHaveLength(1);
    expect(msgInserts[0]).toMatchObject({ message_id: "wamid.GOOD" });
    expect(insertPayloads("contacts")).toHaveLength(1);
    expect(insertPayloads("contacts")[0]).toMatchObject({ phone: "5921111111" });

    // Contrato de whatsapp_webhook_log:
    // - fila ANTES de procesar para AMBOS mensajes (el malo también)…
    const logInserts = insertPayloads("whatsapp_webhook_log");
    expect(logInserts).toHaveLength(2);
    expect(logInserts[0]).toMatchObject({ wamid: "wamid.BAD" });
    expect(logInserts[1]).toMatchObject({ wamid: "wamid.GOOD" });
    // …el malo con el motivo y SIN procesado…
    const logUpdates = updates["whatsapp_webhook_log"] ?? [];
    const badUpdate = logUpdates.find((u) => "error" in (u.payload as object));
    expect(badUpdate).toBeTruthy();
    expect(badUpdate!.payload).toMatchObject({
      error: "boom: telefono malformado",
    });
    expect(
      logUpdates.some((u) => (u.payload as { procesado?: boolean }).procesado === true),
    ).toBe(true); // …y el bueno con procesado=true.
    // El malo nunca se marca procesado.
    const badRow = logInserts[0] as { id?: string };
    const badMarked = logUpdates.find(
      (u) =>
        (u.payload as { procesado?: boolean }).procesado === true &&
        u.eqs.includes(String(badRow.id)),
    );
    expect(badMarked).toBeUndefined();
  });
});
