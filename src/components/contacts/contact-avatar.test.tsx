// @vitest-environment jsdom
import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";

const generate = vi.hoisted(() => vi.fn((seed: string, gender?: string | null, seq?: number | null) => `data:image/svg+xml,seed-${seed}-${gender ?? ""}-${seq ?? ""}`));
vi.mock("@/lib/avatars/contact-avatar", () => ({ contactAvatarDataUri: generate }));

import { ContactAvatar } from "./contact-avatar";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

afterEach(() => {
  document.body.replaceChildren();
  generate.mockClear();
});

async function render(ui: React.ReactElement) {
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  await act(async () => root.render(ui));
  return { node, root };
}

describe("ContactAvatar", () => {
  it("shows the real photo when imageUrl exists", async () => {
    const { node } = await render(
      <ContactAvatar seed="c1" name="Ana" imageUrl="https://cdn.example/ana.jpg" />,
    );
    const img = node.querySelector("img");
    expect(img?.getAttribute("src")).toBe("https://cdn.example/ana.jpg");
    expect(img?.getAttribute("alt")).toBe("Ana");
    expect(generate).not.toHaveBeenCalled();
  });

  it("shows the generated illustration, decorative, without imageUrl", async () => {
    const { node } = await render(<ContactAvatar seed="c1" name="Ana" />);
    const img = node.querySelector("img");
    expect(img?.getAttribute("src")).toBe("data:image/svg+xml,seed-c1--");
    expect(img?.getAttribute("alt")).toBe("");
    expect(node.textContent).toBe("");
  });

  it("falls back to the initial when generation throws", async () => {
    generate.mockImplementationOnce(() => {
      throw new Error("boom");
    });
    const { node } = await render(<ContactAvatar seed="c1" name="ana" />);
    expect(node.querySelector("img")).toBeNull();
    expect(node.textContent).toBe("A");
  });

  it("passes className through to the container", async () => {
    const { node } = await render(<ContactAvatar seed="c1" name="Ana" className="h-10 w-10" />);
    expect(node.firstElementChild?.className).toContain("h-10 w-10");
  });

  it("passes gender and seq to the generator", async () => {
    const { node } = await render(<ContactAvatar seed="c1" name="Ana" gender="f" seq={4} />);
    expect(generate).toHaveBeenCalledWith("c1", "f", 4);
    expect(node.querySelector("img")?.getAttribute("src")).toBe("data:image/svg+xml,seed-c1-f-4");
  });
});
