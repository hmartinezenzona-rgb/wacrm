// @vitest-environment jsdom
// Spec: chat-remesa-operations-panel / deposit-verification-review (panel
// 16). Presentational "Receipts" block rendered above the beneficiaries
// list inside an expanded operation card: lists each declared deposit
// receipt with its thumbnail, amount, reference and match state, lets an
// agent correct the declared ref/amount locally before submitting a verify
// attempt, and (for admins) force-verify with a reason. No fetch here —
// the container owns data loading and the verify/force network calls;
// this component only keeps local UI/draft state and calls back.

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import en from "../../../../messages/en.json";
import type { DepositReceipt, OperationReceiptsRead, VerifyDepositItem } from "@/lib/remittance-operations/types";

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

afterEach(() => {
  document.body.replaceChildren();
  vi.restoreAllMocks();
});

const T = en.Inbox.operationsPanel.depositReview;

function receipt(overrides: Partial<DepositReceipt> = {}): DepositReceipt {
  return {
    compId: "comp-1",
    messageId: "msg-1",
    mediaUrl: "https://example.test/comp-1.jpg",
    receivedAt: "2026-09-10T00:00:00Z",
    declaredAmount: 25000,
    declaredCurrency: "GYD",
    declaredRef: "10412345678901",
    matchedDeposit: null,
    ...overrides,
  };
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
    receipts: [receipt()],
    consumedDeposits: [],
    ...overrides,
  };
}

interface RenderOptions {
  data?: OperationReceiptsRead;
  canVerify?: boolean;
  canForce?: boolean;
  busy?: boolean;
  result?: { kind: "success" | "error"; message: string } | null;
  onVerify?: (items: VerifyDepositItem[]) => void;
  onForce?: (reason: string) => void;
}

async function render(options: RenderOptions = {}) {
  const { DepositReviewSection } = await import("./deposit-review-section");
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  const onVerify = options.onVerify ?? vi.fn();
  const onForce = options.onForce ?? vi.fn();
  await act(async () =>
    root.render(
      <DepositReviewSection
        data={options.data ?? readModel()}
        canVerify={options.canVerify ?? true}
        canForce={options.canForce ?? true}
        busy={options.busy ?? false}
        result={options.result ?? null}
        onVerify={onVerify}
        onForce={onForce}
      />,
    ),
  );
  return { node, root, onVerify, onForce };
}

function setValue(input: HTMLInputElement, value: string) {
  const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value")!.set!;
  setter.call(input, value);
  input.dispatchEvent(new Event("input", { bubbles: true }));
}

function iconButton(node: Element, label: string) {
  return node.querySelector(`button[aria-label="${label}"]`) as HTMLButtonElement | null;
}

function textButton(node: Element, text: string) {
  return Array.from(node.querySelectorAll("button")).find((b) => b.textContent?.trim() === text) as
    | HTMLButtonElement
    | undefined;
}

describe("DepositReviewSection", () => {
  it("renders the title with the receipt count, the formatted amount and the reference with a copy button", async () => {
    const { node, root } = await render();

    expect(node.textContent).toContain("Receipts (1)");
    expect(node.textContent).toContain("25,000 GYD");
    expect(node.textContent).toContain("10412345678901");
    expect(iconButton(node, `${en.Inbox.operationsPanel.copy} ${T.ref}`)).not.toBeNull();
    await act(async () => root.unmount());
  });

  it("shows 'Not matched' for a receipt with no matched deposit", async () => {
    const { node, root } = await render();
    expect(node.textContent).toContain(T.notMatched);
    await act(async () => root.unmount());
  });

  it("shows 'Matched <transId>' for a receipt with a matched deposit", async () => {
    const { node, root } = await render({
      data: readModel({
        receipts: [
          receipt({
            matchedDeposit: { transId: "TX-99", amount: 25000, currency: "GYD", receivedAt: null, consumedAt: null },
          }),
        ],
      }),
    });
    expect(node.textContent).toContain("Matched TX-99");
    await act(async () => root.unmount());
  });

  it("hides the verify button and the force link when canVerify is false, but still shows receipts read-only", async () => {
    const { node, root } = await render({ canVerify: false });
    expect(textButton(node, T.verify)).toBeUndefined();
    expect(node.textContent).not.toContain(T.force);
    expect(node.textContent).toContain("10412345678901");
    await act(async () => root.unmount());
  });

  it("hides the force link when canForce is false", async () => {
    const { node, root } = await render({ canForce: false });
    expect(textButton(node, T.verify)).not.toBeUndefined();
    expect(node.textContent).not.toContain(T.force);
    await act(async () => root.unmount());
  });

  it("edits a receipt's ref/amount, saves the draft, and sends the edited values on verify", async () => {
    const { node, onVerify } = await render();

    const editButton = iconButton(node, T.edit)!;
    await act(async () => editButton.dispatchEvent(new MouseEvent("click", { bubbles: true })));

    const refInput = node.querySelector<HTMLInputElement>("#deposit-review-ref-comp-1")!;
    const amountInput = node.querySelector<HTMLInputElement>("#deposit-review-amount-comp-1")!;
    await act(async () => setValue(refInput, "NEWREF123"));
    await act(async () => setValue(amountInput, "30000"));

    const saveButton = textButton(node, T.save)!;
    await act(async () => saveButton.dispatchEvent(new MouseEvent("click", { bubbles: true })));

    const verifyButton = textButton(node, T.verify)!;
    await act(async () => verifyButton.dispatchEvent(new MouseEvent("click", { bubbles: true })));

    expect(onVerify).toHaveBeenCalledWith([{ ref: "NEWREF123", amount: 30000 }]);
  });

  it("does not submit unsaved edits (Cancel discards the pending edit)", async () => {
    const { node, onVerify } = await render();

    const editButton = iconButton(node, T.edit)!;
    await act(async () => editButton.dispatchEvent(new MouseEvent("click", { bubbles: true })));
    const refInput = node.querySelector<HTMLInputElement>("#deposit-review-ref-comp-1")!;
    await act(async () => setValue(refInput, "DISCARDED"));

    const cancelButton = textButton(node, T.cancel)!;
    await act(async () => cancelButton.dispatchEvent(new MouseEvent("click", { bubbles: true })));

    const verifyButton = textButton(node, T.verify)!;
    await act(async () => verifyButton.dispatchEvent(new MouseEvent("click", { bubbles: true })));

    expect(onVerify).toHaveBeenCalledWith([{ ref: "10412345678901", amount: 25000 }]);
  });

  it("excludes matched receipts from the verify items", async () => {
    const { node, onVerify } = await render({
      data: readModel({
        receipts: [
          receipt({ compId: "comp-1", declaredRef: "ref-1", declaredAmount: 1000 }),
          receipt({
            compId: "comp-2",
            declaredRef: "ref-2",
            declaredAmount: 2000,
            matchedDeposit: { transId: "TX-1", amount: 2000, currency: "GYD", receivedAt: null, consumedAt: null },
          }),
        ],
      }),
    });

    const verifyButton = textButton(node, T.verify)!;
    await act(async () => verifyButton.dispatchEvent(new MouseEvent("click", { bubbles: true })));

    expect(onVerify).toHaveBeenCalledWith([{ ref: "ref-1", amount: 1000 }]);
  });

  it("disables the verify button when there is no eligible receipt", async () => {
    const { node } = await render({
      data: readModel({
        receipts: [
          receipt({
            matchedDeposit: { transId: "TX-1", amount: 25000, currency: "GYD", receivedAt: null, consumedAt: null },
          }),
        ],
      }),
    });

    const verifyButton = textButton(node, T.verify)!;
    expect(verifyButton.disabled).toBe(true);
  });

  it("disables the verify button while busy", async () => {
    const { node } = await render({ busy: true });
    const verifyButton = textButton(node, T.verify)!;
    expect(verifyButton.disabled).toBe(true);
  });

  it("keeps the force confirm button disabled until the reason is at least 5 trimmed characters, then calls onForce with the trimmed reason", async () => {
    const { node, onForce } = await render();

    const forceToggle = textButton(node, T.force)!;
    await act(async () => forceToggle.dispatchEvent(new MouseEvent("click", { bubbles: true })));

    const reasonInput = node.querySelector<HTMLInputElement>("#deposit-review-force-reason")!;
    expect(textButton(node, T.forceConfirm)!.disabled).toBe(true);

    await act(async () => setValue(reasonInput, "1234"));
    expect(textButton(node, T.forceConfirm)!.disabled).toBe(true);

    await act(async () => setValue(reasonInput, "  valid reason  "));
    expect(textButton(node, T.forceConfirm)!.disabled).toBe(false);

    await act(async () => textButton(node, T.forceConfirm)!.dispatchEvent(new MouseEvent("click", { bubbles: true })));
    expect(onForce).toHaveBeenCalledWith("valid reason");
  });

  it("opens a dialog with the full receipt image on thumbnail click", async () => {
    const { node } = await render();

    expect(document.body.querySelector('[data-slot="dialog-content"]')).toBeNull();
    const thumbnail = iconButton(node, T.enlarge)!;
    await act(async () => thumbnail.dispatchEvent(new MouseEvent("click", { bubbles: true })));

    const dialogImg = document.body.querySelector<HTMLImageElement>('[data-slot="dialog-content"] img');
    expect(dialogImg).not.toBeNull();
    expect(dialogImg!.getAttribute("src")).toBe("https://example.test/comp-1.jpg");
  });

  it("renders the result line with role=status", async () => {
    const { node } = await render({ result: { kind: "success", message: "Verified · ready to transfer" } });
    const status = node.querySelector('[role="status"]');
    expect(status).not.toBeNull();
    expect(status!.textContent).toContain("Verified · ready to transfer");
  });
});
