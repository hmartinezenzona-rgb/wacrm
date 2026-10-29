// @vitest-environment jsdom
// One archived week, read only (what "Ver los registros" opens in the Cierres tab).

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";

import type { CalculatorWeek } from "@/lib/calculator/weeks";
import type { ChatCalculatorEntry } from "@/lib/calculator/realtime-entry";
import { ArchivedWeekDetail } from "./archived-weeks";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

afterEach(() => document.body.replaceChildren());

const DEL_COMPLETED: ChatCalculatorEntry = {
  id: "entry-a", operationId: "op-a", source: "completed_operation", status: "completed", service: "ZELLE", customerName: "Raúl", amount: 100,
  amountCurrency: "USD", entryDate: "2026-09-12", facturadoGyd: 26000, invertidoGyd: 24000, retornoGyd: 2000, missingRates: [],
};
const MANUAL_ROW: ChatCalculatorEntry = {
  id: "man-iza", operationId: null, source: "manual", status: "completed", service: "DIRECTO", customerName: "Iza", amount: 4000,
  amountCurrency: "GYD", entryDate: "2026-10-06", facturadoGyd: 4000, invertidoGyd: 0, retornoGyd: 4000, missingRates: [],
};

const WEEK: CalculatorWeek = {
  id: "week-1", cutAt: "2026-10-03T12:00:00+00:00", periodo: "SEMANA 1",
  manualTotals: { facturadoGyd: 1000, invertidoGyd: 800, retornoGyd: 200 },
  chatTotals: { count: 1, facturadoGyd: 26000, invertidoGyd: 24000, retornoGyd: 2000 },
  rawText: "• Fran 50k CUP (235/980)",
  entries: [{ ...DEL_COMPLETED, id: "arch-1", customerName: "Archivada Ana" }],
};

async function show(week: CalculatorWeek, onClose = vi.fn()) {
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  await act(async () => root.render(<ArchivedWeekDetail week={week} onClose={onClose} />));
  return { node, root, onClose };
}

const toneOf = (row: Element, label: string) => row.querySelector(`td[data-label="${label}"]`)?.getAttribute("data-tone") ?? null;
const tones = (root: ParentNode) => [...root.querySelectorAll(".legacyTotalBox p [data-tone]")].map((el) => (el as HTMLElement).dataset.tone);

describe("ArchivedWeekDetail", () => {
  it("styles itself with the legacy calculator classes, without the full-page shell", async () => {
    const { node } = await show(WEEK);
    const shell = node.querySelector(".legacyCalc") as HTMLElement;
    expect(shell.classList.contains("legacyEmbedded")).toBe(true);
  });

  it("opens read-only: text, period, totals and the entries of that week, with no edit or delete", async () => {
    const { node } = await show(WEEK);
    const view = node.querySelector("#semanaArchivada") as HTMLElement;
    expect(view.textContent).toContain("SEMANA 1");
    expect(view.textContent).toContain("2026-10-03");
    expect(view.querySelector("pre")?.textContent).toBe("• Fran 50k CUP (235/980)");
    expect(view.textContent).toContain("Operaciones");
    expect(view.textContent).toContain("Archivada Ana");
    expect(view.textContent!.replace(/\s/g, " ")).toContain("26 000,00");
    expect(view.querySelector("textarea, input")).toBeNull();
    expect(view.querySelector("[id^=eliminarEntry], [id^=editarEntry]")).toBeNull();
  });

  it("Cerrar calls onClose", async () => {
    const { node, onClose } = await show(WEEK);
    await act(async () => { (node.querySelector("#cerrarSemana") as HTMLButtonElement).click(); });
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it("says so when the week had no operations", async () => {
    const { node } = await show({ ...WEEK, entries: [] });
    expect(node.textContent).toContain("Esta semana no tuvo operaciones.");
  });

  it("shows manual operations with the mark, read only, next to the bot's; the totals are the week's", async () => {
    const { node } = await show({ ...WEEK, manualTotals: { facturadoGyd: 4000, invertidoGyd: 0, retornoGyd: 4000 }, entries: [DEL_COMPLETED, MANUAL_ROW] });
    const rows = [...node.querySelectorAll("tbody tr")] as HTMLElement[];
    expect(rows).toHaveLength(2);
    expect(rows[1]!.querySelector('td[data-label="Tipo"]')!.textContent).toContain("Manual");
    expect(rows[0]!.querySelector('td[data-label="Tipo"]')!.textContent).not.toContain("Manual");
    expect(node.textContent!.replace(/\s/g, " ")).toContain("30 000,00");
  });

  it("applies the money tones and the service dot", async () => {
    const { node } = await show({ ...WEEK, manualTotals: { facturadoGyd: 0, invertidoGyd: 0, retornoGyd: 0 } });
    expect(tones(node)).toEqual(["in", "out", "profit"]);
    expect(node.querySelectorAll(".legacyTotalBox p")[2]!.textContent).toBe("+2 000,00");
    const row = node.querySelector("tbody tr")!;
    expect([toneOf(row, "Fact. (GYD)"), toneOf(row, "Inv. (GYD)"), toneOf(row, "Ganancia")]).toEqual(["in", "out", "profit"]);
    expect(toneOf(row, "Monto")).toBeNull();
    expect(node.querySelector('tbody td[data-label="Tipo"] [data-service]')?.getAttribute("data-service")).toBe("zelle");
  });

  it("shows no emoji", async () => {
    const { node } = await show(WEEK);
    expect(node.textContent).not.toMatch(/\p{Extended_Pictographic}/u);
  });
});
