import { cn } from "@/lib/utils";

/** A notice on a neutral ground in the page's own text colour; an amber dot (green for good news) carries the tone, never coloured text. */
export function Notice({ children, tone = "warn" }: { children: string; tone?: "warn" | "ok" }) {
  return (
    <div data-warning className="mb-2 flex items-start gap-2 rounded-md bg-muted px-2.5 py-1.5 text-xs text-foreground" role="status">
      <span data-warning-dot aria-hidden="true" className={cn("mt-1 size-2 shrink-0 rounded-full", tone === "ok" ? "bg-money-profit" : "bg-amber-500")} />
      <span>{children}</span>
    </div>
  );
}
