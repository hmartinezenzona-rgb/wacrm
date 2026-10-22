// @vitest-environment jsdom
import React, { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

(
  globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }
).IS_REACT_ACT_ENVIRONMENT = true;

const authState: { accountRole: string | null } = { accountRole: "admin" };
vi.mock("@/hooks/use-auth", () => ({ useAuth: () => authState }));
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn() } }));

// base-ui's Popover never settles in jsdom (its positioner loops on zero-size
// layout), so the primitive is swapped for a minimal controlled stand-in. The
// component under test only relies on open/onOpenChange, trigger and content.
vi.mock("@/components/ui/popover", async () => {
  const React = await import("react");
  const Ctx = React.createContext<{ open: boolean; setOpen: (o: boolean) => void }>({
    open: false,
    setOpen: () => {},
  });
  return {
    Popover: ({
      open,
      onOpenChange,
      children,
    }: {
      open: boolean;
      onOpenChange: (o: boolean) => void;
      children: React.ReactNode;
    }) => <Ctx.Provider value={{ open, setOpen: onOpenChange }}>{children}</Ctx.Provider>,
    PopoverTrigger: ({ children, ...props }: React.ComponentProps<"button">) => {
      const { open, setOpen } = React.useContext(Ctx);
      return (
        <button type="button" {...props} onClick={() => setOpen(!open)}>
          {children}
        </button>
      );
    },
    PopoverContent: ({ children }: { children: React.ReactNode }) => {
      const { open } = React.useContext(Ctx);
      return open ? <div role="dialog">{children}</div> : null;
    },
  };
});

import { AwayModeButton } from "./away-mode-button";
import { AWAY_NOW, AWAY_SAMPLE, AwayWrapper, jsonResponse } from "./away-test-utils";

const TITLE = "Avisar que no estamos";

async function flush() {
  await act(async () => {
    await new Promise((r) => setTimeout(r, 0));
  });
}

describe("AwayModeButton", () => {
  let container: HTMLDivElement;
  let root: Root;
  let fetchMock: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(AWAY_NOW);
    authState.accountRole = "admin";
    container = document.createElement("div");
    document.body.appendChild(container);
    root = createRoot(container);
    fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);
  });

  afterEach(() => {
    act(() => root.unmount());
    container.remove();
    document.body.innerHTML = "";
    vi.unstubAllGlobals();
    vi.useRealTimers();
  });

  async function mount() {
    await act(async () => {
      root.render(
        <AwayWrapper>
          <AwayModeButton />
        </AwayWrapper>,
      );
    });
    await flush();
  }

  const trigger = () => container.querySelector("button") as HTMLButtonElement;
  const bodyButton = (label: string) =>
    Array.from(document.body.querySelectorAll("button")).find((b) =>
      b.textContent?.includes(label),
    ) as HTMLButtonElement | undefined;

  async function open() {
    await act(async () => {
      trigger().click();
    });
    await flush();
  }

  it("shows Disponible when there is no absence", async () => {
    fetchMock.mockResolvedValue(jsonResponse({ ausencia: null }));
    await mount();
    expect(container.textContent).toContain("Disponible");
  });

  it("shows the return time while absent", async () => {
    fetchMock.mockResolvedValue(jsonResponse({ ausencia: AWAY_SAMPLE }));
    await mount();
    expect(container.textContent).toContain("Ausentes hasta 3:00 pm");
  });

  it("non-admins get an informational label and no popover", async () => {
    authState.accountRole = "agent";
    fetchMock.mockResolvedValue(jsonResponse({ ausencia: AWAY_SAMPLE }));
    await mount();
    expect(container.textContent).toContain("Ausentes hasta 3:00 pm");
    const clickable = container.querySelector("button");
    if (clickable) {
      await act(async () => {
        clickable.click();
      });
      await flush();
    }
    expect(document.body.textContent).not.toContain(TITLE);
    expect(container.querySelector("[title]")?.getAttribute("title")).toMatch(/administradores/i);
  });

  it("admins open the popover with presets and the default reason", async () => {
    fetchMock.mockResolvedValue(jsonResponse({ ausencia: null }));
    await mount();
    await open();
    expect(document.body.textContent).toContain(TITLE);
    expect(document.body.textContent).toContain("Un rato");
    expect(document.body.textContent).toContain("Hasta una hora");
    expect(document.body.textContent).toContain("Resto del día");
    const input = document.body.querySelector('input[type="text"]') as HTMLInputElement;
    expect(input.value).toBe("porque tuvieron que salir un momento");
    expect(document.body.textContent).toContain("Así responderá el bot");
    expect(document.body.textContent).toContain(
      "Ahora mismo los encargados no están disponibles porque tuvieron que salir un momento; regresan a las 12:00 pm.",
    );
    expect(document.body.textContent).toContain("tuvieron un asunto personal");
  });

  it("a reason chip fills the input", async () => {
    fetchMock.mockResolvedValue(jsonResponse({ ausencia: null }));
    await mount();
    await open();
    await act(async () => {
      bodyButton("es día festivo")!.click();
    });
    const input = document.body.querySelector('input[type="text"]') as HTMLInputElement;
    expect(input.value).toBe("porque es día festivo");
  });

  it("Activar aviso sends PUT with the default one-hour preset", async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse({ ausencia: null }));
    await mount();
    await open();
    fetchMock.mockResolvedValueOnce(jsonResponse({ ausencia: AWAY_SAMPLE }));
    await act(async () => {
      bodyButton("Activar aviso")!.click();
    });
    await flush();
    const [url, init] = fetchMock.mock.calls[1];
    expect(url).toBe("/api/ausencia");
    expect(init.method).toBe("PUT");
    expect(JSON.parse(init.body)).toEqual({
      hasta: "2026-10-22T16:00:00.000Z",
      motivo: "porque tuvieron que salir un momento",
    });
    expect(container.textContent).toContain("Ausentes hasta 3:00 pm");
  });

  it("with an active absence the popover offers Ya volvimos (DELETE)", async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse({ ausencia: AWAY_SAMPLE }));
    await mount();
    await open();
    fetchMock.mockResolvedValueOnce(jsonResponse({ ausencia: null }));
    await act(async () => {
      bodyButton("Ya volvimos")!.click();
    });
    await flush();
    expect(fetchMock.mock.calls[1][1].method).toBe("DELETE");
    expect(container.textContent).toContain("Disponible");
  });
});
