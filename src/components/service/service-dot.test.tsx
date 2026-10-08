// @vitest-environment jsdom
import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it } from "vitest";
import { ServiceDot } from "./service-dot";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

async function render(service: string) {
  const node = document.createElement("div");
  document.body.appendChild(node);
  await act(async () => createRoot(node).render(<ServiceDot service={service} />));
  return node.firstElementChild as HTMLElement;
}

afterEach(() => {
  document.body.innerHTML = "";
});

describe("ServiceDot", () => {
  it("is an 8px decorative circle in the colour of the service", async () => {
    const el = await render("ZELLE");
    expect(el.getAttribute("aria-hidden")).toBe("true");
    expect(el.dataset.service).toBe("zelle");
    expect(el.className).toContain("bg-service-zelle");
    expect(el.className).toContain("size-2");
    expect(el.className).toContain("rounded-full");
    expect(el.textContent).toBe("");
  });

  it("is neutral for an unknown service", async () => {
    const el = await render("whatever");
    expect(el.dataset.service).toBe("other");
    expect(el.className).toContain("bg-service-other");
  });
});
