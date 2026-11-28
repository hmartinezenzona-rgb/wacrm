import { afterEach, describe, expect, it, vi } from "vitest";

// getRequestConfig is an identity wrapper for our purposes: expose the
// callback so the test can call it directly.
vi.mock("next-intl/server", () => ({
  getRequestConfig: (fn: unknown) => fn,
}));

type RequestConfig = () => Promise<{
  locale: string;
  messages: { Sidebar: { finanzas: string } };
}>;

async function loadConfig(): Promise<RequestConfig> {
  vi.resetModules();
  return (await import("./request")).default as unknown as RequestConfig;
}

describe("i18n request config", () => {
  afterEach(() => {
    vi.unstubAllEnvs();
  });

  it("loads messages/es.json when NEXT_PUBLIC_APP_LOCALE=es", async () => {
    vi.stubEnv("NEXT_PUBLIC_APP_LOCALE", "es");
    const config = await (await loadConfig())();
    expect(config.locale).toBe("es");
    expect(config.messages.Sidebar.finanzas).toBe("Finanzas");
  });

  it("defaults to en.json when no locale is set", async () => {
    vi.stubEnv("NEXT_PUBLIC_APP_LOCALE", "");
    const config = await (await loadConfig())();
    expect(config.locale).toBe("en");
    expect(config.messages.Sidebar.finanzas).toBe("Finances");
  });
});
