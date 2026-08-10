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
// `inserts[tabla]` acumula los payloads insertados; los tests lo leen
// para comprobar qué se guardó (y qué no).
const inserts: Record<string, unknown[]> = {};

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
  dispatchInboundToFlows: vi.fn(async () => undefined),
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
  builder.eq = vi.fn(() => builder);
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
    inserts[table] = [...(inserts[table] ?? []), payload];
    result.data = Array.isArray(payload) ? payload : [payload];
    return builder;
  });
  builder.upsert = vi.fn((payload: unknown) => {
    inserts[table] = [...(inserts[table] ?? []), payload];
    result.data = Array.isArray(payload) ? payload : [payload];
    return builder;
  });
  builder.update = vi.fn(() => builder);
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
  });
});
