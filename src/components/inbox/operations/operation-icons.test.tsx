// @vitest-environment jsdom
// Spec: chat-remesa-operations-panel icon helpers — pure method-kind
// classification plus the two presentational icon components used by the
// operation card (method badges and status chips).

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it } from "vitest";
import { KNOWN_BENEFICIARY_TYPES, MethodIcon, StatusChip, methodKind } from "./operation-icons";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

afterEach(() => {
  document.body.replaceChildren();
});

async function renderNode(element: React.ReactElement) {
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  await act(async () => root.render(element));
  return { node, root };
}

describe("methodKind", () => {
  it("classifies cuban_card", () => {
    expect(methodKind("cuban_card")).toBe("cuban_card");
  });

  it("classifies zelle", () => {
    expect(methodKind("zelle")).toBe("zelle");
  });

  it("classifies clasica as cash", () => {
    expect(methodKind("clasica")).toBe("cash");
  });

  it("classifies tropical as cash", () => {
    expect(methodKind("tropical")).toBe("cash");
  });

  it("classifies multiple_distribution as multiple", () => {
    expect(methodKind("multiple_distribution")).toBe("multiple");
  });

  it("classifies mmg as mobile_money", () => {
    expect(methodKind("mmg")).toBe("mobile_money");
  });

  it("classifies null as unknown", () => {
    expect(methodKind(null)).toBe("unknown");
  });

  it("classifies an unrecognized value as unknown", () => {
    expect(methodKind("foo")).toBe("unknown");
  });
});

describe("MethodIcon", () => {
  it("renders the Z letter for zelle", async () => {
    const { node, root } = await renderNode(<MethodIcon method="zelle" label="Zelle" />);

    const el = node.querySelector('[aria-label="Zelle"]');
    expect(el).not.toBeNull();
    expect(el!.textContent).toBe("Z");
    await act(async () => root.unmount());
  });

  it("renders a lucide icon for cuban_card", async () => {
    const { node, root } = await renderNode(<MethodIcon method="cuban_card" label="Cuban card" />);

    const el = node.querySelector('[aria-label="Cuban card"]');
    expect(el).not.toBeNull();
    expect(el!.querySelector("svg")).not.toBeNull();
    await act(async () => root.unmount());
  });
});

describe("StatusChip", () => {
  it("renders the label with a status dot inside a soft pill (no border)", async () => {
    const { node, root } = await renderNode(<StatusChip status="incident" label="Incident" />);

    expect(node.textContent).toBe("Incident");
    const chip = node.firstElementChild as HTMLElement;
    expect(chip.className).not.toContain("border");
    expect(chip.className).toContain("rounded-full");
    expect(chip.className).toContain("px-2");
    expect(chip.querySelector("svg")).toBeNull();
    const dot = chip.firstElementChild as HTMLElement;
    expect(dot.className).toContain("rounded-full");
    await act(async () => root.unmount());
  });

  it.each([
    ["awaiting_deposit", "info"],
    ["transferring", "ready"],
    ["awaiting_beneficiary", "info"],
    ["deposit_received", "attention"],
    ["deposit_verification", "attention"],
    ["ready_to_transfer", "ready"],
    ["completed", "success"],
    ["incident", "danger"],
  ])("takes the shared %s status tone (%s)", async (status, tone) => {
    const { node, root } = await renderNode(<StatusChip status={status} label={status} />);
    const chip = node.firstElementChild as HTMLElement;
    expect(chip.className).toContain(`text-status-${tone}`);
    expect(chip.className).not.toMatch(/emerald|amber|red-/);
    await act(async () => root.unmount());
  });

  it("uses the muted tone for collecting_information and any other/unknown status", async () => {
    for (const status of ["collecting_information", "some_unknown_status"]) {
      const { node, root } = await renderNode(<StatusChip status={status} label={status} />);
      const chip = node.firstElementChild as HTMLElement;
      expect(chip.className).toContain("text-muted-foreground");
      await act(async () => root.unmount());
    }
  });
});

describe("KNOWN_BENEFICIARY_TYPES", () => {
  it("includes combo so its label resolves through beneficiaryType", () => {
    expect(KNOWN_BENEFICIARY_TYPES).toContain("combo");
    expect(KNOWN_BENEFICIARY_TYPES).toContain("mexico_cuenta");
    expect(KNOWN_BENEFICIARY_TYPES).toContain("mexico_retiro");
  });
});
