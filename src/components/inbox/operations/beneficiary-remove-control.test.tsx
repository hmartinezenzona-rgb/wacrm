// @vitest-environment jsdom
// Spec: panel-fully-editable T1. Removing a current recipient of an open operation: an inline confirmation (warning + confirm / cancel
// icon buttons), one request to quitarBeneficiario, and the refusal message of the server when it says no.

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

const quitarBeneficiario = vi.fn();
vi.mock("@/lib/remittance-operations/commands", () => ({
  quitarBeneficiario: (...args: unknown[]) => quitarBeneficiario(...args),
}));

afterEach(() => {
  document.body.replaceChildren();
  vi.restoreAllMocks();
  quitarBeneficiario.mockReset();
});

const P = en.Inbox.operationsPanel;

async function render(onDone = vi.fn(), onCancel = vi.fn()) {
  const { BeneficiaryRemoveControl } = await import("./beneficiary-remove-control");
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  await act(async () => root.render(<BeneficiaryRemoveControl beneficiaryId="ben-1" onDone={onDone} onCancel={onCancel} />));
  return { node, root, onDone, onCancel };
}

const confirmButton = (node: HTMLElement) => node.querySelector(`button[aria-label="${P.confirmRemoveBeneficiary}"]`) as HTMLButtonElement;
const cancelButton = (node: HTMLElement) => node.querySelector(`button[aria-label="${P.cancel}"]`) as HTMLButtonElement;

describe("BeneficiaryRemoveControl", () => {
  it("warns that the recipient is taken off the send and offers confirm and cancel", async () => {
    const { node, root } = await render();

    expect(node.textContent).toContain(P.removeBeneficiaryWarning);
    expect(confirmButton(node)).not.toBeNull();
    expect(cancelButton(node)).not.toBeNull();
    expect(quitarBeneficiario).not.toHaveBeenCalled();
    await act(async () => root.unmount());
  });

  it("confirming removes that recipient and tells the card it is done", async () => {
    quitarBeneficiario.mockResolvedValue({ ok: true, id: "ben-1", complete: false });
    const { node, root, onDone } = await render();

    await act(async () => confirmButton(node).dispatchEvent(new MouseEvent("click", { bubbles: true })));

    expect(quitarBeneficiario).toHaveBeenCalledWith("ben-1");
    expect(onDone).toHaveBeenCalledTimes(1);
    await act(async () => root.unmount());
  });

  it("a refusal shows the server's message and does not finish", async () => {
    quitarBeneficiario.mockResolvedValue({ ok: false, status: 400, error: "operation is closed" });
    const { node, root, onDone } = await render();

    await act(async () => confirmButton(node).dispatchEvent(new MouseEvent("click", { bubbles: true })));

    expect(node.textContent).toContain("operation is closed");
    expect(onDone).not.toHaveBeenCalled();
    await act(async () => root.unmount());
  });

  it("cancel closes the confirmation without sending anything", async () => {
    const { node, root, onCancel } = await render();

    await act(async () => cancelButton(node).dispatchEvent(new MouseEvent("click", { bubbles: true })));

    expect(onCancel).toHaveBeenCalledTimes(1);
    expect(quitarBeneficiario).not.toHaveBeenCalled();
    await act(async () => root.unmount());
  });
});
