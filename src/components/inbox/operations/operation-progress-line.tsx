import { PROGRESS_STEPS } from "@/lib/remittance-operations/progress-step";

/** 4 steps with connecting lines plus the "Step n of 4" text. Done steps are success, the current one has a primary ring,
 *  pending ones are muted. Decorative dots are hidden from assistive tech; the text carries the meaning. */
export function OperationProgressLine({ step, label }: { step: number; label: string }) {
  const steps = Array.from({ length: PROGRESS_STEPS }, (_, i) => i + 1);
  return (
    <div data-testid="operation-progress" data-step={step} className="mt-1 flex items-center gap-1">
      {steps.map((n) => (
        <span key={n} aria-hidden="true" className="contents">
          {n > 1 && <span className={`h-0.5 flex-1 rounded-full ${n <= step ? "bg-status-success" : "bg-border"}`} />}
          <span
            className={
              n < step
                ? "size-2 shrink-0 rounded-full bg-status-success"
                : n === step
                  ? "box-border size-2.5 shrink-0 rounded-full border-2 border-primary bg-card"
                  : "size-2 shrink-0 rounded-full bg-border"
            }
          />
        </span>
      ))}
      <span className="ml-1.5 text-[10px] text-muted-foreground">{label}</span>
    </div>
  );
}
