import { describe, expect, it } from "vitest";
import { contactAvatarDataUri } from "./contact-avatar";

describe("contactAvatarDataUri", () => {
  it("returns an SVG data URI", () => {
    const uri = contactAvatarDataUri("contact-1");
    expect(uri.startsWith("data:image/svg+xml")).toBe(true);
    expect(decodeURIComponent(uri)).toContain("<svg");
  });

  it("is stable for the same seed", () => {
    expect(contactAvatarDataUri("contact-1")).toBe(contactAvatarDataUri("contact-1"));
  });

  it("differs between seeds", () => {
    expect(contactAvatarDataUri("contact-1")).not.toBe(contactAvatarDataUri("contact-2"));
  });

  it("only uses the soft pastel palette for the background", () => {
    const svg = decodeURIComponent(contactAvatarDataUri("contact-3"));
    const palette = ["c0aede", "d1d4f9", "ffd5dc", "ffdfbf", "b6e3f4"];
    expect(palette.some((hex) => svg.toLowerCase().includes(`#${hex}`))).toBe(true);
  });
});
