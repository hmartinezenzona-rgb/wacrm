// Tests for the browser-side remittance-operations command helpers.
// Verifies request shape (method/url/body) for each action plus the
// ok / non-ok / network-error result mapping, mocking global.fetch.

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  corregirOperacion,
  corregirBeneficiario,
  reasignarBeneficiario,
  quitarBeneficiario,
  crearOperacion,
  cambiarEstado,
  fetchFreeDeposits,
  moverDeposito,
  fetchOperationReceipts,
  fetchChatImages,
  verifyDeposit,
  forceVerifyDeposit,
  deliverOperation,
  cerrarOperacionManual,
  setComboCosto,
  cambiarServicio,
  repartirEnvio,
  eliminarOperacion,
  registerBeneficiaryProof,
} from "./commands";

const OPERATION_ID = "11111111-1111-1111-1111-111111111111";
const BENEFICIARY_ID = "22222222-2222-2222-2222-222222222222";
const TARGET_OPERATION_ID = "33333333-3333-3333-3333-333333333333";

function jsonResponse(body: unknown, status = 200): Response {
  return {
    ok: status >= 200 && status < 300,
    status,
    json: () => Promise.resolve(body),
  } as Response;
}

beforeEach(() => {
  vi.stubGlobal("fetch", vi.fn());
});

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("corregirOperacion", () => {
  it("PATCHes the operation with cambios in the body", async () => {
    vi.mocked(fetch).mockResolvedValueOnce(jsonResponse({ ok: true }));

    const cambios = { status: "ready_to_transfer" };
    const result = await corregirOperacion(OPERATION_ID, cambios);

    expect(fetch).toHaveBeenCalledWith(
      `/api/remittance-operations/${OPERATION_ID}`,
      expect.objectContaining({
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ cambios }),
      }),
    );
    expect(result).toEqual({ ok: true, id: undefined });
  });

  it("maps a non-2xx response to ok:false with status and error message", async () => {
    vi.mocked(fetch).mockResolvedValueOnce(
      jsonResponse({ error: "operation is closed" }, 400),
    );

    const result = await corregirOperacion(OPERATION_ID, { status: "x" });

    expect(result).toEqual({ ok: false, status: 400, error: "operation is closed" });
  });

  it("maps a network failure to ok:false status 0", async () => {
    vi.mocked(fetch).mockRejectedValueOnce(new Error("offline"));

    const result = await corregirOperacion(OPERATION_ID, { status: "x" });

    expect(result).toEqual({ ok: false, status: 0, error: "Network error" });
  });
});

describe("corregirBeneficiario", () => {
  it("PATCHes the beneficiary with cambios in the body", async () => {
    vi.mocked(fetch).mockResolvedValueOnce(
      jsonResponse({ ok: true, id: BENEFICIARY_ID }),
    );

    const cambios = { name: "New Name" };
    const result = await corregirBeneficiario(BENEFICIARY_ID, cambios);

    expect(fetch).toHaveBeenCalledWith(
      `/api/remittance-operations/beneficiaries/${BENEFICIARY_ID}`,
      expect.objectContaining({
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ cambios }),
      }),
    );
    expect(result).toEqual({ ok: true, id: BENEFICIARY_ID });
  });

  it("maps a non-2xx response to ok:false with status and error message", async () => {
    vi.mocked(fetch).mockResolvedValueOnce(jsonResponse({ error: "Forbidden" }, 403));

    const result = await corregirBeneficiario(BENEFICIARY_ID, { name: "x" });

    expect(result).toEqual({ ok: false, status: 403, error: "Forbidden" });
  });

  it("maps a network failure to ok:false status 0", async () => {
    vi.mocked(fetch).mockRejectedValueOnce(new Error("offline"));

    const result = await corregirBeneficiario(BENEFICIARY_ID, { name: "x" });

    expect(result).toEqual({ ok: false, status: 0, error: "Network error" });
  });
});

describe("reasignarBeneficiario", () => {
  it("POSTs targetOperationId in the body", async () => {
    vi.mocked(fetch).mockResolvedValueOnce(
      jsonResponse({ ok: true, id: BENEFICIARY_ID }),
    );

    const result = await reasignarBeneficiario(BENEFICIARY_ID, TARGET_OPERATION_ID);

    expect(fetch).toHaveBeenCalledWith(
      `/api/remittance-operations/beneficiaries/${BENEFICIARY_ID}/reassign`,
      expect.objectContaining({
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ targetOperationId: TARGET_OPERATION_ID }),
      }),
    );
    expect(result).toEqual({ ok: true, id: BENEFICIARY_ID });
  });

  it("maps a non-2xx response to ok:false with status and error message", async () => {
    vi.mocked(fetch).mockResolvedValueOnce(jsonResponse({ error: "Not found" }, 404));

    const result = await reasignarBeneficiario(BENEFICIARY_ID, TARGET_OPERATION_ID);

    expect(result).toEqual({ ok: false, status: 404, error: "Not found" });
  });

  it("maps a network failure to ok:false status 0", async () => {
    vi.mocked(fetch).mockRejectedValueOnce(new Error("offline"));

    const result = await reasignarBeneficiario(BENEFICIARY_ID, TARGET_OPERATION_ID);

    expect(result).toEqual({ ok: false, status: 0, error: "Network error" });
  });
});

describe("fetchOperationReceipts", () => {
  it("GETs the receipts endpoint and unwraps the receipts field", async () => {
    const receipts = {
      operationId: OPERATION_ID,
      status: "deposit_verification",
      dealId: null,
      canVerify: true,
      objetivo: 25000,
      depositado: 25000,
      saldo: 0,
      moneda: "GYD",
      receipts: [],
      consumedDeposits: [],
    };
    vi.mocked(fetch).mockResolvedValueOnce(jsonResponse({ receipts }));

    const result = await fetchOperationReceipts(OPERATION_ID);

    expect(fetch).toHaveBeenCalledWith(
      `/api/remittance-operations/${OPERATION_ID}/receipts`,
    );
    expect(result).toEqual({ ok: true, data: receipts });
  });

  it("maps a non-2xx response to ok:false with status and error message", async () => {
    vi.mocked(fetch).mockResolvedValueOnce(jsonResponse({ error: "Not found" }, 404));

    const result = await fetchOperationReceipts(OPERATION_ID);

    expect(result).toEqual({ ok: false, status: 404, error: "Not found" });
  });

  it("maps a network failure to ok:false status 0", async () => {
    vi.mocked(fetch).mockRejectedValueOnce(new Error("offline"));

    const result = await fetchOperationReceipts(OPERATION_ID);

    expect(result).toEqual({ ok: false, status: 0, error: "Network error" });
  });
});

describe("verifyDeposit", () => {
  it("POSTs the items to the verify endpoint and unwraps the result", async () => {
    const result = {
      resultado: "verificado",
      metodo: "manual",
      todosVerificados: true,
      totalVerificado: 25000,
      nComprobantes: 1,
      detalle: { items: [] },
      objetivo: 25000,
      depositado: 25000,
      saldo: 0,
      stageChanged: true,
      newStatus: "ready_to_transfer",
    };
    vi.mocked(fetch).mockResolvedValueOnce(jsonResponse({ ok: true, result }));

    const items = [{ ref: "TX-1", amount: 25000 }];
    const response = await verifyDeposit(OPERATION_ID, items);

    expect(fetch).toHaveBeenCalledWith(
      `/api/remittance-operations/${OPERATION_ID}/verify`,
      expect.objectContaining({
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ items, notify: true }),
      }),
    );
    expect(response).toEqual({ ok: true, result });
  });

  it("sends notify:false when the caller turns the customer message off", async () => {
    vi.mocked(fetch).mockResolvedValueOnce(jsonResponse({ ok: true, result: {} }));

    await verifyDeposit(OPERATION_ID, [{ ref: "TX-1", amount: 1 }], false);

    expect(JSON.parse(vi.mocked(fetch).mock.calls[0]![1]!.body as string)).toEqual({
      items: [{ ref: "TX-1", amount: 1 }],
      notify: false,
    });
  });

  it("maps a non-2xx response to ok:false with status and error message", async () => {
    vi.mocked(fetch).mockResolvedValueOnce(
      jsonResponse({ error: "operation is closed" }, 400),
    );

    const response = await verifyDeposit(OPERATION_ID, [{ ref: "TX-1", amount: 1 }]);

    expect(response).toEqual({ ok: false, status: 400, error: "operation is closed" });
  });

  it("maps a network failure to ok:false status 0", async () => {
    vi.mocked(fetch).mockRejectedValueOnce(new Error("offline"));

    const response = await verifyDeposit(OPERATION_ID, [{ ref: "TX-1", amount: 1 }]);

    expect(response).toEqual({ ok: false, status: 0, error: "Network error" });
  });
});

describe("forceVerifyDeposit", () => {
  it("POSTs only notify (no reason) to the force-verify endpoint and unwraps newStatus", async () => {
    vi.mocked(fetch).mockResolvedValueOnce(
      jsonResponse({ ok: true, newStatus: "ready_to_transfer" }),
    );

    const response = await forceVerifyDeposit(OPERATION_ID);

    expect(fetch).toHaveBeenCalledWith(
      `/api/remittance-operations/${OPERATION_ID}/force-verify`,
      expect.objectContaining({
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ notify: true }),
      }),
    );
    expect(response).toEqual({ ok: true, newStatus: "ready_to_transfer" });
  });

  it("maps a non-2xx response to ok:false with status and error message", async () => {
    vi.mocked(fetch).mockResolvedValueOnce(jsonResponse({ error: "Forbidden" }, 403));

    const response = await forceVerifyDeposit(OPERATION_ID);

    expect(response).toEqual({ ok: false, status: 403, error: "Forbidden" });
  });

  it("maps a network failure to ok:false status 0", async () => {
    vi.mocked(fetch).mockRejectedValueOnce(new Error("offline"));

    const response = await forceVerifyDeposit(OPERATION_ID);

    expect(response).toEqual({ ok: false, status: 0, error: "Network error" });
  });
});

describe("deliverOperation", () => {
  it("POSTs the evidence to the deliver endpoint and unwraps newStatus/completedAt", async () => {
    vi.mocked(fetch).mockResolvedValueOnce(
      jsonResponse({ ok: true, newStatus: "completed", completedAt: "2026-09-15T12:00:00Z" }),
    );

    const evidence = { mode: "proof_sent" as const, wamid: "wamid.ABC", path: "account-1/x.png" };
    const response = await deliverOperation(OPERATION_ID, evidence);

    expect(fetch).toHaveBeenCalledWith(
      `/api/remittance-operations/${OPERATION_ID}/deliver`,
      expect.objectContaining({
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ evidence, notify: true }),
      }),
    );
    expect(response).toEqual({
      ok: true,
      newStatus: "completed",
      completedAt: "2026-09-15T12:00:00Z",
    });
  });

  it("maps a non-2xx response to ok:false with status and error message", async () => {
    vi.mocked(fetch).mockResolvedValueOnce(
      jsonResponse({ error: "operation is not ready to transfer" }, 400),
    );

    const response = await deliverOperation(OPERATION_ID, { mode: "no_proof" });

    expect(response).toEqual({
      ok: false,
      status: 400,
      error: "operation is not ready to transfer",
    });
  });

  it("maps a network failure to ok:false status 0", async () => {
    vi.mocked(fetch).mockRejectedValueOnce(new Error("offline"));

    const response = await deliverOperation(OPERATION_ID, { mode: "no_proof" });

    expect(response).toEqual({ ok: false, status: 0, error: "Network error" });
  });
});

describe("registerBeneficiaryProof", () => {
  it("POSTs the evidence to the beneficiary proof endpoint and unwraps registered/missing", async () => {
    vi.mocked(fetch).mockResolvedValueOnce(jsonResponse({ ok: true, registered: true, missing: 1 }));

    const evidence = { wamid: "wamid.ABC", path: "account-1/x.png", caption: "Ana" };
    const response = await registerBeneficiaryProof(OPERATION_ID, BENEFICIARY_ID, evidence);

    expect(fetch).toHaveBeenCalledWith(
      `/api/remittance-operations/${OPERATION_ID}/beneficiaries/${BENEFICIARY_ID}/proof`,
      expect.objectContaining({
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ evidence }),
      }),
    );
    expect(response).toEqual({ ok: true, registered: true, missing: 1 });
  });

  it("maps a non-2xx response to ok:false with status and error message", async () => {
    vi.mocked(fetch).mockResolvedValueOnce(
      jsonResponse({ error: "beneficiary is not a current beneficiary of this operation" }, 400),
    );

    const response = await registerBeneficiaryProof(OPERATION_ID, BENEFICIARY_ID, { wamid: "w" });

    expect(response).toEqual({
      ok: false,
      status: 400,
      error: "beneficiary is not a current beneficiary of this operation",
    });
  });

  it("maps a network failure to ok:false status 0", async () => {
    vi.mocked(fetch).mockRejectedValueOnce(new Error("offline"));

    const response = await registerBeneficiaryProof(OPERATION_ID, BENEFICIARY_ID, { wamid: "w" });

    expect(response).toEqual({ ok: false, status: 0, error: "Network error" });
  });
});

describe("forceVerifyDeposit / deliverOperation notify flag", () => {
  it("forceVerifyDeposit sends notify:false when asked", async () => {
    vi.mocked(fetch).mockResolvedValueOnce(jsonResponse({ ok: true, newStatus: "ready_to_transfer" }));

    await forceVerifyDeposit(OPERATION_ID, false);

    expect(JSON.parse(vi.mocked(fetch).mock.calls[0]![1]!.body as string)).toEqual({ notify: false });
  });

  it("deliverOperation sends notify:false when asked", async () => {
    vi.mocked(fetch).mockResolvedValueOnce(jsonResponse({ ok: true, newStatus: "completed", completedAt: null }));

    await deliverOperation(OPERATION_ID, { mode: "no_proof" }, false);

    expect(JSON.parse(vi.mocked(fetch).mock.calls[0]![1]!.body as string)).toEqual({
      evidence: { mode: "no_proof" },
      notify: false,
    });
  });
});

describe("cerrarOperacionManual", () => {
  const closed = { ok: true, newStatus: "completed", completedAt: "2026-10-02T10:00:00Z" };

  it("POSTs notify:false by default, with no reason, and unwraps newStatus", async () => {
    vi.mocked(fetch).mockResolvedValueOnce(jsonResponse(closed));

    const response = await cerrarOperacionManual(OPERATION_ID);

    expect(fetch).toHaveBeenCalledWith(
      `/api/remittance-operations/${OPERATION_ID}/close-manual`,
      expect.objectContaining({
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ notify: false }),
      }),
    );
    expect(response).toMatchObject({ ok: true, newStatus: "completed" });
  });

  it("POSTs deliveryMethod only when a service was picked", async () => {
    vi.mocked(fetch).mockResolvedValueOnce(jsonResponse(closed));

    await cerrarOperacionManual(OPERATION_ID, true, "zelle");

    expect(JSON.parse(vi.mocked(fetch).mock.calls[0]![1]!.body as string)).toEqual({
      notify: true,
      deliveryMethod: "zelle",
    });
  });

  it("POSTs notify:true when the operator turns the bell on", async () => {
    vi.mocked(fetch).mockResolvedValueOnce(jsonResponse(closed));

    await cerrarOperacionManual(OPERATION_ID, true);

    expect(JSON.parse(vi.mocked(fetch).mock.calls[0]![1]!.body as string)).toEqual({ notify: true });
  });

  it("maps a non-2xx response to ok:false with status and error message", async () => {
    vi.mocked(fetch).mockResolvedValueOnce(jsonResponse({ error: "Forbidden" }, 403));

    expect(await cerrarOperacionManual(OPERATION_ID)).toEqual({ ok: false, status: 403, error: "Forbidden" });
  });
});

describe("eliminarOperacion", () => {
  it("POSTs an empty body (no reason) and unwraps newStatus", async () => {
    vi.mocked(fetch).mockResolvedValueOnce(jsonResponse({ ok: true, newStatus: "cancelled" }));

    const response = await eliminarOperacion(OPERATION_ID);

    expect(fetch).toHaveBeenCalledWith(
      `/api/remittance-operations/${OPERATION_ID}/delete`,
      expect.objectContaining({
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({}),
      }),
    );
    expect(response).toMatchObject({ ok: true, newStatus: "cancelled" });
  });

  it("maps a non-2xx response to ok:false with status and error message", async () => {
    vi.mocked(fetch).mockResolvedValueOnce(jsonResponse({ error: "Forbidden" }, 403));

    expect(await eliminarOperacion(OPERATION_ID)).toEqual({ ok: false, status: 403, error: "Forbidden" });
  });
});

describe("setComboCosto", () => {
  it("POSTs the cost to the combo-cost route and unwraps the saved value", async () => {
    vi.mocked(fetch).mockResolvedValueOnce(jsonResponse({ ok: true, costGyd: 18000 }));

    const response = await setComboCosto(OPERATION_ID, 18000);

    expect(fetch).toHaveBeenCalledWith(
      `/api/remittance-operations/${OPERATION_ID}/combo-cost`,
      expect.objectContaining({
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ costGyd: 18000 }),
      }),
    );
    expect(response).toEqual({ ok: true, costGyd: 18000 });
  });

  it("sends null to clear and surfaces a failure's status and message", async () => {
    vi.mocked(fetch).mockResolvedValueOnce(jsonResponse({ error: "Forbidden" }, 403));

    const response = await setComboCosto(OPERATION_ID, null);

    expect(fetch).toHaveBeenCalledWith(expect.any(String), expect.objectContaining({ body: JSON.stringify({ costGyd: null }) }));
    expect(response).toEqual({ ok: false, status: 403, error: "Forbidden" });
  });
});

describe("cambiarServicio", () => {
  it("POSTs the service to the service route and unwraps the summary", async () => {
    vi.mocked(fetch).mockResolvedValueOnce(jsonResponse({ ok: true, service: "recarga", changed: true }));

    const response = await cambiarServicio(OPERATION_ID, "recarga");

    expect(fetch).toHaveBeenCalledWith(
      `/api/remittance-operations/${OPERATION_ID}/service`,
      expect.objectContaining({
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ servicio: "recarga" }),
      }),
    );
    expect(response).toEqual({ ok: true, service: "recarga", changed: true });
  });

  it("surfaces a failure's status and message", async () => {
    vi.mocked(fetch).mockResolvedValueOnce(jsonResponse({ error: "operation is closed" }, 400));

    expect(await cambiarServicio(OPERATION_ID, "zelle")).toEqual({ ok: false, status: 400, error: "operation is closed" });
  });

  it("a network failure is a status-0 error", async () => {
    vi.mocked(fetch).mockRejectedValueOnce(new Error("offline"));

    expect(await cambiarServicio(OPERATION_ID, "zelle")).toEqual({ ok: false, status: 0, error: "Network error" });
  });
});

describe("repartirEnvio", () => {
  const PARTS = [
    { service: "clasica", amountGyd: 18200 },
    { service: "recarga", amountGyd: 6200 },
  ];
  const SUMMARY = {
    group: OPERATION_ID,
    deposited: 24400,
    balance: 0,
    parts: [{ operationId: OPERATION_ID, service: "clasica", amountGyd: 18200, created: false, status: "ready_to_transfer" }],
  };

  it("POSTs the parts to the split route and unwraps the summary", async () => {
    vi.mocked(fetch).mockResolvedValueOnce(jsonResponse({ ok: true, ...SUMMARY }));

    const response = await repartirEnvio(OPERATION_ID, PARTS);

    expect(fetch).toHaveBeenCalledWith(
      `/api/remittance-operations/${OPERATION_ID}/split`,
      expect.objectContaining({
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ parts: PARTS }),
      }),
    );
    expect(response).toEqual({ ok: true, ...SUMMARY });
  });

  it("surfaces a failure's status and message", async () => {
    vi.mocked(fetch).mockResolvedValueOnce(jsonResponse({ error: "parts add up to 24000" }, 400));

    expect(await repartirEnvio(OPERATION_ID, PARTS)).toEqual({ ok: false, status: 400, error: "parts add up to 24000" });
  });

  it("a network failure is a status-0 error", async () => {
    vi.mocked(fetch).mockRejectedValueOnce(new Error("offline"));

    expect(await repartirEnvio(OPERATION_ID, PARTS)).toEqual({ ok: false, status: 0, error: "Network error" });
  });
});

describe("fetchChatImages", () => {
  const CONVERSATION_ID = "44444444-4444-4444-4444-444444444444";

  it("GETs the chat-images endpoint for the conversation and unwraps the images", async () => {
    const images = [
      { id: "m1", wamid: "wamid.1", createdAt: "2026-10-08T16:35:00Z", senderType: "customer", mediaUrl: "https://x/1.jpg" },
    ];
    vi.mocked(fetch).mockResolvedValueOnce(jsonResponse({ images }));

    const result = await fetchChatImages(CONVERSATION_ID);

    expect(fetch).toHaveBeenCalledWith(
      `/api/remittance-operations/chat-images?conversationId=${CONVERSATION_ID}`,
    );
    expect(result).toEqual({ ok: true, data: images });
  });

  it("maps a non-2xx response to ok:false with status and error message", async () => {
    vi.mocked(fetch).mockResolvedValueOnce(jsonResponse({ error: "Forbidden" }, 403));
    expect(await fetchChatImages(CONVERSATION_ID)).toEqual({ ok: false, status: 403, error: "Forbidden" });
  });

  it("maps a network failure to status 0", async () => {
    vi.mocked(fetch).mockRejectedValueOnce(new Error("offline"));
    expect(await fetchChatImages(CONVERSATION_ID)).toEqual({ ok: false, status: 0, error: "Network error" });
  });
});

describe("CUP source card (migration 257)", () => {
  const CARD_ID = "22222222-2222-2222-2222-222222222222";

  it("deliverOperation sends cupSourceCardId only when a card was chosen", async () => {
    vi.mocked(fetch)
      .mockResolvedValueOnce(jsonResponse({ ok: true, newStatus: "completed", completedAt: null }))
      .mockResolvedValueOnce(jsonResponse({ ok: true, newStatus: "completed", completedAt: null }));

    await deliverOperation(OPERATION_ID, { mode: "no_proof" }, true, CARD_ID);
    expect(JSON.parse(vi.mocked(fetch).mock.calls[0]![1]!.body as string)).toEqual({
      evidence: { mode: "no_proof" },
      notify: true,
      cupSourceCardId: CARD_ID,
    });

    await deliverOperation(OPERATION_ID, { mode: "no_proof" }, true, null);
    expect(JSON.parse(vi.mocked(fetch).mock.calls[1]![1]!.body as string)).toEqual({ evidence: { mode: "no_proof" }, notify: true });
  });

  it("cerrarOperacionManual sends cupSourceCardId only when a card was chosen", async () => {
    vi.mocked(fetch).mockResolvedValueOnce(jsonResponse({ ok: true, newStatus: "completed", completedAt: null }));

    await cerrarOperacionManual(OPERATION_ID, false, undefined, CARD_ID);
    expect(JSON.parse(vi.mocked(fetch).mock.calls[0]![1]!.body as string)).toEqual({ notify: false, cupSourceCardId: CARD_ID });
  });
});

describe("quitarBeneficiario", () => {
  it("POSTs to the remove route and returns the id and whether the operation is still complete", async () => {
    vi.mocked(fetch).mockResolvedValueOnce(jsonResponse({ ok: true, id: BENEFICIARY_ID, complete: false }));

    const result = await quitarBeneficiario(BENEFICIARY_ID);

    expect(fetch).toHaveBeenCalledWith(
      `/api/remittance-operations/beneficiaries/${BENEFICIARY_ID}/remove`,
      expect.objectContaining({ method: "POST", headers: { "Content-Type": "application/json" } }),
    );
    expect(result).toEqual({ ok: true, id: BENEFICIARY_ID, complete: false });
  });

  it("maps a refusal to ok:false with status and error message", async () => {
    vi.mocked(fetch).mockResolvedValueOnce(jsonResponse({ error: "operation is closed" }, 400));

    const result = await quitarBeneficiario(BENEFICIARY_ID);

    expect(result).toEqual({ ok: false, status: 400, error: "operation is closed" });
  });
});

describe("crearOperacion", () => {
  it("POSTs the conversation, the service and the amount to the collection route", async () => {
    vi.mocked(fetch).mockResolvedValueOnce(jsonResponse({ ok: true, id: OPERATION_ID, service: "zelle" }));

    const result = await crearOperacion("conv-1", "zelle", 13000);

    expect(fetch).toHaveBeenCalledWith(
      "/api/remittance-operations",
      expect.objectContaining({
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ conversationId: "conv-1", servicio: "zelle", monto: 13000 }),
      }),
    );
    expect(result).toEqual({ ok: true, id: OPERATION_ID, service: "zelle" });
  });

  it("sends a null amount for a combo with no amount", async () => {
    vi.mocked(fetch).mockResolvedValueOnce(jsonResponse({ ok: true, id: OPERATION_ID, service: "combo" }));

    await crearOperacion("conv-1", "combo", null);

    expect(fetch).toHaveBeenCalledWith(
      "/api/remittance-operations",
      expect.objectContaining({ body: JSON.stringify({ conversationId: "conv-1", servicio: "combo", monto: null }) }),
    );
  });

  it("maps a refusal to ok:false with status and error message", async () => {
    vi.mocked(fetch).mockResolvedValueOnce(jsonResponse({ error: "amount must be greater than 0" }, 400));

    const result = await crearOperacion("conv-1", "zelle", 0);

    expect(result).toEqual({ ok: false, status: 400, error: "amount must be greater than 0" });
  });
});

describe("cambiarEstado", () => {
  it("POSTs the state and the bell to the status route", async () => {
    vi.mocked(fetch).mockResolvedValueOnce(jsonResponse({ ok: true, changed: true, newStatus: "ready_to_transfer" }));

    const result = await cambiarEstado(OPERATION_ID, "ready_to_transfer", true);

    expect(fetch).toHaveBeenCalledWith(
      `/api/remittance-operations/${OPERATION_ID}/status`,
      expect.objectContaining({
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ estado: "ready_to_transfer", notify: true }),
      }),
    );
    expect(result).toEqual({ ok: true, changed: true, newStatus: "ready_to_transfer" });
  });

  it("maps a refusal to ok:false with status and error message", async () => {
    vi.mocked(fetch).mockResolvedValueOnce(jsonResponse({ error: "operation is closed" }, 400));

    expect(await cambiarEstado(OPERATION_ID, "awaiting_deposit", false)).toEqual({ ok: false, status: 400, error: "operation is closed" });
  });
});

describe("fetchFreeDeposits", () => {
  it("GETs the free deposits of the operation", async () => {
    const deposits = [{ transId: "T-1", amount: 13000, currency: "GYD", receivedAt: "2026-11-17T14:18:14Z", holder: null }];
    vi.mocked(fetch).mockResolvedValueOnce(jsonResponse({ deposits }));

    const result = await fetchFreeDeposits(OPERATION_ID);

    expect(fetch).toHaveBeenCalledWith(`/api/remittance-operations/${OPERATION_ID}/free-deposits`);
    expect(result).toEqual({ ok: true, data: deposits });
  });

  it("maps a refusal to ok:false with status and error message", async () => {
    vi.mocked(fetch).mockResolvedValueOnce(jsonResponse({ error: "Not found" }, 404));

    expect(await fetchFreeDeposits(OPERATION_ID)).toEqual({ ok: false, status: 404, error: "Not found" });
  });
});

describe("moverDeposito", () => {
  it("POSTs the TransID and the target to the move-deposit route", async () => {
    vi.mocked(fetch).mockResolvedValueOnce(jsonResponse({ ok: true, moved: true, released: false, sourceStatus: "awaiting_deposit", targetStatus: "ready_to_transfer" }));

    const result = await moverDeposito(OPERATION_ID, "10400000009977", TARGET_OPERATION_ID);

    expect(fetch).toHaveBeenCalledWith(
      `/api/remittance-operations/${OPERATION_ID}/move-deposit`,
      expect.objectContaining({
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ transId: "10400000009977", destino: TARGET_OPERATION_ID }),
      }),
    );
    expect(result).toEqual({ ok: true, moved: true, released: false, sourceStatus: "awaiting_deposit", targetStatus: "ready_to_transfer" });
  });

  it("a null target releases the deposit", async () => {
    vi.mocked(fetch).mockResolvedValueOnce(jsonResponse({ ok: true, moved: false, released: true, sourceStatus: "awaiting_deposit", targetStatus: null }));

    await moverDeposito(OPERATION_ID, "T-1", null);

    expect(fetch).toHaveBeenCalledWith(expect.any(String), expect.objectContaining({ body: JSON.stringify({ transId: "T-1", destino: null }) }));
  });

  it("maps a refusal to ok:false with status and error message", async () => {
    vi.mocked(fetch).mockResolvedValueOnce(jsonResponse({ error: "the target operation is closed" }, 400));

    expect(await moverDeposito(OPERATION_ID, "T-1", TARGET_OPERATION_ID)).toEqual({ ok: false, status: 400, error: "the target operation is closed" });
  });
});
