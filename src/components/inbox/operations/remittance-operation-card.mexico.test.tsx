// @vitest-environment jsdom
// México recipients on an operation card: a bank-account recipient shows its CLABE (grouped for reading, copied
// whole), bank and holder; a cardless withdrawal shows its network (Coppel/BBVA), receiver name and phone.

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import en from "../../../../messages/en.json";
import type { RemittanceBeneficiaryRead, RemittanceOperationRead } from "@/lib/remittance-operations/types";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

vi.mock("next-intl", () => ({
  useTranslations: (namespace: string) => {
    const node = namespace.split(".").reduce((acc: Record<string, unknown>, part) => acc[part] as Record<string, unknown>, en as unknown as Record<string, unknown>);
    return (key: string, params?: Record<string, unknown>) => {
      const raw = key.split(".").reduce((acc: unknown, part) => (acc as Record<string, unknown>)[part], node) as string;
      if (!params) return raw;
      return Object.entries(params).reduce((acc, [k, v]) => acc.replace(`{${k}}`, String(v)), raw);
    };
  },
}));

vi.mock("@/lib/remittance-operations/commands", () => ({ corregirBeneficiario: vi.fn() }));
vi.mock("./deposit-review-container", () => ({ DepositReviewContainer: () => null }));
vi.mock("./operation-correction-form", () => ({ OperationCorrectionForm: () => null }));
vi.mock("./split-deposit-form", () => ({ SplitDepositForm: () => null }));

afterEach(() => {
  document.body.replaceChildren();
});

const copyLabel = (label: string) => en.Inbox.operationsPanel.copyValue.replace("{label}", label);
const ops = en.Inbox.operationsPanel;

function beneficiary(overrides: Partial<RemittanceBeneficiaryRead>): RemittanceBeneficiaryRead {
  return {
    id: "ben-mx",
    beneficiaryType: "mexico_cuenta",
    name: null,
    cardNumber: null,
    phone: null,
    zelleAccount: null,
    deliveryMethod: null,
    amount: null,
    amountOrigin: null,
    currency: null,
    position: 1,
    address: null,
    idPhotoWamid: null,
    idPhotoUrl: null,
    ...overrides,
  } as RemittanceBeneficiaryRead;
}

function mexicoOperation(beneficiary: RemittanceBeneficiaryRead): RemittanceOperationRead {
  return {
    id: "op-mx",
    status: "ready_to_transfer",
    serviceType: "mexico",
    sourceCurrency: "GYD",
    destinationCurrency: "MXN",
    deliveryMethod: beneficiary.beneficiaryType,
    depositMethod: null,
    quotedSourceAmount: 26000,
    quotedDestinationAmount: null,
    quotedDestinationRate: null,
    quotedDestinationOrigin: null,
    adminLockedFields: {},
    createdAt: "2026-10-20T00:00:00Z",
    completedAt: null,
    isHistory: false,
    beneficiariesComplete: true,
    deliveryMode: null,
    deliveredAt: null,
    mixedGroupId: null,
    beneficiaries: [beneficiary],
  } as RemittanceOperationRead;
}

async function render(op: RemittanceOperationRead) {
  const { RemittanceOperationCard } = await import("./remittance-operation-card");
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  await act(async () =>
    root.render(
      <RemittanceOperationCard
        operation={op}
        canEdit={false}
        role="agent"
        otherOpenOperations={[]}
        onChanged={vi.fn()}
        expanded
        onToggle={vi.fn()}
        conversationId="conv-1"
      />,
    ),
  );
  return { node, root };
}

describe("RemittanceOperationCard on a México bank account", () => {
  it("shows the CLABE grouped 4-4-4-6, copyable as its full digits, with the bank and holder", async () => {
    const { node, root } = await render(
      mexicoOperation(beneficiary({ beneficiaryType: "mexico_cuenta", name: "Ana Lopez", clabe: "012345678901234567", bankName: "BBVA" })),
    );

    const clabe = node.querySelector<HTMLElement>(`[aria-label="${copyLabel(ops.clabe)}"]`);
    expect(clabe).not.toBeNull();
    expect(clabe!.textContent).toContain("0123 4567 8901 234567");
    expect(node.textContent).toContain("BBVA");
    expect(node.querySelector(`[aria-label="${copyLabel(ops.name)}"]`)!.textContent).toContain("Ana Lopez");
    expect(node.querySelector(`[aria-label="${copyLabel(ops.card)}"]`)).toBeNull();
    await act(async () => root.unmount());
  });
});

describe("RemittanceOperationCard on a México cardless withdrawal", () => {
  it("shows the withdrawal network, the receiver's name and phone, and no CLABE", async () => {
    const { node, root } = await render(
      mexicoOperation(beneficiary({ beneficiaryType: "mexico_retiro", name: "Luis Perez", phone: "52345678", bankName: "Coppel" })),
    );

    expect(node.textContent).toContain("Coppel");
    expect(node.querySelector(`[aria-label="${copyLabel(ops.name)}"]`)!.textContent).toContain("Luis Perez");
    expect(node.querySelector(`[aria-label="${copyLabel(ops.phone)}"]`)!.textContent).toContain("52345678");
    expect(node.querySelector(`[aria-label="${copyLabel(ops.clabe)}"]`)).toBeNull();
    await act(async () => root.unmount());
  });
});
