// @vitest-environment jsdom
// The split editor (crm_repartir_envio): one row per part (service + GYD), prefilled with the group's members or the
// operation alone, a live "assigned X of TOTAL" line, and a submit that stays locked until there are at least two
// parts, each with its own service, adding up exactly to the total.

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

const repartirEnvio = vi.fn();
vi.mock("@/lib/remittance-operations/commands", () => ({
  repartirEnvio: (...args: unknown[]) => repartirEnvio(...args),
}));

// The app's Select (Base UI) hangs under jsdom; same native stand-in as the correction form's tests.
vi.mock("@/components/ui/select", () => ({
  Select: ({ id, value, disabled, onValueChange, children }: {
    id?: string; value?: string; disabled?: boolean; onValueChange?: (value: string) => void; children?: React.ReactNode;
  }) => (
    <select id={id} value={value ?? ""} disabled={disabled} onChange={(event) => onValueChange?.(event.target.value)}>
      <option value="" />
      {children}
    </select>
  ),
  SelectTrigger: () => null,
  SelectValue: () => null,
  SelectContent: ({ children }: { children?: React.ReactNode }) => <>{children}</>,
  SelectItem: ({ value, children }: { value: string; children?: React.ReactNode }) => <option value={value}>{children}</option>,
}));

const toast = { success: vi.fn(), error: vi.fn() };
vi.mock("sonner", () => ({ toast: { success: (...a: unknown[]) => toast.success(...a), error: (...a: unknown[]) => toast.error(...a) } }));

afterEach(() => {
  repartirEnvio.mockReset();
  toast.success.mockReset();
  toast.error.mockReset();
  document.body.replaceChildren();
});

const t = en.Inbox.operationsPanel.splitDeposit;

function operation(overrides: Partial<RemittanceOperationRead> = {}): RemittanceOperationRead {
  return {
    id: "op-1",
    status: "deposit_verification",
    serviceType: "remesa",
    sourceCurrency: "GYD",
    destinationCurrency: "USD",
    deliveryMethod: "clasica",
    depositMethod: "mmg",
    quotedSourceAmount: 24400,
    quotedDestinationAmount: null,
    quotedDestinationRate: null,
    quotedDestinationOrigin: null,
    adminLockedFields: {},
    createdAt: "2026-10-20T00:00:00Z",
    completedAt: null,
    isHistory: false,
    beneficiariesComplete: false,
    deliveryMode: null,
    deliveredAt: null,
    mixedGroupId: null,
    beneficiaries: [],
    ...overrides,
  };
}

const PAIR = [
  operation({ id: "op-1", quotedSourceAmount: 18200, mixedGroupId: "op-1" }),
  operation({ id: "op-2", serviceType: "recarga", deliveryMethod: null, quotedSourceAmount: 6200, mixedGroupId: "op-1" }),
];

function setValue(input: HTMLInputElement, value: string) {
  const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value")!.set!;
  setter.call(input, value);
  input.dispatchEvent(new Event("input", { bubbles: true }));
}

function pick(select: HTMLSelectElement, value: string) {
  const setter = Object.getOwnPropertyDescriptor(window.HTMLSelectElement.prototype, "value")!.set!;
  setter.call(select, value);
  select.dispatchEvent(new Event("change", { bubbles: true }));
}

async function render(members: RemittanceOperationRead[], onDone = vi.fn(), onCancel = vi.fn()) {
  const { SplitDepositForm } = await import("./split-deposit-form");
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  await act(async () => root.render(<SplitDepositForm operationId="op-1" members={members} onDone={onDone} onCancel={onCancel} />));
  return { node, root, onDone, onCancel };
}

const services = (node: HTMLElement) => [...node.querySelectorAll<HTMLSelectElement>("select")].map((s) => s.value);
const amounts = (node: HTMLElement) => [...node.querySelectorAll<HTMLInputElement>('input[inputmode="decimal"]')].map((i) => i.value);
const confirm = (node: HTMLElement) => node.querySelector<HTMLButtonElement>(`button[aria-label="${t.confirm}"]`)!;
const assigned = (assignedAmount: number, total: number) =>
  t.assigned.replace("{assigned}", formatNumber(assignedAmount)).replace("{total}", formatNumber(total));

describe("SplitDepositForm", () => {
  it("prefills one row per group member with its service and share, adding up to the total", async () => {
    const { node, root } = await render(PAIR);

    expect(services(node)).toEqual(["clasica", "recarga"]);
    expect(amounts(node)).toEqual(["18200", "6200"]);
    expect(node.textContent).toContain(assigned(24400, 24400));
    expect(confirm(node).disabled).toBe(false);
    await act(async () => root.unmount());
  });

  it("prefills a lone operation as one row and keeps submit locked until a second part is added", async () => {
    const { node, root } = await render([operation()]);

    expect(services(node)).toEqual(["clasica"]);
    expect(amounts(node)).toEqual(["24400"]);
    expect(confirm(node).disabled).toBe(true);

    await act(async () => node.querySelector<HTMLButtonElement>(`button[aria-label="${t.addPart}"]`)!.click());

    expect(services(node)).toEqual(["clasica", ""]);
    expect(node.textContent).toContain(assigned(24400, 24400));
    expect(confirm(node).disabled).toBe(true);
    await act(async () => root.unmount());
  });

  it("unlocks submit only when the new part is chosen and the amounts add up exactly to the total", async () => {
    const { node, root } = await render([operation()]);
    await act(async () => node.querySelector<HTMLButtonElement>(`button[aria-label="${t.addPart}"]`)!.click());

    await act(async () => pick(node.querySelectorAll("select")[1]!, "recarga"));
    await act(async () => setValue(node.querySelectorAll<HTMLInputElement>('input[inputmode="decimal"]')[1]!, "6200"));
    expect(node.textContent).toContain(assigned(30600, 24400));
    expect(confirm(node).disabled).toBe(true);

    await act(async () => setValue(node.querySelectorAll<HTMLInputElement>('input[inputmode="decimal"]')[0]!, "18200"));
    expect(node.textContent).toContain(assigned(24400, 24400));
    expect(confirm(node).disabled).toBe(false);
    await act(async () => root.unmount());
  });

  it("keeps submit locked when two rows share a service or an amount is not above zero", async () => {
    const { node, root } = await render(PAIR);

    await act(async () => pick(node.querySelectorAll("select")[1]!, "clasica"));
    expect(confirm(node).disabled).toBe(true);

    await act(async () => pick(node.querySelectorAll("select")[1]!, "recarga"));
    expect(confirm(node).disabled).toBe(false);

    await act(async () => setValue(node.querySelectorAll<HTMLInputElement>('input[inputmode="decimal"]')[0]!, "24400"));
    await act(async () => setValue(node.querySelectorAll<HTMLInputElement>('input[inputmode="decimal"]')[1]!, "0"));
    expect(confirm(node).disabled).toBe(true);
    await act(async () => root.unmount());
  });

  it("removes a row, and drops back to locked when fewer than two remain", async () => {
    const { node, root } = await render(PAIR);

    await act(async () => node.querySelectorAll<HTMLButtonElement>(`button[aria-label="${t.removePart}"]`)[1]!.click());

    expect(services(node)).toEqual(["clasica"]);
    expect(confirm(node).disabled).toBe(true);
    expect(node.querySelectorAll(`button[aria-label="${t.removePart}"]`)).toHaveLength(0);
    await act(async () => root.unmount());
  });

  it("sends the parts as service + numeric GYD, toasts and reports done", async () => {
    repartirEnvio.mockResolvedValue({ ok: true, group: "op-1", deposited: 24400, balance: 0, parts: [] });
    const { node, root, onDone } = await render(PAIR);

    await act(async () => setValue(node.querySelectorAll<HTMLInputElement>('input[inputmode="decimal"]')[0]!, "20.000"));
    await act(async () => setValue(node.querySelectorAll<HTMLInputElement>('input[inputmode="decimal"]')[1]!, "4400"));
    await act(async () => {
      node.querySelector("form")!.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
    });

    expect(repartirEnvio).toHaveBeenCalledWith("op-1", [
      { service: "clasica", amountGyd: 20000 },
      { service: "recarga", amountGyd: 4400 },
    ]);
    expect(toast.success).toHaveBeenCalledWith(t.saved);
    expect(onDone).toHaveBeenCalled();
    await act(async () => root.unmount());
  });

  it("shows the server's message when the split is refused and does not report done", async () => {
    repartirEnvio.mockResolvedValue({ ok: false, status: 400, error: "group member x is completed and cannot be re-split" });
    const { node, root, onDone } = await render(PAIR);

    await act(async () => {
      node.querySelector("form")!.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
    });

    expect(node.textContent).toContain(t.failed.replace("{message}", "group member x is completed and cannot be re-split"));
    expect(onDone).not.toHaveBeenCalled();
    expect(toast.success).not.toHaveBeenCalled();
    await act(async () => root.unmount());
  });

  it("never sends while the parts are invalid", async () => {
    const { node, root } = await render([operation()]);

    await act(async () => {
      node.querySelector("form")!.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
    });

    expect(repartirEnvio).not.toHaveBeenCalled();
    await act(async () => root.unmount());
  });

  it("cancels with the X", async () => {
    const { node, root, onCancel } = await render(PAIR);

    await act(async () => node.querySelector<HTMLButtonElement>('button[aria-label="Cancel"]')!.click());

    expect(onCancel).toHaveBeenCalled();
    await act(async () => root.unmount());
  });
});
