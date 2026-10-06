// @vitest-environment jsdom
// Screens whose copy used to be hard-coded English render the Spanish catalog when the locale is es.

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { renderToStaticMarkup } from "react-dom/server";
import { NextIntlClientProvider } from "next-intl";
import { describe, expect, it, vi } from "vitest";
import es from "../../messages/es.json";

vi.mock("next/navigation", () => ({
  useSearchParams: () => new URLSearchParams(""),
  useParams: () => ({ token: "tok" }),
  useRouter: () => ({ push: vi.fn() }),
}));
vi.mock("@/lib/supabase/client", () => ({
  createClient: () => ({ auth: { getUser: () => new Promise(() => {}) } }),
}));
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

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

describe("hard-coded English moved into the catalog (es)", () => {
  it("forgot-password page", async () => {
    const { default: Page } = await import("@/app/(auth)/forgot-password/page");
    const html = render(<Page />);
    expect(html).toContain("Restablecer contraseña");
    expect(html).toContain("Enviar enlace");
    expect(html).toContain("Volver a iniciar sesión");
    expect(html).not.toContain("Reset password");
    expect(html).not.toContain("Back to sign in");
  });

  it("signup page", async () => {
    const { default: Page } = await import("@/app/(auth)/signup/page");
    const html = render(<Page />);
    expect(html).toContain("Crear cuenta");
    expect(html).toContain("Nombre completo");
    expect(html).toContain("¿Ya tienes una cuenta?");
    expect(html).not.toContain("Full name");
    expect(html).not.toContain("Already have an account?");
  });

  it("join page loading state", async () => {
    const { default: Page } = await import("@/app/join/[token]/page");
    const html = render(<Page />);
    expect(html).toContain("Verificando invitación…");
    expect(html).not.toContain("Verifying invitation");
  });

  it("quick replies manager header", async () => {
    const { QuickRepliesManager } = await import("@/components/settings/quick-replies-manager");
    const html = render(<QuickRepliesManager />);
    expect(html).toContain("Respuestas rápidas");
    expect(html).toContain("Nueva respuesta rápida");
    expect(html).not.toContain("New quick reply");
  });

  it("the dialog close button is announced in Spanish", async () => {
    const { Dialog, DialogContent } = await import("@/components/ui/dialog");
    const host = document.createElement("div");
    document.body.appendChild(host);
    const root = createRoot(host);
    await act(async () => {
      root.render(
        <NextIntlClientProvider locale="es" messages={es}>
          <Dialog open>
            <DialogContent>x</DialogContent>
          </Dialog>
        </NextIntlClientProvider>,
      );
    });
    const labels = Array.from(document.querySelectorAll(".sr-only")).map((el) => el.textContent);
    expect(labels).toContain("Cerrar");
    expect(labels).not.toContain("Close");
    await act(async () => root.unmount());
    host.remove();
  });
});
