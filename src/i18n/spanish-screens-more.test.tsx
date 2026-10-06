// @vitest-environment jsdom
// Second batch of screens moved off hard-coded English (agents, interactive builder, flows validation, dashboard
// activity feed, presence labels). Each renders with es.json and must show the Spanish copy.

import React from "react";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { renderToStaticMarkup } from "react-dom/server";
import { NextIntlClientProvider, useTranslations } from "next-intl";
import { describe, expect, it, vi } from "vitest";
import en from "../../messages/en.json";
import es from "../../messages/es.json";
import { blankButtonsPayload, InteractiveBuilder } from "@/components/interactive/interactive-builder";
import { AiPlayground } from "@/components/agents/ai-playground";
import { ActivityFeed } from "@/components/dashboard/activity-feed";
import { IssueLine } from "@/components/flows/validation-panel";
import { presenceLabel } from "@/lib/presence";
import { formatRelative } from "@/lib/automations/trigger-meta";
import { validateFlowForActivation } from "@/lib/flows/validate";

vi.mock("next/link", () => ({
  default: ({ children, href }: { children: React.ReactNode; href: string }) => <a href={href}>{children}</a>,
}));

function render(node: React.ReactElement): string {
  return renderToStaticMarkup(
    <NextIntlClientProvider locale="es" messages={es}>
      {node}
    </NextIntlClientProvider>,
  );
}

describe("agents and interactive builder (es)", () => {
  it("the playground shows its empty state and composer placeholder in Spanish", () => {
    const html = render(<AiPlayground onGoToSetup={() => {}} />);
    expect(html).toContain("Envía un mensaje para ver cómo respondería tu agente.");
    expect(html).toContain('placeholder="Escribe un mensaje de cliente…"');
    expect(html).not.toContain("Send a message to see");
  });

  it("the interactive builder shows its labels in Spanish", () => {
    const html = render(<InteractiveBuilder value={blankButtonsPayload()} onChange={() => {}} />);
    expect(html).toContain("Botones de respuesta");
    expect(html).toContain("Añadir botón");
    expect(html).toContain("Vista previa");
    expect(html).not.toContain("Reply buttons");
    expect(html).not.toContain("Add button");
  });
});

describe("flows validation messages (es)", () => {
  function Line({ code, params }: { code: string; params?: Record<string, string | number> }) {
    const t = useTranslations("Flows.validation");
    return (
      <IssueLine
        issue={{ severity: "error", scope: "flow", message: "ENGLISH FALLBACK", code, params }}
        t={t}
      />
    );
  }

  it("renders a coded issue from the catalog with its values", () => {
    const html = render(<Line code="buttonTitleTooLong" params={{ n: 2, max: 20 }} />);
    expect(html).toContain("El título del botón 2 supera los 20 caracteres (límite de WhatsApp).");
    expect(html).not.toContain("ENGLISH FALLBACK");
  });

  it("every code emitted by the validator exists in both catalogs", () => {
    const source = readFileSync(join(process.cwd(), "src/lib/flows/validate.ts"), "utf8");
    const codes = [...source.matchAll(/code: "(\w+)"/g)].map((m) => m[1]);
    expect(codes.length).toBeGreaterThan(40);
    const issues = (catalog: typeof en) =>
      (catalog.Flows.validation as unknown as { issues: Record<string, string> }).issues;
    for (const code of codes) {
      expect(issues(en)[code], `en ${code}`).toBeTypeOf("string");
      expect(issues(es)[code], `es ${code}`).toBeTypeOf("string");
    }
  });

  it("the validator still returns the English message next to the code", () => {
    const issues = validateFlowForActivation(
      { name: "", trigger_type: "manual", trigger_config: {}, entry_node_id: null },
      [],
    );
    expect(issues[0]).toMatchObject({ message: "Flow name is required.", code: "nameRequired" });
  });
});

describe("dashboard activity feed (es)", () => {
  it("renders structured items in Spanish and keeps stored text for legacy items", () => {
    const at = new Date().toISOString();
    const html = render(
      <ActivityFeed
        loading={false}
        items={[
          { id: "1", kind: "message", text: "New message from Ana", at, i18n: { key: "newMessage", values: { who: "Ana" } } },
          { id: "2", kind: "message", text: "New message from Unknown", at, i18n: { key: "newMessage", values: {} } },
          {
            id: "3",
            kind: "broadcast",
            text: "Broadcast",
            at,
            i18n: { key: "broadcastOther", values: { name: "Promo", status: "draft", count: 4 } },
          },
          { id: "4", kind: "contact", text: "Texto ya formateado", at },
        ]}
      />,
    );
    expect(html).toContain("Mensaje nuevo de Ana");
    expect(html).toContain("Mensaje nuevo de Desconocido");
    expect(html).toContain("Difusión &quot;Promo&quot; borrador (4 destinatarios)");
    expect(html).toContain("Texto ya formateado");
    expect(html).not.toContain("New message from");
  });
});

describe("presence and relative-time helpers (es)", () => {
  function Label({ minutes }: { minutes: number }) {
    const t = useTranslations("Common.presence");
    const now = Date.UTC(2026, 9, 6, 12, 0, 0);
    return <span>{presenceLabel("offline", new Date(now - minutes * 60_000).toISOString(), now, t)}</span>;
  }
  const fiveMinutesAgo = new Date(Date.now() - 5 * 60_000).toISOString();
  function Rel() {
    const t = useTranslations("Common.relative");
    return <span>{formatRelative(fiveMinutesAgo, t)}</span>;
  }

  it("translates the offline tooltip and its plural", () => {
    expect(render(<Label minutes={120} />)).toContain("Desconectado — visto por última vez hace 2 horas");
    expect(render(<Label minutes={1} />)).toContain("hace 1 minuto");
  });

  it("translates the automation list's relative time", () => {
    expect(render(<Rel />)).toContain("hace 5 min");
  });
});
