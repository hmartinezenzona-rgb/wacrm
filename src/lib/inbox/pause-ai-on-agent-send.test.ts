// HT1-HT5: un envío humano toma la conversación.
//
// El caso real: un operador escribió cinco mensajes en un hilo que llevaba el
// bot, el bot siguió activo y contestó tres veces por encima. El cliente acabó
// escribiendo «Disculpe mande un mensaje equivocado»: estaba hablando con dos.
import { describe, expect, it, vi } from 'vitest'
import { AGENT_REPLIED_REASON, pauseAiOnAgentSend } from './pause-ai-on-agent-send'

/** Un Supabase de mentira con sólo lo que toca esta función. */
function fakeSupabase(opts: {
  paused?: boolean
  readError?: string
  writeError?: string
  missing?: boolean
}) {
  const updates: Record<string, unknown>[] = []
  const client = {
    from: (_t: string) => ({
      select: (_c: string) => ({
        eq: (_k: string, _v: string) => ({
          single: async () => ({
            data: opts.missing
              ? null
              : { ai_autoreply_disabled: opts.paused ?? false },
            error: opts.readError ? { message: opts.readError } : null,
          }),
        }),
      }),
      update: (patch: Record<string, unknown>) => {
        updates.push(patch)
        return {
          eq: async () => ({
            error: opts.writeError ? { message: opts.writeError } : null,
          }),
        }
      },
    }),
  }
  return { client: client as never, updates }
}

describe('HT1 · el envío manual pausa el bot', () => {
  it('apaga el autoreply de una conversación que llevaba el bot', async () => {
    const { client, updates } = fakeSupabase({ paused: false })
    const r = await pauseAiOnAgentSend(client, 'conv-1')

    expect(r).toEqual({ paused: true, alreadyPaused: false })
    expect(updates).toHaveLength(1)
    expect(updates[0].ai_autoreply_disabled).toBe(true)
    expect(updates[0].ai_handoff_reason).toBe(AGENT_REPLIED_REASON)
    expect(updates[0].ai_handoff_at).toEqual(expect.any(String))
  })

  it('no toca assigned_agent_id', () => {
    // Silenciar el bot y asignar a alguien son dos cosas distintas: la segunda
    // cambia los filtros de la bandeja. Aquí sólo hace falta la primera.
    const { client, updates } = fakeSupabase({ paused: false })
    return pauseAiOnAgentSend(client, 'conv-1').then(() => {
      expect(updates[0]).not.toHaveProperty('assigned_agent_id')
    })
  })
})

describe('HT5 · idempotencia', () => {
  it('una conversación ya pausada no se vuelve a escribir', async () => {
    // Pisar `ai_handoff_at` borraría cuándo se relevó de verdad, y ese dato es
    // el que se audita después.
    const { client, updates } = fakeSupabase({ paused: true })
    const r = await pauseAiOnAgentSend(client, 'conv-1')

    expect(r).toEqual({ paused: true, alreadyPaused: true })
    expect(updates).toHaveLength(0)
  })

  it('tres envíos seguidos dejan una sola escritura', async () => {
    let paused = false
    const updates: Record<string, unknown>[] = []
    const client = {
      from: () => ({
        select: () => ({
          eq: () => ({
            single: async () => ({
              data: { ai_autoreply_disabled: paused },
              error: null,
            }),
          }),
        }),
        update: (patch: Record<string, unknown>) => {
          updates.push(patch)
          paused = true
          return { eq: async () => ({ error: null }) }
        },
      }),
    }
    for (let i = 0; i < 3; i++) {
      await pauseAiOnAgentSend(client as never, 'conv-1')
    }
    expect(updates).toHaveLength(1)
  })
})

describe('falla hacia el lado que no rompe el trabajo del operador', () => {
  it('un fallo de lectura no revienta', async () => {
    const { client } = fakeSupabase({ readError: 'boom' })
    await expect(pauseAiOnAgentSend(client, 'conv-1')).resolves.toEqual({
      paused: false,
      alreadyPaused: false,
    })
  })

  it('un fallo de escritura no revienta y NO dice que pausó', async () => {
    // Decir que se pausó cuando no se pausó es el mismo error que el del
    // handoff: una confirmación falsa sobre algo que no ocurrió.
    const { client } = fakeSupabase({ paused: false, writeError: 'boom' })
    await expect(pauseAiOnAgentSend(client, 'conv-1')).resolves.toEqual({
      paused: false,
      alreadyPaused: false,
    })
  })

  it('una conversación que no existe no revienta', async () => {
    const { client } = fakeSupabase({ missing: true })
    await expect(pauseAiOnAgentSend(client, 'conv-1')).resolves.toEqual({
      paused: false,
      alreadyPaused: false,
    })
  })

  it('una excepción inesperada se traga y se registra', async () => {
    const espia = vi.spyOn(console, 'error').mockImplementation(() => {})
    const client = {
      from: () => {
        throw new Error('la red no está')
      },
    }
    await expect(pauseAiOnAgentSend(client as never, 'conv-1')).resolves.toEqual({
      paused: false,
      alreadyPaused: false,
    })
    expect(espia).toHaveBeenCalled()
    espia.mockRestore()
  })
})

describe('HT3 y HT4 · quién NO pausa', () => {
  it('sólo la ruta del dashboard la llama', async () => {
    // Propiedad de ESTRUCTURA: no se puede observar llamando a la función.
    //
    // `/api/v1/messages` es el bot (requireApiKey) y el shadow usará esa misma
    // ruta con su propia clave. Si la llamada estuviera en el core compartido
    // `sendMessageToConversation`, el bot se pausaría a sí mismo con cada
    // respuesta y el shadow apagaría bots de producción.
    const fs = await import('node:fs/promises')
    const path = await import('node:path')
    const raiz = path.resolve(__dirname, '../../..')

    const humana = await fs.readFile(
      path.join(raiz, 'src/app/api/whatsapp/send/route.ts'),
      'utf8'
    )
    expect(humana).toContain('pauseAiOnAgentSend')

    for (const otra of [
      'src/app/api/v1/messages/route.ts',
      'src/lib/whatsapp/send-message.ts',
      'src/lib/flows/meta-send.ts',
      'src/lib/automations/meta-send.ts',
      'src/lib/ai/auto-reply.ts',
    ]) {
      const texto = await fs.readFile(path.join(raiz, otra), 'utf8')
      expect(texto, otra).not.toContain('pauseAiOnAgentSend')
    }
  })
})
