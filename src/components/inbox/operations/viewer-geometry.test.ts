// Pure geometry helpers for the receipt review viewer (ported from the
// Hermes reference apps/wacrm/src/components/inbox/operations/
// viewer-geometry.ts): zooming keeps the point under the cursor/pinch
// centroid fixed on screen, scale is clamped to the viewer's supported
// bounds, and distanceBetween is the plain Euclidean distance used to
// detect pinch changes.

import { describe, expect, it } from "vitest";
import {
  MAX_RECEIPT_SCALE,
  MIN_RECEIPT_SCALE,
  clampScale,
  distanceBetween,
  zoomAroundPoint,
  type ViewerTransform,
} from "./viewer-geometry";

describe("clampScale", () => {
  it("clamps below the minimum up to MIN_RECEIPT_SCALE", () => {
    expect(clampScale(0.2)).toBe(MIN_RECEIPT_SCALE);
  });

  it("clamps above the maximum down to MAX_RECEIPT_SCALE", () => {
    expect(clampScale(50)).toBe(MAX_RECEIPT_SCALE);
  });

  it("passes through an in-range scale unchanged", () => {
    expect(clampScale(2.5)).toBe(2.5);
  });
});

describe("distanceBetween", () => {
  it("computes the Euclidean distance between two points", () => {
    expect(distanceBetween({ x: 0, y: 0 }, { x: 3, y: 4 })).toBe(5);
  });

  it("is zero for coincident points", () => {
    expect(distanceBetween({ x: 10, y: 10 }, { x: 10, y: 10 })).toBe(0);
  });
});

describe("zoomAroundPoint", () => {
  it("keeps the focus point fixed on screen when zooming in", () => {
    const current: ViewerTransform = { scale: 1, x: 0, y: 0 };
    const focus = { x: 50, y: 40 };

    const next = zoomAroundPoint(current, 2, focus);

    // The point under the cursor in image space must map back to the same
    // screen coordinate before and after the zoom: screen = focus*scale + t.
    const screenBefore = { x: focus.x * current.scale + current.x, y: focus.y * current.scale + current.y };
    const screenAfter = { x: focus.x * next.scale + next.x, y: focus.y * next.scale + next.y };
    expect(screenAfter.x).toBeCloseTo(screenBefore.x);
    expect(screenAfter.y).toBeCloseTo(screenBefore.y);
    expect(next.scale).toBe(2);
  });

  it("clamps the requested scale to the supported bounds", () => {
    const current: ViewerTransform = { scale: 1, x: 0, y: 0 };

    expect(zoomAroundPoint(current, 100, { x: 0, y: 0 }).scale).toBe(MAX_RECEIPT_SCALE);
    expect(zoomAroundPoint(current, 0.1, { x: 0, y: 0 }).scale).toBe(MIN_RECEIPT_SCALE);
  });

  it("returns the same transform unchanged when the clamped scale doesn't change", () => {
    const current: ViewerTransform = { scale: MAX_RECEIPT_SCALE, x: 5, y: 5 };

    const next = zoomAroundPoint(current, 999, { x: 10, y: 10 });

    expect(next).toBe(current);
  });
});
