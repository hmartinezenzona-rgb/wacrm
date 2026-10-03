// @vitest-environment jsdom
// Spec: chat-remesa-operations-panel ("Resolver State Handling" —
// "Ambiguous state surfaces explicitly"). This banner is the panel's only
// signal for the `ambigua` resolver state; it must never pick a winner.

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import en from "../../../../messages/en.json";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

// Mocks next-intl against the REAL messages/en.json so assertions check
// actual user-visible copy, not translation keys. `{param}` interpolation
// mirrors next-intl's own ICU-lite substitution for the one param this
// namespace uses.
vi.mock("next-intl", () => ({
  useTranslations: (namespace: string) => {
    const node = namespace.split(".").reduce((acc: Record<string, unknown>, part) => acc[part] as Record<string, unknown>, en as unknown as Record<string, unknown>);
    return (key: string, params?: Record<string, unknown>) => {
      const raw = key.split(".").reduce((acc: unknown, part) => (acc as Record<string, unknown>)[part], node) as string;
      if (!params) return raw;
      return Object.entries(params).reduce((acc, [k, v]) => acc.replace(`{${k}}`, String(v)), raw);
    };
  },
}));

afterEach(() => {
  document.body.replaceChildren();
  vi.restoreAllMocks();
});

describe("ResolverStateBanner (compact badge, owner 2026-10-03: the old block took room and looked heavy)", () => {
  async function renderBadge(count: number) {
    const { ResolverStateBanner } = await import("./resolver-state-banner");
    const node = document.createElement("div");
    document.body.appendChild(node);
    const root = createRoot(node);
    await act(async () => root.render(<ResolverStateBanner candidateCount={count} />));
    return { node, root };
  }

  it("shows only a short count, with the full explanation as its tooltip", async () => {
    const { node, root } = await renderBadge(4);

    expect(node.textContent).toBe("4 open");
    const badge = node.querySelector('[role="status"]');
    expect(badge?.getAttribute("title")).toBe(
      "4 open operations for this conversation — resolve which one before acting.",
    );
    expect(badge?.getAttribute("aria-label")).toBe(badge?.getAttribute("title"));
    await act(async () => root.unmount());
  });

  it("substitutes a different candidate count (triangulation)", async () => {
    const { node, root } = await renderBadge(2);

    expect(node.textContent).toBe("2 open");
    await act(async () => root.unmount());
  });
});
