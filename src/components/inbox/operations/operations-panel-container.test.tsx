// @vitest-environment jsdom
// Spec: chat-remesa-operations-panel. Covers the container's fetch + state
// machine: loads on conversationId, lists every open remesa (ninguna shows
// nothing / no fabrication, ambigua shows the banner + still lists every
// operation instead of picking one), that a card reporting a change (via
// `onChanged`) makes the container refetch, and the accordion behavior:
// only one card is expanded at a time (owned here as `expandedId`),
// defaulting to the single operation when there's exactly one.

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import en from "../../../../messages/en.json";
import type { ConversationOperationsRead, RemittanceOperationRead } from "@/lib/remittance-operations/types";

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

// canEdit gate: `useCan` composes with `useAuth`, which needs a provider
// this test doesn't set up. Mocked directly so the container's own
// canEdit-computation logic is what's under test, not the auth context.
vi.mock("@/hooks/use-can", () => ({
  useCan: () => true,
}));

const corregirBeneficiario = vi.fn();
vi.mock("@/lib/remittance-operations/commands", () => ({
  corregirOperacion: vi.fn(),
  corregirBeneficiario: (...args: unknown[]) => corregirBeneficiario(...args),
  reasignarBeneficiario: vi.fn(),
}));

// Deposit review has its own fetch/network flow, covered by
// deposit-review-container.test.tsx — mocked here to a null-rendering
// stub so this file's accordion/resolver-state tests stay isolated from
// it (this container is rendered by the real, unmocked
// RemittanceOperationCard whenever a card is expanded).
vi.mock("./deposit-review-container", () => ({
  DepositReviewContainer: () => null,
}));

// Chainable `supabase.channel(...).on(...).subscribe()` mock that records
// every channel created (name, the `on()` args, subscribe calls) so tests
// can capture the realtime handler and assert on cleanup, without pulling
// in the real `@supabase/ssr` client.
const mockRealtime = vi.hoisted(() => {
  interface MockChannel {
    name: string;
    handler: ((payload?: unknown) => void) | null;
    onCalls: Array<[string, unknown]>;
    subscribeCalls: number;
    on: (event: string, filter: unknown, handler: (payload?: unknown) => void) => MockChannel;
    subscribe: () => MockChannel;
  }
  const channels: MockChannel[] = [];
  const channelCalls: string[] = [];
  const removeChannelCalls: unknown[] = [];

  // Like realtime-js >= 2.108: `channel(topic)` hands back the EXISTING channel
  // when one with that topic is live, and `on()` after `subscribe()` throws.
  // That is exactly how a second mounted panel crashed the mobile inbox.
  function channel(name: string): MockChannel {
    channelCalls.push(name);
    const existing = channels.find((c) => c.name === name && !removeChannelCalls.includes(c));
    if (existing) return existing;
    const chan: MockChannel = {
      name,
      handler: null,
      onCalls: [],
      subscribeCalls: 0,
      on(event, filter, handler) {
        if (chan.subscribeCalls > 0) {
          throw new Error(`cannot add \`postgres_changes\` callbacks for realtime:${name} after \`subscribe()\`.`);
        }
        chan.onCalls.push([event, filter]);
        chan.handler = handler;
        return chan;
      },
      subscribe() {
        chan.subscribeCalls += 1;
        return chan;
      },
    };
    channels.push(chan);
    return chan;
  }

  function removeChannel(ch: unknown) {
    removeChannelCalls.push(ch);
  }

  function reset() {
    channels.length = 0;
    channelCalls.length = 0;
    removeChannelCalls.length = 0;
  }

  return { channels, channelCalls, removeChannelCalls, channel, removeChannel, reset };
});

vi.mock("@/lib/supabase/client", () => ({
  createClient: () => ({ channel: mockRealtime.channel, removeChannel: mockRealtime.removeChannel }),
}));

function flush() {
  return act(async () => {
    await Promise.resolve();
    await Promise.resolve();
  });
}

afterEach(() => {
  document.body.replaceChildren();
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
  vi.useRealTimers();
  mockRealtime.reset();
});

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status });
}

const OP1 = {
  id: "op-1",
  status: "deposit_verification" as const,
  serviceType: "remesa",
  sourceCurrency: "GYD",
  destinationCurrency: null,
  deliveryMethod: null,
  depositMethod: null,
  quotedSourceAmount: 10000,
  quotedDestinationAmount: null,
  quotedDestinationRate: null,
  quotedDestinationOrigin: null,
  adminLockedFields: {},
  createdAt: "2026-09-14T00:00:00Z",
  completedAt: null,
  isHistory: false,
  beneficiariesComplete: true,
  deliveryMode: null,
  deliveredAt: null,
  beneficiaries: [
    {
      id: "ben-1",
      beneficiaryType: "cuban_card" as const,
      name: null,
      cardNumber: "9205123412349412",
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
    },
  ],
};

const OP2 = {
  ...OP1,
  id: "op-2",
  status: "awaiting_deposit" as const,
  beneficiaries: [],
};

const HISTORY_OP = {
  ...OP1,
  id: "op-hist-1",
  status: "completed" as const,
  isHistory: true,
  beneficiariesComplete: true,
  deliveryMode: "proof_sent" as const,
  completedAt: "2026-09-10T00:00:00Z",
  deliveredAt: "2026-09-10T00:00:00Z",
  beneficiaries: [],
};

async function renderContainer(conversationId: string | null) {
  const { OperationsPanelContainer } = await import("./operations-panel-container");
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  await act(async () => root.render(<OperationsPanelContainer conversationId={conversationId} />));
  return { node, root };
}

function setValue(input: HTMLInputElement, value: string) {
  const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value")!.set!;
  setter.call(input, value);
  input.dispatchEvent(new Event("input", { bubbles: true }));
}

/** Each operation card's own expand/collapse button (inside its `<article>`) —
 *  scoped so the History section's toggle is never counted as a card. */
function toggleButtons(node: Element) {
  return Array.from(node.querySelectorAll<HTMLButtonElement>("article button[aria-expanded]"));
}

function historyToggle(node: Element) {
  return Array.from(node.querySelectorAll<HTMLButtonElement>("button[aria-expanded]")).find(
    (button) => !button.closest("article") && button.textContent?.startsWith(en.Inbox.operationsPanel.historyTitle),
  );
}

async function click(button: Element) {
  await act(async () => {
    button.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
  });
}

describe("OperationsPanelContainer", () => {
  it("renders nothing when there is no active conversation", async () => {
    vi.stubGlobal("fetch", vi.fn());
    const { node, root } = await renderContainer(null);
    await flush();

    expect(node.textContent).toBe("");
    await act(async () => root.unmount());
  });

  it("holds the panel's shape while loading instead of a line of text the loaded panel then reflows", async () => {
    // A fetch that never settles parks the container in `loading`.
    vi.stubGlobal("fetch", vi.fn(() => new Promise(() => {})));
    const { node, root } = await renderContainer("conv-1");

    // The frame is a busy region with card-shaped blocks, so the sidebar
    // does not visibly rearrange when the data lands a moment later.
    expect(node.querySelector('[role="status"][aria-busy="true"]')).not.toBeNull();
    expect(node.querySelectorAll(".animate-pulse").length).toBeGreaterThan(1);
    // And the message a screen reader had before is still announced.
    expect(node.textContent).toContain(en.Inbox.operationsPanel.loading);

    await act(async () => root.unmount());
  });

  it("fetches the conversation's operations and lists every open remesa, auto-expanded when there's exactly one", async () => {
    const data: ConversationOperationsRead = {
      resolverState: "unica",
      resolverOperationId: "op-1",
      resolverCandidateCount: 1,
      operations: [OP1],
    };
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse(data));
    vi.stubGlobal("fetch", fetchMock);

    const { node, root } = await renderContainer("conv-1");
    await flush();

    expect(fetchMock).toHaveBeenCalledWith(
      "/api/remittance-operations?conversationId=conv-1",
      expect.objectContaining({ cache: "no-store" }),
    );
    expect(node.textContent).toContain("9205 1234 1234 9412");
    expect(toggleButtons(node)[0].getAttribute("aria-expanded")).toBe("true");
    await act(async () => root.unmount());
  });

  it("shows nothing and fabricates no operation when the resolver reports ninguna", async () => {
    const data: ConversationOperationsRead = {
      resolverState: "ninguna",
      resolverOperationId: null,
      resolverCandidateCount: 0,
      operations: [],
    };
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(jsonResponse(data)));

    const { node, root } = await renderContainer("conv-2");
    await flush();

    expect(node.textContent).toContain("No open remittance operations for this conversation.");
    expect(node.textContent).not.toContain("9205 1234 1234 9412");
    await act(async () => root.unmount());
  });

  it("shows no ambiguous banner and still lists every open remesa, both collapsed (no auto-select)", async () => {
    const data: ConversationOperationsRead = {
      resolverState: "ambigua",
      resolverOperationId: null,
      resolverCandidateCount: 2,
      operations: [OP1, OP2],
    };
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(jsonResponse(data)));

    const { node, root } = await renderContainer("conv-3");
    await flush();

    // No ambiguous-state badge any more (owner, 2026-10-03): the cards and their
    // statuses already say it. The panel title is just "Operations".
    expect(node.querySelector('[role="status"]')).toBeNull();
    expect(node.textContent).not.toContain("open operations for this conversation");
    expect(node.querySelector("h3")?.textContent).toBe("Operations");
    // Both operations render — "no guessing" means not hiding data, not
    // picking a winner (spec: "List All Open Remesas Per Conversation").
    expect(node.querySelectorAll("article")).toHaveLength(2);
    const buttons = toggleButtons(node);
    expect(buttons).toHaveLength(2);
    expect(buttons.every((btn) => btn.getAttribute("aria-expanded") === "false")).toBe(true);
    await act(async () => root.unmount());
  });

  it("expands a card on click and collapses the previously expanded one", async () => {
    const data: ConversationOperationsRead = {
      resolverState: "ambigua",
      resolverOperationId: null,
      resolverCandidateCount: 2,
      operations: [OP1, OP2],
    };
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(jsonResponse(data)));

    const { node, root } = await renderContainer("conv-3b");
    await flush();

    let buttons = toggleButtons(node);
    await act(async () => {
      buttons[0].dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
    });
    buttons = toggleButtons(node);
    expect(buttons[0].getAttribute("aria-expanded")).toBe("true");
    expect(buttons[1].getAttribute("aria-expanded")).toBe("false");

    await act(async () => {
      buttons[1].dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
    });
    buttons = toggleButtons(node);
    expect(buttons[0].getAttribute("aria-expanded")).toBe("false");
    expect(buttons[1].getAttribute("aria-expanded")).toBe("true");
    await act(async () => root.unmount());
  });

  it("shows a load error when the fetch fails", async () => {
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(jsonResponse({ error: "boom" }, 500)));

    const { node, root } = await renderContainer("conv-4");
    await flush();

    expect(node.textContent).toContain("Couldn't load remittance operations.");
    await act(async () => root.unmount());
  });

  it("refetches when a card reports a change via onChanged", async () => {
    // The inline name field only renders for a "zelle" beneficiary
    // (cuban_card beneficiaries have no name) — this test needs
    // `#inline-name-ben-1`, so it uses a zelle variant of OP1's
    // beneficiary while every other test keeps OP1's cuban_card shape.
    const zelleBeneficiary = {
      id: "ben-1",
      beneficiaryType: "zelle" as const,
      name: "Yaima Perez",
      cardNumber: null,
      phone: null,
      zelleAccount: "yaima@example.invalid",
      deliveryMethod: null,
      amount: null,
      amountOrigin: null,
      currency: null,
      position: 1,
      address: null,
      idPhotoWamid: null,
      idPhotoUrl: null,
    };
    const data: ConversationOperationsRead = {
      resolverState: "unica",
      resolverOperationId: "op-1",
      resolverCandidateCount: 1,
      operations: [{ ...OP1, beneficiaries: [zelleBeneficiary] }],
    };
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse(data));
    vi.stubGlobal("fetch", fetchMock);
    corregirBeneficiario.mockResolvedValue({ ok: true, id: "ben-1" });

    const { node, root } = await renderContainer("conv-5");
    await flush();
    expect(fetchMock).toHaveBeenCalledTimes(1);

    const editButton = Array.from(node.querySelectorAll("button")).find(
      (btn) => btn.getAttribute("aria-label") === en.Inbox.operationsPanel.editBeneficiary,
    ) as HTMLButtonElement;
    await act(async () => {
      editButton.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
    });

    const nameInput = node.querySelector<HTMLInputElement>("#inline-name-ben-1")!;
    await act(async () => setValue(nameInput, "Yaima Perez Updated"));

    const saveButton = Array.from(node.querySelectorAll("button")).find(
      (btn) => btn.textContent?.trim() === en.Inbox.operationsPanel.save,
    ) as HTMLButtonElement;
    await act(async () => {
      saveButton.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
    });
    await flush();

    expect(corregirBeneficiario).toHaveBeenCalledWith("ben-1", { name: "Yaima Perez Updated" });
    expect(fetchMock).toHaveBeenCalledTimes(2);
    await act(async () => root.unmount());
  });

  describe("history (migration 102)", () => {
    const historyOps = (count: number) =>
      Array.from({ length: count }, (_, i) => ({ ...HISTORY_OP, id: `op-hist-${i + 1}` }));

    it("hides history behind a collapsed History (N) toggle, below the open operations", async () => {
      const data: ConversationOperationsRead = {
        resolverState: "unica",
        resolverOperationId: "op-1",
        resolverCandidateCount: 1,
        operations: [OP1, ...historyOps(2)],
      };
      vi.stubGlobal("fetch", vi.fn().mockResolvedValue(jsonResponse(data)));

      const { node, root } = await renderContainer("conv-hist-1");
      await flush();

      const toggle = historyToggle(node);
      expect(toggle).toBeDefined();
      expect(toggle!.textContent).toBe(`${en.Inbox.operationsPanel.historyTitle} (2)`);
      expect(toggle!.getAttribute("aria-expanded")).toBe("false");
      // Only the open operation's card is rendered while history is collapsed.
      expect(node.querySelectorAll("article")).toHaveLength(1);
      await act(async () => root.unmount());
    });

    it("reveals the history cards, each collapsed, when the History toggle is clicked", async () => {
      const data: ConversationOperationsRead = {
        resolverState: "unica",
        resolverOperationId: "op-1",
        resolverCandidateCount: 1,
        operations: [OP1, ...historyOps(2)],
      };
      vi.stubGlobal("fetch", vi.fn().mockResolvedValue(jsonResponse(data)));

      const { node, root } = await renderContainer("conv-hist-1b");
      await flush();
      await click(historyToggle(node)!);

      expect(historyToggle(node)!.getAttribute("aria-expanded")).toBe("true");
      const buttons = toggleButtons(node);
      expect(buttons).toHaveLength(3);
      // The single open op auto-expands; the history cards stay collapsed.
      expect(buttons[0].getAttribute("aria-expanded")).toBe("true");
      expect(buttons[1].getAttribute("aria-expanded")).toBe("false");
      expect(buttons[2].getAttribute("aria-expanded")).toBe("false");

      await click(historyToggle(node)!);
      expect(node.querySelectorAll("article")).toHaveLength(1);
      await act(async () => root.unmount());
    });

    it("shows only the latest 5 history operations until Show more is clicked", async () => {
      const data: ConversationOperationsRead = {
        resolverState: "unica",
        resolverOperationId: "op-1",
        resolverCandidateCount: 1,
        operations: [OP1, ...historyOps(7)],
      };
      vi.stubGlobal("fetch", vi.fn().mockResolvedValue(jsonResponse(data)));

      const { node, root } = await renderContainer("conv-hist-1c");
      await flush();
      await click(historyToggle(node)!);

      expect(node.querySelectorAll("article")).toHaveLength(1 + 5);
      const showMoreText = en.Inbox.operationsPanel.historyShowMore.replace("{count}", "2");
      const showMore = Array.from(node.querySelectorAll("button")).find((b) => b.textContent === showMoreText);
      expect(showMore).toBeDefined();

      await click(showMore!);
      expect(node.querySelectorAll("article")).toHaveLength(1 + 7);
      expect(Array.from(node.querySelectorAll("button")).some((b) => b.textContent === showMoreText)).toBe(false);
      await act(async () => root.unmount());
    });

    it("offers no Show more button when there are 5 or fewer history operations", async () => {
      const data: ConversationOperationsRead = {
        resolverState: "unica",
        resolverOperationId: "op-1",
        resolverCandidateCount: 1,
        operations: [OP1, ...historyOps(5)],
      };
      vi.stubGlobal("fetch", vi.fn().mockResolvedValue(jsonResponse(data)));

      const { node, root } = await renderContainer("conv-hist-1d");
      await flush();
      await click(historyToggle(node)!);

      expect(node.querySelectorAll("article")).toHaveLength(1 + 5);
      const showMorePrefix = en.Inbox.operationsPanel.historyShowMore.split("{count}")[0];
      expect(Array.from(node.querySelectorAll("button")).some((b) => b.textContent?.startsWith(showMorePrefix))).toBe(false);
      await act(async () => root.unmount());
    });

    it("does not render a History section when there are no completed operations", async () => {
      const data: ConversationOperationsRead = {
        resolverState: "unica",
        resolverOperationId: "op-1",
        resolverCandidateCount: 1,
        operations: [OP1],
      };
      vi.stubGlobal("fetch", vi.fn().mockResolvedValue(jsonResponse(data)));

      const { node, root } = await renderContainer("conv-hist-2");
      await flush();

      expect(node.textContent).not.toContain("History");
      await act(async () => root.unmount());
    });

    it("auto-expands the single open operation even with two history operations present (auto-expand only counts open ops)", async () => {
      const data: ConversationOperationsRead = {
        resolverState: "unica",
        resolverOperationId: "op-1",
        resolverCandidateCount: 1,
        operations: [OP1, ...historyOps(2)],
      };
      vi.stubGlobal("fetch", vi.fn().mockResolvedValue(jsonResponse(data)));

      const { node, root } = await renderContainer("conv-hist-3");
      await flush();

      const buttons = toggleButtons(node);
      expect(buttons).toHaveLength(1);
      expect(buttons[0].getAttribute("aria-expanded")).toBe("true");
      await act(async () => root.unmount());
    });

    it("still shows the no-open-operations message AND a collapsed History toggle when the resolver reports ninguna", async () => {
      const data: ConversationOperationsRead = {
        resolverState: "ninguna",
        resolverOperationId: null,
        resolverCandidateCount: 0,
        operations: [HISTORY_OP],
      };
      vi.stubGlobal("fetch", vi.fn().mockResolvedValue(jsonResponse(data)));

      const { node, root } = await renderContainer("conv-hist-4");
      await flush();

      expect(node.textContent).toContain("No open remittance operations for this conversation.");
      expect(historyToggle(node)!.getAttribute("aria-expanded")).toBe("false");
      expect(node.querySelectorAll("article")).toHaveLength(0);

      await click(historyToggle(node)!);
      expect(node.querySelectorAll("article")).toHaveLength(1);
      expect(toggleButtons(node)[0].getAttribute("aria-expanded")).toBe("false");
      await act(async () => root.unmount());
    });

    it("renders a history card fully read-only: no edit-operation pencil and no Complete transfer button, even though canEdit is true", async () => {
      const data: ConversationOperationsRead = {
        resolverState: "unica",
        resolverOperationId: "op-1",
        resolverCandidateCount: 1,
        operations: [OP1, HISTORY_OP],
      };
      vi.stubGlobal("fetch", vi.fn().mockResolvedValue(jsonResponse(data)));

      const { node, root } = await renderContainer("conv-hist-5");
      await flush();
      await click(historyToggle(node)!);
      await click(toggleButtons(node)[1]);

      const historyArticle = node.querySelectorAll("article")[1];
      expect(
        historyArticle.querySelector(`button[aria-label="${en.Inbox.operationsPanel.editOperation}"]`),
      ).toBeNull();
      expect(historyArticle.textContent).not.toContain(en.Inbox.operationsPanel.completeTransfer.button);
      await act(async () => root.unmount());
    });
  });

  describe("live refresh (realtime)", () => {
    // beneficiariesComplete:false demotes ready_to_transfer to
    // awaiting_beneficiary (effectiveStatus) — label "Waiting for
    // beneficiary". Flipping it to true (simulating a `remittance_operations`
    // update) promotes it back to "Ready to transfer".
    const WAITING_OP = { ...OP1, status: "ready_to_transfer" as const, beneficiariesComplete: false };
    const READY_OP = { ...WAITING_OP, beneficiariesComplete: true };

    function dataWith(operation: RemittanceOperationRead) {
      return {
        resolverState: "unica" as const,
        resolverOperationId: operation.id,
        resolverCandidateCount: 1,
        operations: [operation],
      };
    }

    it("subscribes to remittance_operations changes filtered by conversation and removes the channel on unmount", async () => {
      vi.stubGlobal("fetch", vi.fn().mockResolvedValue(jsonResponse(dataWith(WAITING_OP))));

      const { root } = await renderContainer("conv-rt-1");
      await flush();

      expect(mockRealtime.channelCalls).toHaveLength(1);
      expect(mockRealtime.channelCalls[0]).toMatch(/^operations-panel-conv-rt-1/);
      const chan = mockRealtime.channels[0]!;
      expect(chan.onCalls).toHaveLength(1);
      expect(chan.onCalls[0]![0]).toBe("postgres_changes");
      expect(chan.onCalls[0]![1]).toEqual({
        event: "*",
        schema: "public",
        table: "remittance_operations",
        filter: "conversation_id=eq.conv-rt-1",
      });
      expect(chan.subscribeCalls).toBe(1);

      await act(async () => root.unmount());
      expect(mockRealtime.removeChannelCalls).toEqual([chan]);
    });

    it("two panels for the same conversation (desktop rail + mobile sheet) each get their own channel", async () => {
      vi.stubGlobal("fetch", vi.fn().mockResolvedValue(jsonResponse(dataWith(WAITING_OP))));
      const { OperationsPanelContainer } = await import("./operations-panel-container");
      const node = document.createElement("div");
      document.body.appendChild(node);
      const root = createRoot(node);

      await act(async () =>
        root.render(
          <>
            <OperationsPanelContainer conversationId="conv-rt-2" />
            <OperationsPanelContainer conversationId="conv-rt-2" />
          </>,
        ),
      );
      await flush();

      expect(mockRealtime.channels).toHaveLength(2);
      const [a, b] = mockRealtime.channels;
      expect(a!.name).not.toBe(b!.name);
      expect(a!.subscribeCalls).toBe(1);
      expect(b!.subscribeCalls).toBe(1);

      await act(async () => root.unmount());
      expect(mockRealtime.removeChannelCalls).toHaveLength(2);
    });

    it("coalesces two quick events into exactly one silent fetch after 800ms, with no loading flash and fresh data", async () => {
      const fetchMock = vi
        .fn()
        .mockResolvedValueOnce(jsonResponse(dataWith(WAITING_OP)))
        .mockResolvedValueOnce(jsonResponse(dataWith(READY_OP)));
      vi.stubGlobal("fetch", fetchMock);

      vi.useFakeTimers();
      const { node } = await renderContainer("conv-rt-2");
      await flush();
      expect(fetchMock).toHaveBeenCalledTimes(1);
      expect(node.textContent).toContain(en.Inbox.operationsPanel.status.awaiting_beneficiary);

      const chan = mockRealtime.channels[0]!;
      await act(async () => {
        chan.handler!();
        chan.handler!();
      });
      expect(fetchMock).toHaveBeenCalledTimes(1);

      await act(async () => {
        await vi.advanceTimersByTimeAsync(800);
      });

      expect(fetchMock).toHaveBeenCalledTimes(2);
      expect(node.textContent).not.toContain(en.Inbox.operationsPanel.loading);
      expect(node.textContent).toContain(en.Inbox.operationsPanel.status.ready_to_transfer);
      expect(node.textContent).not.toContain(en.Inbox.operationsPanel.status.awaiting_beneficiary);
    });

    it("keeps the previous content when the silent refetch fails", async () => {
      const fetchMock = vi
        .fn()
        .mockResolvedValueOnce(jsonResponse(dataWith(WAITING_OP)))
        .mockResolvedValueOnce(jsonResponse({ error: "boom" }, 500));
      vi.stubGlobal("fetch", fetchMock);

      vi.useFakeTimers();
      const { node } = await renderContainer("conv-rt-3");
      await flush();

      const chan = mockRealtime.channels[0]!;
      await act(async () => {
        chan.handler!();
      });
      await act(async () => {
        await vi.advanceTimersByTimeAsync(800);
      });

      expect(fetchMock).toHaveBeenCalledTimes(2);
      expect(node.textContent).toContain(en.Inbox.operationsPanel.status.awaiting_beneficiary);
      expect(node.textContent).not.toContain(en.Inbox.operationsPanel.loadError);
    });

    it("unsubscribes the old channel and subscribes a new one when conversationId changes", async () => {
      vi.stubGlobal(
        "fetch",
        vi.fn().mockResolvedValue(jsonResponse(dataWith(WAITING_OP))),
      );

      const { OperationsPanelContainer } = await import("./operations-panel-container");
      const node = document.createElement("div");
      document.body.appendChild(node);
      const root = createRoot(node);
      await act(async () => root.render(<OperationsPanelContainer conversationId="conv-rt-a" />));
      await flush();

      expect(mockRealtime.channels).toHaveLength(1);
      const firstChannel = mockRealtime.channels[0]!;

      await act(async () => root.render(<OperationsPanelContainer conversationId="conv-rt-b" />));
      await flush();

      expect(mockRealtime.removeChannelCalls).toContain(firstChannel);
      expect(mockRealtime.channels).toHaveLength(2);
      expect(mockRealtime.channels[1]!.name).toMatch(/^operations-panel-conv-rt-b-\d+$/);

      await act(async () => root.unmount());
    });
  });
});

describe("OperationsPanelContainer — the bot's quote", () => {
  const QUOTE = { gyd: 5000, destinationAmount: 15000, destinationCurrency: "CUP", quotedAt: "2026-10-02T10:00:00Z" };

  function load(operations: unknown[], quote: unknown) {
    vi.stubGlobal(
      "fetch",
      vi.fn(() =>
        Promise.resolve(
          jsonResponse({
            resolverState: operations.length > 1 ? "ambigua" : "unica",
            resolverOperationId: "op-1",
            resolverCandidateCount: operations.length,
            operations,
            quote,
          }),
        ),
      ),
    );
  }

  it("shows the quote on the open operation", async () => {
    load([OP1], QUOTE);
    const { node, root } = await renderContainer("conv-1");
    await flush();

    expect(node.textContent).toContain("Quoted: 5,000 GYD → 15,000 CUP");
    await act(async () => root.unmount());
  });

  it("shows it once, on the newest open operation, when there are several", async () => {
    load([OP1, OP2], QUOTE);
    const { node, root } = await renderContainer("conv-1");
    await flush();

    expect(node.textContent?.match(/Quoted:/g)).toHaveLength(1);
    expect(node.querySelectorAll("article")[0]!.textContent).toContain("Quoted:");
    await act(async () => root.unmount());
  });

  it("shows nothing when the quote is null", async () => {
    load([OP1], null);
    const { node, root } = await renderContainer("conv-1");
    await flush();

    expect(node.textContent).not.toContain("Quoted:");
    await act(async () => root.unmount());
  });

  it("does not show it on a history operation", async () => {
    load([HISTORY_OP], QUOTE);
    const { node, root } = await renderContainer("conv-1");
    await flush();
    await click(historyToggle(node)!);

    expect(node.querySelectorAll("article")).toHaveLength(1);
    expect(node.textContent).not.toContain("Quoted:");
    await act(async () => root.unmount());
  });
});
