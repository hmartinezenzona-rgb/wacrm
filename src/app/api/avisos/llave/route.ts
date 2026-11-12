import { NextResponse } from 'next/server'
import { getCurrentAccount, toErrorResponse } from '@/lib/auth/account'
import { obtenerLlaves } from '@/lib/avisos/push'

// Llave pública para que el celular se suscriba a los avisos.
export async function GET() {
  try {
    await getCurrentAccount()
    const { publica } = await obtenerLlaves()
    return NextResponse.json({ publica })
  } catch (err) {
    return toErrorResponse(err)
  }
}
