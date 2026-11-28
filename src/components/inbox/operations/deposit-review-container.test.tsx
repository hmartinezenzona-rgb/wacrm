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
import es from "../../../../messages/es.json";
import type { OperationReceiptsRead, VerifyDepositResult } from "@/lib/remittance-operations/types";
import type { SummaryAmount } from "./deposit-review-section";

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
const fetchFreeDeposits = vi.fn();
const cambiarEstado = vi.fn();
vi.mock("@/lib/remittance-operations/commands", () => ({
  cambiarEstado: (...args: unknown[]) => cambiarEstado(...args),
  fetchFreeDeposits: (...args: unknown[]) => fetchFreeDeposits(...args),
  fetchOperationReceipts: (...args: unknown[]) => fetchOperationReceipts(...args),
  verifyDeposit: (...args: unknown[]) => verifyDeposit(...args),
  forceVerifyDeposit: (...args: unknown[]) => forceVerifyDeposit(...args),
}));

// The release/move control has its own form and request (consumed-deposits-control.test.tsx): here it is a stub that exposes what the
// container hands it and "moves" on click, so this file tests where the container puts it and what it does afterwards.
// The attach-receipt control owns the chat-image picker and its request (attach-receipt-control.test.tsx): here a stub that shows what the
// container hands it and "attaches" on click.
vi.mock("./attach-receipt-control", () => ({
  AttachReceiptControl: ({ operationId, conversationId, onAttached }: { operationId: string; conversationId: string; onAttached: () => void }) => (
    <button type="button" data-testid="attach-receipt" data-op={operationId} data-conversation={conversationId} onClick={onAttached}>
      attach
    </button>
  ),
}));

vi.mock("./consumed-deposits-control", () => ({
  ConsumedDepositsControl: ({ operationId, deposits, targets, onMoved }: { operationId: string; deposits: unknown[]; targets: { id: string }[]; onMoved: () => void }) => (
    <button type="button" data-testid="move-deposits" data-op={operationId} data-count={deposits.length} data-targets={targets.map((x) => x.id).join(",")} onClick={onMoved}>
      move
    </button>
  ),
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
  summaryAmount?: SummaryAmount | null;
  onAddAmount?: () => void;
  moveTargets?: { id: string; label: string }[];
  conversationId?: string;
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
        summaryAmount={options.summaryAmount}
        onAddAmount={options.onAddAmount}
        moveTargets={options.moveTargets}
        conversationId={options.conversationId}
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

describe("DepositReviewContainer", () => {
  it("fetches receipts on mount and renders the section", async () => {
    fetchOperationReceipts.mockResolvedValue({ ok: true, data: readModel() });

    const { node } = await renderContainer();
    await flush();

    expect(fetchOperationReceipts).toHaveBeenCalledWith("op-1");
    expect(node.querySelector<HTMLInputElement>("#deposit-review-ref-comp-1")!.value).toBe("10412345678901");
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

    expect(verifyDeposit).toHaveBeenCalledWith("op-1", [{ ref: "10412345678901", amount: 25000 }], true);
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

  it("a notify bell turned off reaches verifyDeposit as notify=false", async () => {
    fetchOperationReceipts.mockResolvedValue({ ok: true, data: readModel() });
    verifyDeposit.mockResolvedValue({ ok: true, result: verifyResult() });

    const { node } = await renderContainer();
    await flush();

    const bell = node.querySelector<HTMLButtonElement>("button[aria-pressed]")!;
    await act(async () => bell.dispatchEvent(new MouseEvent("click", { bubbles: true })));
    await act(async () => textButton(node, T.verify)!.dispatchEvent(new MouseEvent("click", { bubbles: true })));
    await flush();

    expect(verifyDeposit).toHaveBeenCalledWith("op-1", [{ ref: "10412345678901", amount: 25000 }], false);
  });

  it("force success refetches, calls onChanged, and shows the forced message", async () => {
    fetchOperationReceipts.mockResolvedValue({ ok: true, data: readModel() });
    forceVerifyDeposit.mockResolvedValue({ ok: true, newStatus: "ready_to_transfer" });
    const onChanged = vi.fn();

    const { node } = await renderContainer({ onChanged, role: "admin" });
    await flush();

    const forceToggle = textButton(node, T.force)!;
    await act(async () => forceToggle.dispatchEvent(new MouseEvent("click", { bubbles: true })));
    const forceConfirm = node.querySelector<HTMLButtonElement>(`button[aria-label="${T.forceConfirm}"]`)!;
    await act(async () => forceConfirm.dispatchEvent(new MouseEvent("click", { bubbles: true })));
    await flush();

    expect(forceVerifyDeposit).toHaveBeenCalledWith("op-1", true);
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
    const forceConfirm = node.querySelector<HTMLButtonElement>(`button[aria-label="${T.forceConfirm}"]`)!;
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

  it("forwards summaryAmount through to the rendered section", async () => {
    fetchOperationReceipts.mockResolvedValue({
      ok: true,
      data: readModel({ status: "ready_to_transfer", canVerify: false }),
    });

    const { node } = await renderContainer({ summaryAmount: { kind: "amount", display: "100 Zelle" } });
    await flush();

    expect(node.textContent).toContain("100 Zelle");
  });

  it("forwards a missing summaryAmount and onAddAmount through to the rendered section", async () => {
    fetchOperationReceipts.mockResolvedValue({
      ok: true,
      data: readModel({ status: "ready_to_transfer", canVerify: false }),
    });
    const onAddAmount = vi.fn();

    const { node } = await renderContainer({ summaryAmount: { kind: "missing" }, onAddAmount });
    await flush();

    const warningButton = textButton(node, en.Inbox.operationsPanel.amountMissing)!;
    expect(warningButton).not.toBeUndefined();
    await act(async () => warningButton.dispatchEvent(new MouseEvent("click", { bubbles: true })));
    expect(onAddAmount).toHaveBeenCalledTimes(1);
  });

  it("refetches receipts silently when refreshToken changes, without showing the loading text", async () => {
    const { DepositReviewContainer } = await import("./deposit-review-container");
    const node = document.createElement("div");
    document.body.appendChild(node);
    const root = createRoot(node);

    fetchOperationReceipts
      .mockResolvedValueOnce({ ok: true, data: readModel() })
      .mockResolvedValueOnce({ ok: true, data: readModel({ objetivo: 30000 }) });

    await act(async () =>
      root.render(
        <DepositReviewContainer
          operationId="op-1"
          canEdit={true}
          role="admin"
          onChanged={vi.fn()}
          refreshToken={0}
        />,
      ),
    );
    await flush();
    expect(fetchOperationReceipts).toHaveBeenCalledTimes(1);

    await act(async () =>
      root.render(
        <DepositReviewContainer
          operationId="op-1"
          canEdit={true}
          role="admin"
          onChanged={vi.fn()}
          refreshToken={1}
        />,
      ),
    );
    await flush();

    expect(fetchOperationReceipts).toHaveBeenCalledTimes(2);
    expect(node.textContent).not.toContain(T.loading);
    await act(async () => root.unmount());
  });

  // Slice: panel-26 (readiness). `initialData` lets the panel container
  // hand this container an already-fetched receipts read model (from the
  // route's prefetch) so the deposit block paints in the same pass as the
  // rest of the card instead of a second round trip.
  it("given initialData, renders the section immediately and performs no initial fetch", async () => {
    const { DepositReviewContainer } = await import("./deposit-review-container");
    const node = document.createElement("div");
    document.body.appendChild(node);
    const root = createRoot(node);

    await act(async () =>
      root.render(
        <DepositReviewContainer
          operationId="op-1"
          canEdit={true}
          role="admin"
          onChanged={vi.fn()}
          initialData={readModel()}
        />,
      ),
    );
    await flush();

    expect(fetchOperationReceipts).not.toHaveBeenCalled();
    expect(node.querySelector<HTMLInputElement>("#deposit-review-ref-comp-1")!.value).toBe("10412345678901");
    await act(async () => root.unmount());
  });

  it("shows a loading skeleton (not a text line) while the initial fetch is pending, keeping the message for screen readers", async () => {
    fetchOperationReceipts.mockReturnValue(new Promise(() => {}));

    const { node } = await renderContainer();

    expect(node.querySelector('[role="status"][aria-busy="true"]')).not.toBeNull();
    expect(node.querySelectorAll(".animate-pulse").length).toBeGreaterThan(0);
    expect(node.textContent).toContain(T.loading);
  });

  it("does not show the loading skeleton when initialData is provided", async () => {
    const { DepositReviewContainer } = await import("./deposit-review-container");
    const node = document.createElement("div");
    document.body.appendChild(node);
    const root = createRoot(node);

    await act(async () =>
      root.render(
        <DepositReviewContainer
          operationId="op-1"
          canEdit={true}
          role="admin"
          onChanged={vi.fn()}
          initialData={readModel()}
        />,
      ),
    );

    expect(node.querySelector('[role="status"][aria-busy="true"]')).toBeNull();
    await act(async () => root.unmount());
  });

  it("refetches silently on a refreshToken bump after mount even when initialData skipped the initial fetch — exactly one refetch, no missed or duplicated call", async () => {
    const { DepositReviewContainer } = await import("./deposit-review-container");
    const node = document.createElement("div");
    document.body.appendChild(node);
    const root = createRoot(node);

    fetchOperationReceipts.mockResolvedValue({ ok: true, data: readModel({ objetivo: 30000 }) });

    await act(async () =>
      root.render(
        <DepositReviewContainer
          operationId="op-1"
          canEdit={true}
          role="admin"
          onChanged={vi.fn()}
          initialData={readModel()}
          refreshToken={0}
        />,
      ),
    );
    await flush();
    expect(fetchOperationReceipts).not.toHaveBeenCalled();

    await act(async () =>
      root.render(
        <DepositReviewContainer
          operationId="op-1"
          canEdit={true}
          role="admin"
          onChanged={vi.fn()}
          initialData={readModel()}
          refreshToken={1}
        />,
      ),
    );
    await flush();

    expect(fetchOperationReceipts).toHaveBeenCalledTimes(1);
    expect(node.textContent).not.toContain(T.loading);
    await act(async () => root.unmount());
  });
});

// panel-fully-editable T3b: link a ledger deposit nobody owns with the verify the container already has.
describe("DepositReviewContainer: link a deposit without an owner", () => {
  const F = en.Inbox.operationsPanel.freeDeposits;
  const DEPOSIT = { transId: "10400000009977", amount: 13000, currency: "GYD", receivedAt: "2026-11-17T14:18:14Z", holder: "Pagador Uno" };
  const click = (el: Element | null | undefined) => act(async () => el!.dispatchEvent(new MouseEvent("click", { bubbles: true })));
  const pickerButton = (node: Element) => node.querySelector(`button[aria-label="${F.button}"]`);

  it("offers the picker while the operation awaits verification and the user can edit", async () => {
    fetchOperationReceipts.mockResolvedValue({ ok: true, data: readModel({ receipts: [] }) });
    const { node } = await renderContainer();
    await flush();

    expect(pickerButton(node)).not.toBeNull();
  });

  it("offers nothing to a user who cannot edit, nor once the operation is not awaiting verification", async () => {
    fetchOperationReceipts.mockResolvedValue({ ok: true, data: readModel() });
    const a = await renderContainer({ canEdit: false });
    await flush();
    expect(pickerButton(a.node)).toBeNull();

    fetchOperationReceipts.mockResolvedValue({ ok: true, data: readModel({ canVerify: false, status: "ready_to_transfer" }) });
    const b = await renderContainer();
    await flush();
    expect(pickerButton(b.node)).toBeNull();
  });

  it("linking a deposit runs the existing verify with its TransID and amount, refetches and tells the panel", async () => {
    fetchOperationReceipts.mockResolvedValue({ ok: true, data: readModel({ receipts: [] }) });
    fetchFreeDeposits.mockResolvedValue({ ok: true, data: [DEPOSIT] });
    verifyDeposit.mockResolvedValue({ ok: true, result: verifyResult() });
    const onChanged = vi.fn();
    const { node } = await renderContainer({ onChanged });
    await flush();

    await click(pickerButton(node));
    await flush();
    await click(node.querySelector(`button[aria-label="${F.link}"]`));
    await flush();

    expect(verifyDeposit).toHaveBeenCalledWith("op-1", [{ ref: "10400000009977", amount: 13000 }], true);
    expect(fetchOperationReceipts).toHaveBeenCalledTimes(2);
    expect(onChanged).toHaveBeenCalledTimes(1);
    expect(node.textContent).toContain(T.results.verificado);
  });
});

// panel-fully-editable T3c: release or move a verified deposit from the deposit block.
describe("DepositReviewContainer: release or move a verified deposit", () => {
  const DEP = { transId: "10400000009977", amount: 13000, currency: "GYD", receivedAt: "2026-11-17T14:18:14Z", consumedAt: "2026-11-17T14:30:00Z" };
  const stub = (node: Element) => node.querySelector<HTMLButtonElement>('[data-testid="move-deposits"]');

  it("offers the control with the verified deposits and the other open operations as targets", async () => {
    fetchOperationReceipts.mockResolvedValue({ ok: true, data: readModel({ status: "ready_to_transfer", canVerify: false, consumedDeposits: [DEP] }) });
    const { node } = await renderContainer({ moveTargets: [{ id: "op-2", label: "x" }, { id: "op-3", label: "y" }] });
    await flush();

    expect(stub(node)).not.toBeNull();
    expect(stub(node)!.dataset.op).toBe("op-1");
    expect(stub(node)!.dataset.count).toBe("1");
    expect(stub(node)!.dataset.targets).toBe("op-2,op-3");
  });

  it("offers nothing without verified deposits, to a user who cannot edit, nor on a closed operation", async () => {
    fetchOperationReceipts.mockResolvedValue({ ok: true, data: readModel({ status: "ready_to_transfer", canVerify: false, consumedDeposits: [] }) });
    const a = await renderContainer();
    await flush();
    expect(stub(a.node)).toBeNull();

    fetchOperationReceipts.mockResolvedValue({ ok: true, data: readModel({ status: "ready_to_transfer", canVerify: false, consumedDeposits: [DEP] }) });
    const b = await renderContainer({ canEdit: false });
    await flush();
    expect(stub(b.node)).toBeNull();

    fetchOperationReceipts.mockResolvedValue({ ok: true, data: readModel({ status: "completed", canVerify: false, consumedDeposits: [DEP] }) });
    const c = await renderContainer();
    await flush();
    expect(stub(c.node)).toBeNull();
  });

  it("once a deposit is moved it refetches and tells the panel", async () => {
    fetchOperationReceipts.mockResolvedValue({ ok: true, data: readModel({ status: "ready_to_transfer", canVerify: false, consumedDeposits: [DEP] }) });
    const onChanged = vi.fn();
    const { node } = await renderContainer({ onChanged });
    await flush();
    expect(fetchOperationReceipts).toHaveBeenCalledTimes(1);

    await act(async () => stub(node)!.dispatchEvent(new MouseEvent("click", { bubbles: true })));
    await flush();

    expect(fetchOperationReceipts).toHaveBeenCalledTimes(2);
    expect(onChanged).toHaveBeenCalledTimes(1);
  });
});

// panel-fully-editable T3a: attach a chat image as a receipt from the deposit block.
describe("DepositReviewContainer: attach a receipt from the chat", () => {
  const attach = (node: Element) => node.querySelector<HTMLButtonElement>('[data-testid="attach-receipt"]');

  it("offers the control with the conversation to an editor on an open operation", async () => {
    fetchOperationReceipts.mockResolvedValue({ ok: true, data: readModel({ receipts: [] }) });
    const { node } = await renderContainer({ conversationId: "conv-1" });
    await flush();

    expect(attach(node)).not.toBeNull();
    expect(attach(node)!.dataset.op).toBe("op-1");
    expect(attach(node)!.dataset.conversation).toBe("conv-1");
  });

  it("offers the control on an open operation even with no receipts and no verification to run", async () => {
    // Staging 2026-11-17: a ready_to_transfer operation with no receipts hid the
    // whole block, so its admin could not attach the chat image of the receipt.
    fetchOperationReceipts.mockResolvedValue({
      ok: true,
      data: readModel({ status: "ready_to_transfer", canVerify: false, receipts: [] }),
    });
    const { node } = await renderContainer({ conversationId: "conv-1" });
    await flush();

    expect(attach(node)).not.toBeNull();
    expect(attach(node)!.dataset.conversation).toBe("conv-1");
  });

  it("offers nothing without a conversation, to a user who cannot edit, nor on a closed operation", async () => {
    fetchOperationReceipts.mockResolvedValue({ ok: true, data: readModel({ receipts: [] }) });
    const a = await renderContainer();
    await flush();
    expect(attach(a.node)).toBeNull();

    const b = await renderContainer({ conversationId: "conv-1", canEdit: false });
    await flush();
    expect(attach(b.node)).toBeNull();

    fetchOperationReceipts.mockResolvedValue({ ok: true, data: readModel({ status: "completed", canVerify: false }) });
    const c = await renderContainer({ conversationId: "conv-1" });
    await flush();
    expect(attach(c.node)).toBeNull();
  });

  it("once a receipt is attached it reloads the receipts", async () => {
    fetchOperationReceipts.mockResolvedValue({ ok: true, data: readModel({ receipts: [] }) });
    const { node } = await renderContainer({ conversationId: "conv-1" });
    await flush();
    expect(fetchOperationReceipts).toHaveBeenCalledTimes(1);

    await act(async () => attach(node)!.dispatchEvent(new MouseEvent("click", { bubbles: true })));
    await flush();

    expect(fetchOperationReceipts).toHaveBeenCalledTimes(2);
  });
});

// Staging 2026-11-17: an operation created from scratch stays in
// collecting_information, so a just-attached receipt had no verify form.
// The receipt block offers the audited status change (migration 379) that
// moves it to deposit_verification, where the verify form lives.
describe("DepositReviewContainer: move to deposit verification from the receipt block", () => {
  const moveButton = (node: Element) => textButton(node, en.Inbox.operationsPanel.depositReview.moveToVerification);
  const collecting = () => readModel({ status: "collecting_information", canVerify: false });

  it("offers the action to an editor on an open operation with a receipt and no verification to run", async () => {
    fetchOperationReceipts.mockResolvedValue({ ok: true, data: collecting() });
    const { node } = await renderContainer();
    await flush();

    expect(moveButton(node)).not.toBeUndefined();
    expect(es.Inbox.operationsPanel.depositReview.moveToVerification).toBe("Pasar a verificación de depósito");
    expect(en.Inbox.operationsPanel.depositReview.moveToVerification).toBe("Move to deposit verification");
  });

  it("clicking it changes the status, refetches the receipts and tells the panel", async () => {
    fetchOperationReceipts
      .mockResolvedValueOnce({ ok: true, data: collecting() })
      .mockResolvedValueOnce({ ok: true, data: readModel({ status: "deposit_verification", canVerify: true }) });
    cambiarEstado.mockResolvedValue({ ok: true, changed: true, newStatus: "deposit_verification" });
    const onChanged = vi.fn();
    const { node } = await renderContainer({ onChanged });
    await flush();
    expect(fetchOperationReceipts).toHaveBeenCalledTimes(1);

    await act(async () => moveButton(node)!.dispatchEvent(new MouseEvent("click", { bubbles: true })));
    await flush();

    expect(cambiarEstado).toHaveBeenCalledWith("op-1", "deposit_verification", false);
    expect(fetchOperationReceipts).toHaveBeenCalledTimes(2);
    expect(onChanged).toHaveBeenCalledTimes(1);
  });

  it("offers nothing once verification is already available", async () => {
    fetchOperationReceipts.mockResolvedValue({ ok: true, data: readModel() });
    const { node } = await renderContainer();
    await flush();

    expect(moveButton(node)).toBeUndefined();
  });

  it("offers nothing to a user who cannot edit", async () => {
    fetchOperationReceipts.mockResolvedValue({ ok: true, data: collecting() });
    const { node } = await renderContainer({ canEdit: false });
    await flush();

    expect(moveButton(node)).toBeUndefined();
  });
});
