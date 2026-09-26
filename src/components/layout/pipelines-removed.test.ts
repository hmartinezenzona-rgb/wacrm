// Slice 11 (port-chat-operations-calculator), task 11.4 — the pipeline
// UI (kanban board and its navigation entry) MUST NOT be reachable after
// the cutover (spec: remesa-operation-source-of-truth, "Pipeline UI
// Removed").
//
// Source-level guard, same trade-off as
// src/lib/pipelines/notes-untouched.test.ts: vitest runs with
// `environment: "node"`, there is no route-reachability harness in this
// repo, and Next.js App Router routes are not unit-renderable without
// one. So this asserts on the two things that make a route reachable —
// the route file existing at all, and a nav/quick-action entry pointing
// at it — rather than on rendered output.

import { describe, it, expect } from "vitest";
import { existsSync } from "node:fs";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const root = process.cwd();

describe("pipeline UI removal (slice 11 cutover)", () => {
  it("has no /pipelines route file left in the app router", () => {
    const routeFile = join(root, "src/app/(dashboard)/pipelines/page.tsx");
    expect(
      existsSync(routeFile),
      "src/app/(dashboard)/pipelines/page.tsx still exists — the pipeline route is still reachable",
    ).toBe(false);
  });

  it("has no page-only pipeline board/settings/analytics/deal-form components left", () => {
    for (const file of [
      "src/components/pipelines/pipeline-board.tsx",
      "src/components/pipelines/pipeline-settings.tsx",
      "src/components/pipelines/pipeline-analytics.tsx",
      "src/components/pipelines/deal-form.tsx",
      "src/components/pipelines/deal-card.tsx",
    ]) {
      expect(existsSync(join(root, file)), `${file} still exists`).toBe(false);
    }
  });

  it("keeps delivery-proof.tsx — it is still shared with the operations panel", () => {
    // Regression guard for the deletion itself: a future cleanup pass
    // must not sweep this file away along with the page-only ones above.
    // src/components/inbox/operations/complete-transfer-section.tsx
    // imports DeliveryProofPanel from here.
    expect(
      existsSync(join(root, "src/components/pipelines/delivery-proof.tsx")),
      "delivery-proof.tsx was removed, but it is still used by the operations panel",
    ).toBe(true);
  });

  it("the sidebar carries no /pipelines nav entry", () => {
    const sidebar = readFileSync(
      join(root, "src/components/layout/sidebar.tsx"),
      "utf8",
    );
    expect(sidebar).not.toContain('href: "/pipelines"');
  });

  it("the dashboard carries no /pipelines shortcut (quick actions were removed)", () => {
    // The quick-actions strip (new contact / broadcast / automation) was
    // dropped from the dashboard on 2026-09-25; nothing on it may link
    // to the pipeline board either.
    expect(existsSync(join(root, "src/components/dashboard/quick-actions.tsx"))).toBe(false);
    const dashboard = readFileSync(
      join(root, "src/app/(dashboard)/dashboard/page.tsx"),
      "utf8",
    );
    expect(dashboard).not.toContain("/pipelines");
  });

  it("the header's page-title map carries no /pipelines entry", () => {
    const header = readFileSync(
      join(root, "src/components/layout/header.tsx"),
      "utf8",
    );
    expect(header).not.toContain('"/pipelines"');
  });
});
