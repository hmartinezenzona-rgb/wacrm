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
    expect(item.capability).toBeUndefined();
  });

  it("groups every row under Operación, Dinero or Herramientas", () => {
    for (const item of navItems) {
      expect(["operation", "money", "tools"]).toContain(item.group);
    }
    // The rows keep their order inside their group.
    const byGroup = (group: string) =>
      navItems.filter((i) => i.group === group).map((i) => i.href);
    expect(byGroup("operation")).toEqual([
      "/inbox",
      "/notifications",
      "/contacts",
    ]);
    expect(byGroup("money")).toEqual([
      "/resumen",
      "/calculadora",
      "/inventario-cup",
      "/tablero",
    ]);
    expect(byGroup("tools")).toEqual([
      "/broadcasts",
      "/automations",
      "/flows",
      "/agents",
    ]);
    expect((es.Sidebar as Record<string, string>).groupOperation).toBe("Operación");
    expect((es.Sidebar as Record<string, string>).groupMoney).toBe("Dinero");
    expect((es.Sidebar as Record<string, string>).groupTools).toBe("Herramientas");
    expect((en.Sidebar as Record<string, string>).groupOperation).toBe("Operations");
    expect((en.Sidebar as Record<string, string>).groupMoney).toBe("Money");
    expect((en.Sidebar as Record<string, string>).groupTools).toBe("Tools");
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
