// Shared harness for the reseller UI tests: a real next-intl provider with the
// Spanish catalog (so ICU plurals and interpolations are exercised, not mocked),
// a fetch response builder and text-based button lookup.

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { NextIntlClientProvider } from "next-intl";
import es from "../../../messages/es.json";

export function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

export async function renderWithIntl(element: React.ReactElement) {
  const host = document.createElement("div");
  document.body.appendChild(host);
  const root = createRoot(host);
  await act(async () => {
    root.render(
      <NextIntlClientProvider locale="es" messages={es}>
        {element}
      </NextIntlClientProvider>,
    );
  });
  return {
    host,
    root,
    text: () => document.body.textContent ?? "",
    async unmount() {
      await act(async () => root.unmount());
      host.remove();
    },
  };
}

export function buttonByText(text: string): HTMLButtonElement {
  const button = [...document.querySelectorAll("button")].find(
    (el) => el.textContent?.trim() === text,
  );
  if (!button) throw new Error(`button not found: ${text}`);
  return button as HTMLButtonElement;
}

/** Type into a controlled React field the way a user does (native setter + input event). */
export function typeInto(
  element: HTMLInputElement | HTMLTextAreaElement,
  value: string,
) {
  const proto =
    element instanceof HTMLTextAreaElement
      ? HTMLTextAreaElement.prototype
      : HTMLInputElement.prototype;
  const setter = Object.getOwnPropertyDescriptor(proto, "value")?.set;
  setter?.call(element, value);
  element.dispatchEvent(new Event("input", { bubbles: true }));
}

export function inputById(id: string): HTMLInputElement {
  const element = document.getElementById(id);
  if (!(element instanceof HTMLInputElement)) {
    throw new Error(`input not found: ${id}`);
  }
  return element;
}
