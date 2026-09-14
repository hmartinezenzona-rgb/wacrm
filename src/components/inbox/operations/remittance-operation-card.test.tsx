// @vitest-environment jsdom
// Spec: chat-remesa-operations-panel ("List All Open Remesas Per
// Conversation" — lists ALL beneficiaries per remesa, supports multiple
// beneficiaries). Read-only: no correction/verify/deliver affordances
// (those are Slices 6-8, out of scope here).

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import en from "../../../../messages/en.json";
import type { RemittanceOperationRead } from "@/lib/remittance-operations/types";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

vi.mock("next-intl", () => ({
  useTranslations: (namespace: string) => {
    const node = namespace.split(".").reduce((acc: Record<string, unknown>, part) => acc[part] as Record<string, unknown>, en as unknown as Record<string, unknown>);
    return (key: string) => key.split(".").reduce((acc: unknown, part) => (acc as Record<string, unknown>)[part], node) as string;
  },
}));

afterEach(() => {
  document.body.replaceChildren();
  vi.restoreAllMocks();
});

function operation(overrides: Partial<RemittanceOperationRead>): RemittanceOperationRead {
  return {
    id: "op-1",
    status: "deposit_verification",
    serviceType: "remesa",
    sourceCurrency: "GYD",
    destinationCurrency: null,
    deliveryMethod: null,
    depositMethod: null,
    quotedSourceAmount: 10000,
    quotedDestinationAmount: null,
    adminLockedFields: {},
    createdAt: "2026-09-14T00:00:00Z",
    completedAt: null,
    beneficiaries: [],
    ...overrides,
  };
}

async function render(op: RemittanceOperationRead) {
  const { RemittanceOperationCard } = await import("./remittance-operation-card");
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  await act(async () => root.render(<RemittanceOperationCard operation={op} />));
  return { node, root };
}

describe("RemittanceOperationCard", () => {
  it("renders the source amount and the status label", async () => {
    const { node, root } = await render(
      operation({ quotedSourceAmount: 10000, sourceCurrency: "GYD", status: "deposit_verification" }),
    );

    expect(node.textContent).toContain("10,000 GYD");
    expect(node.textContent).toContain("Deposit verification");
    await act(async () => root.unmount());
  });

  it("renders every beneficiary of a multi-beneficiary remesa with masked card/phone", async () => {
    const { node, root } = await render(
      operation({
        beneficiaries: [
          {
            id: "ben-1",
            beneficiaryType: "cuban_card",
            name: "Yaima Perez",
            cardNumberMasked: "9205****9412",
            phoneMasked: "*******1111",
            zelleAccount: null,
            deliveryMethod: null,
            amount: null,
            currency: null,
            position: 1,
          },
          {
            id: "ben-2",
            beneficiaryType: "zelle",
            name: "Yaima Perez Zelle",
            cardNumberMasked: null,
            phoneMasked: null,
            zelleAccount: "yaima@example.invalid",
            deliveryMethod: null,
            amount: null,
            currency: null,
            position: 2,
          },
        ],
      }),
    );

    expect(node.textContent).toContain("Yaima Perez");
    expect(node.textContent).toContain("9205****9412");
    expect(node.textContent).toContain("*******1111");
    expect(node.textContent).toContain("Yaima Perez Zelle");
    expect(node.textContent).toContain("yaima@example.invalid");
    // Never a raw card/phone value, only the masked form.
    expect(node.textContent).not.toContain("92051234");
    await act(async () => root.unmount());
  });

  it("renders the no-beneficiaries state when the list is empty (triangulation)", async () => {
    const { node, root } = await render(operation({ beneficiaries: [] }));

    expect(node.textContent).toContain("No beneficiaries recorded yet");
    await act(async () => root.unmount());
  });
});
