"use client";

import { useCallback, useRef, useState, type PointerEvent, type WheelEvent } from "react";
import { useTranslations } from "next-intl";
import { toChatMediaSrc } from "@/lib/storage/chat-media";
import { Minus, Plus, RotateCcw } from "lucide-react";
import { distanceBetween, zoomAroundPoint, type Point, type ViewerTransform } from "./viewer-geometry";

interface ReceiptReviewViewerProps {
  src: string;
  alt: string;
}

const INITIAL_TRANSFORM: ViewerTransform = { scale: 1, x: 0, y: 0 };

/**
 * Pinch/wheel/drag zoomable image viewer for one deposit receipt. Ported
 * from the Hermes reference (apps/wacrm/.../receipt-review-viewer.tsx) —
 * same interaction logic (`viewer-geometry.ts`), i18n copy instead of
 * hardcoded Spanish, and a plain `{ src, alt }` contract so the caller
 * decides what image and accessible name to show.
 */
export function ReceiptReviewViewer({ src, alt }: ReceiptReviewViewerProps) {
  const t = useTranslations("Inbox.operationsPanel");
  const viewportRef = useRef<HTMLDivElement>(null);
  const pointers = useRef(new Map<number, Point>());
  const lastPinchDistance = useRef<number | null>(null);
  const [transform, setTransform] = useState(INITIAL_TRANSFORM);

  const zoomAtCenter = useCallback((factor: number) => {
    const viewport = viewportRef.current;
    const focus = viewport
      ? { x: viewport.clientWidth / 2, y: viewport.clientHeight / 2 }
      : { x: 120, y: 90 };
    setTransform((current) => zoomAroundPoint(current, current.scale * factor, focus));
  }, []);

  const handlePointerDown = (event: PointerEvent<HTMLDivElement>) => {
    try {
      event.currentTarget.setPointerCapture(event.pointerId);
    } catch {
      // Some embedded browsers do not expose pointer capture; pan/pinch still work.
    }
    const point = { x: event.clientX, y: event.clientY };
    pointers.current.set(event.pointerId, point);
    if (pointers.current.size === 2) {
      const [a, b] = [...pointers.current.values()];
      lastPinchDistance.current = distanceBetween(a, b);
    }
  };

  const handlePointerMove = (event: PointerEvent<HTMLDivElement>) => {
    if (!pointers.current.has(event.pointerId)) return;
    const previous = pointers.current.get(event.pointerId)!;
    const next = { x: event.clientX, y: event.clientY };
    pointers.current.set(event.pointerId, next);

    if (pointers.current.size === 2) {
      const [a, b] = [...pointers.current.values()];
      const distance = distanceBetween(a, b);
      const priorDistance = lastPinchDistance.current;
      const rect = event.currentTarget.getBoundingClientRect();
      if (priorDistance && distance > 0) {
        const focus = {
          x: (a.x + b.x) / 2 - rect.left,
          y: (a.y + b.y) / 2 - rect.top,
        };
        setTransform((current) =>
          zoomAroundPoint(current, current.scale * (distance / priorDistance), focus),
        );
      }
      lastPinchDistance.current = distance;
      return;
    }

    setTransform((current) =>
      current.scale === 1
        ? current
        : { ...current, x: current.x + next.x - previous.x, y: current.y + next.y - previous.y },
    );
  };

  const releasePointer = (event: PointerEvent<HTMLDivElement>) => {
    pointers.current.delete(event.pointerId);
    lastPinchDistance.current = null;
  };

  const handleWheel = (event: WheelEvent<HTMLDivElement>) => {
    event.preventDefault();
    const rect = event.currentTarget.getBoundingClientRect();
    setTransform((current) =>
      zoomAroundPoint(current, current.scale * (event.deltaY < 0 ? 1.18 : 0.85), {
        x: event.clientX - rect.left,
        y: event.clientY - rect.top,
      }),
    );
  };

  return (
    <div className="space-y-2">
      <div className="flex items-center justify-between gap-2">
        <p className="text-[11px] font-semibold uppercase tracking-wider text-muted-foreground">
          {t("depositReview.receipt")}
        </p>
        <span className="text-[10px] tabular-nums text-muted-foreground">
          {Math.round(transform.scale * 100)}%
        </span>
      </div>
      <div
        ref={viewportRef}
        aria-label={t("viewer.hint")}
        className="relative h-44 w-full touch-none overflow-hidden rounded-lg border border-border bg-slate-950 select-none"
        onWheel={handleWheel}
        onPointerDown={handlePointerDown}
        onPointerMove={handlePointerMove}
        onPointerUp={releasePointer}
        onPointerCancel={releasePointer}
      >
        {/* eslint-disable-next-line @next/next/no-img-element */}
        <img
          src={toChatMediaSrc(src)}
          alt={alt}
          draggable={false}
          className="pointer-events-none absolute inset-0 h-full w-full object-contain"
          style={{
            transform: `translate3d(${transform.x}px, ${transform.y}px, 0) scale(${transform.scale})`,
            transformOrigin: "0 0",
          }}
        />
      </div>
      <div className="flex items-center gap-1">
        <button
          type="button"
          onClick={() => zoomAtCenter(0.8)}
          aria-label={t("viewer.zoomOut")}
          className="flex h-9 flex-1 items-center justify-center rounded-md border border-border bg-card hover:bg-muted"
        >
          <Minus className="h-4 w-4" />
        </button>
        <button
          type="button"
          onClick={() => zoomAtCenter(1.25)}
          aria-label={t("viewer.zoomIn")}
          className="flex h-9 flex-1 items-center justify-center rounded-md border border-border bg-card hover:bg-muted"
        >
          <Plus className="h-4 w-4" />
        </button>
        <button
          type="button"
          onClick={() => setTransform(INITIAL_TRANSFORM)}
          aria-label={t("viewer.reset")}
          className="flex h-9 flex-1 items-center justify-center rounded-md border border-border bg-card hover:bg-muted"
        >
          <RotateCcw className="h-4 w-4" />
        </button>
      </div>
    </div>
  );
}
