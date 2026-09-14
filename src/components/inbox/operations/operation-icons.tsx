import {
  ArrowDownToLine,
  Banknote,
  Circle,
  CircleCheck,
  CircleHelp,
  ClipboardList,
  Clock,
  CreditCard,
  FileSearch,
  Send,
  Smartphone,
  TriangleAlert,
  Users,
  type LucideIcon,
} from "lucide-react";

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

const MEDIUM = {
  wrap: "size-7",
  icon: "size-4",
  letter: "text-base",
};

const SMALL = {
  wrap: "size-5",
  icon: "size-3",
  letter: "text-[11px]",
};

export function MethodIcon({
  method,
  label,
  size = "md",
}: {
  method: string | null;
  label: string;
  size?: "sm" | "md";
}) {
  const kind = methodKind(method);
  const dims = size === "sm" ? SMALL : MEDIUM;

  if (kind === "zelle") {
    return (
      <span
        role="img"
        aria-label={label}
        title={label}
        className={`inline-flex shrink-0 items-center justify-center rounded-full bg-emerald-600 text-white ${dims.wrap}`}
      >
        <span className={`font-black leading-none ${dims.letter}`}>Z</span>
      </span>
    );
  }

  const { className, Icon } = METHOD_STYLE[kind];
  return (
    <span
      role="img"
      aria-label={label}
      title={label}
      className={`inline-flex shrink-0 items-center justify-center rounded-full ${className} ${dims.wrap}`}
    >
      <Icon className={dims.icon} aria-hidden="true" />
    </span>
  );
}

const STATUS_STYLE: Record<string, { className: string; Icon: LucideIcon }> = {
  collecting_information: {
    className: "bg-slate-100 text-slate-700 dark:bg-slate-500/15 dark:text-slate-300",
    Icon: ClipboardList,
  },
  awaiting_deposit: {
    className: "bg-amber-100 text-amber-800 dark:bg-amber-500/15 dark:text-amber-300",
    Icon: Clock,
  },
  deposit_received: {
    className: "bg-sky-100 text-sky-800 dark:bg-sky-500/15 dark:text-sky-300",
    Icon: ArrowDownToLine,
  },
  deposit_verification: {
    className: "bg-blue-100 text-blue-800 dark:bg-blue-500/15 dark:text-blue-300",
    Icon: FileSearch,
  },
  ready_to_transfer: {
    className: "bg-emerald-100 text-emerald-800 dark:bg-emerald-500/15 dark:text-emerald-300",
    Icon: CircleCheck,
  },
  transferring: {
    className: "bg-indigo-100 text-indigo-800 dark:bg-indigo-500/15 dark:text-indigo-300",
    Icon: Send,
  },
  incident: {
    className: "bg-red-100 text-red-800 dark:bg-red-500/15 dark:text-red-300",
    Icon: TriangleAlert,
  },
};

const STATUS_FALLBACK = { className: "bg-muted text-muted-foreground", Icon: Circle };

export function StatusChip({ status, label }: { status: string; label: string }) {
  const { className, Icon } = STATUS_STYLE[status] ?? STATUS_FALLBACK;
  return (
    <span
      className={`inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-[11px] font-medium whitespace-nowrap ${className}`}
    >
      <Icon className="size-3" aria-hidden="true" />
      {label}
    </span>
  );
}

export const KNOWN_BENEFICIARY_TYPES: ReadonlyArray<string> = [
  "cuban_card",
  "zelle",
  "clasica",
  "tropical",
  "multiple_distribution",
];
