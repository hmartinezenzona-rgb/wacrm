// @vitest-environment jsdom
// Adjustment dialog: signed non-zero amount, optional reason, live preview of
// the resulting total, and a POST shaped exactly like the API expects.

import React, { act } from "react";
import { afterEach, describe, expect, it, vi } from "vitest";
import es from "../../../messages/es.json";
import { ResellerAdjustDialog } from "./reseller-adjust-dialog";
import { buttonByText, inputById, jsonResponse, renderWithIntl, typeInto } from "./test-helpers";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

const copy = es.Resellers.adjustDialog;

afterEach(() => {
  vi.unstubAllGlobals();
  document.body.replaceChildren();
});

describe("ResellerAdjustDialog", () => {
  it("previews the new total and submits a signed amount with an optional reason", async () => {
    const fetchMock = vi.fn<(url: string, init?: RequestInit) => Promise<Response>>(async () =>
      jsonResponse({
        adjustment: {
          adjustmentId: "a1",
          contactId: "c1",
          amountGyd: -250,
          createdAt: "2026-11-24T12:00:00Z",
          totalBeforeGyd: 1000,
          totalAfterGyd: 750,
        },
      }),
    );
    vi.stubGlobal("fetch", fetchMock);
    const onSaved = vi.fn();
    const onClose = vi.fn();

    const { text, unmount } = await renderWithIntl(
      <ResellerAdjustDialog open contactId="c1" resellerName="Ana" currentTotalGyd={1000} onClose={onClose} onSaved={onSaved} />,
    );

    typeInto(inputById("reseller-adjust-amount"), "-250");
    typeInto(inputById("reseller-adjust-reason"), "  corrección  ");

    expect(text()).toContain(copy.preview);
    expect(text()).toContain("750 GYD");

    await act(async () => {
      buttonByText(copy.submit).click();
      await Promise.resolve();
    });

    expect(fetchMock).toHaveBeenCalledWith(
      "/api/revendedores/c1/ajustes",
      expect.objectContaining({ method: "POST" }),
    );
    const init = fetchMock.mock.calls[0]?.[1] as RequestInit;
    expect(JSON.parse(String(init.body))).toEqual({ amountGyd: -250, reason: "corrección" });
    expect(onSaved).toHaveBeenCalledWith(750);
    expect(onClose).toHaveBeenCalledTimes(1);
    await unmount();
  });

  it("rejects a zero amount without calling the API", async () => {
    const fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);

    const { text, unmount } = await renderWithIntl(
      <ResellerAdjustDialog open contactId="c1" resellerName="Ana" currentTotalGyd={1000} onClose={vi.fn()} />,
    );

    typeInto(inputById("reseller-adjust-amount"), "0");
    expect(text()).toContain(copy.invalidAmount);
    expect(buttonByText(copy.submit).disabled).toBe(true);

    await act(async () => {
      buttonByText(copy.submit).click();
      await Promise.resolve();
    });
    expect(fetchMock).not.toHaveBeenCalled();
    await unmount();
  });

  it("sends a null reason when the field is left empty", async () => {
    const fetchMock = vi.fn<(url: string, init?: RequestInit) => Promise<Response>>(async () =>
      jsonResponse({
        adjustment: {
          adjustmentId: "a1",
          contactId: "c1",
          amountGyd: 500,
          createdAt: "2026-11-24T12:00:00Z",
          totalBeforeGyd: 1000,
          totalAfterGyd: 1500,
        },
      }),
    );
    vi.stubGlobal("fetch", fetchMock);

    const { unmount } = await renderWithIntl(
      <ResellerAdjustDialog open contactId="c1" resellerName="Ana" currentTotalGyd={1000} onClose={vi.fn()} />,
    );
    typeInto(inputById("reseller-adjust-amount"), "500");

    await act(async () => {
      buttonByText(copy.submit).click();
      await Promise.resolve();
    });

    const init = fetchMock.mock.calls[0]?.[1] as RequestInit;
    expect(JSON.parse(String(init.body))).toEqual({ amountGyd: 500, reason: null });
    await unmount();
  });
});
