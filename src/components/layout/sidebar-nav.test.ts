// The operations board is one click away for every account member: a plain
// nav entry (no role gate, like Finanzas) after Finanzas,
// with a label in messages/en.json.

import { describe, expect, it } from "vitest";
import en from "../../../messages/en.json";
import es from "../../../messages/es.json";
import { navItems } from "./sidebar";

describe("sidebar navigation", () => {
  it("links /tablero after Finanzas, with an icon", () => {
    const hrefs = navItems.map((i) => i.href);
    const at = hrefs.indexOf("/tablero");
    expect(at).toBeGreaterThan(-1);
    expect(hrefs.indexOf("/finanzas")).toBeLessThan(at);
    expect(navItems[at].icon).toBeDefined();
  });

  // Finanzas replaces "Finanzas e historial" (/resumen) and "Control semanal" (/calculadora), which only redirect now.
  it("has exactly one Finanzas entry in the money group and no resumen or calculadora entries", () => {
    const finanzas = navItems.filter((i) => i.href === "/finanzas");
    expect(finanzas).toHaveLength(1);
    expect(finanzas[0].group).toBe("money");
    expect(finanzas[0].icon).toBeDefined();
    expect(finanzas[0].capability).toBeUndefined();
    expect(navItems.some((i) => i.href === "/resumen" || i.href === "/calculadora")).toBe(false);
    expect((es.Sidebar as Record<string, string>)[finanzas[0].labelKey]).toBe("Finanzas");
    expect((en.Sidebar as Record<string, string>)[finanzas[0].labelKey]).toBe("Finances");
    for (const messages of [es, en]) {
      expect((messages.Sidebar as Record<string, string>).resumen).toBeUndefined();
      expect((messages.Sidebar as Record<string, string>).controlSemanal).toBeUndefined();
    }
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
      "/finanzas",
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
