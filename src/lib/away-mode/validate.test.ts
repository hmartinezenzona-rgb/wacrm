import { describe, expect, it } from "vitest";

import {
  parseDiasCerrados,
  validateAusenciaInput,
  validateDiasCerrados,
} from "./validate";

const NOW = new Date("2026-10-21T12:00:00.000Z");
const HOUR = 3600_000;

describe("validateAusenciaInput", () => {
  it("accepts a future hasta and trims motivo, normalizing hasta to UTC ISO", () => {
    const r = validateAusenciaInput(
      { hasta: "2026-10-21T15:00:00-04:00", motivo: "  porque salimos  " },
      NOW,
    );
    expect(r).toEqual({ ok: true, hasta: "2026-10-21T19:00:00.000Z", motivo: "porque salimos" });
  });

  it("rejects non-object bodies", () => {
    expect(validateAusenciaInput(null, NOW).ok).toBe(false);
    expect(validateAusenciaInput("x", NOW).ok).toBe(false);
  });

  it("rejects garbage or non-string hasta", () => {
    expect(validateAusenciaInput({ hasta: "mañana", motivo: "x" }, NOW).ok).toBe(false);
    expect(validateAusenciaInput({ hasta: 123, motivo: "x" }, NOW).ok).toBe(false);
    expect(validateAusenciaInput({ motivo: "x" }, NOW).ok).toBe(false);
  });

  it("rejects hasta in the past or less than one minute ahead", () => {
    const past = new Date(NOW.getTime() - HOUR).toISOString();
    const soon = new Date(NOW.getTime() + 30_000).toISOString();
    expect(validateAusenciaInput({ hasta: past, motivo: "x" }, NOW).ok).toBe(false);
    expect(validateAusenciaInput({ hasta: soon, motivo: "x" }, NOW).ok).toBe(false);
  });

  it("rejects hasta more than 7 days ahead but accepts exactly 7 days", () => {
    const over = new Date(NOW.getTime() + 7 * 24 * HOUR + 1000).toISOString();
    const edge = new Date(NOW.getTime() + 7 * 24 * HOUR).toISOString();
    expect(validateAusenciaInput({ hasta: over, motivo: "x" }, NOW).ok).toBe(false);
    expect(validateAusenciaInput({ hasta: edge, motivo: "x" }, NOW).ok).toBe(true);
  });

  it("rejects empty, blank, non-string or over-120 motivo", () => {
    const hasta = new Date(NOW.getTime() + HOUR).toISOString();
    expect(validateAusenciaInput({ hasta, motivo: "" }, NOW).ok).toBe(false);
    expect(validateAusenciaInput({ hasta, motivo: "   " }, NOW).ok).toBe(false);
    expect(validateAusenciaInput({ hasta, motivo: 5 }, NOW).ok).toBe(false);
    expect(validateAusenciaInput({ hasta, motivo: "a".repeat(121) }, NOW).ok).toBe(false);
    expect(validateAusenciaInput({ hasta, motivo: "a".repeat(120) }, NOW).ok).toBe(true);
  });
});

describe("validateDiasCerrados", () => {
  it("accepts, trims motivo and sorts ascending by fecha", () => {
    const r = validateDiasCerrados({
      dias: [
        { fecha: "2026-12-25", motivo: " porque es Navidad " },
        { fecha: "2026-10-05", motivo: "porque es nuestro aniversario" },
      ],
    });
    expect(r).toEqual({
      ok: true,
      dias: [
        { fecha: "2026-10-05", motivo: "porque es nuestro aniversario" },
        { fecha: "2026-12-25", motivo: "porque es Navidad" },
      ],
    });
  });

  it("accepts an empty list", () => {
    expect(validateDiasCerrados({ dias: [] })).toEqual({ ok: true, dias: [] });
  });

  it("rejects bodies without a dias array", () => {
    expect(validateDiasCerrados(null).ok).toBe(false);
    expect(validateDiasCerrados({}).ok).toBe(false);
    expect(validateDiasCerrados({ dias: "x" }).ok).toBe(false);
  });

  it("rejects impossible or malformed dates", () => {
    expect(validateDiasCerrados({ dias: [{ fecha: "2026-02-30", motivo: "x" }] }).ok).toBe(false);
    expect(validateDiasCerrados({ dias: [{ fecha: "2026-2-3", motivo: "x" }] }).ok).toBe(false);
    expect(validateDiasCerrados({ dias: [{ fecha: "2026-10-05T00:00:00Z", motivo: "x" }] }).ok).toBe(false);
    expect(validateDiasCerrados({ dias: [{ motivo: "x" }] }).ok).toBe(false);
  });

  it("accepts a real leap day", () => {
    expect(validateDiasCerrados({ dias: [{ fecha: "2028-02-29", motivo: "x" }] }).ok).toBe(true);
  });

  it("rejects duplicate dates", () => {
    const r = validateDiasCerrados({
      dias: [{ fecha: "2026-10-05", motivo: "a" }, { fecha: "2026-10-05", motivo: "b" }],
    });
    expect(r.ok).toBe(false);
  });

  it("rejects empty or over-120 motivo", () => {
    expect(validateDiasCerrados({ dias: [{ fecha: "2026-10-05", motivo: " " }] }).ok).toBe(false);
    expect(validateDiasCerrados({ dias: [{ fecha: "2026-10-05", motivo: "a".repeat(121) }] }).ok).toBe(false);
  });

  it("allows 60 entries and rejects 61", () => {
    const make = (n: number) =>
      Array.from({ length: n }, (_, i) => {
        const d = new Date(Date.UTC(2027, 0, 1 + i));
        return { fecha: d.toISOString().slice(0, 10), motivo: "x" };
      });
    expect(validateDiasCerrados({ dias: make(60) }).ok).toBe(true);
    expect(validateDiasCerrados({ dias: make(61) }).ok).toBe(false);
  });
});

describe("parseDiasCerrados", () => {
  it("returns [] for empty, null or broken JSON", () => {
    expect(parseDiasCerrados(null)).toEqual([]);
    expect(parseDiasCerrados("")).toEqual([]);
    expect(parseDiasCerrados("{not json")).toEqual([]);
    expect(parseDiasCerrados('{"a":1}')).toEqual([]);
  });

  it("drops malformed entries, keeps valid ones sorted ascending", () => {
    const raw = JSON.stringify([
      { fecha: "2026-12-25", motivo: "porque es Navidad" },
      { fecha: "basura", motivo: "x" },
      { fecha: "2026-10-05", motivo: "porque aniversario" },
      42,
    ]);
    expect(parseDiasCerrados(raw)).toEqual([
      { fecha: "2026-10-05", motivo: "porque aniversario" },
      { fecha: "2026-12-25", motivo: "porque es Navidad" },
    ]);
  });
});
