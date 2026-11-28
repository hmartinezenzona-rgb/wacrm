// @vitest-environment jsdom
// The /tablero page: loads the board with the caller's session client,
// refetches every 20 s and when the window regains focus, and shows a
// loading / error / forbidden state instead of a blank board.

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import en from "../../../../messages/en.json";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

vi.mock("next-intl", () => ({
  useTranslations: (namespace: string) => {
    const node = namespace.split(".").reduce((acc: Record<string, unknown>, part) => acc[part] as Record<string, unknown>, en as unknown as Record<string, unknown>);
    return (key: string, values?: Record<string, string | number>) => {
      const raw = key.split(".").reduce((acc: unknown, part) => (acc as Record<string, unknown>)[part], node) as string;
      return raw.replace(/\{(\w+)\}/g, (_, k) => String(values?.[k]));
    };
  },
}));

const rpc = vi.fn();
vi.mock("@/lib/supabase/client", () => ({ createClient: () => ({ rpc }) }));

const t = en.Tablero;

const row = (over: Record<string, unknown> = {}) => ({
  operation_id: "op-1", conversation_id: "conv-1", contact_name: "Ana Perez", contact_phone: "592",
  service_type: "remesa", delivery_method: "zelle", status: "incident", quoted_source_amount: 30000,
  source_currency: "GYD", created_at: "2026-10-05T10:00:00Z", completed_at: null,
  state_since: "2026-10-05T10:00:00Z", beneficiaries_complete: true, ...over,
});

beforeEach(() => vi.useFakeTimers());
const mounted: Array<{ unmount: () => void }> = [];

afterEach(async () => {
  await act(async () => mounted.splice(0).forEach((r) => r.unmount()));
  vi.useRealTimers();
  document.body.replaceChildren();
  rpc.mockReset();
});

async function mount() {
  const { default: TableroPage } = await import("./page");
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  await act(async () => root.render(<TableroPage />));
  mounted.push(root);
  return { node, root };
}

describe("TableroPage", () => {
  it("loads the board on mount and renders the cards", async () => {
    rpc.mockResolvedValue({ data: [row()], error: null });
    const { node } = await mount();
    expect(rpc).toHaveBeenCalledWith("crm_tablero_operaciones");
    expect(node.querySelector("h1")!.textContent).toBe(t.title);
    expect(node.querySelector("a")!.getAttribute("href")).toBe("/inbox");
  });

  it("refetches every 20 seconds and stops when unmounted", async () => {
    rpc.mockResolvedValue({ data: [], error: null });
    const { root } = await mount();
    expect(rpc).toHaveBeenCalledTimes(1);
    await act(async () => { await vi.advanceTimersByTimeAsync(20_000); });
    expect(rpc).toHaveBeenCalledTimes(2);
    await act(async () => { await vi.advanceTimersByTimeAsync(20_000); });
    expect(rpc).toHaveBeenCalledTimes(3);
    await act(async () => root.unmount());
    await act(async () => { await vi.advanceTimersByTimeAsync(60_000); });
    expect(rpc).toHaveBeenCalledTimes(3);
  });

  it("refetches when the window regains focus", async () => {
    rpc.mockResolvedValue({ data: [], error: null });
    await mount();
    await act(async () => { await vi.advanceTimersByTimeAsync(0); });
    await act(async () => { window.dispatchEvent(new Event("focus")); });
    expect(rpc).toHaveBeenCalledTimes(2);
  });

  it("keeps the last board on screen when a refresh fails, and says so", async () => {
    rpc.mockResolvedValueOnce({ data: [row()], error: null });
    const { node } = await mount();
    rpc.mockResolvedValueOnce({ data: null, error: { code: "XX000", message: "boom" } });
    await act(async () => { await vi.advanceTimersByTimeAsync(20_000); });
    expect(node.querySelector("a")).not.toBeNull();
    expect(node.textContent).toContain(t.loadError);
  });

  it("shows the forbidden message for a non-member", async () => {
    rpc.mockResolvedValue({ data: null, error: { code: "42501", message: "insufficient_privilege" } });
    const { node } = await mount();
    expect(node.textContent).toContain(t.forbidden);
    expect(node.textContent).not.toContain(t.loadError);
  });
});
