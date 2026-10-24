import { NextResponse } from 'next/server';

// Public redirect used by the WhatsApp template button: Meta rejects
// chat.whatsapp.com links inside buttons (error 2388081), so the approved
// template points at this path and the redirect resolves the real invite.
// Changing the group only touches this constant; the template stays approved.
const GRUPO_URL = 'https://chat.whatsapp.com/GFznWMcrlHa5RSBo76Vw81';

export function GET(): NextResponse {
  return NextResponse.redirect(GRUPO_URL, 302);
}
