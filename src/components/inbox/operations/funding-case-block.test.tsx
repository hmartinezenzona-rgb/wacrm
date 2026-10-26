// @vitest-environment jsdom
// Funding case block: amounts, deposits, allocations, incident note and the
// resolve action. The component fetches the panel RPC through the API route.

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import en from "../../../../messages/en.json";
import { formatNumber } from "@/lib/format-number";
import { FundingCaseBlock } from "./funding-case-block";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

vi.mock("next-intl", () => ({
  useTranslations: (namespace: string) => {
    const node = namespace
      .split(".")
      .reduce(
        (acc: Record<string, unknown>, part) => acc[part] as Record<string, unknown>,
        en as unknown as Record<string, unknown>,
      );
    return (key: string) =>
      key
        .split(".")
        .reduce(
          (acc: unknown, part) => (acc as Record<string, unknown> | undefined)?.[part],
          node,
        ) as string;
  },
}));

const { toastSuccess, toastError } = vi.hoisted(() => ({
  toastSuccess: vi.fn(),
  toastError: vi.fn(),
}));
vi.mock("sonner", () => ({
  toast: { success: toastSuccess, error: toastError },
}));

const baseCase = {
  id: "case-1",
  status: "allocating",
  opened_at: "2026-10-26T12:00:00Z",
  closed_at: null,
  note: null,
  depositado: 26000,
  asignado: 26000,
  disponible: 0,
  deposits: [
    {
      trans_id: "33200000000001",
      monto: 26000,
      recibido_en: "2026-10-26T11:00:00Z",
      anulado_en: null,
    },
  ],
  allocations: [
    {
      id: "alloc-1",
      operation_id: "11111111-2222-3333-4444-555555555555",
      service: "zelle",
      amount_gyd: 26000,
      status: "committed",
      evidence_type: "data",
      created_at: "2026-10-26T12:00:00Z",
    },
  ],
  operations: [
    {
      id: "11111111-2222-3333-4444-555555555555",
      service: "zelle",
      status: "ready_to_transfer",
      quoted_source_amount: 26000,
      allocated: 26000,
    },
  ],
};

const incidentCase = {
  ...baseCase,
  status: "incident",
  note: "conflicto: la tarjeta con prefijo 9234 es cuban_card pero la operación es clasica",
};

function jsonResponse(body: unknown) {
  return { ok: true, json: async () => body } as Response;
}

async function render() {
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  await act(async () => root.render(<FundingCaseBlock conversationId="conv-1" />));
  await act(async () => {
    await Promise.resolve();
  });
  return { node, root };
}

afterEach(() => {
  document.body.replaceChildren();
  vi.unstubAllGlobals();
  toastSuccess.mockReset();
  toastError.mockReset();
});

describe("FundingCaseBlock", () => {
  it("renders the amounts, the deposit and the allocation", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValueOnce(jsonResponse({ case: baseCase })),
    );

    const { node, root } = await render();
    const text = node.textContent ?? "";

    expect(text).toContain(en.Inbox.fundingCase.title);
    expect(text).toContain(en.Inbox.fundingCase.status.allocating);
    expect(text).toContain(formatNumber(26000));
    expect(text).toContain("33200000000001");
    expect(text).toContain("Zelle");

    const assignButton = Array.from(node.querySelectorAll("button")).find(
      (candidate) => candidate.textContent === en.Inbox.fundingCase.assign,
    );
    expect(assignButton).toBeTruthy();
    await act(async () => {
      assignButton?.dispatchEvent(new MouseEvent("click", { bubbles: true }));
      await Promise.resolve();
    });
    expect(node.textContent).toContain(en.Inbox.fundingCase.assignTitle);

    await act(async () => root.unmount());
  });

  it("releases an allocation after confirming", async () => {
    const releasedCase = {
      ...baseCase,
      asignado: 0,
      disponible: 26000,
      allocations: [{ ...baseCase.allocations[0], status: "released" }],
      operations: [{ ...baseCase.operations[0], allocated: 0 }],
    };
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(jsonResponse({ case: baseCase }))
      .mockResolvedValueOnce(jsonResponse({ case: releasedCase }));
    vi.stubGlobal("fetch", fetchMock);

    const { node, root } = await render();
    const releaseButton = Array.from(node.querySelectorAll("button")).find(
      (candidate) => candidate.textContent === en.Inbox.fundingCase.release,
    );
    expect(releaseButton).toBeTruthy();
    await act(async () => {
      releaseButton?.dispatchEvent(new MouseEvent("click", { bubbles: true }));
      await Promise.resolve();
    });

    const confirmButton = Array.from(node.querySelectorAll("button")).find(
      (candidate) => candidate.textContent === en.Inbox.fundingCase.releaseConfirm,
    );
    expect(confirmButton).toBeTruthy();
    await act(async () => {
      confirmButton?.dispatchEvent(new MouseEvent("click", { bubbles: true }));
      await Promise.resolve();
    });
    await act(async () => {
      await Promise.resolve();
    });

    expect(fetchMock).toHaveBeenCalledWith(
      "/api/funding-case/case-1/release",
      expect.objectContaining({ method: "POST" }),
    );
    expect(toastSuccess).toHaveBeenCalledWith(en.Inbox.fundingCase.releaseSaved);
    expect(node.textContent).toContain(formatNumber(26000));

    await act(async () => root.unmount());
  });

  it("shows the incident and resolves it through the API", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(jsonResponse({ case: incidentCase }))
      .mockResolvedValueOnce(jsonResponse({ status: "allocating" }))
      .mockResolvedValueOnce(jsonResponse({ case: baseCase }));
    vi.stubGlobal("fetch", fetchMock);

    const { node, root } = await render();
    expect(node.textContent).toContain(en.Inbox.fundingCase.conflictTitle);
    expect(node.textContent).toContain("9234");

    const button = Array.from(node.querySelectorAll("button")).find(
      (candidate) => candidate.textContent === en.Inbox.fundingCase.resolve,
    );
    expect(button).toBeTruthy();

    await act(async () => {
      button?.dispatchEvent(new MouseEvent("click", { bubbles: true }));
      await Promise.resolve();
    });
    await act(async () => {
      await Promise.resolve();
    });

    expect(fetchMock).toHaveBeenCalledWith(
      "/api/funding-case/case-1/resolve",
      expect.objectContaining({ method: "POST" }),
    );
    expect(toastSuccess).toHaveBeenCalledWith(en.Inbox.fundingCase.resolved);
    expect(node.textContent).not.toContain(en.Inbox.fundingCase.conflictTitle);

    await act(async () => root.unmount());
  });

  it("keeps the incident when the resolver returns it again", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(jsonResponse({ case: incidentCase }))
      .mockResolvedValueOnce(
        jsonResponse({
          status: "incident",
          conflict: "la tarjeta con prefijo 9234 es cuban_card pero la operación es clasica",
        }),
      )
      .mockResolvedValueOnce(jsonResponse({ case: incidentCase }));
    vi.stubGlobal("fetch", fetchMock);

    const { node, root } = await render();
    const button = Array.from(node.querySelectorAll("button")).find(
      (candidate) => candidate.textContent === en.Inbox.fundingCase.resolve,
    );
    expect(button).toBeTruthy();

    await act(async () => {
      button?.dispatchEvent(new MouseEvent("click", { bubbles: true }));
      await Promise.resolve();
    });
    await act(async () => {
      await Promise.resolve();
    });

    expect(toastError).toHaveBeenCalledWith(
      "la tarjeta con prefijo 9234 es cuban_card pero la operación es clasica",
    );
    expect(toastSuccess).not.toHaveBeenCalled();
    expect(node.textContent).toContain(en.Inbox.fundingCase.conflictTitle);

    await act(async () => root.unmount());
  });
});
