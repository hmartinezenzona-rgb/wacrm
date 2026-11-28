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

import { AwayBanner } from "./away-banner";
import { AWAY_NOW, AWAY_SAMPLE, AwayWrapper, jsonResponse } from "./away-test-utils";

async function flush() {
  await act(async () => {
    await new Promise((r) => setTimeout(r, 0));
  });
}

describe("AwayBanner", () => {
  let container: HTMLDivElement;
  let root: Root;
  let fetchMock: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(AWAY_NOW);
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
    vi.useRealTimers();
  });

  async function mount() {
    await act(async () => {
      root.render(
        <AwayWrapper>
          <AwayBanner />
        </AwayWrapper>,
      );
    });
    await flush();
  }

  const button = (label: string) =>
    Array.from(container.querySelectorAll("button")).find((b) =>
      b.textContent?.includes(label),
    ) as HTMLButtonElement | undefined;

  it("renders nothing without an absence", async () => {
    fetchMock.mockResolvedValue(jsonResponse({ ausencia: null }));
    await mount();
    expect(container.innerHTML).toBe("");
  });

  it("shows return time, reason and who set it", async () => {
    fetchMock.mockResolvedValue(jsonResponse({ ausencia: AWAY_SAMPLE }));
    await mount();
    const status = container.querySelector('[role="status"]');
    expect(status).not.toBeNull();
    expect(status!.textContent).toContain("Aviso activo: ausentes a las 3:00 pm");
    expect(status!.textContent).toContain("porque tuvimos que salir");
    expect(status!.textContent).toContain("lo activó Ana");
  });

  it("hides Ya volvimos from non-admins", async () => {
    authState.accountRole = "agent";
    fetchMock.mockResolvedValue(jsonResponse({ ausencia: AWAY_SAMPLE }));
    await mount();
    expect(container.textContent).toContain("Aviso activo");
    expect(button("Ya volvimos")).toBeUndefined();
  });

  it("Ya volvimos sends DELETE and hides the banner", async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse({ ausencia: AWAY_SAMPLE }));
    await mount();
    fetchMock.mockResolvedValueOnce(jsonResponse({ ausencia: null }));
    await act(async () => {
      button("Ya volvimos")!.click();
    });
    await flush();
    expect(fetchMock.mock.calls[1][0]).toBe("/api/ausencia");
    expect(fetchMock.mock.calls[1][1].method).toBe("DELETE");
    expect(container.innerHTML).toBe("");
  });
});
