// The Dashboard was removed (owner, 2026-10-28): no entry point or landing may still lead to it, and its
// Dashboard-only code and copy are gone. /dashboard itself only redirects to /tablero.

import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import en from "../../../messages/en.json";
import es from "../../../messages/es.json";

const root = join(__dirname, "../../..");
const read = (rel: string) => readFileSync(join(root, rel), "utf8");

describe("dashboard removal", () => {
  // The proxy keeps "/dashboard" in protectedPaths on purpose: an old bookmark goes through the login first.
  it.each(["src/app/(auth)/login/page.tsx", "src/app/join/[token]/page.tsx", "src/proxy.ts"])(
    "%s lands on /tablero, not /dashboard",
    (file) => {
      const src = read(file);
      expect(src).toMatch(/['"]\/tablero['"]/);
      expect(src).not.toMatch(/(pathname = |push\(|href = )\s*['"]\/dashboard['"]/);
    },
  );

  it("keeps /tablero behind the login in the proxy", () => {
    expect(read("src/proxy.ts")).toMatch(/protectedPaths = \[[^\]]*'\/tablero'/);
  });

  it("the sidebar and the header no longer know /dashboard", () => {
    expect(read("src/components/layout/sidebar.tsx")).not.toContain('"/dashboard"');
    expect(read("src/components/layout/header.tsx")).not.toContain('"/dashboard"');
  });

  it("drops the Dashboard-only copy", () => {
    for (const messages of [en, es] as Array<Record<string, Record<string, unknown>>>) {
      expect(messages.Dashboard).toBeUndefined();
      expect(messages.Sidebar.dashboard).toBeUndefined();
    }
  });

  it("deletes the Dashboard-only widgets and queries, keeping the shared skeleton and date helpers", () => {
    for (const gone of [
      "src/components/dashboard/aged-operations-queue.tsx",
      "src/components/dashboard/operations-funnel.tsx",
      "src/components/dashboard/response-time-chart.tsx",
      "src/lib/dashboard/queries.ts",
    ]) {
      expect(existsSync(join(root, gone))).toBe(false);
    }
    expect(existsSync(join(root, "src/components/dashboard/skeleton.tsx"))).toBe(true);
    expect(existsSync(join(root, "src/lib/dashboard/date-utils.ts"))).toBe(true);
  });
});
