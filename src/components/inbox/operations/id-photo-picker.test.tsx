// @vitest-environment jsdom
// The "Elegir del chat" control of a cash recipient's ID photo: a trigger that opens a compact dialog with the
// thumbnails of the conversation's images (newest first, as the endpoint returns them). Choosing one reports its
// wamid. Nothing is fetched until the dialog opens.

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import en from "../../../../messages/en.json";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

vi.mock("next-intl", () => ({
  useTranslations: (namespace: string) => {
    const node = namespace.split(".").reduce((acc: Record<string, unknown>, part) => acc[part] as Record<string, unknown>, en as unknown as Record<string, unknown>);
    return (key: string, values?: Record<string, string>) => {
      const text = key.split(".").reduce((acc: unknown, part) => (acc as Record<string, unknown>)[part], node) as string;
      return values ? text.replace(/\{(\w+)\}/g, (_, name: string) => values[name] ?? "") : text;
    };
  },
}));

const fetchChatImages = vi.fn();
vi.mock("@/lib/remittance-operations/commands", () => ({
  fetchChatImages: (...args: unknown[]) => fetchChatImages(...args),
}));

const copy = en.Inbox.operationsPanel;
const CONVERSATION_ID = "44444444-4444-4444-4444-444444444444";

const IMAGES = [
  { id: "m3", wamid: "wamid.3", createdAt: "2026-10-08T16:35:00Z", senderType: "customer", mediaUrl: "https://cdn.example.invalid/3.jpg" },
  { id: "m2", wamid: "wamid.2", createdAt: "2026-10-08T14:02:00Z", senderType: "agent", mediaUrl: "https://cdn.example.invalid/2.jpg" },
  { id: "m1", wamid: "wamid.1", createdAt: "2026-10-07T09:00:00Z", senderType: "bot", mediaUrl: "https://cdn.example.invalid/1.jpg" },
];

async function render(props: Partial<{ selectedWamid: string | null; label: string; disabled: boolean; onPick: (wamid: string) => void }> = {}) {
  const { IdPhotoPicker } = await import("./id-photo-picker");
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  const onPick = props.onPick ?? vi.fn();
  const onOuterKeyDown = vi.fn();
  await act(async () =>
    root.render(
      <div onKeyDown={onOuterKeyDown}>
        <IdPhotoPicker
          conversationId={CONVERSATION_ID}
          selectedWamid={props.selectedWamid ?? null}
          label={props.label ?? copy.idPhotoPick}
          disabled={props.disabled}
          onPick={onPick}
        />
      </div>,
    ),
  );
  return { node, root, onPick, onOuterKeyDown };
}

const trigger = () => Array.from(document.querySelectorAll("button")).find((b) => b.textContent === copy.idPhotoPick || b.textContent === copy.idPhotoChange)!;
const thumbs = () => Array.from(document.querySelectorAll<HTMLButtonElement>('[role="dialog"] button[data-wamid]'));
const flush = () => act(async () => { await Promise.resolve(); });

beforeEach(() => {
  fetchChatImages.mockReset();
  fetchChatImages.mockResolvedValue({ ok: true, data: IMAGES });
});

afterEach(() => {
  document.body.innerHTML = "";
});

describe("IdPhotoPicker", () => {
  it("shows only the trigger and fetches nothing until it is opened", async () => {
    const { root } = await render();
    expect(trigger().textContent).toBe(copy.idPhotoPick);
    expect(document.querySelector('[role="dialog"]')).toBeNull();
    expect(fetchChatImages).not.toHaveBeenCalled();
    await act(async () => root.unmount());
  });

  it("opens a dialog, fetches the conversation's images once and shows one lazy thumbnail per image, newest first", async () => {
    const { root } = await render();
    await act(async () => trigger().click());
    await flush();

    expect(fetchChatImages).toHaveBeenCalledTimes(1);
    expect(fetchChatImages).toHaveBeenCalledWith(CONVERSATION_ID);
    const dialog = document.querySelector('[role="dialog"]')!;
    expect(dialog.textContent).toContain(copy.idPhotoPickerTitle);
    expect(thumbs().map((b) => b.dataset.wamid)).toEqual(["wamid.3", "wamid.2", "wamid.1"]);
    const imgs = thumbs().map((b) => b.querySelector("img")!);
    expect(imgs.map((i) => i.getAttribute("src"))).toEqual(IMAGES.map((i) => i.mediaUrl));
    expect(imgs.every((i) => i.getAttribute("loading") === "lazy")).toBe(true);
    // accessible name: "Chat image, <time>" and who sent it
    for (const img of imgs) expect(img.getAttribute("alt")).toMatch(/^Chat image, .+/);
    expect(thumbs()[0].textContent).toContain(copy.idPhotoFromCustomer);
    expect(thumbs()[1].textContent).toContain(copy.idPhotoFromTeam);
    expect(thumbs()[2].textContent).toContain(copy.idPhotoFromBot);
    await act(async () => root.unmount());
  });

  it("choosing a thumbnail reports its wamid and closes the dialog", async () => {
    const { root, onPick } = await render();
    await act(async () => trigger().click());
    await flush();

    await act(async () => thumbs()[1].click());
    await flush();

    expect(onPick).toHaveBeenCalledTimes(1);
    expect(onPick).toHaveBeenCalledWith("wamid.2");
    expect(document.querySelector('[role="dialog"]')).toBeNull();
    await act(async () => root.unmount());
  });

  it("marks the current photo as pressed", async () => {
    const { root } = await render({ selectedWamid: "wamid.2", label: copy.idPhotoChange });
    await act(async () => trigger().click());
    await flush();
    expect(thumbs().map((b) => b.getAttribute("aria-pressed"))).toEqual(["false", "true", "false"]);
    await act(async () => root.unmount());
  });

  it("an empty conversation shows the empty note and no thumbnails", async () => {
    fetchChatImages.mockResolvedValue({ ok: true, data: [] });
    const { root } = await render();
    await act(async () => trigger().click());
    await flush();
    expect(document.querySelector('[role="dialog"]')!.textContent).toContain(copy.idPhotoPickerEmpty);
    expect(thumbs()).toHaveLength(0);
    await act(async () => root.unmount());
  });

  it("a failed load shows an alert", async () => {
    fetchChatImages.mockResolvedValue({ ok: false, status: 403, error: "Forbidden" });
    const { root } = await render();
    await act(async () => trigger().click());
    await flush();
    expect(document.querySelector('[role="dialog"] [role="alert"]')!.textContent).toBe(copy.idPhotoPickerLoadError);
    await act(async () => root.unmount());
  });

  it("keys typed in the dialog do not reach the form around the trigger (Enter would save it, Escape would cancel it)", async () => {
    const { root, onOuterKeyDown } = await render();
    await act(async () => trigger().click());
    await flush();
    await act(async () => {
      thumbs()[0].dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
    });
    expect(onOuterKeyDown).not.toHaveBeenCalled();
    await act(async () => root.unmount());
  });

  it("Enter or Space on the trigger opens the picker instead of reaching the form around it", async () => {
    const { root, onOuterKeyDown } = await render();
    for (const key of ["Enter", " "]) {
      await act(async () => {
        trigger().dispatchEvent(new KeyboardEvent("keydown", { key, bubbles: true }));
      });
    }
    expect(onOuterKeyDown).not.toHaveBeenCalled();
    await act(async () => root.unmount());
  });

  it("a disabled picker cannot be opened", async () => {
    const { root } = await render({ disabled: true });
    expect(trigger().disabled).toBe(true);
    await act(async () => root.unmount());
  });
});
