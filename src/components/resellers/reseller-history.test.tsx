// @vitest-environment jsdom
// Period history: the open period is distinguishable, closed periods are newest
// first, the confirmed snapshot shows only when it differs from the live total,
// and the actor and reason appear only when they exist.

import React from "react";
import { afterEach, describe, expect, it } from "vitest";
import es from "../../../messages/es.json";
import type { ResellerPeriod } from "@/lib/resellers/read-model";
import { ResellerHistory } from "./reseller-history";
import { renderWithIntl } from "./test-helpers";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

const copy = es.Resellers.history;

afterEach(() => {
  document.body.replaceChildren();
});

const older: ResellerPeriod = {
  resetId: "r1",
  start: null,
  end: "2026-11-10T12:00:00Z",
  operationsGyd: 1000,
  adjustmentsGyd: 0,
  totalGyd: 1000,
  closedTotalGyd: 900,
  batchId: null,
  resetByName: "Luis",
  reason: "ajuste acordado",
};

const newer: ResellerPeriod = {
  resetId: "r2",
  start: "2026-11-10T12:00:00Z",
  end: "2026-11-20T12:00:00Z",
  operationsGyd: 2000,
  adjustmentsGyd: 0,
  totalGyd: 2000,
  closedTotalGyd: 2000,
  batchId: "b1",
  resetByName: null,
  reason: null,
};

describe("ResellerHistory", () => {
  it("shows the open period first and closed periods newest first", async () => {
    const { text, unmount } = await renderWithIntl(
      <ResellerHistory
        periods={[older, newer]}
        current={{ periodStart: "2026-11-21T12:00:00Z", totalGyd: 300 }}
      />,
    );

    const body = text();
    expect(body).toContain(copy.open);
    expect(body.indexOf(copy.open)).toBeLessThan(body.indexOf("2,000 GYD"));
    expect(body.indexOf("2,000 GYD")).toBeLessThan(body.indexOf("1,000 GYD"));
    expect(body).toContain("300 GYD");
    await unmount();
  });

  it("shows the confirmed snapshot only when it differs from the live total", async () => {
    const { text, unmount } = await renderWithIntl(
      <ResellerHistory periods={[older, newer]} current={null} />,
    );

    const body = text();
    expect(body).toContain(copy.closedSnapshot.replace("{amount}", "900 GYD"));
    expect(body).not.toContain(copy.closedSnapshot.replace("{amount}", "2,000 GYD"));
    await unmount();
  });

  it("shows the actor and reason when present and an absent actor otherwise", async () => {
    const { text, unmount } = await renderWithIntl(
      <ResellerHistory periods={[older, newer]} current={null} />,
    );

    const body = text();
    expect(body).toContain(copy.by.replace("{name}", "Luis"));
    expect(body).toContain(copy.reason.replace("{reason}", "ajuste acordado"));
    expect(body).toContain(copy.unknownActor);
    expect(body.match(/Motivo:/g)).toHaveLength(1);
    await unmount();
  });

  it("shows the empty state when there is nothing to list", async () => {
    const { text, unmount } = await renderWithIntl(<ResellerHistory periods={[]} current={null} />);
    expect(text()).toContain(copy.empty);
    await unmount();
  });
});
