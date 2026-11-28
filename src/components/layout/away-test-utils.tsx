import React from "react";
import { NextIntlClientProvider } from "next-intl";

import es from "../../../messages/es.json";
import { AwayModeProvider } from "./away-mode-provider";

/** Test-only wrapper: Spanish catalog plus the shared away-mode provider. */
export function AwayWrapper({ children }: { children: React.ReactNode }) {
  return (
    <NextIntlClientProvider locale="es" messages={es} timeZone="America/Guyana">
      <AwayModeProvider>{children}</AwayModeProvider>
    </NextIntlClientProvider>
  );
}

export const AWAY_NOW = new Date("2026-10-22T15:00:00Z");

export const AWAY_SAMPLE = {
  motivo: "porque tuvimos que salir",
  hasta: "2026-10-22T19:00:00.000Z",
  hasta_texto: "a las 3:00 pm",
  por: "Ana",
};

export function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
