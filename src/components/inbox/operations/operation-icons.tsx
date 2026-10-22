import { Banknote, CircleHelp, CreditCard, Smartphone, Users, type LucideIcon } from "lucide-react";
import { statusPillClass, statusTone } from "@/lib/status-tone";

/** Delivery/deposit method values are free-form strings from the RPC layer;
 *  this normalizes the known ones into a small set of visual kinds. */
export type MethodKind = "cuban_card" | "zelle" | "cash" | "multiple" | "mobile_money" | "unknown";

export function methodKind(method: string | null): MethodKind {
  switch (method) {
    case "cuban_card":
      return "cuban_card";
    case "zelle":
      return "zelle";
    case "clasica":
    case "tropical":
    case "efectivo_usd":
      return "cash";
    case "multiple_distribution":
      return "multiple";
    case "mmg":
      return "mobile_money";
    default:
      return "unknown";
  }
}

const METHOD_STYLE: Record<Exclude<MethodKind, "zelle">, { className: string; Icon: LucideIcon }> = {
  cuban_card: { className: "bg-blue-100 text-blue-700 dark:bg-blue-500/15 dark:text-blue-300", Icon: CreditCard },
  cash: { className: "bg-amber-100 text-amber-700 dark:bg-amber-500/15 dark:text-amber-300", Icon: Banknote },
  multiple: { className: "bg-violet-100 text-violet-700 dark:bg-violet-500/15 dark:text-violet-300", Icon: Users },
  mobile_money: {
    className: "bg-teal-100 text-teal-700 dark:bg-teal-500/15 dark:text-teal-300",
    Icon: Smartphone,
  },
  unknown: { className: "bg-muted text-muted-foreground", Icon: CircleHelp },
};

export function MethodIcon({ method, label }: { method: string | null; label: string }) {
  const kind = methodKind(method);

  if (kind === "zelle") {
    return (
      <span
        role="img"
        aria-label={label}
        title={label}
        className="inline-flex size-5 shrink-0 items-center justify-center rounded-full bg-emerald-600 text-white"
      >
        <span className="text-[11px] font-black leading-none">Z</span>
      </span>
    );
  }

  const { className, Icon } = METHOD_STYLE[kind];
  return (
    <span
      role="img"
      aria-label={label}
      title={label}
      className={`inline-flex size-5 shrink-0 items-center justify-center rounded-full ${className}`}
    >
      <Icon className="size-3" aria-hidden="true" />
    </span>
  );
}

/** A soft pill (dot + label); its colours are the shared status tone (`status-tone.ts`, same tokens as StatusPill),
 *  reused by the dot via `currentColor`. */
export function StatusChip({ status, label }: { status: string; label: string }) {
  const tone = statusPillClass[statusTone(status)];
  return (
    <span className={`inline-flex items-center gap-1.5 rounded-full px-2 py-0.5 text-[11px] font-bold whitespace-nowrap ${tone}`}>
      <span className="size-1.5 shrink-0 rounded-full bg-current" aria-hidden="true" />
      {label}
    </span>
  );
}

export const KNOWN_BENEFICIARY_TYPES: ReadonlyArray<string> = [
  "cuban_card",
  "zelle",
  "clasica",
  "tropical",
  "efectivo_usd",
  "multiple_distribution",
  "recarga",
  "combo",
  "visa",
  "saldo",
];
