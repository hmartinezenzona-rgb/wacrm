import { describe, expect, it } from "vitest";
import {
  MANUAL_SERVICES,
  guyanaToday,
  manualEntriesFromText,
  parseManualLines,
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
    // 31 skips the 30-day month
    expect(resolveManualDate("31", "2026-10-02")).toBe("2026-08-31");
  });

  it("the weekday must match when given: the number alone is not enough", () => {
    // 6 October 2026 is a Tuesday; the most recent Monday that is the 6th is 6 July 2026
    expect(resolveManualDate("Lunes 6", today)).toBe("2026-07-06");
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

  it("builds one line per parsed operation with its date, position and ledger service", () => {
    const { lines, skipped } = manualEntriesFromText(text, 3, today);
    const byCustomer = Object.fromEntries(lines.map((l) => [l.customer, l]));

    expect(lines.map((l) => l.customer)).toEqual(["Gerardo", "Luis Pérez", "Ana", "Lola", "Pedro", "Mario"]);
    expect(byCustomer.Gerardo).toMatchObject({
      position: 2, date: "2026-10-06", dayLabel: "Martes 6", service: "ZELLE", amount: 100, currency: "USD",
      facturadoGyd: 26000, invertidoGyd: 24000, retornoGyd: 2000, rawLine: "• Gerardo 100 Zelle (240/260)",
    });
    expect(byCustomer["Luis Pérez"]).toMatchObject({ position: 4, service: "CUP", amount: 45000, currency: "CUP", date: "2026-10-06" });
    expect(byCustomer.Ana).toMatchObject({ position: 6, date: "2026-10-07", dayLabel: "Miércoles 7", service: "USDT", currency: "USD" });
    expect(byCustomer.Lola).toMatchObject({ service: "SALDO_MOVIL", currency: "REC" });
    expect(byCustomer.Pedro).toMatchObject({ service: "RECARGA", currency: "REC" });
    expect(byCustomer.Mario).toMatchObject({ service: "DIRECTO", currency: "GYD", amount: 20000, facturadoGyd: 20000, invertidoGyd: 0, retornoGyd: 20000 });
    // an unknown service is reported, an unparseable line is already an error line of the page
    expect(skipped.map((s) => s.raw)).toEqual(["• Raro 5 xyz"]);
  });

  it("the lines' figures add up to the page's own totals when nothing is skipped", () => {
    const clean = text.split("\n").filter((l) => !l.includes("xyz") && !l.includes("no tiene")).join("\n");
    const parsed = procesarTexto(clean, 3);
    const { lines, skipped } = manualEntriesFromText(clean, 3, today);
    expect(skipped).toEqual([]);
    expect(lines.reduce((s, l) => s + l.facturadoGyd, 0)).toBeCloseTo(parsed.totals.fact, 8);
    expect(lines.reduce((s, l) => s + l.invertidoGyd, 0)).toBeCloseTo(parsed.totals.inv, 8);
    expect(lines.reduce((s, l) => s + l.retornoGyd, 0)).toBeCloseTo(parsed.totals.ret, 8);
  });

  it("a line before any header is dated today with no day label", () => {
    const { lines } = manualEntriesFromText("• Ana 10 Zelle (1/2)", 3, today);
    expect(lines[0]).toMatchObject({ date: today, dayLabel: null, position: 1 });
  });

  it("skips a line with a non-positive amount or a negative figure", () => {
    const { lines, skipped } = manualEntriesFromText("• Ana 0 Zelle (1/2)\n• Bea 10 Zelle (-5/2)", 3, today);
    expect(lines).toEqual([]);
    expect(skipped).toHaveLength(2);
  });

  it("an empty text gives no lines", () => {
    expect(manualEntriesFromText("", 3, today)).toEqual({ lines: [], skipped: [] });
  });
});

describe("MANUAL_SERVICES", () => {
  it("is exactly the set the sync RPC accepts (migration 228)", () => {
    expect([...MANUAL_SERVICES].sort()).toEqual(
      ["CLASICA", "CUP", "DIRECTO", "MLC", "RECARGA", "SALDO_MOVIL", "TROPICAL", "USDT", "ZELLE"],
    );
  });
});

describe("parseManualLines", () => {
  const good = {
    position: 2, date: "2026-10-06", dayLabel: "Martes 6", customer: "Gerardo", service: "ZELLE", amount: 100,
    currency: "USD", facturadoGyd: 26000, invertidoGyd: 24000, retornoGyd: 2000, rawLine: "x",
  };

  it("accepts a well-formed array and maps it to the RPC shape", () => {
    const result = parseManualLines([good]);
    expect(result).toEqual({
      ok: true,
      lines: [{
        position: 2, date: "2026-10-06", day_label: "Martes 6", customer: "Gerardo", service: "ZELLE", amount: 100,
        currency: "USD", facturado_gyd: 26000, invertido_gyd: 24000, retorno_gyd: 2000, raw_line: "x",
      }],
    });
  });

  it("accepts an empty array (the week has no manual lines)", () => {
    expect(parseManualLines([])).toEqual({ ok: true, lines: [] });
  });

  it.each([
    ["not an array", { a: 1 }],
    ["a non-object line", ["x"]],
    ["a NaN figure", [{ ...good, facturadoGyd: Number.NaN }]],
    ["a string figure", [{ ...good, amount: "100" }]],
    ["an unknown service", [{ ...good, service: "SALDO MOVIL" }]],
    ["a missing customer", [{ ...good, customer: "" }]],
    ["a bad date", [{ ...good, date: "6/10/2026" }]],
    ["a fractional position", [{ ...good, position: 1.5 }]],
  ])("refuses %s", (_label, input) => {
    expect(parseManualLines(input).ok).toBe(false);
  });

  it("refuses more lines than the RPC takes", () => {
    expect(parseManualLines(Array.from({ length: 3001 }, (_, i) => ({ ...good, position: i + 1 }))).ok).toBe(false);
  });
});
