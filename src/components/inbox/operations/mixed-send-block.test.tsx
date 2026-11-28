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

describe("MixedSendBlock waiting for the deposit", () => {
  it("says the send is waiting for the deposit only when asked to", async () => {
    const { MixedSendBlock } = await import("./mixed-send-block");
    const node = document.createElement("div");
    document.body.appendChild(node);
    const root = createRoot(node);
    const members = [member("op-1", "zelle", "remesa", 13000), member("op-2", null, "recarga", 12400)];

    await act(async () => root.render(<MixedSendBlock members={members} awaitingDeposit><p>card</p></MixedSendBlock>));
    expect(node.textContent).toContain(t.awaitingDeposit);
    expect(node.textContent).toContain(t.total.replace("{amount}", formatNumber(25400)));

    await act(async () => root.render(<MixedSendBlock members={members}><p>card</p></MixedSendBlock>));
    expect(node.textContent).not.toContain(t.awaitingDeposit);
    await act(async () => root.unmount());
  });
});

// ---- Trial (local model): each share shows what the recipient gets ------------------------------------------------------
describe("MixedSendBlock destinations", () => {
  it("adds '→ <amount> <currency>' after a share that has a destination, and nothing after one that has none", async () => {
    const { MixedSendBlock } = await import("./mixed-send-block");
    const node = document.createElement("div");
    document.body.appendChild(node);
    const root = createRoot(node);
    const clasica = { ...member("op-1", "clasica", "remesa", 18200), quotedDestinationAmount: 70, destinationCurrency: "USD" } as RemittanceOperationRead;
    const recarga = member("op-2", null, "recarga", 6200);

    await act(async () => root.render(<MixedSendBlock members={[clasica, recarga]}><p>card</p></MixedSendBlock>));

    const items = [...node.querySelectorAll("li")].map((li) => li.textContent ?? "");
    expect(items[0]).toContain(`→ ${formatNumber(70)} USD`);
    expect(items[1]).not.toContain("→");
    await act(async () => root.unmount());
  });
});

// ---- Mockup v2: one status chip in the header, the deposit line, and the group's actions at the END --------------------------
describe("MixedSendBlock completion layout", () => {
  async function render(props: Record<string, unknown>) {
    const { MixedSendBlock } = await import("./mixed-send-block");
    const node = document.createElement("div");
    document.body.appendChild(node);
    const root = createRoot(node);
    await act(async () =>
      root.render(
        <MixedSendBlock members={[member("op-1", "clasica", "remesa", 18200), member("op-2", null, "recarga", 6200)]} {...props}>
          <article data-testid="card">card</article>
        </MixedSendBlock>,
      ),
    );
    return { node, root };
  }

  it("shows the status chip once in the header, with the verified deposit line", async () => {
    const { node, root } = await render({ statusChip: { status: "ready_to_transfer", label: "Ready to transfer" }, depositTransId: "T-0001" });

    const header = node.querySelector("section > header")!;
    expect(header.textContent).toContain("Ready to transfer");
    expect(header.textContent).toContain(t.verifiedDeposit.replace("{transId}", "0001"));
    expect(node.textContent!.split("Ready to transfer")).toHaveLength(2);
    await act(async () => root.unmount());
  });

  it("puts the actions after the member cards, not in the header", async () => {
    const { node, root } = await render({ actions: <button type="button">Group action</button> });

    const section = node.querySelector("section")!;
    const action = [...section.querySelectorAll("button")].find((b) => b.textContent === "Group action")!;
    expect(section.querySelector("header")!.contains(action)).toBe(false);
    const card = node.querySelector('[data-testid="card"]')!;
    expect(card.compareDocumentPosition(action) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    await act(async () => root.unmount());
  });

  it("replaces the shares, cards and actions with the open section, keeping the title and total", async () => {
    const { node, root } = await render({
      statusChip: { status: "ready_to_transfer", label: "Ready to transfer" },
      actions: <button type="button">Group action</button>,
      section: <div data-testid="open-section">open</div>,
    });

    expect(node.querySelector('[data-testid="open-section"]')).not.toBeNull();
    expect(node.querySelector('[data-testid="card"]')).toBeNull();
    expect(node.querySelectorAll("li")).toHaveLength(0);
    expect(node.textContent).not.toContain("Group action");
    expect(node.textContent).toContain(t.total.replace("{amount}", formatNumber(24400)));
    expect(node.textContent).toContain("Ready to transfer");
    await act(async () => root.unmount());
  });
});

