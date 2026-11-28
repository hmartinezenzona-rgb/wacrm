// @vitest-environment jsdom
// Slice: panel-26 (readiness). A conversation row fires the operations
// panel's prefetch on hover AND on focus — the inbox is "use client"
// (page.tsx) with no server render to piggyback on, so the single
// `/api/remittance-operations` round trip can only start earlier, not
// go faster. Keyboard users arrow through this list and never hover, so
// both onMouseEnter and onFocus are required, not just one.
//
// Selection/ordering/filtering are out of scope here — this file only
// covers the new prefetch wiring, and asserts selection behaviour is
// unchanged as a guard against the wiring breaking it.
//
// The prefetch path is async (jsdom + a stubbed fetch); under the full
// suite's parallel workers the default 5 s is not enough and the file
// failed intermittently while passing alone. The assertions are unchanged.
vi.setConfig({ testTimeout: 20_000 });

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import en from "../../../messages/en.json";
import type { Conversation, Contact } from "@/types";
import { contactAvatarDataUri } from "@/lib/avatars/contact-avatar";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

// jsdom has no PointerEvent constructor. The shadcn/base-ui Checkbox's click
// handler re-dispatches a PointerEvent at its hidden native input — without
// this shim that throw is uncaught and the checkbox never toggles in tests.
if (typeof globalThis.PointerEvent === "undefined") {
  class PointerEventPolyfill extends MouseEvent {}
  // @ts-expect-error jsdom lacks PointerEvent; a MouseEvent subclass is
  // enough for the library's click re-dispatch to work in tests.
  globalThis.PointerEvent = PointerEventPolyfill;
}

vi.mock("next-intl", () => ({
  useTranslations: (namespace: string) => {
    const node = namespace
      .split(".")
      .reduce((acc: Record<string, unknown>, part) => acc[part] as Record<string, unknown>, en as unknown as Record<string, unknown>);
    return (key: string) => node[key] as string;
  },
}));

// The list also fetches its own conversations/tags on mount — irrelevant
// to prefetch-on-hover, which is exercised through the `conversations`
// prop instead (as a real parent would hold that state). Resolves both
// tables to empty so the mount effects settle without error.
//
// `update`/`in` are here too: pin/unpin and the batch "quitar del inbox"
// action (Slice B) call them, and without a stub the resulting unhandled
// promise rejection pollutes unrelated test output even though the
// assertions themselves still pass.
// Board rows returned by `crm_tablero_operaciones` (feeds the status chips) and the
// handlers registered on the `remittance_operations` realtime channel.
let boardRows: unknown[] = [];
const operationsChangeHandlers: Array<() => void> = [];

vi.mock("@/lib/supabase/client", () => ({
  createClient: () => ({
    rpc: () => Promise.resolve({ data: boardRows, error: null }),
    channel: () => {
      const channel = {
        on: (_type: string, _filter: unknown, handler: () => void) => {
          operationsChangeHandlers.push(handler);
          return channel;
        },
        subscribe: () => channel,
      };
      return channel;
    },
    removeChannel: () => undefined,
    from: () => {
      const builder = {
        select: () => builder,
        eq: () => builder,
        is: () => builder,
        order: () => builder,
        or: () => builder,
        limit: () => builder,
        update: () => builder,
        in: () => builder,
        then: (resolve: (value: { data: unknown[]; error: null }) => unknown) =>
          resolve({ data: [], error: null }),
      };
      return builder;
    },
  }),
}));

vi.mock("sonner", () => ({ toast: Object.assign(vi.fn(), { success: vi.fn(), error: vi.fn() }) }));

// ScrollArea/DropdownMenu wrap @base-ui/react primitives that lean on
// ResizeObserver/anchor-positioning — unavailable in jsdom and irrelevant
// to this file's assertions. Passthrough stand-ins keep the row markup
// (and its onMouseEnter/onFocus handlers) intact.
vi.mock("@/components/ui/scroll-area", () => ({
  ScrollArea: ({ children, className }: { children?: React.ReactNode; className?: string }) => (
    <div className={className}>{children}</div>
  ),
}));
vi.mock("@/components/ui/dropdown-menu", () => ({
  DropdownMenu: ({ children }: { children?: React.ReactNode }) => <div>{children}</div>,
  DropdownMenuTrigger: ({ children, ...props }: React.ComponentProps<"button">) => (
    <button {...props}>{children}</button>
  ),
  DropdownMenuContent: ({ children }: { children?: React.ReactNode }) => <div>{children}</div>,
  DropdownMenuItem: ({ children, ...props }: React.ComponentProps<"div">) => <div {...props}>{children}</div>,
  DropdownMenuCheckboxItem: ({ children, ...props }: React.ComponentProps<"div">) => (
    <div {...props}>{children}</div>
  ),
}));

const prefetchConversationOperations = vi.fn();
vi.mock("@/lib/remittance-operations/panel-prefetch", () => ({
  prefetchConversationOperations: (...args: unknown[]) => prefetchConversationOperations(...args),
}));

afterEach(() => {
  boardRows = [];
  operationsChangeHandlers.length = 0;
  document.body.replaceChildren();
  vi.restoreAllMocks();
  prefetchConversationOperations.mockClear();
});

function flush() {
  return act(async () => {
    await Promise.resolve();
    await Promise.resolve();
  });
}

function contact(overrides: Partial<Contact> = {}): Contact {
  return {
    id: "contact-1",
    user_id: "user-1",
    account_id: "account-1",
    phone: "5219622896918",
    name: "Ada Lovelace",
    created_at: "2026-09-14T00:00:00Z",
    updated_at: "2026-09-14T00:00:00Z",
    ...overrides,
  };
}

function conversation(overrides: Partial<Conversation> = {}): Conversation {
  return {
    id: "conv-1",
    user_id: "user-1",
    contact_id: "contact-1",
    status: "open",
    unread_count: 0,
    created_at: "2026-09-14T00:00:00Z",
    updated_at: "2026-09-14T00:00:00Z",
    contact: contact(),
    ...overrides,
  };
}

async function renderList(conversations: Conversation[]) {
  const { ConversationList } = await import("./conversation-list");
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  const onSelect = vi.fn();
  const onConversationsLoaded = vi.fn();
  await act(async () =>
    root.render(
      <ConversationList
        activeConversationId={null}
        onSelect={onSelect}
        conversations={conversations}
        onConversationsLoaded={onConversationsLoaded}
      />,
    ),
  );
  await flush();
  return { node, root, onSelect };
}

/** Like `renderList`, but lets a test pass an `onMarkAllRead` callback. */
async function renderListWithMarkAllRead(
  conversations: Conversation[],
  onMarkAllRead: () => void,
) {
  const { ConversationList } = await import("./conversation-list");
  const node = document.createElement("div");
  document.body.appendChild(node);
  const root = createRoot(node);
  const onSelect = vi.fn();
  const onConversationsLoaded = vi.fn();
  await act(async () =>
    root.render(
      <ConversationList
        activeConversationId={null}
        onSelect={onSelect}
        conversations={conversations}
        onConversationsLoaded={onConversationsLoaded}
        onMarkAllRead={onMarkAllRead}
      />,
    ),
  );
  await flush();
  return { node, root, onSelect };
}

function rowFor(node: Element, name: string): HTMLElement {
  const row = Array.from(node.querySelectorAll('[role="button"]')).find((el) =>
    el.textContent?.includes(name),
  );
  if (!row) throw new Error(`row for "${name}" not found`);
  return row as HTMLElement;
}

describe("ConversationList — prefetch on hover/focus", () => {
  it("prefetches operations for a row's conversation on mouseenter", async () => {
    const convs = [conversation({ id: "conv-1", contact: contact({ name: "Ada Lovelace" }) })];
    const { node, root } = await renderList(convs);

    const row = rowFor(node, "Ada Lovelace");
    await act(async () => {
      row.dispatchEvent(
        new MouseEvent("mouseover", { bubbles: true, cancelable: true, relatedTarget: document.body }),
      );
    });

    expect(prefetchConversationOperations).toHaveBeenCalledWith("conv-1");
    await act(async () => root.unmount());
  });

  it("prefetches operations for a row's conversation on focus (keyboard users never hover)", async () => {
    const convs = [conversation({ id: "conv-2", contact: contact({ name: "Grace Hopper" }) })];
    const { node, root } = await renderList(convs);

    const row = rowFor(node, "Grace Hopper");
    await act(async () => {
      row.focus();
    });

    expect(prefetchConversationOperations).toHaveBeenCalledWith("conv-2");
    await act(async () => root.unmount());
  });

  it("does not prefetch a row that was never hovered or focused", async () => {
    const convs = [
      conversation({ id: "conv-1", contact: contact({ name: "Ada Lovelace" }) }),
      conversation({ id: "conv-2", contact: contact({ name: "Grace Hopper" }) }),
    ];
    const { node, root } = await renderList(convs);

    const row = rowFor(node, "Ada Lovelace");
    await act(async () => {
      row.dispatchEvent(
        new MouseEvent("mouseover", { bubbles: true, cancelable: true, relatedTarget: document.body }),
      );
    });

    expect(prefetchConversationOperations).toHaveBeenCalledWith("conv-1");
    expect(prefetchConversationOperations).not.toHaveBeenCalledWith("conv-2");
    await act(async () => root.unmount());
  });

  it("still calls onSelect with the full conversation on click (selection unchanged)", async () => {
    const convs = [conversation({ id: "conv-1", contact: contact({ name: "Ada Lovelace" }) })];
    const { node, root, onSelect } = await renderList(convs);

    const row = rowFor(node, "Ada Lovelace");
    await act(async () => {
      row.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
    });

    expect(onSelect).toHaveBeenCalledWith(convs[0]);
    await act(async () => root.unmount());
  });
});

// Slice B: re-merge of the batch-selection + pin feature against production's
// independently rebuilt version (pure logic in src/lib/inbox/selection.ts,
// shared shadcn Checkbox, long-press entry for touch). Ported and adapted
// from production's conversation-list.test.tsx, which tests an exported
// `ConversationItem` with @testing-library/react — neither exists on this
// branch, so these render the full `ConversationList` through the same
// createRoot harness the prefetch tests above already use.
describe("ConversationList — selección múltiple y pin", () => {
  it("marcar la casilla selecciona sin abrir la conversación", async () => {
    const convs = [conversation({ id: "conv-1", contact: contact({ name: "Ada Lovelace" }) })];
    const { node, root, onSelect } = await renderList(convs);

    const row = rowFor(node, "Ada Lovelace");
    const casilla = row.querySelector('[role="checkbox"]') as HTMLElement;
    expect(casilla).toBeTruthy();
    expect(casilla.getAttribute("aria-label")).toBe(
      "Seleccionar conversación con Ada Lovelace",
    );

    await act(async () => {
      casilla.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
    });

    expect(onSelect).not.toHaveBeenCalled();
    expect(row.querySelector('[role="checkbox"]')?.getAttribute("aria-checked")).toBe(
      "true",
    );
    expect(node.textContent).toContain("1 seleccionada");
    expect(node.textContent).toContain("Quitar del inbox");
    expect(node.textContent).toContain("Cancelar");

    await act(async () => root.unmount());
  });

  it("pulsación larga (contextmenu) entra en modo selección sin abrir la conversación", async () => {
    const convs = [conversation({ id: "conv-1", contact: contact({ name: "Ada Lovelace" }) })];
    const { node, root, onSelect } = await renderList(convs);

    const row = rowFor(node, "Ada Lovelace");
    await act(async () => {
      row.dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, cancelable: true }));
    });

    expect(onSelect).not.toHaveBeenCalled();
    expect(row.querySelector('[role="checkbox"]')?.getAttribute("aria-checked")).toBe(
      "true",
    );
    expect(node.textContent).toContain("1 seleccionada");

    await act(async () => root.unmount());
  });

  it("«Cancelar» limpia la selección y sale del modo selección", async () => {
    const convs = [conversation({ id: "conv-1", contact: contact({ name: "Ada Lovelace" }) })];
    const { node, root } = await renderList(convs);

    const row = rowFor(node, "Ada Lovelace");
    await act(async () => {
      row.dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, cancelable: true }));
    });
    expect(node.textContent).toContain("Cancelar");

    const cancelar = Array.from(node.querySelectorAll("button")).find(
      (b) => b.textContent === "Cancelar",
    ) as HTMLButtonElement;
    await act(async () => {
      cancelar.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
    });

    expect(node.textContent).not.toContain("Quitar del inbox");
    expect(row.querySelector('[role="checkbox"]')?.getAttribute("aria-checked")).toBe(
      "false",
    );

    await act(async () => root.unmount());
  });

  it("clic normal sigue abriendo la conversación cuando no hay selección", async () => {
    const convs = [conversation({ id: "conv-1", contact: contact({ name: "Ada Lovelace" }) })];
    const { node, root, onSelect } = await renderList(convs);

    await act(async () => {
      rowFor(node, "Ada Lovelace").dispatchEvent(
        new MouseEvent("click", { bubbles: true, cancelable: true }),
      );
    });

    expect(onSelect).toHaveBeenCalledWith(convs[0]);
    await act(async () => root.unmount());
  });
});

describe("ConversationList — pin", () => {
  it("no fijado: botón accesible, sin aria-pressed activo", async () => {
    const convs = [conversation({ id: "conv-1", contact: contact({ name: "Ada Lovelace" }) })];
    const { node, root } = await renderList(convs);

    const row = rowFor(node, "Ada Lovelace");
    const boton = row.querySelector('[aria-label="Fijar conversación"]') as HTMLButtonElement;
    expect(boton).toBeTruthy();
    expect(boton.getAttribute("aria-pressed")).toBe("false");
    expect(boton.disabled).toBe(false);

    await act(async () => root.unmount());
  });

  it("fijado: aria-label y aria-pressed reflejan el estado", async () => {
    const convs = [
      conversation({
        id: "conv-1",
        pinned_at: new Date().toISOString(),
        contact: contact({ name: "Ada Lovelace" }),
      }),
    ];
    const { node, root } = await renderList(convs);

    const row = rowFor(node, "Ada Lovelace");
    const boton = row.querySelector(
      '[aria-label="Desfijar conversación"]',
    ) as HTMLButtonElement;
    expect(boton).toBeTruthy();
    expect(boton.getAttribute("aria-pressed")).toBe("true");

    await act(async () => root.unmount());
  });

  it("fijar/desfijar no abre la conversación", async () => {
    const convs = [conversation({ id: "conv-1", contact: contact({ name: "Ada Lovelace" }) })];
    const { node, root, onSelect } = await renderList(convs);

    const row = rowFor(node, "Ada Lovelace");
    const boton = row.querySelector('[aria-label="Fijar conversación"]') as HTMLButtonElement;
    await act(async () => {
      boton.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
    });

    expect(onSelect).not.toHaveBeenCalled();
    await act(async () => root.unmount());
  });

  it("se deshabilita en modo selección", async () => {
    const convs = [conversation({ id: "conv-1", contact: contact({ name: "Ada Lovelace" }) })];
    const { node, root } = await renderList(convs);

    const row = rowFor(node, "Ada Lovelace");
    await act(async () => {
      row.dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, cancelable: true }));
    });

    const boton = row.querySelector('[aria-label="Fijar conversación"]') as HTMLButtonElement;
    expect(boton.disabled).toBe(true);

    await act(async () => root.unmount());
  });
});

// B1.5(b): the bulk "mark all as read" action lives here because
// ConversationList already owns the `conversations` prop and its own
// direct Supabase writes (pin/unpin, quitar del inbox above) — same
// pattern, one more bulk mutation. The parent (inbox page) is only told
// via `onMarkAllRead` so it can also stop the chat notification sound.
describe("ConversationList — marcar todas como leídas", () => {
  it("no se muestra sin un onMarkAllRead", async () => {
    const convs = [conversation({ id: "conv-1", unread_count: 2 })];
    const { node, root } = await renderList(convs);

    expect(node.textContent).not.toContain("Marcar todas como leídas");

    await act(async () => root.unmount());
  });

  it("se deshabilita cuando ninguna conversación tiene mensajes sin leer", async () => {
    const convs = [conversation({ id: "conv-1", unread_count: 0 })];
    const onMarkAllRead = vi.fn();
    const { node, root } = await renderListWithMarkAllRead(convs, onMarkAllRead);

    const boton = Array.from(node.querySelectorAll("button")).find((b) =>
      b.textContent?.includes("Marcar todas como leídas"),
    ) as HTMLButtonElement;
    expect(boton).toBeTruthy();
    expect(boton.disabled).toBe(true);

    await act(async () => root.unmount());
  });

  it("se habilita y llama a onMarkAllRead al hacer clic cuando hay conversaciones sin leer", async () => {
    const convs = [
      conversation({ id: "conv-1", unread_count: 3 }),
      conversation({ id: "conv-2", unread_count: 0 }),
    ];
    const onMarkAllRead = vi.fn();
    const { node, root } = await renderListWithMarkAllRead(convs, onMarkAllRead);

    const boton = Array.from(node.querySelectorAll("button")).find((b) =>
      b.textContent?.includes("Marcar todas como leídas"),
    ) as HTMLButtonElement;
    expect(boton.disabled).toBe(false);

    await act(async () => {
      boton.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
    });

    expect(onMarkAllRead).toHaveBeenCalledTimes(1);

    await act(async () => root.unmount());
  });
});

describe("ConversationList — customer avatar", () => {
  it("shows the generated illustration instead of the initial when there is no photo", async () => {
    const { node, root } = await renderList([conversation({ contact: contact({ name: "Ada Lovelace" }) })]);

    const row = rowFor(node, "Ada Lovelace");
    const img = row.querySelector('img[alt=""]');
    expect(img?.getAttribute("src")).toMatch(/^data:image\/svg\+xml/);
    await act(async () => root.unmount());
  });

  it("keeps the real photo when the contact has one", async () => {
    const { node, root } = await renderList([
      conversation({ contact: contact({ name: "Ada Lovelace", avatar_url: "https://cdn.example/ada.jpg" }) }),
    ]);

    const img = rowFor(node, "Ada Lovelace").querySelector('img[alt="Ada Lovelace"]');
    expect(img?.getAttribute("src")).toBe("https://cdn.example/ada.jpg");
    await act(async () => root.unmount());
  });

  it("passes the contact's avatar gender and number to the illustration", async () => {
    const c = contact({ name: "Ada Lovelace", avatar_gender: "f", avatar_seq: 7 });
    const { node, root } = await renderList([conversation({ contact: c })]);

    const img = rowFor(node, "Ada Lovelace").querySelector('img[alt=""]');
    expect(img?.getAttribute("src")).toBe(contactAvatarDataUri(c.id, "f", 7));
    expect(img?.getAttribute("src")).not.toBe(contactAvatarDataUri(c.id));
    await act(async () => root.unmount());
  });
});

function boardRow(overrides: Record<string, unknown> = {}) {
  return {
    operation_id: "op-1",
    conversation_id: "conv-1",
    contact_name: "Ada Lovelace",
    contact_phone: null,
    service_type: "remesa",
    delivery_method: null,
    status: "ready_to_transfer",
    quoted_source_amount: 100,
    source_currency: "GYD",
    created_at: "2026-10-21T10:00:00Z",
    completed_at: null,
    state_since: "2026-10-21T10:00:00Z",
    beneficiaries_complete: false,
    ...overrides,
  };
}

describe("ConversationList — open operation status chip", () => {
  it("shows only the panel's status text for the open operation", async () => {
    boardRows = [boardRow()];
    const { node } = await renderList([conversation({ id: "conv-1" })]);
    await flush();

    const chip = node.querySelector('[data-testid="operation-status-chip"]');
    expect(chip?.textContent).toBe("Waiting for beneficiary");
    expect(chip?.getAttribute("data-tone")).toBe("info");
  });

  it("shows no chip when the operation is completed or there is none", async () => {
    boardRows = [boardRow({ status: "completed" })];
    const { node } = await renderList([
      conversation({ id: "conv-1" }),
      conversation({ id: "conv-2", contact: contact({ id: "c2", name: "Grace Hopper" }) }),
    ]);
    await flush();

    expect(node.querySelectorAll('[data-testid="operation-status-chip"]')).toHaveLength(0);
  });

  it("refreshes the chip when a remittance_operations change arrives", async () => {
    boardRows = [boardRow({ status: "awaiting_deposit", beneficiaries_complete: true })];
    const { node } = await renderList([conversation({ id: "conv-1" })]);
    await flush();
    expect(node.querySelector('[data-testid="operation-status-chip"]')?.textContent).toBe("Awaiting deposit");

    vi.useFakeTimers();
    boardRows = [boardRow({ status: "incident" })];
    operationsChangeHandlers.forEach((h) => h());
    await act(async () => {
      await vi.advanceTimersByTimeAsync(900);
    });
    vi.useRealTimers();
    await flush();

    expect(node.querySelector('[data-testid="operation-status-chip"]')?.textContent).toBe("Incident");
  });
});
