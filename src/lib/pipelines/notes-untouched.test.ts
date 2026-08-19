// ============================================================
// DP-18 — the delivery note must never reach `deals.notes`.
//
// This is a source-level guard rather than a behavioural test, and
// that is a deliberate trade: vitest runs with `environment: "node"`
// and the repo has no React testing library, so the deal form cannot
// be rendered and its save payload cannot be observed at runtime.
//
// The regression it guards is specific and expensive. `deals.notes`
// has a trigger on it:
//
//   trg_sync_z_benef_desde_deal  AFTER INSERT OR UPDATE OF notes
//       → cerebro_sync_beneficiarios(NEW.id)
//
// which re-parses the BENEFICIARIO block and updates
// `remittance_operations.delivery_method`. n8n also reads that same
// column with regexes to decide whether it may promise the transfer.
// Appending "Nombre del remitente: Juan Pérez" to it would look
// harmless in a diff and would quietly feed the beneficiary parser
// prose it was never meant to see.
//
// So the assertions below are on the shape of the code: the save
// payload carries the fields it always carried and nothing about a
// proof, and the delivery path writes `stage_id` alone.
// ============================================================

import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const root = process.cwd();
const dealForm = readFileSync(
  join(root, "src/components/pipelines/deal-form.tsx"),
  "utf8",
);
const board = readFileSync(
  join(root, "src/app/(dashboard)/pipelines/page.tsx"),
  "utf8",
);

/** The object literal assigned to `payload` in `handleSave`. */
function savePayload(source: string): string {
  const start = source.indexOf("const payload = {");
  expect(start, "handleSave's payload literal moved or was renamed").
    toBeGreaterThan(-1);
  const end = source.indexOf("};", start);
  return source.slice(start, end);
}

describe("the deal form's save payload", () => {
  it("still writes the fields it always wrote", () => {
    const payload = savePayload(dealForm);
    expect(payload).toContain("notes: notes.trim() || null");
    expect(payload).toContain("stage_id");
    expect(payload).toContain("contact_id");
  });

  it("carries nothing about the delivery proof", () => {
    const payload = savePayload(dealForm);
    for (const forbidden of ["caption", "proof", "delivery", "previewUrl"]) {
      expect(
        payload.toLowerCase(),
        `"${forbidden}" appeared in the deals UPDATE payload — the note ` +
          `belongs on the image, not in deals.notes (it fires ` +
          `trg_sync_z_benef_desde_deal)`,
      ).not.toContain(forbidden);
    }
  });
});

describe("the delivery path's write", () => {
  it("updates stage_id and nothing else", () => {
    // `persistStage` is the single writer both paths go through.
    const start = board.indexOf("const persistStage");
    expect(start, "persistStage moved or was renamed").toBeGreaterThan(-1);
    const body = board.slice(start, board.indexOf("[supabase],", start));

    expect(body).toContain(".update({ stage_id: newStageId })");
    expect(body).not.toContain("notes");
  });

  it("has no other write to the deals table in the whole board", () => {
    // Any `.from("deals").update(...)` outside persistStage would be a
    // second place the trigger chain can fire from.
    const updates = board.match(/from\("deals"\)\s*\.update\(/g) ?? [];
    expect(updates).toHaveLength(1);
  });

  it("never posts a note to the messages API as its own message", () => {
    // The note travels as the image caption (`content_text` on the
    // image send), not as a separate text message: one fewer send
    // that can fail on its own.
    const sends = board.match(/message_type: "(\w+)"/g) ?? [];
    expect(sends).toEqual(['message_type: "image"']);
  });
});
