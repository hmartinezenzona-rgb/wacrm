// @vitest-environment jsdom
// Spec: chat-remesa-operations-panel correction UI. Reassigning a
// beneficiary to another open operation of the same conversation.

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import en from "../../../../messages/en.json";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

vi.mock("next-intl", () => ({
  useTranslations: (namespace: string) => {
    const node = namespace.split(".").reduce((acc: Record<string, unknown>, part) => acc[part] as Record<string, unknown>, en as unknown as Record<string, unknown>);
    return (key: string) => key.split(".").reduce((acc: unknown, part) => (acc as Record<string, unknown>)[part], node) as string;
  },
}));

const reasignarBeneficiario = vi.fn();
vi.mock("@/lib/remittance-operations/commands", () => ({
  reasignarBeneficiario: (...args: unknown[]) => reasignarBeneficiario(...args),
}));

afterEach(() => {
  document.body.replaceChildren();
  vi.restoreAllMocks();
});

const TARGETS = [
  { id: "op-2", label: "10,000 GYD → USD" },
  { id: "op-3", label: "5,000 GYD → USD" },
];

async function render(onDone = vi.fn(), onCancel = vi.fn()) {
  const { BeneficiaryReassignControl } = await import("./beneficiary-reassign-control");
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  await act(async () =>
    root.render(
      <BeneficiaryReassignControl beneficiaryId="ben-1" targets={TARGETS} onDone={onDone} onCancel={onCancel} />,
    ),
  );
  return { node, root, onDone, onCancel };
}

function selectTarget(node: HTMLElement, value: string) {
  const select = node.querySelector<HTMLSelectElement>("select")!;
  const setter = Object.getOwnPropertyDescriptor(window.HTMLSelectElement.prototype, "value")!.set!;
  setter.call(select, value);
  select.dispatchEvent(new Event("change", { bubbles: true }));
}

function confirmButton(node: HTMLElement) {
  return Array.from(node.querySelectorAll("button")).find(
    (btn) => btn.textContent === en.Inbox.operationsPanel.confirmMove,
  ) as HTMLButtonElement;
}

describe("BeneficiaryReassignControl", () => {
  it("keeps confirm disabled until a target is chosen", async () => {
    const { node, root } = await render();

    expect(confirmButton(node).disabled).toBe(true);

    await act(async () => selectTarget(node, "op-2"));

    expect(confirmButton(node).disabled).toBe(false);
    await act(async () => root.unmount());
  });

  it("calls reasignarBeneficiario with the beneficiary id and the chosen target id", async () => {
    reasignarBeneficiario.mockResolvedValue({ ok: true, id: "ben-1" });
    const { node, root, onDone } = await render();

    await act(async () => selectTarget(node, "op-3"));
    await act(async () => {
      confirmButton(node).dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
    });

    expect(reasignarBeneficiario).toHaveBeenCalledWith("ben-1", "op-3");
    expect(onDone).toHaveBeenCalled();
    await act(async () => root.unmount());
  });

  it("shows the server error text on failure", async () => {
    reasignarBeneficiario.mockResolvedValue({ ok: false, status: 409, error: "Target operation is closed" });
    const { node, root, onDone } = await render();

    await act(async () => selectTarget(node, "op-2"));
    await act(async () => {
      confirmButton(node).dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
    });

    expect(node.textContent).toContain("Target operation is closed");
    expect(onDone).not.toHaveBeenCalled();
    await act(async () => root.unmount());
  });
});
