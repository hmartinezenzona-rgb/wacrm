// ============================================================
// The two places where this staging build deliberately parts ways
// with production. Both are one-line changes with large consequences,
// so both are pinned.
//
//   1. A delivery proof does NOT fall back to `link`. Production
//      does, on purpose, because that fallback keeps a live business
//      sending. For the screenshot that evidences a payment we prefer
//      a visible failure the operator can retry: the 24-ago-2026
//      incident is exactly a `link` send that Meta ACCEPTED, returned
//      a wamid for, and only later failed to download — after the deal
//      had been closed on the strength of that acceptance.
//
//   2. Delivering does NOT write `deals.stage_id`. In production the
//      stage change IS the financial transition (`deals_stage_notify`
//      → n8n → the `remesa_completada` template), so dragging a card
//      tells the customer their remittance is complete whether or not
//      any money moved. Here the card follows Remesas Core.
// ============================================================

import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const RAIZ = join(__dirname, "..", "..", "..");
const leer = (p: string) => readFileSync(join(RAIZ, p), "utf8");

describe("la prueba de entrega no acepta el respaldo por link", () => {
  it("`requireMediaId` existe y aborta cuando no hubo media_id", () => {
    const src = leer("src/lib/whatsapp/send-message.ts");
    expect(src).toContain("requireMediaId?: boolean");
    // El fallo tiene que ocurrir ANTES de mandar nada.
    const bloque = src.slice(
      src.indexOf("metaMediaId = await uploadMediaForSend"),
      src.indexOf("const attempt = async"),
    );
    expect(bloque).toContain("if (!metaMediaId && requireMediaId)");
    expect(bloque).toContain("media_upload_failed");
  });

  it("el respaldo por link SIGUE existiendo para todo lo demas", () => {
    // No se rompe lo que hoy funciona: solo la prueba de entrega pide
    // media_id o nada. Un envio normal de la bandeja no cambia.
    const src = leer("src/lib/whatsapp/send-message.ts");
    expect(src).toContain("sending as link");
  });

  it("el tablero lo pide al mandar la captura", () => {
    const page = leer("src/app/(dashboard)/pipelines/page.tsx");
    const envio = page.slice(
      page.indexOf("sendProof: async"),
      page.indexOf("readStage: async"),
    );
    expect(envio).toContain("require_media_id: true");
  });
});

describe("entregar es cosa del Core, no de la columna", () => {
  it("el tablero no escribe la etapa al entregar", () => {
    const page = leer("src/app/(dashboard)/pipelines/page.tsx");
    const mover = page.slice(
      page.indexOf("moveToDelivered:"),
      page.indexOf("let result: DeliveryResult"),
    );
    expect(mover).toContain("/api/remesas/deliver");
    expect(mover).not.toContain("persistStage");
    expect(mover).not.toContain("DELIVERED_STAGE_ID");
  });

  it("la ultima puerta pregunta al Core, no a la tabla de deals", () => {
    const page = leer("src/app/(dashboard)/pipelines/page.tsx");
    const leerEtapa = page.slice(
      page.indexOf("readStage: async"),
      page.indexOf("discardUpload:"),
    );
    expect(leerEtapa).toContain("/api/remesas/deliver?deal_id=");
    expect(leerEtapa).not.toContain('.from("deals")');
    // No saber es abortar, nunca seguir.
    expect(leerEtapa).toContain("return null");
  });

  it("la referencia es obligatoria antes de poder confirmar", () => {
    const page = leer("src/app/(dashboard)/pipelines/page.tsx");
    expect(page).toContain("!transferReference.trim()");
  });

  it("el navegador nunca ve la credencial que completa", () => {
    const page = leer("src/app/(dashboard)/pipelines/page.tsx");
    for (const secreto of [
      "REMESAS_DELIVERY_SECRET",
      "REMESAS_CORE_TOKEN_HUMAN_OPERATOR",
      "8792",
    ]) {
      expect(page).not.toContain(secreto);
    }
  });

  it("la ruta valida sesion Y rol en el servidor", () => {
    const ruta = leer("src/app/api/remesas/deliver/route.ts");
    expect(ruta).toContain("supabase.auth.getUser()");
    expect(ruta).toContain("account_role");
    expect(ruta).toContain("canSendMessages");
    // Y exige la referencia aunque el Core la deje opcional.
    expect(ruta).toContain("falta la referencia de la transferencia");
  });

  it("el secreto solo vive en el servidor", () => {
    const ruta = leer("src/app/api/remesas/deliver/route.ts");
    // `NEXT_PUBLIC_` lo publicaria en el bundle del navegador.
    expect(ruta).not.toContain("NEXT_PUBLIC_REMESAS_DELIVERY");
    expect(ruta).toContain("process.env.REMESAS_DELIVERY_SECRET");
  });
});

describe("el modulo de entrega no se toco", () => {
  it("`deliver-with-proof.ts` sigue sin saber nada del Core", () => {
    // La adaptacion se hizo cambiando las DEPENDENCIAS que se le inyectan,
    // no el modulo: su orden de operaciones, sus formas de fallo y su
    // `sentWamid` son los de produccion, ya probados.
    const src = leer("src/lib/pipelines/deliver-with-proof.ts");
    expect(src).not.toContain("remesas");
    expect(src).not.toContain("transfer_reference");
    expect(src).toContain("moveToDelivered");
  });
});
