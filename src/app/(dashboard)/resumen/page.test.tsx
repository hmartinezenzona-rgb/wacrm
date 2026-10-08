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
// Base UI Select hangs jsdom; the filter is not under test.
vi.mock("@/components/ui/select", () => ({
  Select: () => null,
  SelectContent: () => null,
  SelectItem: () => null,
  SelectTrigger: () => null,
  SelectValue: () => null,
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
});
