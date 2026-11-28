// @vitest-environment jsdom
import React, { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { NextIntlClientProvider } from "next-intl";

import es from "../../../messages/es.json";

(
  globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }
).IS_REACT_ACT_ENVIRONMENT = true;

const toastMock = vi.hoisted(() => ({ success: vi.fn(), error: vi.fn() }));
vi.mock("sonner", () => ({ toast: toastMock }));

import { ClosedDaysSettings } from "./closed-days-settings";
import { resolveSection, visibleSections } from "./settings-sections";

const NOW = new Date("2026-10-22T15:00:00Z"); // Thursday 11:00 in Guyana

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

describe("ClosedDaysSettings", () => {
  let container: HTMLDivElement;
  let root: Root;
  let fetchMock: ReturnType<typeof vi.fn>;

  const INITIAL = [
    { fecha: "2026-10-10", motivo: "porque fue feriado" },
    { fecha: "2026-11-02", motivo: "porque es Diwali" },
  ];

  beforeEach(() => {
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(NOW);
    toastMock.success.mockReset();
    toastMock.error.mockReset();
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
    vi.useRealTimers();
  });

  async function mount(dias = INITIAL) {
    fetchMock.mockResolvedValueOnce(jsonResponse({ dias }));
    await act(async () => {
      root.render(
        <NextIntlClientProvider locale="es" messages={es} timeZone="America/Guyana">
          <ClosedDaysSettings />
        </NextIntlClientProvider>,
      );
    });
    await flush();
  }

  function setInput(el: HTMLInputElement, value: string) {
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!;
    act(() => {
      setter.call(el, value);
      el.dispatchEvent(new Event("input", { bubbles: true }));
    });
  }

  const dateInput = () => container.querySelector('input[type="date"]') as HTMLInputElement;
  const motivoInput = () => container.querySelector('input[type="text"]') as HTMLInputElement;
  const addButton = () =>
    Array.from(container.querySelectorAll("button")).find((b) =>
      b.textContent?.includes("Agregar"),
    ) as HTMLButtonElement;

  async function add(fecha: string, motivo: string) {
    setInput(dateInput(), fecha);
    setInput(motivoInput(), motivo);
    await act(async () => {
      addButton().click();
    });
    await flush();
  }

  function lastPutBody() {
    const call = fetchMock.mock.calls.find(([, init]) => init?.method === "PUT");
    return call ? JSON.parse(call[1].body as string) : null;
  }

  it("renders the list from GET with the date and the bot sentence", async () => {
    await mount();
    expect(fetchMock.mock.calls[0][0]).toBe("/api/dias-cerrados");
    expect(container.textContent).toContain("Lunes 2 de noviembre");
    expect(container.textContent).toContain("no estamos porque es Diwali");
    expect(container.textContent).toContain("Además de los domingos");
  });

  it("greys past days with the pasado label and keeps them removable", async () => {
    await mount();
    expect(container.textContent).toContain("pasado");
    const past = container.querySelector('[data-past="true"]');
    expect(past?.textContent).toContain("Sábado 10 de octubre");
    expect(past?.querySelector("button[aria-label]")).not.toBeNull();
  });

  it("sets the date min to today in Guyana", async () => {
    await mount();
    expect(dateInput().min).toBe("2026-10-22");
    expect(motivoInput().maxLength).toBe(120);
  });

  it("adds a day and PUTs the full sorted list", async () => {
    await mount();
    fetchMock.mockResolvedValueOnce(
      jsonResponse({
        dias: [...INITIAL, { fecha: "2026-10-30", motivo: "porque estamos de aniversario" }].sort(
          (a, b) => a.fecha.localeCompare(b.fecha),
        ),
      }),
    );
    await add("2026-10-30", "porque estamos de aniversario");
    expect(lastPutBody()).toEqual({
      dias: [
        { fecha: "2026-10-10", motivo: "porque fue feriado" },
        { fecha: "2026-10-30", motivo: "porque estamos de aniversario" },
        { fecha: "2026-11-02", motivo: "porque es Diwali" },
      ],
    });
    expect(toastMock.success).toHaveBeenCalled();
    expect(container.textContent).toContain("Viernes 30 de octubre");
  });

  it("shows an inline error for a duplicate date and does not PUT", async () => {
    await mount();
    await add("2026-11-02", "porque otra cosa");
    expect(fetchMock.mock.calls.some(([, init]) => init?.method === "PUT")).toBe(false);
    expect(container.querySelector('[role="alert"]')?.textContent).toContain("Ya hay un día cerrado");
  });

  it("rejects a past date client-side", async () => {
    await mount();
    await add("2026-10-21", "porque si");
    expect(fetchMock.mock.calls.some(([, init]) => init?.method === "PUT")).toBe(false);
    expect(container.querySelector('[role="alert"]')?.textContent).toContain("pasada");
  });

  it("removes a day by PUTting the list without it", async () => {
    await mount();
    fetchMock.mockResolvedValueOnce(jsonResponse({ dias: [INITIAL[0]] }));
    const btn = container.querySelectorAll("button[aria-label]")[1] as HTMLButtonElement;
    expect(btn.getAttribute("aria-label")).toContain("Quitar");
    await act(async () => {
      btn.click();
    });
    await flush();
    expect(lastPutBody()).toEqual({ dias: [INITIAL[0]] });
    expect(container.textContent).not.toContain("Diwali");
  });

  it("shows the server error text on a 400", async () => {
    await mount();
    fetchMock.mockResolvedValueOnce(jsonResponse({ error: "Maximo 60 dias cerrados" }, 400));
    await add("2026-10-30", "porque si");
    expect(container.querySelector('[role="alert"]')?.textContent).toContain("Maximo 60 dias cerrados");
    expect(toastMock.error).toHaveBeenCalled();
    expect(container.textContent).not.toContain("Viernes 30 de octubre");
  });
});

describe("settings sections visibility", () => {
  it("hides the admin-only section from non-admins", () => {
    expect(visibleSections(true)).toContain("closed-days");
    expect(visibleSections(false)).not.toContain("closed-days");
  });

  it("falls back to overview for a non-admin deep link", () => {
    expect(resolveSection("closed-days", true)).toBe("closed-days");
    expect(resolveSection("closed-days", false)).toBe("overview");
  });
});
