// Tests for the browser-side remittance-operations command helpers.
// Verifies request shape (method/url/body) for each action plus the
// ok / non-ok / network-error result mapping, mocking global.fetch.

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  corregirOperacion,
  corregirBeneficiario,
  reasignarBeneficiario,
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
