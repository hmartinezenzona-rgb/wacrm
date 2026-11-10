// @vitest-environment jsdom
// "No es del negocio": header button marks a chat via crm_marcar_no_negocio; the marked state shows a banner with
// "Reactivar" that clears it. Errors leave the parent state untouched.

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import en from "../../../messages/en.json";
import { NotBusinessBanner, NotBusinessButton } from "./not-business-control";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

const rpc = vi.fn();
const toastError = vi.fn();

vi.mock("@/lib/supabase/client", () => ({ createClient: () => ({ rpc }) }));
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: (...a: unknown[]) => toastError(...a) } }));
vi.mock("next-intl", () => ({
  useTranslations: (namespace: string) => {
    const node = namespace
      .split(".")
      .reduce((acc: Record<string, unknown>, part) => acc[part] as Record<string, unknown>, en as unknown as Record<string, unknown>);
    return (key: string) => node[key] as string;
  },
}));

beforeEach(() => {
  rpc.mockReset();
  toastError.mockReset();
});
afterEach(() => document.body.replaceChildren());

async function mount(ui: React.ReactElement) {
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  await act(async () => root.render(ui));
  return { node, root };
}

const t = en.Inbox.notBusiness;

describe("NotBusinessButton", () => {
  it("marks the chat through the RPC and reports the new state", async () => {
    rpc.mockResolvedValue({
      data: { no_negocio: true, not_business_at: "2026-11-10T12:00:00Z", not_business_by: "user-1" },
      error: null,
    });
    const onChange = vi.fn();
    const { node, root } = await mount(
      <NotBusinessButton conversationId="conv-1" notBusinessAt={null} onChange={onChange} />,
    );

    const button = node.querySelector("button");
    expect(button?.textContent).toContain(t.mark);
    await act(async () => button!.click());

    expect(rpc).toHaveBeenCalledWith("crm_marcar_no_negocio", { p_conversation_id: "conv-1", p_no_negocio: true });
    expect(onChange).toHaveBeenCalledWith({ not_business_at: "2026-11-10T12:00:00Z", not_business_by: "user-1" });
    await act(async () => root.unmount());
  });

  it("renders nothing when the chat is already marked", async () => {
    const { node, root } = await mount(
      <NotBusinessButton conversationId="conv-1" notBusinessAt="2026-11-10T12:00:00Z" onChange={vi.fn()} />,
    );
    expect(node.querySelector("button")).toBeNull();
    await act(async () => root.unmount());
  });

  it("keeps the parent state and shows an error when the RPC fails", async () => {
    rpc.mockResolvedValue({ data: null, error: { message: "boom" } });
    const onChange = vi.fn();
    const { node, root } = await mount(
      <NotBusinessButton conversationId="conv-1" notBusinessAt={null} onChange={onChange} />,
    );
    await act(async () => node.querySelector("button")!.click());
    expect(onChange).not.toHaveBeenCalled();
    expect(toastError).toHaveBeenCalledWith(t.failed);
    await act(async () => root.unmount());
  });
});

describe("NotBusinessBanner", () => {
  it("renders nothing for a normal chat", async () => {
    const { node, root } = await mount(
      <NotBusinessBanner conversationId="conv-1" notBusinessAt={null} onChange={vi.fn()} />,
    );
    expect(node.textContent).toBe("");
    await act(async () => root.unmount());
  });

  it("shows the state and clears it with Reactivar", async () => {
    rpc.mockResolvedValue({ data: { no_negocio: false, not_business_at: null, not_business_by: null }, error: null });
    const onChange = vi.fn();
    const { node, root } = await mount(
      <NotBusinessBanner conversationId="conv-1" notBusinessAt="2026-11-10T12:00:00Z" onChange={onChange} />,
    );

    expect(node.textContent).toContain(t.banner);
    const button = node.querySelector("button");
    expect(button?.textContent).toContain(t.reactivate);
    await act(async () => button!.click());

    expect(rpc).toHaveBeenCalledWith("crm_marcar_no_negocio", { p_conversation_id: "conv-1", p_no_negocio: false });
    expect(onChange).toHaveBeenCalledWith({ not_business_at: null, not_business_by: null });
    await act(async () => root.unmount());
  });
});
