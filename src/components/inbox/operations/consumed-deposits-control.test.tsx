// @vitest-environment jsdom
// Spec: panel-fully-editable T3c. Releasing a verified deposit from an operation or moving it to another open operation of the same
// conversation: one row per verified deposit with a button, an inline choice (leave it without an owner / one of the other operations),
// one request to moverDeposito, the server's refusal shown as its message.

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import en from "../../../../messages/en.json";
import type { MatchedDeposit } from "@/lib/remittance-operations/types";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

vi.mock("next-intl", () => ({
  useTranslations: (namespace: string) => {
    const node = namespace.split(".").reduce((acc: Record<string, unknown>, part) => acc[part] as Record<string, unknown>, en as unknown as Record<string, unknown>);
    return (key: string) => key.split(".").reduce((acc: unknown, part) => (acc as Record<string, unknown>)[part], node) as string;
  },
}));

const moverDeposito = vi.fn();
vi.mock("@/lib/remittance-operations/commands", () => ({
  moverDeposito: (...args: unknown[]) => moverDeposito(...args),
}));

// The app's Select (Base UI) hangs under jsdom; a native double keeps the value/onValueChange contract.
vi.mock("@/components/ui/select", () => ({
  Select: ({ id, value, disabled, onValueChange, children }: {
    id?: string; value?: string; disabled?: boolean; onValueChange?: (value: string) => void; children?: React.ReactNode;
  }) => (
    <select id={id} value={value} disabled={disabled} onChange={(event) => onValueChange?.(event.target.value)}>
      <option value="" />
      {children}
    </select>
  ),
  SelectTrigger: () => null,
  SelectValue: () => null,
  SelectContent: ({ children }: { children?: React.ReactNode }) => <>{children}</>,
  SelectItem: ({ value, children }: { value: string; children?: React.ReactNode }) => <option value={value}>{children}</option>,
}));

afterEach(() => {
  document.body.replaceChildren();
  moverDeposito.mockReset();
});

const P = en.Inbox.operationsPanel;
const D = en.Inbox.operationsPanel.depositMove;

const DEPOSITS: MatchedDeposit[] = [
  { transId: "10400000009977", amount: 13000, currency: "GYD", receivedAt: "2026-11-17T14:18:14Z", consumedAt: "2026-11-17T14:30:00Z" },
  { transId: "10400000000024", amount: 15000, currency: "GYD", receivedAt: "2026-11-16T20:25:00Z", consumedAt: "2026-11-16T20:30:00Z" },
];
const TARGETS = [
  { id: "op-2", label: "13,000 GYD → USD" },
  { id: "op-3", label: "5,000 GYD → CUP" },
];

async function render(deposits = DEPOSITS, targets = TARGETS, onMoved = vi.fn()) {
  const { ConsumedDepositsControl } = await import("./consumed-deposits-control");
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  await act(async () => root.render(<ConsumedDepositsControl operationId="op-1" deposits={deposits} targets={targets} onMoved={onMoved} />));
  return { node, root, onMoved };
}

const click = (el: Element | null | undefined) => act(async () => el!.dispatchEvent(new MouseEvent("click", { bubbles: true })));
const moveButtons = (node: HTMLElement) => Array.from(node.querySelectorAll<HTMLButtonElement>(`button[aria-label="${D.button}"]`));
const confirmButton = (node: HTMLElement) => node.querySelector(`button[aria-label="${D.confirm}"]`) as HTMLButtonElement | null;
const options = (node: HTMLElement) => Array.from(node.querySelectorAll("option")).map((o) => o.value).filter(Boolean);

function pick(node: HTMLElement, value: string) {
  const select = node.querySelector<HTMLSelectElement>("select")!;
  const setter = Object.getOwnPropertyDescriptor(window.HTMLSelectElement.prototype, "value")!.set!;
  setter.call(select, value);
  select.dispatchEvent(new Event("change", { bubbles: true }));
}
const submit = (node: HTMLElement) => act(async () => node.querySelector("form")!.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true })));

describe("ConsumedDepositsControl", () => {
  it("renders nothing when the operation has no verified deposit", async () => {
    const { node, root } = await render([]);

    expect(node.textContent).toBe("");
    await act(async () => root.unmount());
  });

  it("one row per verified deposit with its amount and TransID, and a button on each", async () => {
    const { node, root } = await render();

    expect(moveButtons(node)).toHaveLength(2);
    const text = node.textContent ?? "";
    expect(text).toContain("13,000");
    expect(text).toContain("10400000009977");
    expect(text).toContain("10400000000024");
    await act(async () => root.unmount());
  });

  it("the choice offers to leave the deposit without an owner and every other open operation", async () => {
    const { node, root } = await render();

    await click(moveButtons(node)[0]);

    expect(options(node)).toEqual(["release", "op-2", "op-3"]);
    expect(confirmButton(node)!.disabled).toBe(true);
    await act(async () => root.unmount());
  });

  it("releasing sends a null target for that deposit and tells the panel", async () => {
    moverDeposito.mockResolvedValue({ ok: true, moved: false, released: true, sourceStatus: "awaiting_deposit", targetStatus: null });
    const { node, root, onMoved } = await render();
    await click(moveButtons(node)[1]);

    await act(async () => pick(node, "release"));
    await submit(node);

    expect(moverDeposito).toHaveBeenCalledWith("op-1", "10400000000024", null);
    expect(onMoved).toHaveBeenCalledTimes(1);
    await act(async () => root.unmount());
  });

  it("moving sends the chosen operation", async () => {
    moverDeposito.mockResolvedValue({ ok: true, moved: true, released: false, sourceStatus: "awaiting_deposit", targetStatus: "ready_to_transfer" });
    const { node, root, onMoved } = await render();
    await click(moveButtons(node)[0]);

    await act(async () => pick(node, "op-3"));
    await submit(node);

    expect(moverDeposito).toHaveBeenCalledWith("op-1", "10400000009977", "op-3");
    expect(onMoved).toHaveBeenCalledTimes(1);
    await act(async () => root.unmount());
  });

  it("with no other open operation it can only be released", async () => {
    const { node, root } = await render(DEPOSITS, []);
    await click(moveButtons(node)[0]);

    expect(options(node)).toEqual(["release"]);
    await act(async () => root.unmount());
  });

  it("a refusal shows the server's message and keeps the choice open", async () => {
    moverDeposito.mockResolvedValue({ ok: false, status: 400, error: "the target operation is closed" });
    const { node, root, onMoved } = await render();
    await click(moveButtons(node)[0]);

    await act(async () => pick(node, "op-2"));
    await submit(node);

    expect(node.textContent).toContain("the target operation is closed");
    expect(node.querySelector("form")).not.toBeNull();
    expect(onMoved).not.toHaveBeenCalled();
    await act(async () => root.unmount());
  });

  it("nothing is sent until a choice is made, and cancel closes the choice", async () => {
    const { node, root } = await render();
    await click(moveButtons(node)[0]);

    await submit(node);
    expect(moverDeposito).not.toHaveBeenCalled();

    await click(node.querySelector(`button[aria-label="${P.cancel}"]`));
    expect(node.querySelector("form")).toBeNull();
    await act(async () => root.unmount());
  });
});
