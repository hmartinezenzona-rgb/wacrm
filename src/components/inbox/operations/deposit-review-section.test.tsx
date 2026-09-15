// @vitest-environment jsdom
// Spec: panel-19 operation-card redesign, deposit block. Presentational —
// no fetch here, the container owns data loading and the verify/force
// network calls. Two business states, both driven by
// `data.canVerify`/`data.status` (the operation's own state, independent
// of who's viewing): verified (a confirmation line + ref chip, no image)
// and awaiting verification (the first unmatched receipt's viewer + a
// directly-bound "Amount deposited"/"TransID" draft, gated on the
// `canVerify` prop for whether those are interactive or read-only). Every
// other state renders nothing.

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import en from "../../../../messages/en.json";
import type { DepositReceipt, OperationReceiptsRead, VerifyDepositItem } from "@/lib/remittance-operations/types";
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

afterEach(() => {
  document.body.replaceChildren();
  vi.restoreAllMocks();
});

const T = en.Inbox.operationsPanel.depositReview;
const AMOUNT_MISSING = en.Inbox.operationsPanel.amountMissing;

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
  summaryAmount?: SummaryAmount | null;
  onAddAmount?: () => void;
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
        summaryAmount={options.summaryAmount}
        onAddAmount={options.onAddAmount}
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

function textButton(node: Element, text: string) {
  return Array.from(node.querySelectorAll("button")).find((b) => b.textContent?.trim() === text) as
    | HTMLButtonElement
    | undefined;
}

describe("DepositReviewSection", () => {
  describe("verified state (data.canVerify false, status ready_to_transfer/transferring)", () => {
    it("shows the verified line and a ref chip from the matched deposit, with no image", async () => {
      const { node, root } = await render({
        data: readModel({
          status: "ready_to_transfer",
          canVerify: false,
          receipts: [
            receipt({
              matchedDeposit: { transId: "TX-99", amount: 25000, currency: "GYD", receivedAt: null, consumedAt: null },
            }),
          ],
        }),
      });

      expect(node.textContent).toContain(T.verified);
      expect(node.textContent).toContain("TX-99");
      // The chip already carries a hash icon; the text must not repeat it.
      expect(node.textContent).not.toContain("# TX-99");
      expect(node.querySelector("img")).toBeNull();
      await act(async () => root.unmount());
    });

    it("also shows the verified rows for a completed (history) operation", async () => {
      const { node, root } = await render({
        data: readModel({
          status: "completed",
          canVerify: false,
          receipts: [
            receipt({
              matchedDeposit: { transId: "TX-77", amount: 26000, currency: "GYD", receivedAt: null, consumedAt: null },
            }),
          ],
        }),
      });

      expect(node.textContent).toContain(T.verified);
      expect(node.textContent).toContain("TX-77");
      await act(async () => root.unmount());
    });

    it("falls back to the declared ref when there is no matched deposit", async () => {
      const { node, root } = await render({
        data: readModel({ status: "transferring", canVerify: false, receipts: [receipt({ declaredRef: "REF-1" })] }),
      });

      expect(node.textContent).toContain("REF-1");
      await act(async () => root.unmount());
    });

    it("shows no ref chip when no receipt has a ref", async () => {
      const { node, root } = await render({
        data: readModel({
          status: "ready_to_transfer",
          canVerify: false,
          receipts: [receipt({ declaredRef: null, matchedDeposit: null })],
        }),
      });

      expect(node.textContent).toContain(T.verified);
      expect(node.querySelector("button")).toBeNull();
      await act(async () => root.unmount());
    });

    it("renders the three rows in order: verified, amount, transId", async () => {
      const { node, root } = await render({
        data: readModel({
          status: "ready_to_transfer",
          canVerify: false,
          receipts: [
            receipt({
              matchedDeposit: { transId: "TX-99", amount: 25000, currency: "GYD", receivedAt: null, consumedAt: null },
            }),
          ],
        }),
        summaryAmount: { kind: "amount", display: "100 Zelle" },
      });

      const text = node.textContent!;
      const verifiedIdx = text.indexOf(T.verified);
      const amountIdx = text.indexOf("100 Zelle");
      const transIdIdx = text.indexOf("TX-99");
      expect(verifiedIdx).toBeGreaterThanOrEqual(0);
      expect(amountIdx).toBeGreaterThan(verifiedIdx);
      expect(transIdIdx).toBeGreaterThan(amountIdx);
      await act(async () => root.unmount());
    });

    it("renders the TransID row as plain text, never a button", async () => {
      const { node, root } = await render({
        data: readModel({
          status: "ready_to_transfer",
          canVerify: false,
          receipts: [
            receipt({
              matchedDeposit: { transId: "TX-99", amount: 25000, currency: "GYD", receivedAt: null, consumedAt: null },
            }),
          ],
        }),
        summaryAmount: { kind: "amount", display: "100 Zelle" },
      });

      expect(node.textContent).toContain("TX-99");
      expect(node.querySelector("button")).toBeNull();
      await act(async () => root.unmount());
    });

    it("renders the amber missing-amount row as a button that calls onAddAmount when provided", async () => {
      const onAddAmount = vi.fn();
      const { node, root } = await render({
        data: readModel({
          status: "transferring",
          canVerify: false,
          receipts: [receipt({ declaredRef: null, matchedDeposit: null })],
        }),
        summaryAmount: { kind: "missing" },
        onAddAmount,
      });

      const warningButton = textButton(node, AMOUNT_MISSING)!;
      expect(warningButton).not.toBeUndefined();
      await act(async () => warningButton.dispatchEvent(new MouseEvent("click", { bubbles: true })));
      expect(onAddAmount).toHaveBeenCalledTimes(1);
      await act(async () => root.unmount());
    });

    it("renders the missing-amount row as plain amber text (no button) when onAddAmount is not provided", async () => {
      const { node, root } = await render({
        data: readModel({
          status: "transferring",
          canVerify: false,
          receipts: [receipt({ declaredRef: null, matchedDeposit: null })],
        }),
        summaryAmount: { kind: "missing" },
      });

      expect(node.textContent).toContain(AMOUNT_MISSING);
      expect(node.querySelector("button")).toBeNull();
      await act(async () => root.unmount());
    });

    it("omits the amount row entirely when summaryAmount is not provided", async () => {
      const { node, root } = await render({
        data: readModel({
          status: "transferring",
          canVerify: false,
          receipts: [receipt({ declaredRef: null, matchedDeposit: null })],
        }),
      });

      expect(node.textContent).not.toContain(AMOUNT_MISSING);
      await act(async () => root.unmount());
    });
  });

  describe("awaiting verification (data.canVerify true)", () => {
    it("shows the not-verified line and the viewer for the first unmatched receipt", async () => {
      const { node, root } = await render({ data: readModel() });

      expect(node.textContent).toContain(T.notVerified);
      expect(node.querySelector("img")).not.toBeNull();
      await act(async () => root.unmount());
    });

    it("shows the last verify result's reason message below the not-verified line", async () => {
      const { node, root } = await render({ result: { kind: "error", message: T.results.monto_no_coincide } });

      expect(node.textContent).toContain(T.notVerified);
      expect(node.textContent).toContain(T.results.monto_no_coincide);
      await act(async () => root.unmount());
    });

    it("prefills Amount deposited/TransID from the receipt's declared values and submits edits on verify", async () => {
      const { node, onVerify } = await render();

      const amountInput = node.querySelector<HTMLInputElement>("#deposit-review-amount-comp-1")!;
      const refInput = node.querySelector<HTMLInputElement>("#deposit-review-ref-comp-1")!;
      expect(amountInput.value).toBe("25000");
      expect(refInput.value).toBe("10412345678901");

      await act(async () => setValue(amountInput, "30000"));
      await act(async () => setValue(refInput, "NEWREF123"));

      const verifyButton = textButton(node, T.verify)!;
      await act(async () => verifyButton.dispatchEvent(new MouseEvent("click", { bubbles: true })));

      expect(onVerify).toHaveBeenCalledWith([{ ref: "NEWREF123", amount: 30000 }]);
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

      // No unmatched receipt at all: no verify button is rendered.
      expect(textButton(node, T.verify)).toBeUndefined();
    });

    it("disables the verify button while busy", async () => {
      const { node } = await render({ busy: true });
      const verifyButton = textButton(node, T.verify)!;
      expect(verifyButton.disabled).toBe(true);
    });

    it("shows '1/2' and switches between multiple unmatched receipts, keeping other drafts for verify", async () => {
      const { node, onVerify } = await render({
        data: readModel({
          receipts: [
            receipt({ compId: "comp-1", declaredRef: "ref-1", declaredAmount: 1000 }),
            receipt({ compId: "comp-2", declaredRef: "ref-2", declaredAmount: 2000 }),
          ],
        }),
      });

      expect(node.textContent).toContain("1/2");
      expect(node.querySelector<HTMLInputElement>("#deposit-review-ref-comp-1")!.value).toBe("ref-1");

      const next = Array.from(node.querySelectorAll("button")).find((b) => b.textContent?.trim() === "›")!;
      await act(async () => next.dispatchEvent(new MouseEvent("click", { bubbles: true })));

      expect(node.textContent).toContain("2/2");
      expect(node.querySelector<HTMLInputElement>("#deposit-review-ref-comp-2")!.value).toBe("ref-2");

      const verifyButton = textButton(node, T.verify)!;
      await act(async () => verifyButton.dispatchEvent(new MouseEvent("click", { bubbles: true })));

      expect(onVerify).toHaveBeenCalledWith([
        { ref: "ref-1", amount: 1000 },
        { ref: "ref-2", amount: 2000 },
      ]);
    });

    it("read-only when canVerify is false: shows values as text, no inputs, no verify/force", async () => {
      const { node } = await render({ canVerify: false });

      expect(node.querySelector("input")).toBeNull();
      expect(node.textContent).toContain("25000");
      expect(node.textContent).toContain("10412345678901");
      expect(textButton(node, T.verify)).toBeUndefined();
      expect(node.textContent).not.toContain(T.force);
      expect(node.querySelector("img")).not.toBeNull();
    });

    it("hides the force link when canForce is false", async () => {
      const { node } = await render({ canForce: false });
      expect(textButton(node, T.verify)).not.toBeUndefined();
      expect(node.textContent).not.toContain(T.force);
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
  });

  it("renders nothing for any other state", async () => {
    const { node } = await render({
      data: readModel({ status: "incident", canVerify: false }),
      canVerify: false,
    });

    expect(node.textContent).toBe("");
  });
});
