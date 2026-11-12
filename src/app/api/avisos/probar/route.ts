import { NextResponse } from 'next/server'
import { getCurrentAccount, toErrorResponse } from '@/lib/auth/account'
import { avisar } from '@/lib/avisos/push'

// Aviso de prueba solo a los celulares de quien lo pide.
export async function POST() {
  try {
    const ctx = await getCurrentAccount()
    const r = await avisar(
      { accountId: ctx.accountId, userId: ctx.userId },
      { title: '🔔 Avisos activados', body: 'Así te van a llegar los encargos nuevos.', url: '/pipelines', tag: 'prueba' },
    )
    return NextResponse.json(r)
  } catch (err) {
    return toErrorResponse(err)
  }
}
