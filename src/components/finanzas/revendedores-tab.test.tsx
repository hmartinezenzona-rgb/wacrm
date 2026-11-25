// @vitest-environment jsdom
// Finanzas "Revendedores" tab: grand total and per-reseller totals, the empty
// state, admins-only write actions, the reset dialog amount and the detail
// drawer with the current period and history.

import React, { act } from "react";
import { afterEach, describe, expect, it, vi } from "vitest";
import es from "../../../messages/es.json";
import { RevendedoresTab } from "./revendedores-tab";
import { buttonByText, jsonResponse, renderWithIntl } from "@/components/resellers/test-helpers";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

const auth = vi.hoisted(() => ({ role: "admin" as string | null }));
vi.mock("@/hooks/use-auth", () => ({
  useAuth: () => ({ accountRole: auth.role, accountId: "account-1", profile: null }),
}));

const copy = es.Resellers;

const summary = {
  grand: { operationsGyd: 24000, adjustmentsGyd: 3000, totalGyd: 27000, resellers: 2 },
  resellers: [
    {
      contactId: "c1",
      name: "Ana",
      phone: "5551234",
      periodStart: "2026-11-21T12:00:00Z",
      operationsGyd: 12000,
      operationsCount: 2,
      operationsMissingAmount: 0,
      adjustmentsGyd: 3000,
      adjustmentsCount: 1,
      totalGyd: 15000,
    },
    {
      contactId: "c2",
      name: "Luis",
      phone: "5559876",
      periodStart: null,
      operationsGyd: 12000,
      operationsCount: 1,
      operationsMissingAmount: 0,
      adjustmentsGyd: 0,
      adjustmentsCount: 0,
      totalGyd: 12000,
    },
  ],
};

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
      operationsMissingAmount: 0,
      adjustmentsGyd: 3000,
      adjustmentsCount: 1,
      totalGyd: 15000,
      adjustments: [
        { id: "a1", amountGyd: 3000, reason: "bono", actorName: "Luis", createdAt: "2026-11-22T12:00:00Z" },
      ],
    },
    periods: [
      {
        resetId: "r1",
        start: null,
        end: "2026-11-20T12:00:00Z",
        operationsGyd: 1000,
        adjustmentsGyd: 0,
        totalGyd: 1000,
        closedTotalGyd: 1000,
        batchId: null,
        resetByName: "Luis",
        reason: null,
      },
    ],
  },
};

function stubApi(payload: unknown = summary) {
  const fetchMock = vi.fn(async (url: string) => {
    if (url === "/api/revendedores") return jsonResponse(payload);
    if (url === "/api/revendedores/c1") return jsonResponse(detail);
    throw new Error(`unexpected url ${url}`);
  });
  vi.stubGlobal("fetch", fetchMock);
  return fetchMock;
}

async function settle() {
  await act(async () => {
    await Promise.resolve();
    await Promise.resolve();
  });
}

afterEach(() => {
  vi.unstubAllGlobals();
  auth.role = "admin";
  document.body.replaceChildren();
});

describe("RevendedoresTab", () => {
  it("lists each reseller with its total and shows the grand total", async () => {
    const fetchMock = stubApi();
    const { text, unmount } = await renderWithIntl(<RevendedoresTab />);
    await settle();

    expect(fetchMock).toHaveBeenCalledWith("/api/revendedores", { cache: "no-store" });
    const body = text();
    expect(body).toContain(copy.grandTotal);
    expect(body).toContain("27,000 GYD");
    expect(body).toContain("Ana");
    expect(body).toContain("15,000 GYD");
    expect(body).toContain("Luis");
    expect(body).toContain("12,000 GYD");
    expect(body).toContain(copy.periodAllTime);
    await unmount();
  });

  it("shows the empty state when there are no resellers", async () => {
    stubApi({ grand: { operations_gyd: 0, adjustments_gyd: 0, total_gyd: 0, resellers: 0 }, resellers: [] });
    const { text, unmount } = await renderWithIntl(<RevendedoresTab />);
    await settle();

    expect(text()).toContain(copy.emptyTitle);
    expect(text()).toContain(copy.emptyHint);
    await unmount();
  });

  it("shows reset, reset all, adjust and detail to admins", async () => {
    stubApi();
    const { unmount } = await renderWithIntl(<RevendedoresTab />);
    await settle();

    expect(() => buttonByText(copy.actions.resetAll)).not.toThrow();
    expect(() => buttonByText(copy.actions.adjust)).not.toThrow();
    expect(() => buttonByText(copy.actions.reset)).not.toThrow();
    expect(() => buttonByText(copy.actions.detail)).not.toThrow();
    await unmount();
  });

  it("shows the list and totals without write actions to agents", async () => {
    auth.role = "agent";
    stubApi();
    const { text, unmount } = await renderWithIntl(<RevendedoresTab />);
    await settle();

    expect(text()).toContain("27,000 GYD");
    const labels = [...document.querySelectorAll("button")].map((b) => b.textContent?.trim());
    expect(labels).not.toContain(copy.actions.resetAll);
    expect(labels).not.toContain(copy.actions.adjust);
    expect(labels).not.toContain(copy.actions.reset);
    expect(labels).toContain(copy.actions.detail);
    await unmount();
  });

  it("opens the reset dialog with the amount being closed", async () => {
    stubApi();
    const { text, unmount } = await renderWithIntl(<RevendedoresTab />);
    await settle();

    await act(async () => {
      buttonByText(copy.actions.reset).click();
    });

    expect(text()).toContain(es.Resellers.resetDialog.amountLabel);
    expect(text()).toContain("15,000 GYD");
    await unmount();
  });

  it("opens the detail drawer with the current period, adjustments and history", async () => {
    const fetchMock = stubApi();
    const { text, unmount } = await renderWithIntl(<RevendedoresTab />);
    await settle();

    await act(async () => {
      buttonByText(copy.actions.detail).click();
      await Promise.resolve();
    });
    await settle();

    expect(fetchMock).toHaveBeenCalledWith("/api/revendedores/c1", { cache: "no-store" });
    const body = text();
    expect(body).toContain(es.Resellers.detail.current);
    expect(body).toContain(es.Resellers.history.open);
    expect(body).toContain("bono");
    expect(body).toContain("1,000 GYD");
    await unmount();
  });
});
