'use client';

// ============================================================
// /agents — now the Hermes chat
//
// The old "AI agents" page (OpenAI/Anthropic playground, unused in
// production) is replaced by the admin's chat with Hermes, which runs on the
// owner's VPS and reaches the CRM through the read-only MCP tools.
// ============================================================

import { useTranslations } from 'next-intl';

import { HermesChat } from '@/components/hermes/hermes-chat';
import { PageHeader, PageShell } from '@/components/layout/page-header';

export default function AgentsPage() {
  const t = useTranslations('Hermes');
  return (
    <PageShell>
      <PageHeader title={t('title')} description={t('desc')} />
      <HermesChat />
    </PageShell>
  );
}
