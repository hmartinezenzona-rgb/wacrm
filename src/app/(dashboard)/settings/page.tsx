'use client';

import { useMemo, useState, type ReactNode } from 'react';
import { useRouter, useSearchParams } from 'next/navigation';
import { useTranslations } from 'next-intl';

import { useAuth } from '@/hooks/use-auth';
import { useTheme } from '@/hooks/use-theme';
import { SettingsRail } from '@/components/settings/settings-rail';
import { SettingsOverview } from '@/components/settings/settings-overview';
import { ProfileForm } from '@/components/settings/profile-form';
import { SecurityPanel } from '@/components/settings/security-panel';
import { AppearancePanel } from '@/components/settings/appearance-panel';
import { WhatsAppConfig } from '@/components/settings/whatsapp-config';
import { TemplateManager } from '@/components/settings/template-manager';
import { QuickRepliesManager } from '@/components/settings/quick-replies-manager';
import { FieldsAndTagsPanel } from '@/components/settings/fields-and-tags-panel';
import { DealsSettings } from '@/components/settings/deals-settings';
import { MembersTab } from '@/components/settings/members-tab';
import { ApiKeysSettings } from '@/components/settings/api-keys-settings';
import { PageHeader, PageShell } from '@/components/layout/page-header';
import {
  resolveSection,
  type SettingsSection,
} from '@/components/settings/settings-sections';

export default function SettingsPage() {
  const router = useRouter();
  const searchParams = useSearchParams();
  const { defaultCurrency } = useAuth();
  const { mode } = useTheme();
  const t = useTranslations('Settings');

  // `?tab=` stays the deep link — the sidebar and the account menu both
  // point at `/settings?tab=...` and bookmarks must keep working — but it
  // is no longer what the UI *reads*.
  //
  // Why: this route is prerendered (`○ /settings` in the build output) and
  // reads its state through `useSearchParams()`. On a prerendered route a
  // `router.replace()` that changes only the query did not come back
  // through that hook, so `section` never moved: land on
  // `/settings?tab=deals` and every item in the rail stopped working —
  // no error, no spinner, just a dead menu. Arriving with a `?tab=` in
  // the URL is the normal case, not an edge one: both entries in the
  // account menu link that way, and so does any reload.
  //
  // It only reproduces in a production build. Next's own docs note that
  // "in development, routes are rendered on-demand, so `useSearchParams`
  // doesn't suspend and things may appear to work without `Suspense`" —
  // which is exactly why `next dev` looked fine while the deployed site
  // did not.
  //
  // The fix is to stop depending on the router echoing the change back.
  // `override` holds a locally-chosen section and stays in force only
  // while the URL is the one it was chosen from; the moment the URL
  // really changes — back/forward, an account-menu link, a fresh load —
  // it stops applying and the URL wins again. No effect, no clobbering,
  // and correct whether or not the hook updates.
  const urlTab = searchParams.get('tab');
  const [override, setOverride] = useState<{
    from: string | null;
    section: SettingsSection;
  } | null>(null);

  const section =
    override && override.from === urlTab
      ? override.section
      : resolveSection(urlTab);

  const go = (next: SettingsSection) => {
    setOverride({ from: urlTab, section: next });
    const params = new URLSearchParams(searchParams.toString());
    params.set('tab', next);
    router.replace(`/settings?${params.toString()}`, { scroll: false });
  };

  // Cheap, fetch-free rail hints. The Overview landing carries the
  // full live status/counts; the rail just surfaces the two that are
  // already in context.
  const hints: Partial<Record<SettingsSection, ReactNode>> = useMemo(
    () => ({
      appearance: mode.charAt(0).toUpperCase() + mode.slice(1),
      deals: defaultCurrency,
    }),
    [mode, defaultCurrency],
  );

  const panel: Record<SettingsSection, ReactNode> = {
    overview: <SettingsOverview onSelect={go} />,
    profile: <ProfileForm />,
    security: <SecurityPanel />,
    appearance: <AppearancePanel />,
    whatsapp: <WhatsAppConfig />,
    templates: <TemplateManager />,
    'quick-replies': <QuickRepliesManager />,
    fields: <FieldsAndTagsPanel />,
    deals: <DealsSettings />,
    members: <MembersTab />,
    api: <ApiKeysSettings />,
  };

  return (
    <PageShell>
      <PageHeader title={t('pageTitle')} description={t('pageDesc')} />

      <div className="grid gap-6 lg:grid-cols-[236px_minmax(0,1fr)] lg:items-start">
        <SettingsRail active={section} onSelect={go} hints={hints} />
        <div className="min-w-0">{panel[section]}</div>
      </div>
    </PageShell>
  );
}
