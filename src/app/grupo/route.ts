import { NextResponse } from 'next/server';

import { leerGrupoUrl } from '@/lib/settings/group-link';

export const dynamic = 'force-dynamic';

// Public redirect used by the WhatsApp template button: Meta rejects
// chat.whatsapp.com links inside buttons (error 2388081), so the approved
// template points at this path and the redirect resolves the real invite.
// The destination is editable from Settings; changing the group never
// requires re-approving the template or republishing the panel.
export async function GET(): Promise<NextResponse> {
  const destino = await leerGrupoUrl();
  return NextResponse.redirect(destino, 302);
}
