// @vitest-environment jsdom
// Reset dialog (single and all): shows the amount being closed, states that
// only the counter restarts, sends the expected total, and on a 409 reloads the
// dialog with the current amount instead of resetting.

import React, { act } from "react";
import { afterEach, describe, expect, it, vi } from "vitest";
import es from "../../../messages/es.json";
import { ResellerResetDialog } from "./reseller-reset-dialog";
import { buttonByText, jsonResponse, renderWithIntl, typeInto } from "./test-helpers";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

const resetDialog = es.Resellers.resetDialog;

afterEach(() => {
  vi.unstubAllGlobals();
  document.body.replaceChildren();
});

function stubFetch(handler: (url: string, init?: RequestInit) => Promise<Response>) {
  const fetchMock = vi.fn(handler);
  vi.stubGlobal("fetch", fetchMock);
  return fetchMock;
}

function sentBody(fetchMock: ReturnType<typeof vi.fn>, index = 0): Record<string, unknown> {
  const init = fetchMock.mock.calls[index]?.[1] as RequestInit | undefined;
  return JSON.parse(String(init?.body ?? "{}")) as Record<string, unknown>;
}

describe("ResellerResetDialog", () => {
  it("single mode shows the amount being closed and the counter-only copy", async () => {
    const { text, unmount } = await renderWithIntl(
      <ResellerResetDialog open mode="single" contactId="c1" resellerName="Ana" amountGyd={15000} onClose={vi.fn()} />,
    );

    expect(text()).toContain(resetDialog.amountLabel);
    expect(text()).toContain("15,000 GYD");
    expect(text()).toContain(resetDialog.counterOnly);
    expect(text()).toContain(resetDialog.confirmSingle);
    await unmount();
  });

  it("shows the amount being closed with its deposit breakdown", async () => {
    const { text, unmount } = await renderWithIntl(
      <ResellerResetDialog
        open
        mode="single"
        contactId="c1"
        resellerName="Ana"
        amountGyd={15000}
        breakdown={{ depositsGyd: 12000, historicalOperationsGyd: 3000, adjustmentsGyd: 0 }}
        onClose={vi.fn()}
      />,
    );

    expect(text()).toContain(resetDialog.amountLabel);
    expect(text()).toContain("15,000 GYD");
    expect(text()).toContain(es.Resellers.deposits);
    expect(text()).toContain("12,000 GYD");
    expect(text()).toContain(es.Resellers.historicalOperations);
    expect(text()).toContain("3,000 GYD");
    await unmount();
  });

  it("all mode shows the grand total and, after success, the written and skipped counts", async () => {
    stubFetch(async () =>
      jsonResponse({
        batch: {
          batchId: "b1",
          resetAt: "2026-11-24T12:00:00Z",
          count: 1,
          grandTotalGyd: 27000,
          resets: [{ resetId: "r1", contactId: "c1", totalGyd: 15000 }],
        },
      }),
    );

    const { text, unmount } = await renderWithIntl(
      <ResellerResetDialog
        open
        mode="all"
        amountGyd={27000}
        resellerIds={["c1", "c2"]}
        onClose={vi.fn()}
      />,
    );
    expect(text()).toContain("27,000 GYD");

    await act(async () => {
      buttonByText(resetDialog.confirmAll).click();
      await Promise.resolve();
    });

    expect(text()).toContain(resetDialog.summaryTitle);
    expect(text()).toContain("Se cerró 1 periodo");
    expect(text()).toContain("1 revendedor sin saldo");
    await unmount();
  });

  it("sends the expected total and an optional trimmed reason", async () => {
    const fetchMock = stubFetch(async () =>
      jsonResponse({
        reset: {
          resetId: "r1",
          contactId: "c1",
          resetAt: "2026-11-24T12:00:00Z",
          closed: { operationsGyd: 15000, adjustmentsGyd: 0, totalGyd: 15000 },
        },
      }),
    );
    const onClose = vi.fn();

    const { unmount } = await renderWithIntl(
      <ResellerResetDialog open mode="single" contactId="c1" resellerName="Ana" amountGyd={15000} onClose={onClose} />,
    );
    typeInto(document.getElementById("reseller-reset-reason") as HTMLInputElement, "  cierre acordado  ");

    await act(async () => {
      buttonByText(resetDialog.confirmSingle).click();
      await Promise.resolve();
    });

    expect(fetchMock).toHaveBeenCalledWith(
      "/api/revendedores/c1/reiniciar",
      expect.objectContaining({ method: "POST" }),
    );
    expect(sentBody(fetchMock)).toEqual({ reason: "cierre acordado", expectedTotalGyd: 15000 });
    expect(onClose).toHaveBeenCalledTimes(1);
    await unmount();
  });

  it("on 409 shows the new amount, keeps the dialog open and sends the new total on the next try", async () => {
    const fetchMock = stubFetch(async () =>
      jsonResponse({ error: "Total changed", currentTotalGyd: 20000 }, 409),
    );
    const onClose = vi.fn();

    const { text, unmount } = await renderWithIntl(
      <ResellerResetDialog open mode="single" contactId="c1" resellerName="Ana" amountGyd={15000} onClose={onClose} />,
    );

    await act(async () => {
      buttonByText(resetDialog.confirmSingle).click();
      await Promise.resolve();
    });

    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(onClose).not.toHaveBeenCalled();
    expect(text()).toContain("20,000 GYD");
    expect(text()).toContain(resetDialog.conflict.replace("{amount}", "20,000 GYD"));

    await act(async () => {
      buttonByText(resetDialog.confirmSingle).click();
      await Promise.resolve();
    });
    expect(sentBody(fetchMock, 1).expectedTotalGyd).toBe(20000);
    await unmount();
  });
});
