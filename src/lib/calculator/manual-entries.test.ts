import { describe, expect, it } from "vitest";
import {
  MANUAL_SERVICES,
  guyanaToday,
  manualEntriesFromText,
  parseManualLines,
  removeRegisteredLines,
  resolveManualDate,
} from "./manual-entries";
import { procesarTexto } from "./web-calculator";

describe("guyanaToday", () => {
  it("reads the Guyana business day, not the UTC one", () => {
    // 02:30 UTC on the 8th is still 22:30 of the 7th in Guyana (UTC-4).
    expect(guyanaToday(new Date("2026-10-08T02:30:00Z"))).toBe("2026-10-07");
    expect(guyanaToday(new Date("2026-10-07T12:00:00Z"))).toBe("2026-10-07");
  });
});

describe("resolveManualDate", () => {
  const today = "2026-10-07"; // a Wednesday

  it("a weekday plus a day number resolves to the most recent matching date not after today", () => {
    expect(resolveManualDate("Martes 6", today)).toBe("2026-10-06");
    expect(resolveManualDate("Miércoles 7", today)).toBe("2026-10-07");
    expect(resolveManualDate("Lunes 5", today)).toBe("2026-10-05");
  });

  it("tolerates accents, case and bullets", () => {
    expect(resolveManualDate("MIERCOLES 7", today)).toBe("2026-10-07");
    expect(resolveManualDate("miércoles 7", today)).toBe("2026-10-07");
    expect(resolveManualDate("• Sábado 3", today)).toBe("2026-10-03");
  });

  it("a bare day number resolves to the most recent date with that number", () => {
    expect(resolveManualDate("6", today)).toBe("2026-10-06");
    expect(resolveManualDate("7", today)).toBe("2026-10-07");
  });

  it("a day number in the future of this month goes back to the previous month", () => {
    expect(resolveManualDate("30", "2026-10-02")).toBe("2026-09-30");
    expect(resolveManualDate("Miércoles 30", "2026-10-02")).toBe("2026-09-30");
  });

  // The document is a WEEKLY record: a header never dates its lines months back, where Finanzas would not show them
  // in the week being worked on.
  it("only looks two weeks back: a day number with no recent match is today", () => {
    // September has 30 days, so there is no 31st within two weeks of 2 October
    expect(resolveManualDate("31", "2026-10-02")).toBe("2026-10-02");
    // a header written ahead of time (Thursday the 8th, typed on the 7th) is today, not a Thursday 8th of last year
    expect(resolveManualDate("Jueves 8", today)).toBe("2026-10-07");
    expect(resolveManualDate("20", today)).toBe("2026-10-07");
  });

  it("a mistyped weekday does not move the day: the day number wins", () => {
    // 6 October 2026 is a Tuesday
    expect(resolveManualDate("Lunes 6", today)).toBe("2026-10-06");
    expect(resolveManualDate("Viernes 30", "2026-10-02")).toBe("2026-09-30");
  });

  it("a weekday alone resolves to the most recent such day, today included", () => {
    expect(resolveManualDate("Miércoles", today)).toBe("2026-10-07");
    expect(resolveManualDate("Martes", today)).toBe("2026-10-06");
    expect(resolveManualDate("Jueves", today)).toBe("2026-10-01");
  });

  it("an explicit day/month wins; the year is the most recent one not after today", () => {
    expect(resolveManualDate("Lunes 12/10", today)).toBe("2025-10-12");
    expect(resolveManualDate("Lunes 5/10", today)).toBe("2026-10-05");
    expect(resolveManualDate("6/10/2026", today)).toBe("2026-10-06");
    expect(resolveManualDate("martes 6 de octubre", today)).toBe("2026-10-06");
  });

  it("no header, an unknown header or an impossible date falls back to today", () => {
    expect(resolveManualDate(null, today)).toBe(today);
    expect(resolveManualDate("", today)).toBe(today);
    expect(resolveManualDate("General", today)).toBe(today);
    expect(resolveManualDate("Martes 40", today)).toBe(today);
    expect(resolveManualDate("31/02", today)).toBe(today);
  });

  it("crosses a year boundary", () => {
    expect(resolveManualDate("30", "2027-01-02")).toBe("2026-12-30");
  });
});

describe("manualEntriesFromText", () => {
  const today = "2026-10-07";
  const text = [
    "Martes 6",
    "• Gerardo 100 Zelle (240/260)",
    "esto no tiene formato",
    "• Luis Pérez 45k cup(240/1030)",
    "Miércoles 7",
    "• Ana 150 USDT (240/260)",
    "• Lola 2 Saldo movil (1/100/250)",
    "• Pedro 3 rec (1/500/250)",
    "• Mario visa 20000",
    "• Raro 5 xyz",
  ].join("\n");

  it("builds one line per parsed operation with its date, text line and ledger service", () => {
    const { lines } = manualEntriesFromText(text, 3, today);
    const byCustomer = Object.fromEntries(lines.map((l) => [l.customer, l]));

    expect(lines.map((l) => l.customer)).toEqual(["Gerardo", "Luis Pérez", "Ana", "Lola", "Pedro", "Mario"]);
    expect(byCustomer.Gerardo).toMatchObject({
      line: 2, date: "2026-10-06", dayLabel: "Martes 6", service: "ZELLE", amount: 100, currency: "USD",
      facturadoGyd: 26000, invertidoGyd: 24000, retornoGyd: 2000, rawLine: "• Gerardo 100 Zelle (240/260)",
    });
    expect(byCustomer["Luis Pérez"]).toMatchObject({ line: 4, service: "CUP", amount: 45000, currency: "CUP", date: "2026-10-06" });
    expect(byCustomer.Ana).toMatchObject({ line: 6, date: "2026-10-07", dayLabel: "Miércoles 7", service: "USDT", currency: "USD" });
    expect(byCustomer.Lola).toMatchObject({ service: "SALDO_MOVIL", currency: "REC" });
    expect(byCustomer.Pedro).toMatchObject({ service: "RECARGA", currency: "REC" });
    expect(byCustomer.Mario).toMatchObject({ service: "DIRECTO", currency: "GYD", amount: 20000, facturadoGyd: 20000, invertidoGyd: 0, retornoGyd: 20000 });
  });

  it("reports what could not be interpreted: unparseable lines and parsed ones the ledger cannot hold", () => {
    const { uninterpreted } = manualEntriesFromText(text, 3, today);
    expect(uninterpreted).toEqual([
      { line: 3, raw: "esto no tiene formato" },
      { line: 10, raw: "• Raro 5 xyz" },
    ]);
  });

  it("the lines' figures add up to the page's own totals when nothing is left out", () => {
    const clean = text.split("\n").filter((l) => !l.includes("xyz") && !l.includes("no tiene")).join("\n");
    const parsed = procesarTexto(clean, 3);
    const { lines, uninterpreted } = manualEntriesFromText(clean, 3, today);
    expect(uninterpreted).toEqual([]);
    expect(lines.reduce((s, l) => s + l.facturadoGyd, 0)).toBeCloseTo(parsed.totals.fact, 8);
    expect(lines.reduce((s, l) => s + l.invertidoGyd, 0)).toBeCloseTo(parsed.totals.inv, 8);
    expect(lines.reduce((s, l) => s + l.retornoGyd, 0)).toBeCloseTo(parsed.totals.ret, 8);
  });

  it("a line before any header is dated today with no day label", () => {
    const { lines } = manualEntriesFromText("• Ana 10 Zelle (1/2)", 3, today);
    expect(lines[0]).toMatchObject({ date: today, dayLabel: null, line: 1 });
  });

  it("leaves out a line with a non-positive amount or a negative figure", () => {
    const { lines, uninterpreted } = manualEntriesFromText("• Ana 0 Zelle (1/2)\n• Bea 10 Zelle (-5/2)", 3, today);
    expect(lines).toEqual([]);
    expect(uninterpreted.map((u) => u.line)).toEqual([1, 2]);
  });

  it("an empty text gives no lines", () => {
    expect(manualEntriesFromText("", 3, today)).toEqual({ lines: [], uninterpreted: [] });
  });
});

describe("removeRegisteredLines", () => {
  const text = [
    "Martes 6",
    "• Gerardo 100 Zelle (240/260)",
    "esto no tiene formato",
    "• Luis Pérez 45k cup(240/1030)",
    "Miércoles 7",
    "• Ana 150 USDT (240/260)",
    "• Lola 2 Saldo movil (1/100/250)",
  ].join("\n");

  it("removes the registered lines and the day headers left with nothing, keeping what could not be interpreted", () => {
    // lines 2 and 4 (Martes) and 6 and 7 (Miércoles) were registered; line 3 could not be read
    expect(removeRegisteredLines(text, [2, 4, 6, 7])).toBe("Martes 6\nesto no tiene formato");
  });

  it("keeps a day header that still has a line under it", () => {
    expect(removeRegisteredLines(text, [2, 4, 6])).toBe("Martes 6\nesto no tiene formato\nMiércoles 7\n• Lola 2 Saldo movil (1/100/250)");
  });

  it("registering everything empties the box", () => {
    const clean = "Martes 6\n• Gerardo 100 Zelle (240/260)\n\nMiércoles 7\n• Ana 150 USDT (240/260)";
    expect(removeRegisteredLines(clean, [2, 5])).toBe("");
  });

  it("registering nothing leaves the text exactly as it was", () => {
    expect(removeRegisteredLines(text, [])).toBe(text);
  });

  it("a header typed with no line under it yet stays", () => {
    expect(removeRegisteredLines("Martes 6\n• Ana 10 Zelle (1/2)\nMiércoles 7", [2])).toBe("Miércoles 7");
  });

  it("a line before any header is removed alone", () => {
    expect(removeRegisteredLines("• Ana 10 Zelle (1/2)\n• Bea 10 Zelle (1/2)", [1])).toBe("• Bea 10 Zelle (1/2)");
  });
});

describe("MANUAL_SERVICES", () => {
  it("is exactly the set the add RPC accepts (migration 228)", () => {
    expect([...MANUAL_SERVICES].sort()).toEqual(
      ["CLASICA", "CUP", "DIRECTO", "MLC", "RECARGA", "SALDO_MOVIL", "TROPICAL", "USDT", "ZELLE"],
    );
  });
});

describe("parseManualLines", () => {
  const good = {
    date: "2026-10-06", dayLabel: "Martes 6", customer: "Gerardo", service: "ZELLE", amount: 100,
    currency: "USD", facturadoGyd: 26000, invertidoGyd: 24000, retornoGyd: 2000, rawLine: "x",
  };

  it("accepts a well-formed array and maps it to the RPC shape", () => {
    const result = parseManualLines([good]);
    expect(result).toEqual({
      ok: true,
      lines: [{
        date: "2026-10-06", day_label: "Martes 6", customer: "Gerardo", service: "ZELLE", amount: 100,
        currency: "USD", facturado_gyd: 26000, invertido_gyd: 24000, retorno_gyd: 2000, raw_line: "x",
      }],
    });
  });

  it("refuses an empty array: there is nothing to register", () => {
    expect(parseManualLines([]).ok).toBe(false);
  });

  it.each([
    ["not an array", { a: 1 }],
    ["a non-object line", ["x"]],
    ["a NaN figure", [{ ...good, facturadoGyd: Number.NaN }]],
    ["a string figure", [{ ...good, amount: "100" }]],
    ["a non-positive amount", [{ ...good, amount: 0 }]],
    ["a negative facturado", [{ ...good, facturadoGyd: -1 }]],
    ["a negative invertido", [{ ...good, invertidoGyd: -1 }]],
    ["an unknown service", [{ ...good, service: "SALDO MOVIL" }]],
    ["a missing customer", [{ ...good, customer: "" }]],
    ["a bad date", [{ ...good, date: "6/10/2026" }]],
  ])("refuses %s", (_label, input) => {
    expect(parseManualLines(input).ok).toBe(false);
  });

  it("refuses more lines than the RPC takes", () => {
    expect(parseManualLines(Array.from({ length: 501 }, () => good)).ok).toBe(false);
    expect(parseManualLines(Array.from({ length: 500 }, () => good)).ok).toBe(true);
  });
});
