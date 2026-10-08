// @vitest-environment jsdom
import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it } from "vitest";
import { StatusPill } from "./status-pill";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

async function render(status: string, label: string) {
  const node = document.createElement("div");
  document.body.appendChild(node);
  await act(async () => createRoot(node).render(<StatusPill status={status} label={label} />));
  return node.firstElementChild as HTMLElement;
}

afterEach(() => {
  document.body.innerHTML = "";
});

describe("StatusPill", () => {
  it("shows the label with the tone of its status", async () => {
    const el = await render("ready_to_transfer", "Listo para transferir");
    expect(el.textContent).toBe("Listo para transferir");
    expect(el.dataset.tone).toBe("attention");
    expect(el.className).toContain("text-status-attention");
    expect(el.className).toContain("bg-status-attention-soft");
  });

  it("is neutral for an unknown status and still shows its label", async () => {
    const el = await render("brand_new", "Brand new");
    expect(el.textContent).toBe("Brand new");
    expect(el.dataset.tone).toBe("neutral");
    expect(el.className).toContain("text-muted-foreground");
  });
});
