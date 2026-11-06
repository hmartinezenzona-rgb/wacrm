import { describe, expect, it } from "vitest";
import { parseDeleteRefusal } from "./delete-refusal";

describe("parseDeleteRefusal", () => {
  it.each([
    "an operation that is cancelled cannot be deleted",
    "an operation that is completed cannot be deleted",
  ])("maps %s to alreadyClosed", (message) => {
    expect(parseDeleteRefusal(message, 400)).toBe("alreadyClosed");
  });

  it("maps a verified deposit to verifiedDeposit", () => {
    expect(parseDeleteRefusal("an operation with a verified deposit cannot be deleted", 400)).toBe("verifiedDeposit");
  });

  it("maps the RPC owner/admin refusal and any 403 to notAdmin", () => {
    expect(parseDeleteRefusal("only an owner or admin can delete an operation", 400)).toBe("notAdmin");
    expect(parseDeleteRefusal("Forbidden", 403)).toBe("notAdmin");
  });

  it("returns null for anything else so the caller shows the server text", () => {
    expect(parseDeleteRefusal("an operation that is transferring cannot be deleted", 400)).toBeNull();
    expect(parseDeleteRefusal("Request failed", 500)).toBeNull();
  });
});
