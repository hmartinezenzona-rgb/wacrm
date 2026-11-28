// Tests for `evidenceToRpc`: maps the browser-side `DeliveryEvidence`
// (deliver-with-proof.ts) to the `crm_entregar_operacion` RPC's
// `p_evidence` shape (migration 101) — `mode` derived from the two
// booleans, `wamid`/`path` included only when actually present.

import { describe, expect, it } from "vitest";
import { evidenceToRpc } from "./delivery";
import type { DeliveryEvidence } from "@/lib/pipelines/deliver-with-proof";

describe("evidenceToRpc", () => {
  it("maps proofSent to mode 'proof_sent', carrying wamid and path", () => {
    const evidence: DeliveryEvidence = {
      proofSent: true,
      skipProof: false,
      wamid: "wamid.ABC",
      path: "account-1/x.png",
    };

    expect(evidenceToRpc(evidence)).toEqual({
      mode: "proof_sent",
      wamid: "wamid.ABC",
      path: "account-1/x.png",
    });
  });

  it("maps skipProof to mode 'skip_proof' with no wamid/path", () => {
    const evidence: DeliveryEvidence = { proofSent: false, skipProof: true };

    expect(evidenceToRpc(evidence)).toEqual({ mode: "skip_proof" });
  });

  it("maps neither proofSent nor skipProof to mode 'no_proof'", () => {
    const evidence: DeliveryEvidence = { proofSent: false, skipProof: false };

    expect(evidenceToRpc(evidence)).toEqual({ mode: "no_proof" });
  });

  it("proofSent wins over skipProof when (defensively) both are true", () => {
    const evidence: DeliveryEvidence = {
      proofSent: true,
      skipProof: true,
      wamid: "wamid.ABC",
    };

    expect(evidenceToRpc(evidence).mode).toBe("proof_sent");
  });

  it("omits wamid when it is an empty string", () => {
    const evidence: DeliveryEvidence = {
      proofSent: true,
      skipProof: false,
      wamid: "",
      path: "account-1/x.png",
    };

    const result = evidenceToRpc(evidence);
    expect(result).not.toHaveProperty("wamid");
    expect(result.path).toBe("account-1/x.png");
  });

  it("omits path when it is an empty string", () => {
    const evidence: DeliveryEvidence = {
      proofSent: true,
      skipProof: false,
      wamid: "wamid.ABC",
      path: "",
    };

    const result = evidenceToRpc(evidence);
    expect(result).not.toHaveProperty("path");
    expect(result.wamid).toBe("wamid.ABC");
  });

  it("omits both when neither was recorded", () => {
    const evidence: DeliveryEvidence = { proofSent: false, skipProof: false };

    const result = evidenceToRpc(evidence);
    expect(result).not.toHaveProperty("wamid");
    expect(result).not.toHaveProperty("path");
  });
});
