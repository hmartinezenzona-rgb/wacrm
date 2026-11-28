// @vitest-environment jsdom
// Finanzas history table: the "Estado" column is a status pill with the translated label, and the "Servicio"
// column carries the fixed service dot before the name.

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import en from "../../../messages/en.json";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

vi.mock("next-intl", () => ({
  useTranslations: (namespace: string) => {
    const node = namespace
      .split(".")
      .reduce((acc: Record<string, unknown>, part) => acc[part] as Record<string, unknown>, en as unknown as Record<string, unknown>);
    const t = (key: string, values?: Record<string, string | number>) => {
      const text = key.split(".").reduce((acc: unknown, part) => (acc as Record<string, unknown>)?.[part], node) as string;
      return typeof text === "string" && values ? text.replace(/\{(\w+)\}/g, (_, k: string) => String(values[k] ?? `{${k}}`)) : text;
    };
    t.has = (key: string) => typeof t(key) === "string";
    return t;
  },
}));

const rpc = vi.fn();
vi.mock("@/lib/supabase/client", () => ({ createClient: () => ({ rpc }) }));
vi.mock("@/components/resumen/financial-close-section", () => ({ FinancialCloseSection: () => <section data-testid="close" /> }));
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

import { HistorialBusqueda } from "./historial-busqueda";

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
  conversation_id: "conv-1",
  operacion_at: "2026-10-05T18:32:00Z",
  estado_grupo: "completed",
  ...over,
});

async function renderPage(rows: unknown[]) {
  rpc.mockImplementation(async (name: string) => ({ data: name === "crm_historial_operaciones" ? rows : [], error: null }));
  const node = document.createElement("div");
  document.body.appendChild(node);
  await act(async () => createRoot(node).render(<HistorialBusqueda />));
  await act(async () => {});
  return node;
}

beforeEach(() => rpc.mockReset());
afterEach(() => {
  document.body.innerHTML = "";
});

describe("Operaciones tab", () => {
  // The financial close (day / week / month / range) belongs to the Cierres tab now.
  it("keeps the period summary and the history, and leaves the financial close to the Cierres tab", async () => {
    const node = await renderPage([row({})]);
    expect(node.querySelector('[data-testid="resumen-section"]')).not.toBeNull();
    expect(node.querySelector('[data-testid="historial-section"]')).not.toBeNull();
    expect(node.querySelector('[data-testid="close"]')).toBeNull();
    // the Finanzas view owns the page title
    expect(node.querySelector("h1")).toBeNull();
  });
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
      ["Ready to transfer", "ready"],
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
    const cells = [...node.querySelectorAll("tbody tr")].map((r) => r.querySelectorAll("td")[2]!);
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
    const cells = [...node.querySelectorAll("tbody tr")].map((r) => r.querySelectorAll("td")[2]!);
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
    const cells = [...node.querySelectorAll("tbody tr")].map((r) => r.querySelectorAll("td")[2]!);
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
    const calls = rpc.mock.calls.filter(([name]) => name === "crm_historial_operaciones");
    expect(calls.at(-1)![1]).toMatchObject({ p_servicio: "CUP", p_desde_fila: 0 });
  });
});

describe("Finanzas section order", () => {
  const periods = [1, 2, 3, 4, 5].map((orden) => ({
    orden,
    periodo: `p${orden}`,
    desde: "2026-10-01",
    hasta: "2026-10-02",
    operaciones: 4,
    volumen_gyd: 12000,
    ticket_medio_gyd: 3000,
  }));

  async function renderWithPeriods() {
    rpc.mockImplementation(async (name: string) => ({
      data: name === "crm_historial_operaciones" ? [row({})] : name === "crm_historial_estados" ? [] : periods,
      error: null,
    }));
    const node = document.createElement("div");
    document.body.appendChild(node);
    await act(async () => createRoot(node).render(<HistorialBusqueda />));
    await act(async () => {});
    return node;
  }

  it("puts Resumen first, then Historial (the financial close moved to the Cierres tab)", async () => {
    const node = await renderWithPeriods();
    const resumen = node.querySelector("[data-testid='resumen-section']")!;
    const historial = node.querySelector("[data-testid='historial-section']")!;
    const follows = (a: Element, b: Element) => Boolean(a.compareDocumentPosition(b) & Node.DOCUMENT_POSITION_FOLLOWING);
    expect(follows(resumen, historial)).toBe(true);
    expect(node.querySelector("[data-testid='close']")).toBeNull();
  });

  it("shows the volume of each period as the main figure in the money-in tone, keeping every number", async () => {
    const node = await renderWithPeriods();
    const cards = [...node.querySelectorAll("[data-testid='resumen-card']")];
    expect(cards).toHaveLength(5);
    const volume = cards[0]!.querySelector("[data-tone]")!;
    expect(volume.getAttribute("data-tone")).toBe("in");
    expect(volume.textContent).toContain("12\u202f000 GYD");
    expect(cards[0]!.textContent).toContain("4");
    expect(cards[0]!.textContent).toContain("3\u202f000 GYD");
    expect(cards[0]!.className).toContain("--money-in");
    expect(cards[0]!.tagName).toBe("BUTTON");
  });

  it("gives the three top-level sections the same stronger heading", async () => {
    const node = await renderWithPeriods();
    const headings = ["resumen-section", "historial-section"].map((id) => node.querySelector(`[data-testid='${id}'] h2`)!.className);
    expect(headings[0]).toBe(headings[1]);
    expect(headings[0]).toContain("text-base");
  });
});

// ---------------------------------------------------------------------------------------------------------------------
// Redesign (O1): period cards filter the table, search, status chips with counts, Guyana time, open chat, copy id, CSV.
// ---------------------------------------------------------------------------------------------------------------------

const periodos = [
  { orden: 1, periodo: "Hoy", desde: "2026-10-29", hasta: "2026-10-29", operaciones: 18, volumen_gyd: 486000, ticket_medio_gyd: 27000 },
  { orden: 3, periodo: "Semana", desde: "2026-10-26", hasta: "2026-11-01", operaciones: 142, volumen_gyd: 3960000, ticket_medio_gyd: 27900 },
];

function historialCalls() {
  return rpc.mock.calls.filter(([name]) => name === "crm_historial_operaciones");
}

async function mount(rows: unknown[] = [row({})], opts: { counts?: unknown[]; historialError?: unknown } = {}) {
  rpc.mockImplementation(async (name: string) => {
    if (name === "cerebro_dashboard_resumen") return { data: periodos, error: null };
    if (name === "crm_historial_estados") {
      return {
        data: opts.counts ?? [
          { grupo: "completed", cantidad: 13 },
          { grupo: "in_progress", cantidad: 4 },
          { grupo: "incident", cantidad: 1 },
          { grupo: "cancelled", cantidad: 0 },
        ],
        error: null,
      };
    }
    if (opts.historialError) return { data: null, error: opts.historialError };
    return { data: rows, error: null };
  });
  const node = document.createElement("div");
  document.body.appendChild(node);
  await act(async () => createRoot(node).render(<HistorialBusqueda />));
  await act(async () => {});
  return node;
}

const click = async (el: Element) => act(async () => (el as HTMLElement).click());
const buttonByText = (node: Element, text: string) => [...node.querySelectorAll("button")].find((b) => b.textContent?.startsWith(text))!;

describe("Operaciones period cards", () => {
  it("are buttons that set Desde/Hasta to the period and mark the active one with aria-pressed", async () => {
    const node = await mount();
    const cards = [...node.querySelectorAll("[data-testid='resumen-card']")] as HTMLElement[];
    expect(cards.map((c) => c.getAttribute("aria-pressed"))).toEqual(["false", "false"]);
    rpc.mockClear();
    await click(cards[0]!);
    expect(cards[0]!.getAttribute("aria-pressed")).toBe("true");
    const dates = [...node.querySelectorAll("input[type='date']")] as HTMLInputElement[];
    expect(dates.map((d) => d.value)).toEqual(["2026-10-29", "2026-10-29"]);
    expect(historialCalls().at(-1)![1]).toMatchObject({ p_desde: "2026-10-29", p_hasta: "2026-10-29", p_desde_fila: 0 });
  });

  it("releases the range when the active card is pressed again", async () => {
    const node = await mount();
    const card = node.querySelector("[data-testid='resumen-card']") as HTMLElement;
    await click(card);
    await click(card);
    expect(card.getAttribute("aria-pressed")).toBe("false");
    expect(historialCalls().at(-1)![1]).toMatchObject({ p_desde: null, p_hasta: null });
  });
});

describe("Operaciones search and status chips", () => {
  it("shows the chips with the counts from the counts function, Todas being their sum", async () => {
    const node = await mount();
    const chips = [...node.querySelectorAll("[role='group'][aria-label='Status'] button")];
    expect(chips.map((c) => c.textContent)).toEqual(["All · 18", "Completed · 13", "In progress · 4", "Incident · 1", "Cancelled · 0"]);
    expect(chips.map((c) => c.getAttribute("aria-pressed"))).toEqual(["true", "false", "false", "false", "false"]);
  });

  it("sends the status group when a chip is pressed, and goes back to the first page", async () => {
    const node = await mount();
    rpc.mockClear();
    await click(buttonByText(node, "Completed"));
    expect(historialCalls().at(-1)![1]).toMatchObject({ p_estado: "completed", p_desde_fila: 0 });
    // counts ignore the status filter
    const countsCall = rpc.mock.calls.filter(([name]) => name === "crm_historial_estados");
    expect(countsCall.every(([, args]) => !("p_estado" in (args as object)))).toBe(true);
  });

  it("debounces the search ~300 ms and trims it", async () => {
    vi.useFakeTimers();
    try {
      const node = await mount();
      const input = node.querySelector("input[type='search']") as HTMLInputElement;
      rpc.mockClear();
      const set = (value: string) =>
        act(async () => {
          Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(input, value);
          input.dispatchEvent(new Event("input", { bubbles: true }));
        });
      await set("  an");
      await set("  ana ");
      await act(async () => {
        vi.advanceTimersByTime(299);
      });
      expect(historialCalls()).toHaveLength(0);
      await act(async () => {
        vi.advanceTimersByTime(2);
      });
      expect(historialCalls()).toHaveLength(1);
      expect(historialCalls()[0]![1]).toMatchObject({ p_buscar: "ana", p_desde_fila: 0 });
    } finally {
      vi.useRealTimers();
    }
  });
});

describe("Operaciones table", () => {
  it("shows only the time (Guyana) for a single-day range and dd/MM HH:mm otherwise", async () => {
    const node = await mount([row({ operacion_at: "2026-10-29T18:32:00Z" })]);
    const hora = () => node.querySelector("tbody tr td")!.textContent;
    expect(hora()).toBe("29/10 14:32");
    await click(node.querySelector("[data-testid='resumen-card']")!);
    expect(hora()).toBe("14:32");
  });

  it("shows the client with the phone under it, and drops the operation id column", async () => {
    const node = await mount([row({ cliente: "Ana", telefono: "5926001234" })]);
    const headers = [...node.querySelectorAll("thead th")].map((h) => h.textContent);
    expect(headers).toEqual(Object.values(
      (({ hora, cliente, servicio, monto, destino, status, acciones }) => ({ hora, cliente, servicio, monto, destino, status, acciones }))(
        en.Resumen.page.tabla,
      ),
    ));
    const cell = node.querySelectorAll("tbody tr td")[1]!;
    expect(cell.textContent).toBe("Ana5926001234");
    expect(node.querySelector("tbody")!.textContent).not.toContain("op-1");
  });

  it("has no 'Open chat' link: the history is for searching, not for jumping into a conversation", async () => {
    const node = await renderPage([row({ conversation_id: "conv-9" })]);
    expect(node.querySelector("tbody a")).toBeNull();
    expect(node.textContent).not.toContain("Open chat");
    expect(node.textContent).not.toContain("Abrir chat");
  });

  it("copies the operation id from a labelled button in the row", async () => {
    const writeText = vi.fn().mockResolvedValue(undefined);
    Object.defineProperty(navigator, "clipboard", { value: { writeText }, configurable: true });
    const node = await mount([row({ operation_id: "11111111-aaaa" })]);
    const btn = node.querySelector("tbody button[aria-label]") as HTMLButtonElement;
    expect(btn.getAttribute("aria-label")).toBe("Copy operation ID 11111111-aaaa");
    await click(btn);
    expect(writeText).toHaveBeenCalledWith("11111111-aaaa");
  });

  it("shows the empty state, an error with retry, and a clear message when the function is missing", async () => {
    const empty = await mount([]);
    expect(empty.textContent).toContain(en.Resumen.page.tabla.vacio);
    document.body.innerHTML = "";
    const missing = await mount([], { historialError: { code: "PGRST202", message: "Could not find the function public.crm_historial_operaciones" } });
    expect(missing.querySelector("[role='alert']")!.textContent).toContain("migration 351");
  });
});

describe("Operaciones CSV export", () => {
  it("pages through the filter in bounded batches and downloads a BOM-prefixed CSV named after the range", async () => {
    const created: Blob[] = [];
    const names: string[] = [];
    URL.createObjectURL = vi.fn((b: Blob) => (created.push(b), "blob:x"));
    URL.revokeObjectURL = vi.fn();
    const nativeClick = HTMLAnchorElement.prototype.click;
    HTMLAnchorElement.prototype.click = function (this: HTMLAnchorElement) {
      names.push(this.download);
    };
    try {
      const batch = (n: number) => Array.from({ length: n }, (_, i) => row({ operation_id: `op-${i}`, total: 250 }));
      const node = await mount();
      await click(node.querySelector("[data-testid='resumen-card']")!);
      rpc.mockClear();
      rpc.mockImplementation(async (name: string, args: { p_desde_fila: number; p_limite: number }) => {
        if (name !== "crm_historial_operaciones") return { data: [], error: null };
        return { data: args.p_desde_fila === 0 ? batch(200) : batch(50), error: null };
      });
      const exportBtn = buttonByText(node, "Export CSV");
      await act(async () => exportBtn.click());
      await act(async () => {});
      const calls = historialCalls();
      expect(calls.map(([, a]) => [a.p_limite, a.p_desde_fila])).toEqual([[200, 0], [200, 200]]);
      expect(calls[0]![1]).toMatchObject({ p_desde: "2026-10-29", p_hasta: "2026-10-29" });
      expect(names).toEqual(["operaciones_2026-10-29.csv"]);
      const bytes = new Uint8Array(
        await new Promise<ArrayBuffer>((resolve) => {
          const reader = new FileReader();
          reader.onload = () => resolve(reader.result as ArrayBuffer);
          reader.readAsArrayBuffer(created[0]!);
        }),
      );
      expect([...bytes.slice(0, 3)]).toEqual([0xef, 0xbb, 0xbf]);
      // header + 250 rows
      expect(new TextDecoder().decode(bytes).trim().split("\r\n")).toHaveLength(251);
    } finally {
      HTMLAnchorElement.prototype.click = nativeClick;
    }
  });
});
