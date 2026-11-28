import { describe, expect, it } from "vitest";

import {
  defaultHoraInput,
  describeReturn,
  formatHora,
  presetHastaHora,
  presetRato,
  presetRestoDelDia,
} from "./presets";

// 2026-10-22 is a Thursday. Guyana is UTC-4 all year (no DST).
const THU_11AM = new Date("2026-10-22T15:00:00Z"); // 11:00 Guyana

describe("presetRato", () => {
  it("is now plus one hour", () => {
    expect(presetRato(THU_11AM).toISOString()).toBe("2026-10-22T16:00:00.000Z");
  });
});

describe("presetHastaHora", () => {
  it("uses that time today in Guyana", () => {
    expect(presetHastaHora(THU_11AM, "15:00")?.toISOString()).toBe("2026-10-22T19:00:00.000Z");
  });

  it("moves to tomorrow when the time already passed", () => {
    expect(presetHastaHora(THU_11AM, "09:00")?.toISOString()).toBe("2026-10-23T13:00:00.000Z");
  });

  it("moves to tomorrow when the time is exactly now", () => {
    expect(presetHastaHora(THU_11AM, "11:00")?.toISOString()).toBe("2026-10-23T15:00:00.000Z");
  });

  it("uses the Guyana calendar day, not the UTC one", () => {
    // 02:00Z on the 23rd is still Thursday 22nd at 22:00 in Guyana.
    const late = new Date("2026-10-23T02:00:00Z");
    expect(presetHastaHora(late, "23:30")?.toISOString()).toBe("2026-10-23T03:30:00.000Z");
  });

  it("rejects malformed input", () => {
    expect(presetHastaHora(THU_11AM, "")).toBeNull();
    expect(presetHastaHora(THU_11AM, "25:00")).toBeNull();
    expect(presetHastaHora(THU_11AM, "10:75")).toBeNull();
    expect(presetHastaHora(THU_11AM, "abc")).toBeNull();
  });
});

describe("presetRestoDelDia", () => {
  it("is tomorrow 09:00 Guyana", () => {
    expect(presetRestoDelDia(THU_11AM).toISOString()).toBe("2026-10-23T13:00:00.000Z");
  });

  it("skips Sunday: Saturday goes to Monday 09:00", () => {
    const sat = new Date("2026-10-24T15:00:00Z");
    expect(presetRestoDelDia(sat).toISOString()).toBe("2026-10-26T13:00:00.000Z");
  });

  it("on Sunday itself, tomorrow is Monday", () => {
    const sun = new Date("2026-10-25T15:00:00Z");
    expect(presetRestoDelDia(sun).toISOString()).toBe("2026-10-26T13:00:00.000Z");
  });

  it("uses the Guyana calendar day near UTC midnight", () => {
    const late = new Date("2026-10-23T02:00:00Z"); // Thu 22nd 22:00 Guyana
    expect(presetRestoDelDia(late).toISOString()).toBe("2026-10-23T13:00:00.000Z");
  });
});

describe("formatHora", () => {
  it("formats Guyana time as h:mm am/pm", () => {
    expect(formatHora(new Date("2026-10-22T19:00:00Z"))).toBe("3:00 pm");
    expect(formatHora(new Date("2026-10-22T13:05:00Z"))).toBe("9:05 am");
    expect(formatHora(new Date("2026-10-22T04:00:00Z"))).toBe("12:00 am");
    expect(formatHora(new Date("2026-10-22T16:00:00Z"))).toBe("12:00 pm");
  });
});

describe("describeReturn", () => {
  it("same Guyana day", () => {
    expect(describeReturn(new Date("2026-10-22T19:00:00Z"), THU_11AM)).toEqual({
      day: "today",
      weekday: 4,
      time: "3:00 pm",
    });
  });

  it("next Guyana day", () => {
    expect(describeReturn(new Date("2026-10-23T13:00:00Z"), THU_11AM)).toEqual({
      day: "tomorrow",
      weekday: 5,
      time: "9:00 am",
    });
  });

  it("later days carry the weekday", () => {
    expect(describeReturn(new Date("2026-10-26T13:00:00Z"), THU_11AM)).toEqual({
      day: "other",
      weekday: 1,
      time: "9:00 am",
    });
  });
});

describe("defaultHoraInput", () => {
  it("is the next whole hour in Guyana", () => {
    expect(defaultHoraInput(new Date("2026-10-22T15:20:00Z"))).toBe("12:00");
  });

  it("wraps past midnight", () => {
    expect(defaultHoraInput(new Date("2026-10-23T03:30:00Z"))).toBe("00:00");
  });
});
