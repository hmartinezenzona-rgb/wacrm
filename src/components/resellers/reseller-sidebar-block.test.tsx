// @vitest-environment jsdom
// The inbox sidebar reseller block: current total with the operations and
// adjustments split, period start, and the admin-only reset/adjust actions.

import React, { act } from "react";
import { afterEach, describe, expect, it, vi } from "vitest";
import es from "../../../messages/es.json";
import { ResellerSidebarBlock } from "./reseller-sidebar-block";
import { buttonByText, jsonResponse, renderWithIntl } from "./test-helpers";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

const auth = vi.hoisted(() => ({ role: "admin" as string | null }));
vi.mock("@/hooks/use-auth", () => ({
  useAuth: () => ({ accountRole: auth.role, accountId: "account-1", profile: null }),
}));

const copy = es.Resellers.sidebar;

const detail = {
  reseller: {
    contactId: "c1",
    name: "Ana",
    phone: "5551234",
    isReseller: true,
    current: {
      periodStart: "2026-11-21T12:00:00Z",
      operationsGyd: 12000,
      operationsCount: 2,
      operationsMissingAmount: 1,
      adjustmentsGyd: -2000,
      adjustmentsCount: 1,
      totalGyd: 10000,
      adjustments: [],
    },
    periods: [],
  },
};

function stubDetail() {
  const fetchMock = vi.fn(async () => jsonResponse(detail));
  vi.stubGlobal("fetch", fetchMock);
  return fetchMock;
}

afterEach(() => {
  vi.unstubAllGlobals();
  auth.role = "admin";
  document.body.replaceChildren();
});

async function settle() {
  await act(async () => {
    await Promise.resolve();
    await Promise.resolve();
  });
}

describe("ResellerSidebarBlock", () => {
  it("fetches and shows the current total, the split and the period start", async () => {
    const fetchMock = stubDetail();
    const { text, unmount } = await renderWithIntl(<ResellerSidebarBlock contactId="c1" />);
    await settle();

    expect(fetchMock).toHaveBeenCalledWith("/api/revendedores/c1", { cache: "no-store" });
    const body = text();
    expect(body).toContain(copy.title);
    expect(body).toContain("10,000 GYD");
    expect(body).toContain("Periodo desde");
    expect(body).toContain("12,000 GYD");
    expect(body).toContain("2,000 GYD");
    expect(body).toContain("1 operación sin monto");
    await unmount();
  });

  it("offers the detail link and the write actions to admins", async () => {
    stubDetail();
    const { unmount } = await renderWithIntl(<ResellerSidebarBlock contactId="c1" />);
    await settle();

    const link = [...document.querySelectorAll("a")].find(
      (el) => el.textContent?.trim() === copy.detail,
    );
    expect(link?.getAttribute("href")).toBe("/finanzas?tab=revendedores");
    expect(() => buttonByText(copy.adjust)).not.toThrow();
    expect(() => buttonByText(copy.reset)).not.toThrow();
    await unmount();
  });

  it("opens the reset dialog with the current total", async () => {
    stubDetail();
    const { text, unmount } = await renderWithIntl(<ResellerSidebarBlock contactId="c1" />);
    await settle();

    await act(async () => {
      buttonByText(copy.reset).click();
    });

    expect(text()).toContain(es.Resellers.resetDialog.amountLabel);
    expect(text()).toContain("10,000 GYD");
    await unmount();
  });

  it("hides the write actions from non-admins but still shows the total", async () => {
    auth.role = "agent";
    stubDetail();
    const { text, unmount } = await renderWithIntl(<ResellerSidebarBlock contactId="c1" />);
    await settle();

    expect(text()).toContain("10,000 GYD");
    expect([...document.querySelectorAll("button")].some((b) => b.textContent?.trim() === copy.adjust)).toBe(false);
    expect([...document.querySelectorAll("button")].some((b) => b.textContent?.trim() === copy.reset)).toBe(false);
    await unmount();
  });
});
