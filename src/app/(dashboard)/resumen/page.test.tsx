// @vitest-environment jsdom
// Finanzas history table: the "Estado" column is a status pill with the translated label, and the "Servicio"
// column carries the fixed service dot before the name.

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import en from "../../../../messages/en.json";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

vi.mock("next-intl", () => ({
  useTranslations: (namespace: string) => {
    const node = namespace
      .split(".")
      .reduce((acc: Record<string, unknown>, part) => acc[part] as Record<string, unknown>, en as unknown as Record<string, unknown>);
    const t = (key: string) => key.split(".").reduce((acc: unknown, part) => (acc as Record<string, unknown>)?.[part], node) as string;
    t.has = (key: string) => typeof t(key) === "string";
    return t;
  },
}));

const rpc = vi.fn();
vi.mock("@/lib/supabase/client", () => ({ createClient: () => ({ rpc }) }));
vi.mock("@/components/resumen/financial-close-section", () => ({ FinancialCloseSection: () => null }));
// Base UI Select hangs jsdom; a native double keeps the options and the change contract. The first Select on the page is
// the service filter, the second one the page size.
vi.mock("@/components/ui/select", () => ({
  Select: ({ value, onValueChange, children }: { value?: string; onValueChange?: (value: string) => void; children?: React.ReactNode }) => (
    <select value={value} onChange={(event) => onValueChange?.(event.target.value)}>
      {children}
    </select>
  ),
  SelectTrigger: () => null,
  SelectValue: () => null,
  SelectContent: ({ children }: { children?: React.ReactNode }) => <>{children}</>,
  SelectItem: ({ value, children }: { value: string; children?: React.ReactNode }) => <option value={value}>{children}</option>,
}));

import ResumenPage from "./page";

const row = (over: Record<string, unknown>) => ({
  dia: "2026-10-05",
  service_type: "remesa",
  status: "completed",
  cliente: "Ana",
  telefono: "5926000000",
  monto_gyd: 1000,
  beneficiario: null,
  tarjeta: null,
  operation_id: "op-1",
  total: 3,
  ...over,
});

async function renderPage(rows: unknown[]) {
  rpc.mockImplementation(async (name: string) => ({ data: name === "cerebro_dashboard_historial" ? rows : [], error: null }));
  const node = document.createElement("div");
  document.body.appendChild(node);
  await act(async () => createRoot(node).render(<ResumenPage />));
  await act(async () => {});
  return node;
}

beforeEach(() => rpc.mockReset());
afterEach(() => {
  document.body.innerHTML = "";
});

describe("Finanzas history table", () => {
  it("shows the status as a pill with the translated label and its tone", async () => {
    const node = await renderPage([
      row({ operation_id: "a", status: "ready_to_transfer" }),
      row({ operation_id: "b", status: "completed" }),
      row({ operation_id: "c", status: "brand_new" }),
    ]);
    const pills = [...node.querySelectorAll("tbody [data-tone]")] as HTMLElement[];
    expect(pills.map((p) => [p.textContent, p.dataset.tone])).toEqual([
      ["Ready to transfer", "attention"],
      ["Completed", "success"],
      ["brand_new", "neutral"],
    ]);
  });

  it("puts the fixed service dot before the service name, one colour per service", async () => {
    const node = await renderPage([
      row({ operation_id: "a", service_type: "remesa" }),
      row({ operation_id: "b", service_type: "recarga" }),
      row({ operation_id: "c", service_type: "mystery" }),
    ]);
    const cells = [...node.querySelectorAll("tbody tr")].map((r) => r.querySelectorAll("td")[1]!);
    expect(cells.map((c) => [c.textContent, c.querySelector("[data-service]")?.getAttribute("data-service")])).toEqual([
      ["Remesa", "remesa"],
      ["Recarga", "recarga"],
      ["mystery", "other"],
    ]);
    expect(cells[0]!.firstElementChild!.getAttribute("aria-hidden")).toBe("true");
  });

  it("names the specific service of the operation (servicio) and colours the dot after it", async () => {
    const node = await renderPage([
      row({ operation_id: "a", servicio: "CUP" }),
      row({ operation_id: "b", servicio: "ZELLE" }),
      row({ operation_id: "c", servicio: "SALDO_MOVIL", service_type: "saldo" }),
      row({ operation_id: "d", servicio: "MIXTA" }),
      row({ operation_id: "e", servicio: "REMESA" }),
    ]);
    const cells = [...node.querySelectorAll("tbody tr")].map((r) => r.querySelectorAll("td")[1]!);
    expect(cells.map((c) => [c.textContent, c.querySelector("[data-service]")?.getAttribute("data-service")])).toEqual([
      ["CUP", "cup"],
      ["Zelle", "zelle"],
      ["Saldo móvil", "saldo"],
      ["Remesa mixta", "other"],
      ["Remesa", "remesa"],
    ]);
  });

  it("falls back to the service_type name when the database does not send servicio yet", async () => {
    const node = await renderPage([row({ operation_id: "a" }), row({ operation_id: "b", servicio: null, service_type: "combo" })]);
    const cells = [...node.querySelectorAll("tbody tr")].map((r) => r.querySelectorAll("td")[1]!);
    expect(cells.map((c) => c.textContent)).toEqual(["Remesa", "Combo"]);
  });

  it("lists the canonical services in the filter, after Todos, and sends the ledger-style value", async () => {
    const node = await renderPage([row({})]);
    const filter = node.querySelectorAll("select")[0]!;
    expect([...filter.options].map((o) => [o.value, o.textContent])).toEqual([
      ["__todos__", "Todos"],
      ["CUP", "CUP"],
      ["ZELLE", "Zelle"],
      ["CLASICA", "Clásica"],
      ["TROPICAL", "Tropical"],
      ["EFECTIVO", "Efectivo USD"],
      ["RECARGA", "Recarga"],
      ["SALDO_MOVIL", "Saldo móvil"],
      ["COMBO", "Combo"],
      ["VISA", "Visa"],
      ["MIXTA", "Remesa mixta"],
      ["TRADUCCION", "Traducción"],
      ["MEXICO", "México"],
    ]);
    rpc.mockClear();
    await act(async () => {
      // React tracks a controlled value: go through the prototype setter so the change event is seen.
      Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, "value")!.set!.call(filter, "CUP");
      filter.dispatchEvent(new Event("change", { bubbles: true }));
    });
    const apply = [...node.querySelectorAll("button")].find((b) => b.textContent === "Aplicar")!;
    await act(async () => apply.click());
    const calls = rpc.mock.calls.filter(([name]) => name === "cerebro_dashboard_historial");
    expect(calls.at(-1)![1]).toMatchObject({ p_servicio: "CUP", p_desde_fila: 0 });
  });
});
