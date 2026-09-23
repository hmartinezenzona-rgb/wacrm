// @vitest-environment jsdom
// Spec: panel-19 operation-card redesign, inline beneficiary edit. Small
// presentational atom used by the beneficiary inline edit mode: a leading
// icon plus a full-width, low-emphasis input that visually replaces a
// read-only copy chip in the same position. `variant="name"` matches the
// sans-serif name chip; every other field matches the monospace chips.

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import { InlineEditField } from "./inline-edit-field";

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

describe("InlineEditField", () => {
  it("renders the icon and an input with the given value, placeholder and aria-label", async () => {
    const { node, root } = await renderNode(
      <InlineEditField
        icon={<svg data-testid="icon" />}
        value="Yaima Perez"
        onChange={() => {}}
        placeholder="Name"
        ariaLabel="Name"
      />,
    );

    const input = node.querySelector("input")!;
    expect(input.value).toBe("Yaima Perez");
    expect(input.placeholder).toBe("Name");
    expect(input.getAttribute("aria-label")).toBe("Name");
    expect(node.querySelector('[data-testid="icon"]')).not.toBeNull();
    await act(async () => root.unmount());
  });

  it("calls onChange with the new value when typed into", async () => {
    const onChange = vi.fn();
    const { node, root } = await renderNode(
      <InlineEditField icon={null} value="" onChange={onChange} placeholder="Card" ariaLabel="Card" />,
    );

    const input = node.querySelector("input")!;
    const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value")!.set!;
    await act(async () => {
      setter.call(input, "1234");
      input.dispatchEvent(new Event("input", { bubbles: true }));
    });

    expect(onChange).toHaveBeenCalledWith("1234");
    await act(async () => root.unmount());
  });

  it("disables the input when disabled is true", async () => {
    const { node, root } = await renderNode(
      <InlineEditField icon={null} value="" onChange={() => {}} placeholder="Phone" ariaLabel="Phone" disabled />,
    );

    expect(node.querySelector("input")!.disabled).toBe(true);
    await act(async () => root.unmount());
  });

  it("passes inputMode through to the input", async () => {
    const { node, root } = await renderNode(
      <InlineEditField
        icon={null}
        value=""
        onChange={() => {}}
        placeholder="Card"
        ariaLabel="Card"
        inputMode="numeric"
      />,
    );

    expect(node.querySelector("input")!.inputMode).toBe("numeric");
    await act(async () => root.unmount());
  });

  it("uses mono text by default and sans text for the name variant", async () => {
    const mono = await renderNode(
      <InlineEditField icon={null} value="" onChange={() => {}} placeholder="Card" ariaLabel="Card" />,
    );
    expect(mono.node.querySelector("input")!.className).toContain("font-mono");
    await act(async () => mono.root.unmount());

    const name = await renderNode(
      <InlineEditField icon={null} value="" onChange={() => {}} placeholder="Name" ariaLabel="Name" variant="name" />,
    );
    expect(name.node.querySelector("input")!.className).toContain("font-sans");
    await act(async () => name.root.unmount());
  });
});
