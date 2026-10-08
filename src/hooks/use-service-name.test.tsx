// @vitest-environment jsdom
import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { describe, expect, it, vi } from "vitest";
import es from "../../messages/es.json";
import { useOperationServiceName, useServiceName } from "./use-service-name";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

vi.mock("next-intl", () => ({
  useTranslations: (namespace: string) => (key: string) =>
    (es as unknown as Record<string, Record<string, string>>)[namespace][key],
}));

function Probe() {
  const name = useServiceName();
  const operationName = useOperationServiceName();
  return (
    <p>
      {[
        name("SALDO_MOVIL"),
        name("cuban_card"),
        name("something-new"),
        name(null),
        operationName({ serviceType: "remesa", deliveryMethod: "zelle" }),
        operationName({ serviceType: "remesa" }),
      ].join("|")}
    </p>
  );
}

describe("service name hooks", () => {
  it("name any key from the catalog, print an unknown one raw, and name an operation", async () => {
    const node = document.createElement("div");
    const root = createRoot(node);
    await act(async () => root.render(<Probe />));
    expect(node.textContent).toBe("Saldo móvil|CUP|something-new||Zelle|Remesa");
    await act(async () => root.unmount());
  });
});
