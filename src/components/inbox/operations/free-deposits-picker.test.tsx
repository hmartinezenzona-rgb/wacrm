// @vitest-environment jsdom
// Spec: panel-fully-editable T3b. Linking a ledger deposit nobody owns to an operation that awaits verification: a button opens the list
// (newest first), a pick hands the deposit and the notify bell to the panel, which links it with the existing verify.

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import en from "../../../../messages/en.json";
import type { FreeDeposit } from "@/lib/remittance-operations/types";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

vi.mock("next-intl", () => ({
  useTranslations: (namespace: string) => {
    const node = namespace.split(".").reduce((acc: Record<string, unknown>, part) => acc[part] as Record<string, unknown>, en as unknown as Record<string, unknown>);
    return (key: string) => key.split(".").reduce((acc: unknown, part) => (acc as Record<string, unknown>)[part], node) as string;
  },
}));

const fetchFreeDeposits = vi.fn();
vi.mock("@/lib/remittance-operations/commands", () => ({
  fetchFreeDeposits: (...args: unknown[]) => fetchFreeDeposits(...args),
}));

afterEach(() => {
  document.body.replaceChildren();
  fetchFreeDeposits.mockReset();
});

const P = en.Inbox.operationsPanel;
const F = en.Inbox.operationsPanel.freeDeposits;

const DEPOSITS: FreeDeposit[] = [
  { transId: "10400000009977", amount: 13000, currency: "GYD", receivedAt: "2026-11-17T14:18:14Z", holder: "Pagador Uno" },
  { transId: "10400000000024", amount: 15000, currency: "GYD", receivedAt: "2026-11-16T20:25:00Z", holder: null },
];

function flush() {
  return act(async () => {
    await Promise.resolve();
    await Promise.resolve();
  });
}

async function render(onLink = vi.fn(), busy = false) {
  const { FreeDepositsPicker } = await import("./free-deposits-picker");
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  await act(async () => root.render(<FreeDepositsPicker operationId="op-1" busy={busy} onLink={onLink} />));
  return { node, root, onLink };
}

const click = (el: Element | null) => act(async () => el!.dispatchEvent(new MouseEvent("click", { bubbles: true })));
const openButton = (node: HTMLElement) => node.querySelector(`button[aria-label="${F.button}"]`);
const linkButtons = (node: HTMLElement) => Array.from(node.querySelectorAll<HTMLButtonElement>(`button[aria-label="${F.link}"]`));

describe("FreeDepositsPicker", () => {
  it("starts closed and fetches nothing until opened", async () => {
    const { node, root } = await render();

    expect(openButton(node)).not.toBeNull();
    expect(fetchFreeDeposits).not.toHaveBeenCalled();
    await act(async () => root.unmount());
  });

  it("opens the list of deposits nobody owns, newest first, with amount, TransID and holder", async () => {
    fetchFreeDeposits.mockResolvedValue({ ok: true, data: DEPOSITS });
    const { node, root } = await render();

    await click(openButton(node));
    await flush();

    expect(fetchFreeDeposits).toHaveBeenCalledWith("op-1");
    expect(linkButtons(node)).toHaveLength(2);
    const text = node.textContent ?? "";
    expect(text).toContain("13,000");
    expect(text).toContain("10400000009977");
    expect(text).toContain("Pagador Uno");
    expect(text.indexOf("10400000009977")).toBeLessThan(text.indexOf("10400000000024"));
    await act(async () => root.unmount());
  });

  it("picking a deposit hands it to the panel with the bell on (as the verify section does) and closes the list", async () => {
    fetchFreeDeposits.mockResolvedValue({ ok: true, data: DEPOSITS });
    const { node, root, onLink } = await render();
    await click(openButton(node));
    await flush();

    await click(linkButtons(node)[0]!);

    expect(onLink).toHaveBeenCalledWith(DEPOSITS[0], true);
    expect(linkButtons(node)).toHaveLength(0);
    await act(async () => root.unmount());
  });

  it("the bell can be turned off before linking", async () => {
    fetchFreeDeposits.mockResolvedValue({ ok: true, data: DEPOSITS });
    const { node, root, onLink } = await render();
    await click(openButton(node));
    await flush();

    await click(node.querySelector("button[aria-pressed]"));
    await click(linkButtons(node)[1]!);

    expect(onLink).toHaveBeenCalledWith(DEPOSITS[1], false);
    await act(async () => root.unmount());
  });

  it("says so when there are no deposits without an owner", async () => {
    fetchFreeDeposits.mockResolvedValue({ ok: true, data: [] });
    const { node, root } = await render();

    await click(openButton(node));
    await flush();

    expect(node.textContent).toContain(F.empty);
    await act(async () => root.unmount());
  });

  it("shows a load error when the read fails", async () => {
    fetchFreeDeposits.mockResolvedValue({ ok: false, status: 500, error: "x" });
    const { node, root } = await render();

    await click(openButton(node));
    await flush();

    expect(node.textContent).toContain(F.loadError);
    await act(async () => root.unmount());
  });

  it("locks the link buttons while a verification is in flight", async () => {
    fetchFreeDeposits.mockResolvedValue({ ok: true, data: DEPOSITS });
    const { node, root } = await render(vi.fn(), true);
    await click(openButton(node));
    await flush();

    expect(linkButtons(node).every((b) => b.disabled)).toBe(true);
    await act(async () => root.unmount());
  });

  it("cancel closes the list", async () => {
    fetchFreeDeposits.mockResolvedValue({ ok: true, data: DEPOSITS });
    const { node, root } = await render();
    await click(openButton(node));
    await flush();

    await click(node.querySelector(`button[aria-label="${P.cancel}"]`));

    expect(linkButtons(node)).toHaveLength(0);
    await act(async () => root.unmount());
  });
});
