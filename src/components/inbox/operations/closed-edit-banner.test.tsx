// @vitest-environment jsdom
// Spec: panel-fully-editable T5. The banner shown on a closed operation
// (completed/cancelled) whose owner/admin may still correct it: the edit is
// audited, and the calculator lines and card inventories are not recomputed
// (they are edited in the calculator). Both locales are covered here; the
// card's closed+manager-only condition is covered by the card tests.

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import en from "../../../../messages/en.json";
import es from "../../../../messages/es.json";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

const state = vi.hoisted(() => ({ locale: "en" as "en" | "es" }));

vi.mock("next-intl", () => ({
  useTranslations: (namespace: string) => {
    const messages = (state.locale === "es" ? es : en) as unknown as Record<string, unknown>;
    const node = namespace
      .split(".")
      .reduce((acc: Record<string, unknown>, part) => acc[part] as Record<string, unknown>, messages);
    return (key: string) => key.split(".").reduce((acc: unknown, part) => (acc as Record<string, unknown>)[part], node) as string;
  },
}));

afterEach(() => {
  document.body.replaceChildren();
  state.locale = "en";
});

async function render() {
  const { ClosedEditBanner } = await import("./closed-edit-banner");
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  await act(async () => root.render(<ClosedEditBanner />));
  return { node, root };
}

describe("ClosedEditBanner", () => {
  it("says the edit is audited and that calculator lines and card inventories are not recalculated", async () => {
    const { node, root } = await render();
    const copy = en.Inbox.operationsPanel.closedEdit;

    expect(node.textContent).toContain(copy.title);
    expect(node.textContent).toContain(copy.body);
    expect(node.textContent).toContain("not recalculated");
    expect(node.textContent).toContain("calculator");
    await act(async () => root.unmount());
  });

  it("renders the Spanish copy when the locale is es", async () => {
    state.locale = "es";
    const { node, root } = await render();
    const copy = es.Inbox.operationsPanel.closedEdit;

    expect(node.textContent).toContain(copy.title);
    expect(node.textContent).toContain(copy.body);
    expect(node.textContent).toContain("no se recalculan");
    expect(node.textContent).toContain("calculadora");
    await act(async () => root.unmount());
  });
});
