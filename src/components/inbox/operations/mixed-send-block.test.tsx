// @vitest-environment jsdom
// The header over a mixed send (migration 253): the deposit total shared by the group and each member's service and
// share, history members included, with the open cards rendered under it.

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import en from "../../../../messages/en.json";
import { formatNumber } from "@/lib/format-number";
import type { RemittanceOperationRead } from "@/lib/remittance-operations/types";

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

afterEach(() => {
  document.body.replaceChildren();
});

const t = en.Inbox.operationsPanel.mixedSend;

function member(id: string, deliveryMethod: string | null, serviceType: string, amount: number): RemittanceOperationRead {
  return {
    id,
    serviceType,
    deliveryMethod,
    quotedSourceAmount: amount,
    mixedGroupId: "op-1",
    beneficiaries: [],
  } as unknown as RemittanceOperationRead;
}

describe("MixedSendBlock", () => {
  it("shows the header with the total and each member's service and share, then the children", async () => {
    const { MixedSendBlock } = await import("./mixed-send-block");
    const node = document.createElement("div");
    document.body.appendChild(node);
    const root = createRoot(node);

    await act(async () =>
      root.render(
        <MixedSendBlock members={[member("op-1", "clasica", "remesa", 18200), member("op-2", null, "recarga", 6200)]}>
          <p data-testid="card">card</p>
        </MixedSendBlock>,
      ),
    );

    const text = node.textContent!;
    expect(text).toContain(t.title);
    expect(text).toContain(t.total.replace("{amount}", formatNumber(24400)));
    expect(text).toContain(t.share.replace("{service}", en.ServiceNames.clasica).replace("{amount}", formatNumber(18200)));
    expect(text).toContain(t.share.replace("{service}", en.ServiceNames.recarga).replace("{amount}", formatNumber(6200)));
    expect(node.querySelector('[data-testid="card"]')).not.toBeNull();
    await act(async () => root.unmount());
  });
});
