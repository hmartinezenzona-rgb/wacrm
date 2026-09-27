// @vitest-environment jsdom
// Spec: chat-remesa-operations-panel add-beneficiary UI (odd/tasks/
// panel-add-beneficiary.md). Adding a new beneficiary — card/Zelle/other
// types, amount + currency, snake_case keys mirroring
// crm_agregar_beneficiario's `datos` contract exactly.

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

const agregarBeneficiario = vi.fn();
vi.mock("@/lib/remittance-operations/commands", () => ({
  agregarBeneficiario: (...args: unknown[]) => agregarBeneficiario(...args),
}));

afterEach(() => {
  document.body.replaceChildren();
  vi.restoreAllMocks();
});

function setValue(input: HTMLInputElement, value: string) {
  const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value")!.set!;
  setter.call(input, value);
  input.dispatchEvent(new Event("input", { bubbles: true }));
}

function selectType(node: HTMLElement, value: string) {
  const select = node.querySelector<HTMLSelectElement>("select")!;
  const setter = Object.getOwnPropertyDescriptor(window.HTMLSelectElement.prototype, "value")!.set!;
  setter.call(select, value);
  select.dispatchEvent(new Event("change", { bubbles: true }));
}

function submit(node: HTMLElement) {
  const form = node.querySelector("form")!;
  return act(async () => {
    form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
  });
}

async function render(onDone = vi.fn(), onCancel = vi.fn()) {
  const { BeneficiaryAddControl } = await import("./beneficiary-add-control");
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  await act(async () =>
    root.render(<BeneficiaryAddControl operationId="op-1" onDone={onDone} onCancel={onCancel} />),
  );
  return { node, root, onDone, onCancel };
}

describe("BeneficiaryAddControl", () => {
  it("defaults to the cuban_card fields (card number + phone)", async () => {
    const { node, root } = await render();

    expect(node.querySelector("#add-beneficiary-card-number")).not.toBeNull();
    expect(node.querySelector("#add-beneficiary-phone")).not.toBeNull();
    expect(node.querySelector("#add-beneficiary-name")).toBeNull();
    expect(node.querySelector("#add-beneficiary-zelle-account")).toBeNull();
    await act(async () => root.unmount());
  });

  it("switches to name + zelle account fields when zelle is selected", async () => {
    const { node, root } = await render();

    await act(async () => selectType(node, "zelle"));

    expect(node.querySelector("#add-beneficiary-name")).not.toBeNull();
    expect(node.querySelector("#add-beneficiary-zelle-account")).not.toBeNull();
    expect(node.querySelector("#add-beneficiary-card-number")).toBeNull();
    await act(async () => root.unmount());
  });

  it("submits a cuban_card beneficiary with snake_case keys and amount as a number", async () => {
    agregarBeneficiario.mockResolvedValue({ ok: true, id: "ben-1", complete: true });
    const { node, root, onDone } = await render();

    await act(async () => setValue(node.querySelector<HTMLInputElement>("#add-beneficiary-card-number")!, "9205123412349412"));
    await act(async () => setValue(node.querySelector<HTMLInputElement>("#add-beneficiary-phone")!, "55512345"));
    await act(async () => setValue(node.querySelector<HTMLInputElement>("#add-beneficiary-amount")!, "15000"));
    await act(async () => setValue(node.querySelector<HTMLInputElement>("#add-beneficiary-currency")!, "CUP"));
    await submit(node);

    expect(agregarBeneficiario).toHaveBeenCalledWith("op-1", {
      beneficiary_type: "cuban_card",
      card_number: "9205123412349412",
      phone: "55512345",
      amount: 15000,
      currency: "CUP",
    });
    expect(onDone).toHaveBeenCalled();
    await act(async () => root.unmount());
  });

  it("submits a zelle beneficiary with name and zelle_account", async () => {
    agregarBeneficiario.mockResolvedValue({ ok: true, id: "ben-2", complete: true });
    const { node, root, onDone } = await render();

    await act(async () => selectType(node, "zelle"));
    await act(async () => setValue(node.querySelector<HTMLInputElement>("#add-beneficiary-name")!, "Maria Perez"));
    await act(async () => setValue(node.querySelector<HTMLInputElement>("#add-beneficiary-zelle-account")!, "maria@example.com"));
    await act(async () => setValue(node.querySelector<HTMLInputElement>("#add-beneficiary-amount")!, "100"));
    await act(async () => setValue(node.querySelector<HTMLInputElement>("#add-beneficiary-currency")!, "USD"));
    await submit(node);

    expect(agregarBeneficiario).toHaveBeenCalledWith("op-1", {
      beneficiary_type: "zelle",
      name: "Maria Perez",
      zelle_account: "maria@example.com",
      amount: 100,
      currency: "USD",
    });
    expect(onDone).toHaveBeenCalled();
    await act(async () => root.unmount());
  });

  it("blocks submit and shows a message when the card number isn't 16 digits", async () => {
    const { node, root } = await render();

    await act(async () => setValue(node.querySelector<HTMLInputElement>("#add-beneficiary-card-number")!, "123"));
    await act(async () => setValue(node.querySelector<HTMLInputElement>("#add-beneficiary-phone")!, "55512345"));
    await act(async () => setValue(node.querySelector<HTMLInputElement>("#add-beneficiary-amount")!, "100"));
    await act(async () => setValue(node.querySelector<HTMLInputElement>("#add-beneficiary-currency")!, "CUP"));
    await submit(node);

    expect(agregarBeneficiario).not.toHaveBeenCalled();
    expect(node.textContent).toContain(en.Inbox.operationsPanel.invalidCard);
    await act(async () => root.unmount());
  });

  it("blocks submit and shows a message when amount is not > 0", async () => {
    const { node, root } = await render();

    await act(async () => setValue(node.querySelector<HTMLInputElement>("#add-beneficiary-card-number")!, "9205123412349412"));
    await act(async () => setValue(node.querySelector<HTMLInputElement>("#add-beneficiary-phone")!, "55512345"));
    await act(async () => setValue(node.querySelector<HTMLInputElement>("#add-beneficiary-amount")!, "0"));
    await act(async () => setValue(node.querySelector<HTMLInputElement>("#add-beneficiary-currency")!, "CUP"));
    await submit(node);

    expect(agregarBeneficiario).not.toHaveBeenCalled();
    expect(node.textContent).toContain(en.Inbox.operationsPanel.invalidAmount);
    await act(async () => root.unmount());
  });

  it("blocks submit and shows a message when currency doesn't match ^[A-Z]{3}$", async () => {
    const { node, root } = await render();

    await act(async () => setValue(node.querySelector<HTMLInputElement>("#add-beneficiary-card-number")!, "9205123412349412"));
    await act(async () => setValue(node.querySelector<HTMLInputElement>("#add-beneficiary-phone")!, "55512345"));
    await act(async () => setValue(node.querySelector<HTMLInputElement>("#add-beneficiary-amount")!, "100"));
    await act(async () => setValue(node.querySelector<HTMLInputElement>("#add-beneficiary-currency")!, "cup"));
    await submit(node);

    expect(agregarBeneficiario).not.toHaveBeenCalled();
    expect(node.textContent).toContain(en.Inbox.operationsPanel.invalidCurrency);
    await act(async () => root.unmount());
  });

  it("blocks submit for zelle when name or zelle_account is empty", async () => {
    const { node, root } = await render();

    await act(async () => selectType(node, "zelle"));
    await act(async () => setValue(node.querySelector<HTMLInputElement>("#add-beneficiary-amount")!, "100"));
    await act(async () => setValue(node.querySelector<HTMLInputElement>("#add-beneficiary-currency")!, "USD"));
    await submit(node);

    expect(agregarBeneficiario).not.toHaveBeenCalled();
    expect(node.textContent).toContain(en.Inbox.operationsPanel.cannotBeEmpty);
    await act(async () => root.unmount());
  });

  it("calls onCancel when cancel is clicked", async () => {
    const { node, root, onCancel } = await render();

    const cancelButton = Array.from(node.querySelectorAll("button")).find(
      (btn) => btn.textContent === en.Inbox.operationsPanel.cancel,
    ) as HTMLButtonElement;
    await act(async () => cancelButton.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true })));

    expect(onCancel).toHaveBeenCalled();
    await act(async () => root.unmount());
  });

  it("shows the server error text on failure and does not call onDone", async () => {
    agregarBeneficiario.mockResolvedValue({ ok: false, status: 400, error: "beneficiaries can only be added to remesa operations" });
    const { node, root, onDone } = await render();

    await act(async () => setValue(node.querySelector<HTMLInputElement>("#add-beneficiary-card-number")!, "9205123412349412"));
    await act(async () => setValue(node.querySelector<HTMLInputElement>("#add-beneficiary-phone")!, "55512345"));
    await act(async () => setValue(node.querySelector<HTMLInputElement>("#add-beneficiary-amount")!, "100"));
    await act(async () => setValue(node.querySelector<HTMLInputElement>("#add-beneficiary-currency")!, "CUP"));
    await submit(node);

    expect(node.textContent).toContain("beneficiaries can only be added to remesa operations");
    expect(onDone).not.toHaveBeenCalled();
    await act(async () => root.unmount());
  });
});
