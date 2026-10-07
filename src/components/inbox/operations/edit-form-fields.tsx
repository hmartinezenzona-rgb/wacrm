"use client";

import type { ComponentProps, ReactNode } from "react";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { cn } from "@/lib/utils";

/**
 * Shared look of the panel's edit fields: transparent, a bottom rule, no side
 * or top borders, h-8 / text-sm, the rule turning to the ring colour on focus.
 * Tokens only, so it reads the same in the light and dark themes.
 */
export const UNDERLINE_FIELD =
  "h-8 rounded-none border-0 border-b border-input bg-transparent px-1 text-sm shadow-none focus-visible:border-ring focus-visible:ring-2 focus-visible:ring-ring/30 disabled:bg-transparent dark:bg-transparent dark:disabled:bg-transparent";

/** Same look for a Select trigger (full width). */
export const UNDERLINE_SELECT_TRIGGER = `${UNDERLINE_FIELD} w-full min-w-0 justify-between py-0 pl-1 pr-1 data-[size=default]:h-8 dark:hover:bg-transparent`;

export const FIELD_LABEL = "text-[11px] font-normal text-muted-foreground";

export function UnderlineInput({ className, ...props }: ComponentProps<typeof Input>) {
  return <Input className={cn(UNDERLINE_FIELD, className)} {...props} />;
}

/** One label-left row: small muted label, then the field filling the rest. */
export function FieldRow({ label, htmlFor, children }: { label: string; htmlFor: string; children: ReactNode }) {
  return (
    <div className="grid grid-cols-[5.5rem_1fr] items-center gap-x-2">
      <Label htmlFor={htmlFor} className={`${FIELD_LABEL} truncate`} title={label}>
        {label}
      </Label>
      {children}
    </div>
  );
}

/** Two short fields side by side, each with its small label on top. */
export function FieldPair({ children }: { children: ReactNode }) {
  return <div className="grid grid-cols-2 gap-x-2">{children}</div>;
}

export function PairCell({ label, htmlFor, children }: { label: string; htmlFor: string; children: ReactNode }) {
  return (
    <div className="min-w-0">
      <Label htmlFor={htmlFor} className={`${FIELD_LABEL} block truncate`} title={label}>
        {label}
      </Label>
      {children}
    </div>
  );
}

/** Left rule that marks an edit area as part of the card without boxing it. */
export const EDIT_AREA = "space-y-1 border-l-2 border-border pl-2";
