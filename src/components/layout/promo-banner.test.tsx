// @vitest-environment jsdom
import React, { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

(
  globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }
).IS_REACT_ACT_ENVIRONMENT = true;

const authState: { accountRole: string | null } = { accountRole: "owner" };
vi.mock("@/hooks/use-auth", () => ({ useAuth: () => authState }));
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn() } }));

import { PromoBanner } from "./promo-banner";

const PROMO = {
  id: "promo-1",
  min_cup: 500,
  max_cup: null,
  multiplicador: 5,
  precio_gyd: 100,
  vigente_desde: "2026-10-10",
  vigente_hasta: "2026-10-15",
  resumen: "x5 del 10 al 15 oct",
  hay_precio: true,
};

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

async function flush() {
  await act(async () => {
    await new Promise((r) => setTimeout(r, 0));
  });
}

describe("PromoBanner", () => {
  let container: HTMLDivElement;
  let root: Root;
  let fetchMock: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    authState.accountRole = "owner";
    container = document.createElement("div");
    document.body.appendChild(container);
    root = createRoot(container);
    fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);
  });

  afterEach(() => {
    act(() => root.unmount());
    container.remove();
    vi.unstubAllGlobals();
  });

  async function mount() {
    await act(async () => {
      root.render(<PromoBanner />);
    });
    await flush();
  }

  const button = (label: string) =>
    Array.from(container.querySelectorAll("button")).find((b) =>
      b.textContent?.includes(label),
    ) as HTMLButtonElement | undefined;

  it("renders nothing when no promo is pending", async () => {
    fetchMock.mockResolvedValue(jsonResponse({ promo: null, promos: [] }));
    await mount();
    expect(container.innerHTML).toBe("");
  });

  it("shows the summary and both actions for a pending promo", async () => {
    fetchMock.mockResolvedValue(jsonResponse({ promo: PROMO, promos: [PROMO] }));
    await mount();
    expect(container.textContent).toContain("Promoción Etecsa: x5 del 10 al 15 oct");
    expect(button("Confirmar")).toBeDefined();
    expect(button("Descartar")).toBeDefined();
  });

  it("confirm posts the action and hides the banner when nothing is left", async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse({ promo: PROMO, promos: [PROMO] }));
    await mount();
    fetchMock.mockResolvedValueOnce(
      jsonResponse({ result: "confirmada", promo: null, promos: [] }),
    );
    await act(async () => {
      button("Confirmar")!.click();
    });
    await flush();
    const [url, init] = fetchMock.mock.calls[1];
    expect(url).toBe("/api/promotions/etecsa");
    expect(init.method).toBe("POST");
    expect(JSON.parse(init.body)).toEqual({ action: "confirm", id: "promo-1" });
    expect(container.innerHTML).toBe("");
  });

  it("disables Confirmar and flags the missing price when hay_precio is false", async () => {
    const sinPrecio = { ...PROMO, hay_precio: false };
    fetchMock.mockResolvedValue(jsonResponse({ promo: sinPrecio, promos: [sinPrecio] }));
    await mount();
    expect(button("Confirmar")!.disabled).toBe(true);
    expect(button("Descartar")!.disabled).toBe(false);
    expect(container.textContent).toContain("(sin precio)");
  });

  it("refetches on a promo_etecsa notification insert, ignores other types", async () => {
    fetchMock.mockResolvedValue(jsonResponse({ promo: null, promos: [] }));
    await mount();
    expect(fetchMock).toHaveBeenCalledTimes(1);

    await act(async () => {
      window.dispatchEvent(
        new CustomEvent("wacrm:notification-insert", {
          detail: { type: "deal_incidencia" },
        }),
      );
    });
    expect(fetchMock).toHaveBeenCalledTimes(1);

    fetchMock.mockResolvedValue(jsonResponse({ promo: PROMO, promos: [PROMO] }));
    await act(async () => {
      window.dispatchEvent(
        new CustomEvent("wacrm:notification-insert", {
          detail: { type: "promo_etecsa" },
        }),
      );
    });
    await flush();
    expect(fetchMock).toHaveBeenCalledTimes(2);
    expect(container.textContent).toContain("x5 del 10 al 15 oct");
  });

  it("stays hidden for members who cannot act on it", async () => {
    authState.accountRole = "agent";
    fetchMock.mockResolvedValue(jsonResponse({ promo: PROMO, promos: [PROMO] }));
    await mount();
    expect(container.innerHTML).toBe("");
  });
});
