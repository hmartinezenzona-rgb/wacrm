// Tests for the browser-side remittance-operations command helpers.
// Verifies request shape (method/url/body) for each action plus the
// ok / non-ok / network-error result mapping, mocking global.fetch.

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  corregirOperacion,
  corregirBeneficiario,
  reasignarBeneficiario,
  fetchOperationReceipts,
  verifyDeposit,
  forceVerifyDeposit,
  deliverOperation,
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
        body: JSON.stringify({ items }),
      }),
    );
    expect(response).toEqual({ ok: true, result });
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
  it("POSTs the reason to the force-verify endpoint and unwraps newStatus", async () => {
    vi.mocked(fetch).mockResolvedValueOnce(
      jsonResponse({ ok: true, newStatus: "ready_to_transfer" }),
    );

    const reason = "Confirmed by phone with the sender";
    const response = await forceVerifyDeposit(OPERATION_ID, reason);

    expect(fetch).toHaveBeenCalledWith(
      `/api/remittance-operations/${OPERATION_ID}/force-verify`,
      expect.objectContaining({
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ reason }),
      }),
    );
    expect(response).toEqual({ ok: true, newStatus: "ready_to_transfer" });
  });

  it("maps a non-2xx response to ok:false with status and error message", async () => {
    vi.mocked(fetch).mockResolvedValueOnce(jsonResponse({ error: "Forbidden" }, 403));

    const response = await forceVerifyDeposit(OPERATION_ID, "short reason enough");

    expect(response).toEqual({ ok: false, status: 403, error: "Forbidden" });
  });

  it("maps a network failure to ok:false status 0", async () => {
    vi.mocked(fetch).mockRejectedValueOnce(new Error("offline"));

    const response = await forceVerifyDeposit(OPERATION_ID, "short reason enough");

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
        body: JSON.stringify({ evidence }),
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
