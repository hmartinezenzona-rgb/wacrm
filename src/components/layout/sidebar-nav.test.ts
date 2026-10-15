// The operations board is one click away for every account member: a plain
// nav entry (no role gate, like Resumen) next to Resumen and Calculadora,
// with a label in messages/en.json.

import { describe, expect, it } from "vitest";
import en from "../../../messages/en.json";
import es from "../../../messages/es.json";
import { navItems } from "./sidebar";

describe("sidebar navigation", () => {
  it("links /tablero right after Resumen and Control Semanal, with an icon", () => {
    const hrefs = navItems.map((i) => i.href);
    const at = hrefs.indexOf("/tablero");
    expect(at).toBeGreaterThan(-1);
    expect(hrefs.indexOf("/resumen")).toBeLessThan(at);
    expect(hrefs.indexOf("/calculadora")).toBeLessThan(at);
    expect(navItems[at].icon).toBeDefined();
  });

  it("has an English label and no role gate", () => {
    const item = navItems.find((i) => i.href === "/tablero")!;
    expect((en.Sidebar as Record<string, string>)[item.labelKey]).toBe("Operations board");
    expect(Object.keys(item).sort()).toEqual(["href", "icon", "labelKey"]);
  });

  it("links the CUP inventory for owner/admin only, with es and en labels", () => {
    const item = navItems.find((i) => i.href === "/inventario-cup")!;
    expect(item).toBeDefined();
    expect(item.capability).toBe("manage-cup-inventory");
    expect(item.icon).toBeDefined();
    expect((es.Sidebar as Record<string, string>)[item.labelKey]).toBe("Inventario CUP");
    expect((en.Sidebar as Record<string, string>)[item.labelKey]).toBe("CUP inventory");
  });
});
