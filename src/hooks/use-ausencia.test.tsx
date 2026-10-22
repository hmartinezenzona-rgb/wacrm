// @vitest-environment jsdom
import React, { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { NextIntlClientProvider } from "next-intl";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import es from "../../messages/es.json";

(
  globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }
).IS_REACT_ACT_ENVIRONMENT = true;

const toastError = vi.fn();
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: (m: string) => toastError(m) } }));

import { useAusencia } from "./use-ausencia";

const NOW = new Date("2026-10-22T15:00:00Z");
const AUS = {
  motivo: "porque tuvimos que salir",
  hasta: "2026-10-22T19:00:00.000Z",
  hasta_texto: "a las 3:00 pm",
  por: "Ana",
};

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

let api: ReturnType<typeof useAusencia>;
function Probe() {
  api = useAusencia();
  return null;
}

describe("useAusencia", () => {
  let container: HTMLDivElement;
  let root: Root;
  let fetchMock: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout", "setInterval", "clearInterval", "Date"] });
    vi.setSystemTime(NOW);
    container = document.createElement("div");
    document.body.appendChild(container);
    root = createRoot(container);
    fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);
    toastError.mockClear();
  });

  afterEach(() => {
    act(() => root.unmount());
    container.remove();
    vi.unstubAllGlobals();
    vi.useRealTimers();
  });

  async function mount() {
    await act(async () => {
      root.render(
        <NextIntlClientProvider locale="es" messages={es} timeZone="America/Guyana">
          <Probe />
        </NextIntlClientProvider>,
      );
    });
  }

  it("loads on mount with no-store and exposes the absence", async () => {
    fetchMock.mockResolvedValue(jsonResponse({ ausencia: AUS }));
    await mount();
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(fetchMock.mock.calls[0][0]).toBe("/api/ausencia");
    expect(fetchMock.mock.calls[0][1]).toMatchObject({ cache: "no-store" });
    expect(api.ausencia).toEqual(AUS);
    expect(api.loading).toBe(false);
  });

  it("refetches every 60 seconds and on window focus", async () => {
    fetchMock.mockResolvedValue(jsonResponse({ ausencia: null }));
    await mount();
    await act(async () => {
      await vi.advanceTimersByTimeAsync(60_000);
    });
    expect(fetchMock).toHaveBeenCalledTimes(2);
    await act(async () => {
      window.dispatchEvent(new Event("focus"));
    });
    expect(fetchMock).toHaveBeenCalledTimes(3);
  });

  it("treats the absence as null locally once hasta passes", async () => {
    fetchMock.mockResolvedValue(jsonResponse({ ausencia: { ...AUS, hasta: "2026-10-22T15:00:30.000Z" } }));
    await mount();
    expect(api.ausencia).not.toBeNull();
    // Stub keeps returning it; the expiry timer must hide it without a fetch.
    fetchMock.mockClear();
    await act(async () => {
      vi.setSystemTime(new Date("2026-10-22T15:00:31Z"));
      await vi.advanceTimersByTimeAsync(31_000 - 1);
    });
    expect(api.ausencia).toBeNull();
  });

  it("an already expired absence from the server is null", async () => {
    fetchMock.mockResolvedValue(jsonResponse({ ausencia: { ...AUS, hasta: "2026-10-22T14:00:00.000Z" } }));
    await mount();
    expect(api.ausencia).toBeNull();
  });

  it("set sends PUT with hasta and motivo and stores the response", async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse({ ausencia: null }));
    await mount();
    fetchMock.mockResolvedValueOnce(jsonResponse({ ausencia: AUS }));
    let ok = false;
    await act(async () => {
      ok = await api.set(new Date("2026-10-22T19:00:00Z"), "porque tuvimos que salir");
    });
    const [url, init] = fetchMock.mock.calls[1];
    expect(url).toBe("/api/ausencia");
    expect(init.method).toBe("PUT");
    expect(JSON.parse(init.body)).toEqual({
      hasta: "2026-10-22T19:00:00.000Z",
      motivo: "porque tuvimos que salir",
    });
    expect(ok).toBe(true);
    expect(api.ausencia).toEqual(AUS);
  });

  it("set shows the server error text on a 400", async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse({ ausencia: null }));
    await mount();
    fetchMock.mockResolvedValueOnce(jsonResponse({ error: "La hora debe ser futura" }, 400));
    let ok = true;
    await act(async () => {
      ok = await api.set(new Date("2026-10-22T19:00:00Z"), "x");
    });
    expect(ok).toBe(false);
    expect(toastError).toHaveBeenCalledWith("La hora debe ser futura");
  });

  it("set shows a generic message on other failures", async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse({ ausencia: null }));
    await mount();
    fetchMock.mockResolvedValueOnce(jsonResponse({ error: "boom" }, 500));
    await act(async () => {
      await api.set(new Date("2026-10-22T19:00:00Z"), "x");
    });
    expect(toastError).toHaveBeenCalledWith(es.AwayMode.errors.save);
  });

  it("clear sends DELETE and empties the state", async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse({ ausencia: AUS }));
    await mount();
    fetchMock.mockResolvedValueOnce(jsonResponse({ ausencia: null }));
    await act(async () => {
      await api.clear();
    });
    expect(fetchMock.mock.calls[1][1].method).toBe("DELETE");
    expect(api.ausencia).toBeNull();
  });

  it("a failed load keeps the previous state and does not toast", async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse({ ausencia: AUS }));
    await mount();
    fetchMock.mockRejectedValueOnce(new Error("offline"));
    await act(async () => {
      await api.refresh();
    });
    expect(api.ausencia).toEqual(AUS);
    expect(toastError).not.toHaveBeenCalled();
  });
});
