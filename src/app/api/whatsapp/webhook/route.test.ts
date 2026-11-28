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
// Tablas cuyo INSERT debe fallar (error de Postgres simulado).
const failInserts: Record<string, unknown> = {};

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
vi.mock("@/lib/webhooks/outbox", () => ({
  dispatchEventDurably: vi.fn(async () => undefined),
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
  builder.eq = vi.fn((col: string, val: unknown) => {
    // Correlacionar updates con su filtro (p.ej. eq('id', logId)).
    const last = updates[table]?.[updates[table].length - 1];
    if (last) last.eqs.push(String(val));
    // whatsapp_config responde SOLO al phone_number_id configurado —
    // el test del "No config found" depende de que el eq filtre.
    if (table === "whatsapp_config" && col === "phone_number_id") {
      result.data = val === CONFIG_ROW.phone_number_id ? [CONFIG_ROW] : null;
    }
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
    result.error = failInserts[table] ?? null;
    let row = payload;
    if (table === "whatsapp_webhook_log") {
      // La tabla del log devuelve su id — el contrato depende de él.
      row = Array.isArray(payload)
        ? payload.map((p) => ({ ...(p as object), id: `log-${++logSeq}` }))
        : { ...(payload as object), id: `log-${++logSeq}` };
    }
    // Los inserts en lote se aplana[n]: cada fila entra por separado en
    // `inserts[table]`, como si fueran inserts individuales.
    if (Array.isArray(row)) {
      inserts[table] = [...(inserts[table] ?? []), ...row];
    } else {
      inserts[table] = [...(inserts[table] ?? []), row];
    }
    result.data = Array.isArray(row) ? row : [row];
    return builder;
  });
  builder.upsert = vi.fn((payload: unknown) => {
    inserts[table] = [...(inserts[table] ?? []), payload];
    result.data = Array.isArray(payload) ? payload : [payload];
    return builder;
  });
  builder.in = vi.fn(() => builder);
  builder.update = vi.fn((payload: unknown) => {
    updates[table] = [...(updates[table] ?? []), { payload, eqs: [] }];
    return builder;
  });
  builder.then = (resolve: (v: unknown) => unknown) =>
    Promise.resolve({ data: result.data, error: result.error }).then(resolve);
  return builder;
}

// --- Storage + Meta media fakes --------------------------------------------
// Ingest uploads the original and its thumbnail; `failThumbUpload` makes the
// thumbnail upload fail so the "ready with media_error" path is covered.
const uploads: Array<{ bucket: string; path: string; contentType: string }> = [];
let failThumbUpload = false;

vi.mock("@/lib/whatsapp/meta-api", () => ({
  getMediaUrl: vi.fn(async () => ({
    url: "https://meta.test/media",
    mimeType: "image/jpeg",
  })),
  downloadMedia: vi.fn(async () => ({
    buffer: mediaBytes,
    contentType: "image/jpeg",
  })),
}));

let mediaBytes: Buffer = Buffer.from("");

const builders: Record<string, ReturnType<typeof makeBuilder>> = {};

vi.mock("@supabase/supabase-js", () => ({
  createClient: vi.fn(() => ({
    from: (table: string) =>
      builders[table] ?? (builders[table] = makeBuilder(table)),
    storage: {
      from: (bucket: string) => ({
        upload: async (
          path: string,
          _data: unknown,
          opts: { contentType: string },
        ) => {
          if (failThumbUpload && path.includes("/thumbs/")) {
            return { error: { message: "thumb upload refused" } };
          }
          uploads.push({ bucket, path, contentType: opts.contentType });
          return { error: null };
        },
        getPublicUrl: (path: string) => ({
          data: { publicUrl: `https://cdn.test/${bucket}/${path}` },
        }),
      }),
    },
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
    Object.keys(failInserts).forEach((k) => delete failInserts[k]);
    logSeq = 0;
  });

  it("1. contacts vacio: crea el contacto sin nombre (el panel muestra el telefono) y guarda el mensaje", async () => {
    const res = await post(webhookBody([textMessage("5926731279", "wamid.A")], []));

    expect(res.status).toBe(200);
    const contactInserts = insertPayloads("contacts");
    expect(contactInserts).toHaveLength(1);
    expect(contactInserts[0]).toMatchObject({
      account_id: "acc1",
      phone: "5926731279",
      // Sin perfil de WhatsApp no se inventa un nombre: guardar el teléfono
      // como nombre dejaba contactos llamados "5927…" (16 en producción).
      name: null,
    });
    expect(insertPayloads("messages")).toHaveLength(1);
  });

  it("2. contacts sin profile: mismo resultado, sin nombre", async () => {
    const res = await post(
      webhookBody([textMessage("5926731279", "wamid.B")], [{ wa_id: "5926731279" }]),
    );

    expect(res.status).toBe(200);
    expect(insertPayloads("contacts")).toHaveLength(1);
    expect(insertPayloads("contacts")[0]).toMatchObject({
      phone: "5926731279",
      name: null,
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

  it("4. sin config para el phone_number_id: una fila por mensaje, con error y sin procesado", async () => {
    const res = await post(
      // phone_number_id inexistente en whatsapp_config → el flujo sale
      // por "No config found" antes del bucle.
      webhookBody(
        [textMessage("5926731279", "wamid.NOCONFIG")],
        [],
      ).replace("1244814475383839", "1269746806212237"),
    );

    expect(res.status).toBe(200);
    // Nada se guardó (no hay config → no hay contacto ni mensaje).
    expect(insertPayloads("contacts")).toHaveLength(0);
    expect(insertPayloads("messages")).toHaveLength(0);
    // Pero el rastro SÍ quedó: una fila por mensaje, con el motivo…
    const logInserts = insertPayloads("whatsapp_webhook_log");
    expect(logInserts).toHaveLength(1);
    expect(logInserts[0]).toMatchObject({
      wamid: "wamid.NOCONFIG",
      phone_number_id: "1269746806212237",
    });
    const logUpdates = updates["whatsapp_webhook_log"] ?? [];
    const errUpdate = logUpdates.find((u) =>
      String((u.payload as { error?: string }).error).includes("sin config"),
    );
    expect(errUpdate).toBeTruthy();
    // …y NUNCA procesado: un mensaje perdido tiene que sonar.
    expect(
      logUpdates.some(
        (u) => (u.payload as { procesado?: boolean }).procesado === true,
      ),
    ).toBe(false);
  });
});

describe("webhook route — mensaje no guardado deja motivo en el log", () => {
  beforeEach(() => {
    // El fake arrastra result.data entre tests: builders limpios por caso.
    Object.keys(builders).forEach((k) => delete builders[k]);
    vi.clearAllMocks();
    Object.keys(inserts).forEach((k) => delete inserts[k]);
    Object.keys(updates).forEach((k) => delete updates[k]);
    Object.keys(failInserts).forEach((k) => delete failInserts[k]);
    logSeq = 0;
  });

  function logUpdatesOf(): { payload: Record<string, unknown>; eqs: string[] }[] {
    return (updates["whatsapp_webhook_log"] ?? []) as {
      payload: Record<string, unknown>;
      eqs: string[];
    }[];
  }

  it.each([
    ["contacts", "no guardado: contacto"],
    ["conversations", "no guardado: conversacion"],
    ["messages", "no guardado: mensaje"],
  ])("falla el INSERT de %s: error=%s y sin procesado", async (table, motivo) => {
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    failInserts[table] = { code: "XX000", message: "simulado" };
    await post(webhookBody([textMessage("5926731279", "wamid.F")], []));
    errorSpy.mockRestore();

    const updatesLog = logUpdatesOf();
    expect(updatesLog.some((u) => u.payload.error === motivo)).toBe(true);
    expect(updatesLog.some((u) => u.payload.procesado === true)).toBe(false);
  });

  it("un mensaje guardado no escribe error", async () => {
    await post(webhookBody([textMessage("5926731279", "wamid.OK")], []));
    const updatesLog = logUpdatesOf();
    expect(updatesLog.some((u) => u.payload.procesado === true)).toBe(true);
    expect(updatesLog.some((u) => "error" in u.payload)).toBe(false);
  });
});

// --- Slice 5b: media metadata on ingest -------------------------------------
describe("ingest de media (migración 400)", () => {
  const ACCOUNT = "acc1";

  function imageMessage(from: string, id: string): Record<string, unknown> {
    return {
      from,
      id,
      timestamp: "1754300000",
      type: "image",
      image: { id: "meta-media-1", mime_type: "image/jpeg", caption: "foto" },
    };
  }

  it("guarda el objeto, su miniatura y las dimensiones con media_status ready", async () => {
    const sharp = (await import("sharp")).default;
    mediaBytes = await sharp({
      create: { width: 300, height: 200, channels: 3, background: { r: 20, g: 90, b: 200 } },
    })
      .jpeg()
      .toBuffer();
    uploads.length = 0;
    failThumbUpload = false;

    await post(webhookBody([imageMessage("5926731280", "wamid.MEDIA1")], []));

    const row = (inserts.messages ?? []).at(-1) as Record<string, unknown>;
    expect(row.media_status).toBe("ready");
    expect(String(row.media_path)).toMatch(/^account-acc1\/\d+-wa-meta-media-1\.jpg$/);
    expect(String(row.media_thumb_path)).toMatch(/^account-acc1\/thumbs\/\d+-wa-meta-media-1\.webp$/);
    expect(row.media_mime).toBe("image/jpeg");
    expect(row.media_bytes).toBe(mediaBytes.byteLength);
    expect(row.media_width).toBe(300);
    expect(row.media_height).toBe(200);
    expect(row.media_error).toBeNull();

    // Two objects: the original and the thumbnail, both in chat-media.
    expect(uploads.map((u) => u.contentType).sort()).toEqual(["image/jpeg", "image/webp"]);
    expect(uploads.every((u) => u.bucket === "chat-media")).toBe(true);
  });

  it("si la miniatura falla, el mensaje queda ready con el motivo y sin miniatura", async () => {
    const sharp = (await import("sharp")).default;
    mediaBytes = await sharp({
      create: { width: 300, height: 200, channels: 3, background: { r: 20, g: 90, b: 200 } },
    })
      .jpeg()
      .toBuffer();
    uploads.length = 0;
    failThumbUpload = true;

    await post(webhookBody([imageMessage("5926731281", "wamid.MEDIA2")], []));

    const row = (inserts.messages ?? []).at(-1) as Record<string, unknown>;
    failThumbUpload = false;

    expect(row.media_status).toBe("ready");
    expect(row.media_thumb_path).toBeNull();
    expect(String(row.media_error)).toContain("thumbnail:");
    expect(row.media_width).toBe(300);
  });
});
