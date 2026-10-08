import { statusPillClass, statusTone } from "@/lib/status-tone";

/**
 * An operation status as a small tinted label. `label` is the already translated status name; the tone comes from
 * the raw `status` (unknown values are neutral), so the text always says what the colour means.
 */
export function StatusPill({ status, label }: { status: string; label: string }) {
  const tone = statusTone(status);
  return (
    <span
      data-tone={tone}
      className={`inline-flex items-center whitespace-nowrap rounded-full px-2 text-xs font-medium leading-5 ${statusPillClass[tone]}`}
    >
      {label}
    </span>
  );
}
