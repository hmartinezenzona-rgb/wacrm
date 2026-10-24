'use client';

// ============================================================
// GroupLinkCard — Settings → Templates
//
// The WhatsApp template button points at the panel's public /grupo route
// (Meta rejects chat.whatsapp.com links inside buttons), and that route
// redirects to the group invite stored here. Changing the group is a
// one-field edit: the approved template keeps working.
// ============================================================

import { useEffect, useState } from 'react';
import { useTranslations } from 'next-intl';
import { Loader2 } from 'lucide-react';
import { toast } from 'sonner';

import { Button } from '@/components/ui/button';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Input } from '@/components/ui/input';

export function GroupLinkCard() {
  const t = useTranslations('Settings.templates');
  const [url, setUrl] = useState('');
  const [defecto, setDefecto] = useState('');
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    let cancel = false;
    void (async () => {
      try {
        const res = await fetch('/api/settings/group-link', { cache: 'no-store' });
        const data = await res.json().catch(() => ({}));
        if (!cancel && res.ok) {
          setUrl(typeof data.url === 'string' ? data.url : '');
          setDefecto(typeof data.default_url === 'string' ? data.default_url : '');
        }
      } finally {
        if (!cancel) setLoading(false);
      }
    })();
    return () => {
      cancel = true;
    };
  }, []);

  async function guardar() {
    setSaving(true);
    try {
      const res = await fetch('/api/settings/group-link', {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ url: url.trim() }),
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) {
        throw new Error(
          typeof data.error === 'string'
            ? data.error
            : t('groupLinkFailed', { status: res.status }),
        );
      }
      toast.success(t('groupLinkSaved'));
    } catch (err) {
      toast.error(err instanceof Error ? err.message : t('groupLinkFailed', { status: 0 }));
    } finally {
      setSaving(false);
    }
  }

  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-base">{t('groupLinkTitle')}</CardTitle>
        <CardDescription>{t('groupLinkDesc')}</CardDescription>
      </CardHeader>
      <CardContent className="space-y-3">
        <Input
          value={url}
          onChange={(event) => setUrl(event.target.value)}
          placeholder={defecto || 'https://chat.whatsapp.com/…'}
          disabled={loading || saving}
        />
        <div className="flex flex-wrap items-center gap-2">
          <Button onClick={guardar} disabled={loading || saving}>
            {saving ? <Loader2 className="h-4 w-4 animate-spin" /> : null}
            {t('groupLinkSave')}
          </Button>
          {defecto ? (
            <span className="text-xs text-muted-foreground">
              {t('groupLinkDefault', { url: defecto })}
            </span>
          ) : null}
        </div>
      </CardContent>
    </Card>
  );
}
