// @vitest-environment jsdom
import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { describe, expect, it, vi } from "vitest";
import es from "../../../messages/es.json";
import type { AgedOperation } from "@/lib/dashboard/types";
import { AgedOperationsQueue } from "./aged-operations-queue";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

vi.mock("next-intl", () => ({
  useTranslations: (namespace: string) => {
    const node = namespace
      .split(".")
      .reduce((acc: Record<string, unknown>, part) => acc[part] as Record<string, unknown>, es as unknown as Record<string, unknown>);
    return (key: string) => key.split(".").reduce((acc: unknown, part) => (acc as Record<string, unknown>)[part], node) as string;
  },
}));

function row(overrides: Partial<AgedOperation>): AgedOperation {
  return {
    id: "op",
    conversationId: "c1",
    contactName: "Ana",
    deliveryMethod: null,
    destinationCurrency: null,
    quotedSourceAmount: 1000,
    status: "deposit_verification",
    createdAt: new Date().toISOString(),
    ...overrides,
  };
}

async function serviceCells(rows: AgedOperation[]): Promise<string[]> {
  const node = document.createElement("div");
  const root = createRoot(node);
  await act(async () => root.render(<AgedOperationsQueue data={rows} loading={false} />));
  const cells = [...node.querySelectorAll("tbody tr")].map((r) => r.querySelectorAll("td")[1]!.textContent ?? "");
  await act(async () => root.unmount());
  return cells;
}

describe("AgedOperationsQueue service column", () => {
  it("names the delivery method with the canonical service names", async () => {
    const cells = await serviceCells([
      row({ id: "1", deliveryMethod: "cuban_card" }),
      row({ id: "2", deliveryMethod: "zelle" }),
      row({ id: "3", deliveryMethod: "efectivo_usd" }),
      row({ id: "4", deliveryMethod: "clasica" }),
      row({ id: "5", deliveryMethod: "multiple_distribution" }),
    ]);
    expect(cells).toEqual(["CUP", "Zelle", "Efectivo USD", "Clásica", "Remesa mixta"]);
  });

  it("falls back to the destination currency, then to a dash, and prints an unknown method as it is", async () => {
    const cells = await serviceCells([
      row({ id: "1", destinationCurrency: "USD" }),
      row({ id: "2" }),
      row({ id: "3", deliveryMethod: "new_rail" }),
    ]);
    expect(cells).toEqual(["USD", "—", "new_rail"]);
  });
});
