// Pure geometry helpers for the receipt review viewer. Ported from the
// Hermes reference (apps/wacrm/src/components/inbox/operations/
// viewer-geometry.ts) — no behavior change, just relocated into this repo.

export interface Point {
  x: number;
  y: number;
}

export interface ViewerTransform extends Point {
  scale: number;
}

export const MIN_RECEIPT_SCALE = 1;
export const MAX_RECEIPT_SCALE = 5;

export function clampScale(scale: number): number {
  return Math.min(MAX_RECEIPT_SCALE, Math.max(MIN_RECEIPT_SCALE, scale));
}

export function distanceBetween(a: Point, b: Point): number {
  return Math.hypot(b.x - a.x, b.y - a.y);
}

/** Returns a new transform whose `scale` is `requestedScale` (clamped to
 *  the supported bounds) while keeping the image point under `focus` fixed
 *  on screen — i.e. zooming in/out around the cursor or pinch centroid
 *  instead of the image's top-left corner. */
export function zoomAroundPoint(
  current: ViewerTransform,
  requestedScale: number,
  focus: Point,
): ViewerTransform {
  const scale = clampScale(requestedScale);
  if (scale === current.scale) return current;
  const ratio = scale / current.scale;
  return {
    scale,
    x: focus.x - (focus.x - current.x) * ratio,
    y: focus.y - (focus.y - current.y) * ratio,
  };
}
