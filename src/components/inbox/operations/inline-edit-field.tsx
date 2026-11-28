"use client";

import type { ReactNode } from "react";

interface InlineEditFieldProps {
  id?: string;
  /** Small (14px) leading icon, muted — matches the copy chip it replaces. */
  icon: ReactNode;
  value: string;
  onChange: (value: string) => void;
  placeholder: string;
  ariaLabel: string;
  disabled?: boolean;
  inputMode?: "numeric" | "decimal";
  /** "name" renders sans-serif text-sm, matching the read-only name chip;
   *  every other field ("mono", the default) renders font-mono text-xs,
   *  matching every other read-only chip. */
  variant?: "mono" | "name";
  /** Focus the input on mount — set on the first field of an edit session. */
  autoFocus?: boolean;
}

/**
 * One inline-editable data row inside a beneficiary's edit mode. Visually
 * replaces a read-only `CopyChip` in the same position: same leading icon,
 * full width, h-8, transparent with only a bottom rule (the field reads as
 * the same row that became editable, not a boxed form), the rule turning to
 * the ring colour plus a soft ring on the wrapper on focus (so clicking the
 * icon area focuses the input too).
 */
export function InlineEditField({
  id,
  icon,
  value,
  onChange,
  placeholder,
  ariaLabel,
  disabled = false,
  inputMode,
  variant = "mono",
  autoFocus = false,
}: InlineEditFieldProps) {
  const textClassName = variant === "name" ? "font-sans text-sm font-medium" : "font-mono text-xs";

  return (
    <div className="flex h-8 w-full items-center gap-1.5 rounded-sm border-b border-input bg-transparent px-1 transition-colors focus-within:border-ring focus-within:ring-2 focus-within:ring-ring/30">
      <span className="flex size-3.5 shrink-0 items-center justify-center text-muted-foreground" aria-hidden="true">
        {icon}
      </span>
      <input
        id={id}
        type="text"
        value={value}
        placeholder={placeholder}
        aria-label={ariaLabel}
        disabled={disabled}
        inputMode={inputMode}
        autoFocus={autoFocus}
        onChange={(event) => onChange(event.target.value)}
        className={`min-w-0 flex-1 bg-transparent outline-none placeholder:text-muted-foreground disabled:cursor-not-allowed disabled:opacity-60 ${textClassName}`}
      />
    </div>
  );
}
