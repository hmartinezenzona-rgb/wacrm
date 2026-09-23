import type { ComponentType, ReactNode } from 'react';
import { cn } from '@/lib/utils';

/**
 * The one page-title block for the whole dashboard.
 *
 * Before this existed every page hand-rolled its own header, and they
 * had drifted apart: `text-2xl font-bold`, `text-2xl font-semibold`,
 * `text-2xl font-bold tracking-tight` and `text-xl font-semibold` were
 * all in use, three pages wrapped the actions in a flex row and the
 * rest didn't, and one page prefixed the title with an icon nobody
 * else had. Same job, nine spellings.
 *
 * It also owns the `<h1>`. The top bar used to render one too, so
 * every screen shipped two `<h1>`s saying the same word ("Contacts"
 * over "Contacts"). The top bar now renders a breadcrumb instead, and
 * this is the page's only heading.
 */
export function PageHeader({
  title,
  description,
  actions,
  icon: Icon,
  className,
}: {
  title: string;
  /** One line. Says what the page is for — not what the title already says. */
  description?: string;
  /** Buttons. Right-aligned on sm+, stacked under the title on mobile. */
  actions?: ReactNode;
  /** Rarely useful. Only pass it where the icon carries meaning. */
  icon?: ComponentType<{ className?: string }>;
  className?: string;
}) {
  return (
    <div
      className={cn(
        'flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between sm:gap-4',
        className
      )}
    >
      <div className="min-w-0">
        <h1 className="text-foreground flex items-center gap-2 text-xl font-semibold tracking-tight sm:text-2xl">
          {Icon ? (
            <Icon className="text-muted-foreground size-5 shrink-0" />
          ) : null}
          <span className="truncate">{title}</span>
        </h1>
        {description ? (
          // Capped at ~75 characters per line. Left uncapped these ran
          // the full 1900px of a wide monitor as a single line of 10pt
          // grey text, which is nobody's idea of readable.
          <p className="text-muted-foreground mt-1 max-w-prose text-sm">
            {description}
          </p>
        ) : null}
      </div>
      {actions ? (
        <div className="flex shrink-0 flex-wrap items-center gap-2">
          {actions}
        </div>
      ) : null}
    </div>
  );
}

/**
 * Width cap + vertical rhythm for a normal content page.
 *
 * Deliberately *not* applied in the dashboard shell's `<main>`: Inbox
 * and Pipelines are full-bleed by design (a three-pane split and a
 * horizontally-scrolling board), and both cancel `main`'s padding with
 * a negative margin. Capping them there would have fought that.
 *
 * 1600px keeps a four-up metric grid honest while stopping table rows
 * from stretching label-left / value-right across an entire ultrawide.
 */
export function PageShell({
  children,
  className,
}: {
  children: ReactNode;
  className?: string;
}) {
  return (
    <div className={cn('mx-auto w-full max-w-[1600px] space-y-6', className)}>
      {children}
    </div>
  );
}
