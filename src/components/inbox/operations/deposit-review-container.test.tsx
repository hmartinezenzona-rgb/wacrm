// @vitest-environment jsdom
// Spec: chat-remesa-operations-panel / deposit-verification-review (panel
// 16). Container: fetches `crm_comprobantes_de_operacion` (via
// `fetchOperationReceipts`) on mount and renders the real
// `DepositReviewSection` with the fetched data, wiring its verify/force
// callbacks to `verifyDeposit`/`forceVerifyDeposit`. Maps the verify
// result to one of the `depositReview.results.*` messages and refetches +
// calls `onChanged()` (so the panel-level operation list/status reloads)
// only when the attempt actually changed stage — `stageChanged`, or
// (defensively) whenever `resultado` starts with "verificado". A 409
// response on either action shows the generic conflict message.

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import en from "../../../../messages/en.json";
import type { OperationReceiptsRead, VerifyDepositResult } from "@/lib/remittance-operations/types";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

vi.mock("next-intl", () => ({
  useTranslations: (namespace: string) => {
    const node = namespace
      .split(".")
      .reduce((acc: Record<string, unknown>, part) => acc[part] as Record<string, unknown>, en as unknown as Record<string, unknown>);
    return (key: string, params?: Record<string, unknown>) => {
      const raw = key.split(".").reduce((acc: unknown, part) => (acc as Record<string, unknown>)[part], node) as string;
      if (!params) return raw;
      return Object.entries(params).reduce((acc, [k, v]) => acc.replace(`{${k}}`, String(v)), raw);
    };
  },
}));

const fetchOperationReceipts = vi.fn();
const verifyDeposit = vi.fn();
const forceVerifyDeposit = vi.fn();
vi.mock("@/lib/remittance-operations/commands", () => ({
  fetchOperationReceipts: (...args: unknown[]) => fetchOperationReceipts(...args),
  verifyDeposit: (...args: unknown[]) => verifyDeposit(...args),
  forceVerifyDeposit: (...args: unknown[]) => forceVerifyDeposit(...args),
}));

afterEach(() => {
  document.body.replaceChildren();
  vi.restoreAllMocks();
});

const T = en.Inbox.operationsPanel.depositReview;

function flush() {
  return act(async () => {
    await Promise.resolve();
    await Promise.resolve();
  });
}

function readModel(overrides: Partial<OperationReceiptsRead> = {}): OperationReceiptsRead {
  return {
    operationId: "op-1",
    status: "deposit_verification",
    dealId: "deal-1",
    canVerify: true,
    objetivo: 25000,
    depositado: 0,
    saldo: 25000,
    moneda: "GYD",
    receipts: [
      {
        compId: "comp-1",
        messageId: "msg-1",
        mediaUrl: "https://example.test/comp-1.jpg",
        receivedAt: "2026-09-10T00:00:00Z",
        declaredAmount: 25000,
        declaredCurrency: "GYD",
        declaredRef: "10412345678901",
        matchedDeposit: null,
      },
    ],
    consumedDeposits: [],
    ...overrides,
  };
}

function verifyResult(overrides: Partial<VerifyDepositResult> = {}): VerifyDepositResult {
  return {
    resultado: "verificado",
    metodo: "mmg",
    todosVerificados: true,
    totalVerificado: 25000,
    nComprobantes: 1,
    detalle: null,
    objetivo: 25000,
    depositado: 25000,
    saldo: 0,
    stageChanged: true,
    newStatus: "ready_to_transfer",
    ...overrides,
  };
}

interface RenderOptions {
  canEdit?: boolean;
  role?: "owner" | "admin" | "agent" | "viewer" | null;
  onChanged?: () => void;
}

async function renderContainer(options: RenderOptions = {}) {
  const { DepositReviewContainer } = await import("./deposit-review-container");
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  const onChanged = options.onChanged ?? vi.fn();
  await act(async () =>
    root.render(
      <DepositReviewContainer
        operationId="op-1"
        canEdit={options.canEdit ?? true}
        role={options.role ?? "admin"}
        onChanged={onChanged}
      />,
    ),
  );
  return { node, root, onChanged };
}

function textButton(node: Element, text: string) {
  return Array.from(node.querySelectorAll("button")).find((b) => b.textContent?.trim() === text) as
    | HTMLButtonElement
    | undefined;
}

function setValue(input: HTMLInputElement, value: string) {
  const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value")!.set!;
  setter.call(input, value);
  input.dispatchEvent(new Event("input", { bubbles: true }));
}

describe("DepositReviewContainer", () => {
  it("fetches receipts on mount and renders the section", async () => {
    fetchOperationReceipts.mockResolvedValue({ ok: true, data: readModel() });

    const { node } = await renderContainer();
    await flush();

    expect(fetchOperationReceipts).toHaveBeenCalledWith("op-1");
    expect(node.textContent).toContain("Receipts (1)");
    expect(node.textContent).toContain("10412345678901");
  });

  it("shows a load error when the fetch fails", async () => {
    fetchOperationReceipts.mockResolvedValue({ ok: false, status: 500, error: "boom" });

    const { node } = await renderContainer();
    await flush();

    expect(node.textContent).toContain(T.loadError);
  });

  it("on a successful verify (verificado, stageChanged) refetches, calls onChanged, and shows the success message", async () => {
    fetchOperationReceipts.mockResolvedValue({ ok: true, data: readModel() });
    verifyDeposit.mockResolvedValue({ ok: true, result: verifyResult() });
    const onChanged = vi.fn();

    const { node } = await renderContainer({ onChanged });
    await flush();
    expect(fetchOperationReceipts).toHaveBeenCalledTimes(1);

    const verifyButton = textButton(node, T.verify)!;
    await act(async () => verifyButton.dispatchEvent(new MouseEvent("click", { bubbles: true })));
    await flush();

    expect(verifyDeposit).toHaveBeenCalledWith("op-1", [{ ref: "10412345678901", amount: 25000 }]);
    expect(fetchOperationReceipts).toHaveBeenCalledTimes(2);
    expect(onChanged).toHaveBeenCalledTimes(1);
    expect(node.textContent).toContain(T.results.verificado);
  });

  it("shows the mapped error message and does not refetch or call onChanged when the amount does not match", async () => {
    fetchOperationReceipts.mockResolvedValue({ ok: true, data: readModel() });
    verifyDeposit.mockResolvedValue({
      ok: true,
      result: verifyResult({ resultado: "monto_no_coincide", stageChanged: false, todosVerificados: false }),
    });
    const onChanged = vi.fn();

    const { node } = await renderContainer({ onChanged });
    await flush();

    const verifyButton = textButton(node, T.verify)!;
    await act(async () => verifyButton.dispatchEvent(new MouseEvent("click", { bubbles: true })));
    await flush();

    expect(node.textContent).toContain(T.results.monto_no_coincide);
    expect(onChanged).not.toHaveBeenCalled();
    expect(fetchOperationReceipts).toHaveBeenCalledTimes(1);
  });

  it("shows the conflict message on a 409 verify response", async () => {
    fetchOperationReceipts.mockResolvedValue({ ok: true, data: readModel() });
    verifyDeposit.mockResolvedValue({ ok: false, status: 409, error: "stale" });

    const { node } = await renderContainer();
    await flush();

    const verifyButton = textButton(node, T.verify)!;
    await act(async () => verifyButton.dispatchEvent(new MouseEvent("click", { bubbles: true })));
    await flush();

    expect(node.textContent).toContain(T.conflict);
  });

  it("force success refetches, calls onChanged, and shows the forced message", async () => {
    fetchOperationReceipts.mockResolvedValue({ ok: true, data: readModel() });
    forceVerifyDeposit.mockResolvedValue({ ok: true, newStatus: "ready_to_transfer" });
    const onChanged = vi.fn();

    const { node } = await renderContainer({ onChanged, role: "admin" });
    await flush();

    const forceToggle = textButton(node, T.force)!;
    await act(async () => forceToggle.dispatchEvent(new MouseEvent("click", { bubbles: true })));
    const reasonInput = node.querySelector<HTMLInputElement>("#deposit-review-force-reason")!;
    await act(async () => setValue(reasonInput, "manual override"));
    const forceConfirm = textButton(node, T.forceConfirm)!;
    await act(async () => forceConfirm.dispatchEvent(new MouseEvent("click", { bubbles: true })));
    await flush();

    expect(forceVerifyDeposit).toHaveBeenCalledWith("op-1", "manual override");
    expect(fetchOperationReceipts).toHaveBeenCalledTimes(2);
    expect(onChanged).toHaveBeenCalledTimes(1);
    expect(node.textContent).toContain(T.forced);
  });

  it("shows the conflict message on a 409 force response and does not call onChanged", async () => {
    fetchOperationReceipts.mockResolvedValue({ ok: true, data: readModel() });
    forceVerifyDeposit.mockResolvedValue({ ok: false, status: 409, error: "stale" });
    const onChanged = vi.fn();

    const { node } = await renderContainer({ onChanged, role: "admin" });
    await flush();

    const forceToggle = textButton(node, T.force)!;
    await act(async () => forceToggle.dispatchEvent(new MouseEvent("click", { bubbles: true })));
    const reasonInput = node.querySelector<HTMLInputElement>("#deposit-review-force-reason")!;
    await act(async () => setValue(reasonInput, "manual override"));
    const forceConfirm = textButton(node, T.forceConfirm)!;
    await act(async () => forceConfirm.dispatchEvent(new MouseEvent("click", { bubbles: true })));
    await flush();

    expect(node.textContent).toContain(T.conflict);
    expect(onChanged).not.toHaveBeenCalled();
  });

  it("does not offer force verification when the role cannot force (agent)", async () => {
    fetchOperationReceipts.mockResolvedValue({ ok: true, data: readModel() });

    const { node } = await renderContainer({ role: "agent" });
    await flush();

    expect(textButton(node, T.force)).toBeUndefined();
  });

  it("renders nothing when there are no receipts and verification is not offered", async () => {
    fetchOperationReceipts.mockResolvedValue({
      ok: true,
      data: readModel({ receipts: [], canVerify: false }),
    });

    const { node } = await renderContainer();
    await flush();

    expect(node.textContent).toBe("");
  });
});
