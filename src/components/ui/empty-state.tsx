import type { ComponentType, ReactNode } from 'react';
import { cn } from '@/lib/utils';

/**
 * The empty state for a page that has nothing to list yet.
 *
 * There were four of these, one per page, and no two agreed: Broadcasts
 * used a solid card with a bare grey icon, Notifications a dashed box
 * with a violet icon in a violet tile, Flows a dashed card with a grey
 * icon in a grey circle, and Resumen a plain rectangle with a line of
 * centred text and no icon at all. Heights ran 48 / 64 / whatever the
 * content came to, and each was a slightly different shade of "nothing
 * here". Same message, four costumes.
 *
 * The panel is capped and centred rather than stretched: at 1900px the
 * old ones drew a 1330px-wide dashed rectangle around two short lines
 * of text, which reads as a broken layout rather than a calm blank.
 */
export function EmptyState({
  title,
  description,
  icon: Icon,
  action,
  className,
}: {
  title: string;
  /** Optional. Say what would put something here. */
  description?: string;
  icon?: ComponentType<{ className?: string }>;
  /** The one thing to do next, if there is one. */
  action?: ReactNode;
  className?: string;
}) {
  return (
    <div
      className={cn(
        'border-border bg-card/40 flex flex-col items-center justify-center rounded-xl border border-dashed px-6 py-14 text-center',
        className
      )}
    >
      {Icon ? (
        <div className="bg-muted mb-4 flex size-12 items-center justify-center rounded-full">
          <Icon className="text-muted-foreground size-6" />
        </div>
      ) : null}
      <p className="text-foreground text-base font-medium">{title}</p>
      {description ? (
        <p className="text-muted-foreground mt-1.5 max-w-sm text-sm">
          {description}
        </p>
      ) : null}
      {action ? <div className="mt-5">{action}</div> : null}
    </div>
  );
}
