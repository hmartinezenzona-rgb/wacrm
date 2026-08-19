import { describe, it, expect, vi } from "vitest";
import {
  markProofSent,
  pruneStaleDrafts,
  putProofDraft,
  removeProofDraft,
  revokeAllPreviews,
  setProofCaption,
  type ProofDrafts,
} from "./proof-drafts";

function file(name: string): File {
  return { type: "image/png", size: 100, name } as unknown as File;
}

/** Object-URL doubles that record every create and revoke. */
function urls() {
  let n = 0;
  return {
    createUrl: vi.fn(() => `blob:${++n}`),
    revokeUrl: vi.fn(),
  };
}

const EMPTY: ProofDrafts = new Map();

describe("putProofDraft", () => {
  it("attaches a file to its deal", () => {
    const u = urls();
    const drafts = putProofDraft(EMPTY, "deal-a", file("a.png"), "png", u);

    expect(drafts.get("deal-a")).toMatchObject({
      dealId: "deal-a",
      kind: "png",
      previewUrl: "blob:1",
      caption: "",
    });
    expect(u.revokeUrl).not.toHaveBeenCalled();
  });

  // DP-07
  it("revokes the previous preview when the image is replaced", () => {
    const u = urls();
    let drafts = putProofDraft(EMPTY, "deal-a", file("first.png"), "png", u);
    drafts = putProofDraft(drafts, "deal-a", file("second.png"), "jpeg", u);

    expect(u.revokeUrl).toHaveBeenCalledTimes(1);
    expect(u.revokeUrl).toHaveBeenCalledWith("blob:1");
    expect(drafts.get("deal-a")).toMatchObject({
      previewUrl: "blob:2",
      kind: "jpeg",
    });
    expect(drafts.size).toBe(1);
  });

  it("leaks nothing across repeated swaps", () => {
    const u = urls();
    let drafts: ProofDrafts = EMPTY;
    for (let i = 0; i < 5; i++) {
      drafts = putProofDraft(drafts, "deal-a", file(`${i}.png`), "png", u);
    }
    // Five created, four revoked, one still live and owned by the map.
    expect(u.createUrl).toHaveBeenCalledTimes(5);
    expect(u.revokeUrl).toHaveBeenCalledTimes(4);
    expect(drafts.get("deal-a")?.previewUrl).toBe("blob:5");
  });

  it("keeps the note already typed when the image is swapped", () => {
    const u = urls();
    let drafts = putProofDraft(EMPTY, "deal-a", file("a.png"), "png", u);
    drafts = setProofCaption(drafts, "deal-a", "Nombre del remitente: Juan");
    drafts = putProofDraft(drafts, "deal-a", file("b.png"), "png", u);

    expect(drafts.get("deal-a")?.caption).toBe("Nombre del remitente: Juan");
  });

  it("does not mutate the map it was given", () => {
    const u = urls();
    const before = putProofDraft(EMPTY, "deal-a", file("a.png"), "png", u);
    const after = putProofDraft(before, "deal-b", file("b.png"), "png", u);

    expect(before.size).toBe(1);
    expect(after.size).toBe(2);
    expect(before).not.toBe(after);
  });
});

// DP-17
describe("drafts of different deals", () => {
  it("stay apart, each with its own file and note", () => {
    const u = urls();
    let drafts = putProofDraft(EMPTY, "deal-a", file("a.png"), "png", u);
    drafts = putProofDraft(drafts, "deal-b", file("b.png"), "png", u);
    drafts = setProofCaption(drafts, "deal-a", "para A");

    expect(drafts.get("deal-a")?.caption).toBe("para A");
    expect(drafts.get("deal-b")?.caption).toBe("");
    expect(drafts.get("deal-a")?.previewUrl).not.toBe(
      drafts.get("deal-b")?.previewUrl,
    );
  });

  it("removing one leaves the other untouched", () => {
    const u = urls();
    let drafts = putProofDraft(EMPTY, "deal-a", file("a.png"), "png", u);
    drafts = putProofDraft(drafts, "deal-b", file("b.png"), "png", u);
    drafts = removeProofDraft(drafts, "deal-a", u);

    expect(drafts.has("deal-a")).toBe(false);
    expect(drafts.get("deal-b")?.previewUrl).toBe("blob:2");
    expect(u.revokeUrl).toHaveBeenCalledExactlyOnceWith("blob:1");
  });

  it("has nothing for a deal that never got one", () => {
    const u = urls();
    const drafts = putProofDraft(EMPTY, "deal-a", file("a.png"), "png", u);
    expect(drafts.get("deal-b")).toBeUndefined();
  });
});

// DP-08
describe("removeProofDraft", () => {
  it("drops the draft and revokes its preview", () => {
    const u = urls();
    let drafts = putProofDraft(EMPTY, "deal-a", file("a.png"), "png", u);
    drafts = removeProofDraft(drafts, "deal-a", u);

    expect(drafts.size).toBe(0);
    expect(u.revokeUrl).toHaveBeenCalledWith("blob:1");
  });

  it("is a no-op for a deal with no draft", () => {
    const u = urls();
    const drafts = removeProofDraft(EMPTY, "deal-a", u);
    // Same reference, so React skips the re-render.
    expect(drafts).toBe(EMPTY);
    expect(u.revokeUrl).not.toHaveBeenCalled();
  });
});

describe("setProofCaption", () => {
  it("edits the note without touching the preview", () => {
    const u = urls();
    let drafts = putProofDraft(EMPTY, "deal-a", file("a.png"), "png", u);
    drafts = setProofCaption(drafts, "deal-a", "Nombre del remitente: Ana");

    expect(drafts.get("deal-a")?.caption).toBe("Nombre del remitente: Ana");
    expect(drafts.get("deal-a")?.previewUrl).toBe("blob:1");
    expect(u.revokeUrl).not.toHaveBeenCalled();
    expect(u.createUrl).toHaveBeenCalledTimes(1);
  });

  it("ignores a deal with no draft", () => {
    expect(setProofCaption(EMPTY, "deal-a", "hola")).toBe(EMPTY);
  });
});

describe("markProofSent", () => {
  it("stamps the wamid so a retry cannot re-send", () => {
    const u = urls();
    let drafts = putProofDraft(EMPTY, "deal-a", file("a.png"), "png", u);
    drafts = markProofSent(drafts, "deal-a", "wamid.ABC");
    expect(drafts.get("deal-a")?.sentWamid).toBe("wamid.ABC");
  });

  it("still marks it sent when Meta returned no wamid", () => {
    const u = urls();
    let drafts = putProofDraft(EMPTY, "deal-a", file("a.png"), "png", u);
    drafts = markProofSent(drafts, "deal-a", undefined);
    // The flag is what prevents the second send; the id is only useful
    // for tracing.
    expect(drafts.get("deal-a")?.sentWamid).toBeTruthy();
  });
});

describe("revokeAllPreviews", () => {
  it("revokes every live preview, for unmount", () => {
    const u = urls();
    let drafts = putProofDraft(EMPTY, "deal-a", file("a.png"), "png", u);
    drafts = putProofDraft(drafts, "deal-b", file("b.png"), "png", u);

    revokeAllPreviews(drafts, u);

    expect(u.revokeUrl).toHaveBeenCalledTimes(2);
    expect(u.revokeUrl).toHaveBeenCalledWith("blob:1");
    expect(u.revokeUrl).toHaveBeenCalledWith("blob:2");
  });

  it("does nothing when there are no drafts", () => {
    const u = urls();
    revokeAllPreviews(EMPTY, u);
    expect(u.revokeUrl).not.toHaveBeenCalled();
  });
});

// ---------------------------------------------------------------
// DRAFT-01 — the draft outlives the panel
//
// The panel unmounts every time the deal sheet closes. The draft
// must NOT: an operator who pastes a screenshot, closes the sheet
// to check something, and reopens it has to find their work there.
// That means no revoke on unmount of the panel — only on replace,
// remove, consume, or unmount of the whole board.
// ---------------------------------------------------------------

describe("closing and reopening the deal sheet", () => {
  it("leaves the draft and its preview untouched", () => {
    const u = urls();
    // open deal A → paste
    let drafts = putProofDraft(EMPTY, "deal-a", file("captura.png"), "png", u);
    drafts = setProofCaption(drafts, "deal-a", "Nombre del remitente: Juan");

    // close the sheet — nothing in the store is called; the panel
    // simply unmounts. Reopening reads the same entry back.
    const reopened = drafts.get("deal-a");

    expect(reopened?.previewUrl).toBe("blob:1");
    expect(reopened?.caption).toBe("Nombre del remitente: Juan");
    expect(reopened?.file).toBeDefined();
    // The URL handed to the <img> must still be alive.
    expect(u.revokeUrl).not.toHaveBeenCalled();
  });

  it("survives opening a different deal in between", () => {
    const u = urls();
    let drafts = putProofDraft(EMPTY, "deal-a", file("a.png"), "png", u);
    // open deal B (no proof), then come back to A
    drafts = setProofCaption(drafts, "deal-b", "ignored — B has no draft");

    expect(drafts.get("deal-a")?.previewUrl).toBe("blob:1");
    expect(u.revokeUrl).not.toHaveBeenCalled();
  });
});

// ---------------------------------------------------------------
// DRAFT-02 — someone else moved the deal
// ---------------------------------------------------------------

const PROOF_STAGE = "stage-lista-para-transferir";
const OTHER_STAGE = "stage-entregada";

describe("pruneStaleDrafts", () => {
  it("drops a draft whose deal left 'Lista para transferir'", () => {
    const u = urls();
    const drafts = putProofDraft(EMPTY, "deal-a", file("a.png"), "png", u);

    const pruned = pruneStaleDrafts(
      drafts,
      [{ id: "deal-a", stage_id: OTHER_STAGE }],
      PROOF_STAGE,
      u,
    );

    expect(pruned.has("deal-a")).toBe(false);
    expect(u.revokeUrl).toHaveBeenCalledWith("blob:1");
  });

  it("keeps a draft whose deal is still in the right stage", () => {
    const u = urls();
    const drafts = putProofDraft(EMPTY, "deal-a", file("a.png"), "png", u);

    const pruned = pruneStaleDrafts(
      drafts,
      [{ id: "deal-a", stage_id: PROOF_STAGE }],
      PROOF_STAGE,
      u,
    );

    // Same reference, so React skips the re-render.
    expect(pruned).toBe(drafts);
    expect(u.revokeUrl).not.toHaveBeenCalled();
  });

  it("prunes only the deals that moved", () => {
    const u = urls();
    let drafts = putProofDraft(EMPTY, "deal-a", file("a.png"), "png", u);
    drafts = putProofDraft(drafts, "deal-b", file("b.png"), "png", u);

    const pruned = pruneStaleDrafts(
      drafts,
      [
        { id: "deal-a", stage_id: OTHER_STAGE },
        { id: "deal-b", stage_id: PROOF_STAGE },
      ],
      PROOF_STAGE,
      u,
    );

    expect(pruned.has("deal-a")).toBe(false);
    expect(pruned.get("deal-b")?.previewUrl).toBe("blob:2");
    expect(u.revokeUrl).toHaveBeenCalledExactlyOnceWith("blob:1");
  });

  it("never prunes the delivery this tab is running", () => {
    const u = urls();
    const drafts = putProofDraft(EMPTY, "deal-a", file("a.png"), "png", u);

    // Our own send just moved it to Entregada; Realtime echoed it back.
    const pruned = pruneStaleDrafts(
      drafts,
      [{ id: "deal-a", stage_id: OTHER_STAGE }],
      PROOF_STAGE,
      u,
      { keepDealId: "deal-a" },
    );

    expect(pruned.get("deal-a")).toBeDefined();
    expect(u.revokeUrl).not.toHaveBeenCalled();
  });

  it("never prunes a draft whose image already reached the customer", () => {
    const u = urls();
    let drafts = putProofDraft(EMPTY, "deal-a", file("a.png"), "png", u);
    drafts = markProofSent(drafts, "deal-a", "wamid.SENT");

    const pruned = pruneStaleDrafts(
      drafts,
      [{ id: "deal-a", stage_id: OTHER_STAGE }],
      PROOF_STAGE,
      u,
    );

    // Dropping it would lose the "already sent" flag and let a later
    // drag re-send the same screenshot.
    expect(pruned.get("deal-a")?.sentWamid).toBe("wamid.SENT");
    expect(u.revokeUrl).not.toHaveBeenCalled();
  });

  it("treats an empty board as 'not loaded', not as 'everything is gone'", () => {
    const u = urls();
    const drafts = putProofDraft(EMPTY, "deal-a", file("a.png"), "png", u);

    const pruned = pruneStaleDrafts(drafts, [], PROOF_STAGE, u);

    expect(pruned).toBe(drafts);
    expect(u.revokeUrl).not.toHaveBeenCalled();
  });

  it("leaves a draft whose deal is absent from the loaded board", () => {
    const u = urls();
    const drafts = putProofDraft(EMPTY, "deal-a", file("a.png"), "png", u);

    // The board query filters by status and delivery window, so a
    // missing row does not reliably mean the deal moved.
    const pruned = pruneStaleDrafts(
      drafts,
      [{ id: "deal-z", stage_id: PROOF_STAGE }],
      PROOF_STAGE,
      u,
    );

    expect(pruned.get("deal-a")).toBeDefined();
    expect(u.revokeUrl).not.toHaveBeenCalled();
  });

  it("is a no-op with no drafts at all", () => {
    const u = urls();
    const pruned = pruneStaleDrafts(
      EMPTY,
      [{ id: "deal-a", stage_id: OTHER_STAGE }],
      PROOF_STAGE,
      u,
    );
    expect(pruned).toBe(EMPTY);
  });
});
