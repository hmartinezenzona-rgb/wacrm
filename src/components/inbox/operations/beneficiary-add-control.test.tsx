// @vitest-environment jsdom
// Spec: chat-remesa-operations-panel add-beneficiary UI (odd/tasks/
// panel-add-beneficiary.md). Adding a new beneficiary — card/Zelle/other
// types, amount + currency, snake_case keys mirroring
// crm_agregar_beneficiario's `datos` contract exactly.

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import en from "../../../../messages/en.json";
import type { OperationService } from "@/lib/remittance-operations/services";

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

// The app's Select (Base UI) hangs under jsdom; a native double keeps the value/onValueChange contract.
// The picker owns its dialog and fetch (id-photo-picker.test.tsx); here it is a button that "chooses" a fixed image.
vi.mock("./id-photo-picker", () => ({
  IdPhotoPicker: ({ conversationId, label, onPick }: { conversationId: string; selectedWamid: string | null; label: string; onPick: (wamid: string) => void }) => (
    <button type="button" data-testid="id-photo-picker" data-conversation={conversationId} onClick={() => onPick("wamid.CHOSEN")}>
      {label}
    </button>
  ),
}));

vi.mock("@/components/ui/select", () => ({
  Select: ({ id, value, disabled, onValueChange, children }: {
    id?: string; value?: string; disabled?: boolean; onValueChange?: (value: string) => void; children?: React.ReactNode;
  }) => (
    <select id={id} value={value} disabled={disabled} onChange={(event) => onValueChange?.(event.target.value)}>
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

async function render(
  onDone = vi.fn(),
  onCancel = vi.fn(),
  serviceType?: string,
  service?: OperationService | null,
  quote?: { amount: number; currency: string } | null,
  conversationId?: string,
) {
  const { BeneficiaryAddControl } = await import("./beneficiary-add-control");
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  await act(async () =>
    root.render(<BeneficiaryAddControl operationId="op-1" conversationId={conversationId} serviceType={serviceType} service={service} quote={quote} onDone={onDone} onCancel={onCancel} />),
  );
  return { node, root, onDone, onCancel };
}

describe("BeneficiaryAddControl on a recharge", () => {
  it("offers only a phone field: no type select, card, amount or currency", async () => {
    const { node, root } = await render(vi.fn(), vi.fn(), "recarga");

    expect(node.querySelector("select")).toBeNull();
    expect(node.querySelector("#add-beneficiary-phone")).not.toBeNull();
    expect(node.querySelector("#add-beneficiary-card-number")).toBeNull();
    expect(node.querySelector("#add-beneficiary-amount")).toBeNull();
    expect(node.querySelector("#add-beneficiary-currency")).toBeNull();
    await act(async () => root.unmount());
  });

  it("sends {beneficiary_type: recarga, phone} for a Cuban mobile", async () => {
    agregarBeneficiario.mockResolvedValue({ ok: true, id: "ben-9", complete: true });
    const { node, root, onDone } = await render(vi.fn(), vi.fn(), "recarga");

    await act(async () => setValue(node.querySelector<HTMLInputElement>("#add-beneficiary-phone")!, "52345678"));
    await submit(node);

    expect(agregarBeneficiario).toHaveBeenCalledWith("op-1", { beneficiary_type: "recarga", phone: "52345678" });
    expect(onDone).toHaveBeenCalled();
    await act(async () => root.unmount());
  });

  it.each(["12345678", "5234567", "523456789", ""])("rejects %j (8 digits starting 5 or 6)", async (value) => {
    const { node, root } = await render(vi.fn(), vi.fn(), "recarga");

    await act(async () => setValue(node.querySelector<HTMLInputElement>("#add-beneficiary-phone")!, value));
    await submit(node);

    expect(node.textContent).toContain(en.Inbox.operationsPanel.invalidRechargePhone);
    expect(agregarBeneficiario).not.toHaveBeenCalled();
    await act(async () => root.unmount());
  });
});

describe("BeneficiaryAddControl on a mobile balance (saldo)", () => {
  it("offers only a phone field, like a recharge, and sends {beneficiary_type: recarga, phone}", async () => {
    agregarBeneficiario.mockResolvedValue({ ok: true, id: "ben-10", complete: true });
    const { node, root, onDone } = await render(vi.fn(), vi.fn(), "saldo");

    expect(node.querySelector("select")).toBeNull();
    expect(node.querySelector("#add-beneficiary-card-number")).toBeNull();
    expect(node.querySelector("#add-beneficiary-amount")).toBeNull();
    await act(async () => setValue(node.querySelector<HTMLInputElement>("#add-beneficiary-phone")!, "52345678"));
    await submit(node);

    expect(agregarBeneficiario).toHaveBeenCalledWith("op-1", { beneficiary_type: "recarga", phone: "52345678" });
    expect(onDone).toHaveBeenCalled();
    await act(async () => root.unmount());
  });

  it("rejects a number that is not a Cuban mobile", async () => {
    const { node, root } = await render(vi.fn(), vi.fn(), "saldo");

    await act(async () => setValue(node.querySelector<HTMLInputElement>("#add-beneficiary-phone")!, "12345678"));
    await submit(node);

    expect(node.textContent).toContain(en.Inbox.operationsPanel.invalidRechargePhone);
    expect(agregarBeneficiario).not.toHaveBeenCalled();
    await act(async () => root.unmount());
  });
});

describe("BeneficiaryAddControl", () => {
  it("on a remesa never offers recarga", async () => {
    const { node, root } = await render(vi.fn(), vi.fn(), "remesa");
    const values = Array.from(node.querySelectorAll("option")).map((o) => o.getAttribute("value"));
    expect(values).not.toContain("recarga");
    await act(async () => root.unmount());
  });

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

  it("submits a card beneficiary without a phone and sends no phone key", async () => {
    agregarBeneficiario.mockResolvedValue({ ok: true, id: "ben-3", complete: false });
    const { node, root, onDone } = await render();

    await act(async () => setValue(node.querySelector<HTMLInputElement>("#add-beneficiary-card-number")!, "9205123412349412"));
    await act(async () => setValue(node.querySelector<HTMLInputElement>("#add-beneficiary-amount")!, "5000"));
    await submit(node);

    expect(agregarBeneficiario).toHaveBeenCalledWith("op-1", {
      beneficiary_type: "cuban_card",
      card_number: "9205123412349412",
      amount: 5000,
      currency: "CUP",
    });
    expect(onDone).toHaveBeenCalled();
    await act(async () => root.unmount());
  });

  it("still blocks a non-empty phone that isn't 8 to 15 digits", async () => {
    const { node, root } = await render();

    await act(async () => setValue(node.querySelector<HTMLInputElement>("#add-beneficiary-card-number")!, "9205123412349412"));
    await act(async () => setValue(node.querySelector<HTMLInputElement>("#add-beneficiary-phone")!, "123"));
    await act(async () => setValue(node.querySelector<HTMLInputElement>("#add-beneficiary-amount")!, "5000"));
    await submit(node);

    expect(node.textContent).toContain(en.Inbox.operationsPanel.invalidPhone);
    expect(agregarBeneficiario).not.toHaveBeenCalled();
    await act(async () => root.unmount());
  });

  it("submits a zelle beneficiary with name and zelle_account", async () => {
    agregarBeneficiario.mockResolvedValue({ ok: true, id: "ben-2", complete: true });
    const { node, root, onDone } = await render();

    await act(async () => selectType(node, "zelle"));
    await act(async () => setValue(node.querySelector<HTMLInputElement>("#add-beneficiary-name")!, "Maria Perez"));
    await act(async () => setValue(node.querySelector<HTMLInputElement>("#add-beneficiary-zelle-account")!, "maria@example.com"));
    await act(async () => setValue(node.querySelector<HTMLInputElement>("#add-beneficiary-amount")!, "100"));
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
    await submit(node);

    expect(agregarBeneficiario).not.toHaveBeenCalled();
    expect(node.textContent).toContain(en.Inbox.operationsPanel.invalidAmount);
    await act(async () => root.unmount());
  });

  it("blocks submit for zelle when name or zelle_account is empty", async () => {
    const { node, root } = await render();

    await act(async () => selectType(node, "zelle"));
    await act(async () => setValue(node.querySelector<HTMLInputElement>("#add-beneficiary-amount")!, "100"));
    await submit(node);

    expect(agregarBeneficiario).not.toHaveBeenCalled();
    expect(node.textContent).toContain(en.Inbox.operationsPanel.cannotBeEmpty);
    await act(async () => root.unmount());
  });

  it("calls onCancel when cancel is clicked", async () => {
    const { node, root, onCancel } = await render();

    const cancelButton = node.querySelector(
      `button[aria-label="${en.Inbox.operationsPanel.cancel}"]`,
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
    await submit(node);

    expect(node.textContent).toContain("beneficiaries can only be added to remesa operations");
    expect(onDone).not.toHaveBeenCalled();
    await act(async () => root.unmount());
  });
});

describe("BeneficiaryAddControl derives the currency and prefills the amount (T2e)", () => {
  it.each([
    ["cuban_card", "CUP"],
    ["zelle", "USD"],
    ["clasica", "USD"],
    ["tropical", "USD"],
  ] as const)("%s: no currency field, sends %s", async (service, currency) => {
    agregarBeneficiario.mockResolvedValue({ ok: true, id: "b", complete: true });
    const { node, root } = await render(vi.fn(), vi.fn(), "remesa", service);

    expect(node.querySelector("#add-beneficiary-currency")).toBeNull();
    if (service === "zelle") {
      await act(async () => setValue(node.querySelector<HTMLInputElement>("#add-beneficiary-name")!, "Ana"));
      await act(async () => setValue(node.querySelector<HTMLInputElement>("#add-beneficiary-zelle-account")!, "a@b.co"));
    } else {
      await act(async () => setValue(node.querySelector<HTMLInputElement>("#add-beneficiary-card-number")!, "9205123412349412"));
    }
    await act(async () => setValue(node.querySelector<HTMLInputElement>("#add-beneficiary-amount")!, "50"));
    await submit(node);

    expect(agregarBeneficiario).toHaveBeenCalledWith("op-1", expect.objectContaining({ beneficiary_type: service, amount: 50, currency }));
    await act(async () => root.unmount());
  });

  it("the picker flow derives the currency from the chosen type", async () => {
    agregarBeneficiario.mockResolvedValue({ ok: true, id: "b", complete: true });
    const { node, root } = await render();
    await act(async () => selectType(node, "zelle"));
    await act(async () => setValue(node.querySelector<HTMLInputElement>("#add-beneficiary-name")!, "Ana"));
    await act(async () => setValue(node.querySelector<HTMLInputElement>("#add-beneficiary-zelle-account")!, "a@b.co"));
    await act(async () => setValue(node.querySelector<HTMLInputElement>("#add-beneficiary-amount")!, "20"));
    await submit(node);
    expect(agregarBeneficiario).toHaveBeenCalledWith("op-1", expect.objectContaining({ currency: "USD" }));
    await act(async () => root.unmount());
  });

  it("prefills the amount with the operation's quote (editable) and submits it untouched", async () => {
    agregarBeneficiario.mockResolvedValue({ ok: true, id: "b", complete: true });
    const { node, root } = await render(vi.fn(), vi.fn(), "remesa", "zelle", { amount: 100, currency: "USD" });
    const amount = node.querySelector<HTMLInputElement>("#add-beneficiary-amount")!;
    expect(amount.value).toBe("100");
    await act(async () => setValue(node.querySelector<HTMLInputElement>("#add-beneficiary-name")!, "Ana"));
    await act(async () => setValue(node.querySelector<HTMLInputElement>("#add-beneficiary-zelle-account")!, "a@b.co"));
    await submit(node);
    expect(agregarBeneficiario).toHaveBeenCalledWith("op-1", expect.objectContaining({ amount: 100, currency: "USD" }));
    await act(async () => setValue(amount, "80"));
    expect(amount.value).toBe("80");
    await act(async () => root.unmount());
  });

  it("does not prefill when there is no quote or its currency is not the service's", async () => {
    const a = await render(vi.fn(), vi.fn(), "remesa", "zelle", null);
    expect(a.node.querySelector<HTMLInputElement>("#add-beneficiary-amount")!.value).toBe("");
    await act(async () => a.root.unmount());
    const b = await render(vi.fn(), vi.fn(), "remesa", "cuban_card", { amount: 100, currency: "USD" });
    expect(b.node.querySelector<HTMLInputElement>("#add-beneficiary-amount")!.value).toBe("");
    await act(async () => b.root.unmount());
  });
});

describe("BeneficiaryAddControl on a combo", () => {
  const fill = async (node: HTMLElement, values: Record<string, string>) => {
    for (const [id, value] of Object.entries(values)) {
      await act(async () => setValue(node.querySelector<HTMLInputElement>(`#add-beneficiary-${id}`)!, value));
    }
  };

  it("offers name, phone, address, reference, contact phone and amount, no type, card or currency, and hints the minimum", async () => {
    const { node, root } = await render(vi.fn(), vi.fn(), "combo");

    expect(node.querySelector("select")).toBeNull();
    for (const id of ["name", "phone", "address", "reference", "contact-phone", "amount"]) {
      expect(node.querySelector(`#add-beneficiary-${id}`), id).not.toBeNull();
    }
    expect(node.querySelector("#add-beneficiary-card-number")).toBeNull();
    expect(node.querySelector("#add-beneficiary-currency")).toBeNull();
    expect(node.textContent).toContain("25\u202f000");
    await act(async () => root.unmount());
  });

  it.each([
    ["missing name", { name: "", phone: "52345678", amount: "25000" }, en.Inbox.operationsPanel.cannotBeEmpty],
    ["missing phone", { name: "Ana", phone: "", amount: "25000" }, en.Inbox.operationsPanel.invalidPhone],
    ["bad phone", { name: "Ana", phone: "12345", amount: "25000" }, en.Inbox.operationsPanel.invalidPhone],
    ["zero amount", { name: "Ana", phone: "52345678", amount: "0" }, en.Inbox.operationsPanel.invalidAmount],
    ["missing amount", { name: "Ana", phone: "52345678", amount: "" }, en.Inbox.operationsPanel.invalidAmount],
  ])("%s -> error and no request", async (_label, values, message) => {
    agregarBeneficiario.mockReset();
    const { node, root } = await render(vi.fn(), vi.fn(), "combo");

    await fill(node, values);
    await submit(node);

    expect(agregarBeneficiario).not.toHaveBeenCalled();
    expect(node.textContent).toContain(message);
    await act(async () => root.unmount());
  });

  it("sends the five fields and GYD amount, leaving empty optionals out", async () => {
    agregarBeneficiario.mockReset();
    agregarBeneficiario.mockResolvedValue({ ok: true, id: "ben-9", complete: true });
    const { node, root, onDone } = await render(vi.fn(), vi.fn(), "combo");

    await fill(node, {
      name: " Ana Lopez ",
      phone: "523-45678",
      address: "Calle 1 #2",
      reference: "frente a la bodega",
      "contact-phone": "53456789",
      amount: "25000",
    });
    await submit(node);

    expect(agregarBeneficiario).toHaveBeenCalledWith("op-1", {
      beneficiary_type: "combo",
      name: "Ana Lopez",
      phone: "52345678",
      address: "Calle 1 #2",
      reference: "frente a la bodega",
      contact_phone: "53456789",
      amount: 25000,
      currency: "GYD",
    });
    expect(onDone).toHaveBeenCalled();
    await act(async () => root.unmount());
  });

  it("sends only the required fields when the optionals are empty, and accepts an amount below the 25,000 hint", async () => {
    agregarBeneficiario.mockReset();
    agregarBeneficiario.mockResolvedValue({ ok: true, id: "ben-9", complete: false });
    const { node, root } = await render(vi.fn(), vi.fn(), "combo");

    await fill(node, { name: "Ana", phone: "52345678", amount: "20000" });
    await submit(node);

    expect(agregarBeneficiario).toHaveBeenCalledWith("op-1", {
      beneficiary_type: "combo",
      name: "Ana",
      phone: "52345678",
      amount: 20000,
      currency: "GYD",
    });
    await act(async () => root.unmount());
  });

  it("rejects a contact phone that is not 8 to 15 digits", async () => {
    agregarBeneficiario.mockReset();
    const { node, root } = await render(vi.fn(), vi.fn(), "combo");

    await fill(node, { name: "Ana", phone: "52345678", "contact-phone": "123", amount: "25000" });
    await submit(node);

    expect(agregarBeneficiario).not.toHaveBeenCalled();
    expect(node.textContent).toContain(en.Inbox.operationsPanel.invalidPhone);
    await act(async () => root.unmount());
  });

describe("BeneficiaryAddControl minimalist edit mode", () => {
  it("labels the check with the add key, shows no button text, and Escape in a field cancels", async () => {
    const { node, root, onCancel } = await render();

    const add = node.querySelector(`button[aria-label="${en.Inbox.operationsPanel.add}"]`)!;
    expect(add.getAttribute("type")).toBe("submit");
    expect(Array.from(node.querySelectorAll("button")).every((b) => (b.textContent ?? "").trim() === "")).toBe(true);
    expect(node.querySelector("form")!.className).not.toContain("bg-muted");

    await act(async () => node.querySelector("input")!.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true })));
    expect(onCancel).toHaveBeenCalledTimes(1);
    await act(async () => root.unmount());
  });

  it.each(["recarga", "combo"])("the %s form is also an unboxed form with the icon-only add check", async (serviceType) => {
    const { node, root, onCancel } = await render(vi.fn(), vi.fn(), serviceType);

    expect(node.querySelector("form")!.className).not.toContain("bg-muted");
    expect(node.querySelector(`button[aria-label="${en.Inbox.operationsPanel.add}"]`)).not.toBeNull();
    await act(async () => node.querySelector("input")!.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true })));
    expect(onCancel).toHaveBeenCalledTimes(1);
    await act(async () => root.unmount());
  });
});
});

describe("BeneficiaryAddControl follows the operation's service", () => {
  const fill = async (node: HTMLElement, values: Record<string, string>) => {
    for (const [id, value] of Object.entries(values)) {
      await act(async () => setValue(node.querySelector<HTMLInputElement>(`#add-beneficiary-${id}`)!, value));
    }
  };

  it("offers Cash USD in the picker when the operation has no service yet", async () => {
    const { node, root } = await render(vi.fn(), vi.fn(), "remesa", null);
    const values = Array.from(node.querySelectorAll("option")).map((o) => o.getAttribute("value"));
    expect(values).toEqual(["cuban_card", "zelle", "clasica", "tropical", "efectivo_usd"]);
    await act(async () => root.unmount());
  });

  it("shows the cash fields once Cash USD is picked: name, phone and address, no card, amount or currency", async () => {
    const { node, root } = await render(vi.fn(), vi.fn(), "remesa", null);

    await act(async () => selectType(node, "efectivo_usd"));

    for (const id of ["name", "phone", "address"]) expect(node.querySelector(`#add-beneficiary-${id}`), id).not.toBeNull();
    for (const id of ["card-number", "zelle-account", "amount", "currency"]) {
      expect(node.querySelector(`#add-beneficiary-${id}`), id).toBeNull();
    }
    expect(node.textContent).not.toContain("cashIdPhotoHint");
    await act(async () => root.unmount());
  });

  it.each(["cuban_card", "zelle", "clasica", "tropical", "efectivo_usd"] as const)(
    "shows the %s fields directly, with no type picker, when that is the operation's service",
    async (service) => {
      const { node, root } = await render(vi.fn(), vi.fn(), "remesa", service);

      expect(node.querySelector("select")).toBeNull();
      expect(node.querySelector("#add-beneficiary-type")).toBeNull();
      const has = (id: string) => node.querySelector(`#add-beneficiary-${id}`) !== null;
      expect(has("zelle-account")).toBe(service === "zelle");
      expect(has("card-number")).toBe(service !== "zelle" && service !== "efectivo_usd");
      expect(has("address")).toBe(service === "efectivo_usd");
      expect(has("amount")).toBe(service !== "efectivo_usd");
      await act(async () => root.unmount());
    },
  );

  it("sends the service as the recipient type for a clasica operation", async () => {
    agregarBeneficiario.mockReset();
    agregarBeneficiario.mockResolvedValue({ ok: true, id: "ben-20", complete: true });
    const { node, root, onDone } = await render(vi.fn(), vi.fn(), "remesa", "clasica");

    await fill(node, { "card-number": "9205123412349412", phone: "55512345", amount: "100" });
    await submit(node);

    expect(agregarBeneficiario).toHaveBeenCalledWith("op-1", {
      beneficiary_type: "clasica",
      card_number: "9205123412349412",
      phone: "55512345",
      amount: 100,
      currency: "USD",
    });
    expect(onDone).toHaveBeenCalled();
    await act(async () => root.unmount());
  });

  it("ignores the service on a recharge, a mobile balance and a combo: they keep their own forms", async () => {
    for (const [serviceType, service, field] of [
      ["recarga", "recarga", "#add-beneficiary-phone"],
      ["saldo", "saldo", "#add-beneficiary-phone"],
      ["combo", "combo", "#add-beneficiary-reference"],
    ] as const) {
      const { node, root } = await render(vi.fn(), vi.fn(), serviceType, service);
      expect(node.querySelector(field), serviceType).not.toBeNull();
      expect(node.querySelector("#add-beneficiary-address") !== null, serviceType).toBe(serviceType === "combo");
      await act(async () => root.unmount());
    }
  });

  it("sends {efectivo_usd, name, phone, address} for a cash recipient and nothing else", async () => {
    agregarBeneficiario.mockReset();
    agregarBeneficiario.mockResolvedValue({ ok: true, id: "ben-21", complete: false });
    const { node, root, onDone } = await render(vi.fn(), vi.fn(), "remesa", "efectivo_usd");

    await fill(node, { name: " Maria Perez ", phone: "5212-3456", address: " Calle 1 #23, Plaza " });
    await submit(node);

    expect(agregarBeneficiario).toHaveBeenCalledWith("op-1", {
      beneficiary_type: "efectivo_usd",
      name: "Maria Perez",
      phone: "52123456",
      address: "Calle 1 #23, Plaza",
    });
    expect(onDone).toHaveBeenCalled();
    await act(async () => root.unmount());
  });

  it("offers the ID photo picker on a cash recipient when the conversation is known, and sends the chosen wamid", async () => {
    agregarBeneficiario.mockReset();
    agregarBeneficiario.mockResolvedValue({ ok: true, id: "ben-23", complete: true });
    const { node, root } = await render(vi.fn(), vi.fn(), "remesa", "efectivo_usd", null, "conv-7");

    const picker = node.querySelector<HTMLButtonElement>('[data-testid="id-photo-picker"]')!;
    expect(picker.textContent).toBe(en.Inbox.operationsPanel.idPhotoPick);
    expect(picker.dataset.conversation).toBe("conv-7");
    expect(node.textContent).toContain(en.Inbox.operationsPanel.idPhotoMissing);

    await fill(node, { phone: "52123456", address: "Calle 1" });
    await act(async () => picker.click());
    expect(node.textContent).toContain(en.Inbox.operationsPanel.idPhotoChosen);
    await submit(node);

    expect(agregarBeneficiario).toHaveBeenCalledWith("op-1", {
      beneficiary_type: "efectivo_usd",
      phone: "52123456",
      address: "Calle 1",
      id_photo_wamid: "wamid.CHOSEN",
    });
    await act(async () => root.unmount());
  });

  it("without a chosen photo no id_photo_wamid key is sent; without a conversation no picker is offered", async () => {
    agregarBeneficiario.mockReset();
    agregarBeneficiario.mockResolvedValue({ ok: true, id: "ben-24", complete: false });
    const withConversation = await render(vi.fn(), vi.fn(), "remesa", "efectivo_usd", null, "conv-7");
    await fill(withConversation.node, { phone: "52123456", address: "Calle 1" });
    await submit(withConversation.node);
    expect(agregarBeneficiario.mock.calls[0][1]).not.toHaveProperty("id_photo_wamid");
    await act(async () => withConversation.root.unmount());

    const without = await render(vi.fn(), vi.fn(), "remesa", "efectivo_usd");
    expect(without.node.querySelector('[data-testid="id-photo-picker"]')).toBeNull();
    await act(async () => without.root.unmount());
  });

  it("the other recipient types never offer the picker", async () => {
    for (const service of ["zelle", "cuban_card"] as const) {
      const { node, root } = await render(vi.fn(), vi.fn(), "remesa", service, null, "conv-7");
      expect(node.querySelector('[data-testid="id-photo-picker"]'), service).toBeNull();
      await act(async () => root.unmount());
    }
  });

  it("leaves the name out when it is empty (it is optional)", async () => {
    agregarBeneficiario.mockReset();
    agregarBeneficiario.mockResolvedValue({ ok: true, id: "ben-22", complete: false });
    const { node, root } = await render(vi.fn(), vi.fn(), "remesa", "efectivo_usd");

    await fill(node, { phone: "52123456", address: "Calle 1" });
    await submit(node);

    expect(agregarBeneficiario).toHaveBeenCalledWith("op-1", {
      beneficiary_type: "efectivo_usd",
      phone: "52123456",
      address: "Calle 1",
    });
    await act(async () => root.unmount());
  });

  it.each([
    ["a bad phone", { phone: "123", address: "Calle 1" }, en.Inbox.operationsPanel.invalidPhone],
    ["a missing phone", { phone: "", address: "Calle 1" }, en.Inbox.operationsPanel.invalidPhone],
    ["a missing address", { phone: "52123456", address: "  " }, en.Inbox.operationsPanel.cannotBeEmpty],
  ])("%s -> error and no request", async (_label, values, message) => {
    agregarBeneficiario.mockReset();
    const { node, root } = await render(vi.fn(), vi.fn(), "remesa", "efectivo_usd");

    await fill(node, values);
    await submit(node);

    expect(agregarBeneficiario).not.toHaveBeenCalled();
    expect(node.textContent).toContain(message);
    await act(async () => root.unmount());
  });

  it("Enter saves (form submit) and Escape cancels on the cash form", async () => {
    agregarBeneficiario.mockReset();
    const onCancel = vi.fn();
    const { node, root } = await render(vi.fn(), onCancel, "remesa", "efectivo_usd");

    const input = node.querySelector<HTMLInputElement>("#add-beneficiary-address")!;
    await act(async () => {
      input.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }));
    });

    expect(onCancel).toHaveBeenCalled();
    expect(node.querySelector("form")!.querySelector('button[type="submit"]')).not.toBeNull();
    await act(async () => root.unmount());
  });

  it("shows the server error and keeps the form open when the add is refused", async () => {
    agregarBeneficiario.mockReset();
    agregarBeneficiario.mockResolvedValue({ ok: false, status: 400, error: "a cash delivery has one recipient: correct it instead of adding another" });
    const { node, root, onDone } = await render(vi.fn(), vi.fn(), "remesa", "efectivo_usd");

    await fill(node, { phone: "52123456", address: "Calle 1" });
    await submit(node);

    expect(node.textContent).toContain("a cash delivery has one recipient");
    expect(onDone).not.toHaveBeenCalled();
    await act(async () => root.unmount());
  });
});

describe("BeneficiaryAddControl on a México operation", () => {
  const fill = async (node: HTMLElement, values: Record<string, string>) => {
    for (const [id, value] of Object.entries(values)) {
      await act(async () => setValue(node.querySelector<HTMLInputElement>(`#${id}`)!, value));
    }
  };

  it("offers a bank account by default: holder, CLABE, bank and an optional USD amount, with no card or phone", async () => {
    const { node, root } = await render(vi.fn(), vi.fn(), "mexico", "mexico");

    expect(node.querySelector("#add-beneficiary-name")).not.toBeNull();
    expect(node.querySelector("#add-beneficiary-clabe")).not.toBeNull();
    expect(node.querySelector("#add-beneficiary-bank")).not.toBeNull();
    expect(node.querySelector("#add-beneficiary-amount")).not.toBeNull();
    expect(node.querySelector("#add-beneficiary-card-number")).toBeNull();
    expect(node.querySelector("#add-beneficiary-phone")).toBeNull();
    await act(async () => root.unmount());
  });

  it("sends the USD amount of the recipient when it is filled, and blocks a zero", async () => {
    agregarBeneficiario.mockReset();
    agregarBeneficiario.mockResolvedValue({ ok: true, id: "ben-m3", complete: true });
    const { node, root } = await render(vi.fn(), vi.fn(), "mexico", "mexico");

    await fill(node, { "add-beneficiary-name": "Ana", "add-beneficiary-clabe": "012345678901234567", "add-beneficiary-bank": "BBVA", "add-beneficiary-amount": "0" });
    await submit(node);
    expect(agregarBeneficiario).not.toHaveBeenCalled();
    expect(node.textContent).toContain(en.Inbox.operationsPanel.invalidAmount);

    await fill(node, { "add-beneficiary-amount": "50" });
    await submit(node);
    expect(agregarBeneficiario).toHaveBeenCalledWith("op-1", {
      beneficiary_type: "mexico_cuenta",
      name: "Ana",
      clabe: "012345678901234567",
      bank_name: "BBVA",
      amount: 50,
    });
    await act(async () => root.unmount());
  });

  it("sends a bank account with the CLABE digits, bank and holder, and no amount when it is left empty", async () => {
    agregarBeneficiario.mockReset();
    agregarBeneficiario.mockResolvedValue({ ok: true, id: "ben-m1", complete: true });
    const { node, root, onDone } = await render(vi.fn(), vi.fn(), "mexico", "mexico");

    await fill(node, { "add-beneficiary-name": "Ana Lopez", "add-beneficiary-clabe": "0123 4567 8901 234567", "add-beneficiary-bank": "BBVA" });
    await submit(node);

    expect(agregarBeneficiario).toHaveBeenCalledWith("op-1", {
      beneficiary_type: "mexico_cuenta",
      name: "Ana Lopez",
      clabe: "012345678901234567",
      bank_name: "BBVA",
    });
    expect(onDone).toHaveBeenCalled();
    await act(async () => root.unmount());
  });

  it("blocks a CLABE that is not 18 digits and sends nothing", async () => {
    agregarBeneficiario.mockReset();
    const { node, root } = await render(vi.fn(), vi.fn(), "mexico", "mexico");

    await fill(node, { "add-beneficiary-name": "Ana", "add-beneficiary-clabe": "1234", "add-beneficiary-bank": "BBVA" });
    await submit(node);

    expect(agregarBeneficiario).not.toHaveBeenCalled();
    expect(node.textContent).toContain(en.Inbox.operationsPanel.invalidClabe);
    await act(async () => root.unmount());
  });

  it("offers a cardless withdrawal with a Coppel or BBVA network, the receiver and the phone", async () => {
    agregarBeneficiario.mockReset();
    agregarBeneficiario.mockResolvedValue({ ok: true, id: "ben-m2", complete: true });
    const { node, root, onDone } = await render(vi.fn(), vi.fn(), "mexico", "mexico");

    selectType(node, "mexico_retiro");
    await act(async () => {});
    expect(node.querySelector("#add-beneficiary-clabe")).toBeNull();
    const bank = node.querySelector<HTMLSelectElement>("#add-beneficiary-bank")!;
    expect([...bank.options].map((o) => o.value)).toEqual(["Coppel", "BBVA"]);

    await fill(node, { "add-beneficiary-name": "Luis Perez", "add-beneficiary-phone": "52345678" });
    await act(async () => {
      const setter = Object.getOwnPropertyDescriptor(window.HTMLSelectElement.prototype, "value")!.set!;
      setter.call(bank, "BBVA");
      bank.dispatchEvent(new Event("change", { bubbles: true }));
    });
    await submit(node);

    expect(agregarBeneficiario).toHaveBeenCalledWith("op-1", {
      beneficiary_type: "mexico_retiro",
      name: "Luis Perez",
      bank_name: "BBVA",
      phone: "52345678",
    });
    expect(onDone).toHaveBeenCalled();
    await act(async () => root.unmount());
  });
});
