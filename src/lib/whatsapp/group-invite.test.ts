import { beforeEach, describe, expect, it, vi } from 'vitest'

const { sendMock } = vi.hoisted(() => ({ sendMock: vi.fn() }))
vi.mock('./send-message', () => ({ sendMessageToConversation: sendMock }))

import { construirInvitacionGrupo, enviarInvitacionGrupo } from './group-invite'

type Rows = {
  config?: { valor: string } | null
  contactTags?: Array<{ tag_id: string }>
  tags?: Array<{ name: string }>
  messages?: Array<{ id: string; interactive_payload: unknown }>
}

function fakeDb(rows: Rows) {
  const data: Record<string, unknown> = {
    cerebro_config: rows.config ?? null,
    contact_tags: rows.contactTags ?? [],
    tags: rows.tags ?? [],
    messages: rows.messages ?? [],
  }
  return {
    from(table: string) {
      const b: Record<string, unknown> = {}
      for (const m of ['select', 'eq', 'in', 'limit']) b[m] = () => b
      b.maybeSingle = async () => ({ data: data[table] ?? null, error: null })
      b.then = (resolve: (v: unknown) => unknown) => resolve({ data: data[table] ?? [], error: null })
      return b
    },
  } as never
}

beforeEach(() => {
  sendMock.mockReset()
  sendMock.mockResolvedValue({ whatsapp_message_id: 'wamid.invite' })
})

describe('construirInvitacionGrupo', () => {
  it('builds a cta_url payload pointing at /grupo', () => {
    const p = construirInvitacionGrupo('https://app.test/')
    expect(p.kind).toBe('cta_url')
    expect(p.url).toBe('https://app.test/grupo')
    expect(p.button_label).toBe('Unirme al grupo')
    expect(p.body).toContain('grupo de WhatsApp')
    expect(p.footer).toBe('Remesas Ya')
  })
})

describe('enviarInvitacionGrupo', () => {
  it('does nothing when the flag is off', async () => {
    const ok = await enviarInvitacionGrupo(
      fakeDb({ config: { valor: 'no' } }), 'acct', 'conv', 'contact', 'https://app.test',
    )
    expect(ok).toBe(false)
    expect(sendMock).not.toHaveBeenCalled()
  })

  it('sends once for a non-admin first message', async () => {
    const db = fakeDb({ config: { valor: 'si' } })
    const ok = await enviarInvitacionGrupo(db, 'acct', 'conv', 'contact', 'https://app.test')
    expect(ok).toBe(true)
    expect(sendMock).toHaveBeenCalledWith(db, 'acct', expect.objectContaining({
      conversationId: 'conv',
      messageType: 'interactive',
      aiGenerated: true,
      interactivePayload: expect.objectContaining({ kind: 'cta_url' }),
    }))
  })

  it('skips an admin contact', async () => {
    const db = fakeDb({
      config: { valor: 'si' },
      contactTags: [{ tag_id: 't1' }],
      tags: [{ name: 'Admin' }],
    })
    const ok = await enviarInvitacionGrupo(db, 'acct', 'conv', 'contact', 'https://app.test')
    expect(ok).toBe(false)
    expect(sendMock).not.toHaveBeenCalled()
  })

  it('skips when the CTA was already sent in the conversation', async () => {
    const db = fakeDb({
      config: { valor: 'si' },
      messages: [{ id: 'm1', interactive_payload: { kind: 'cta_url' } }],
    })
    const ok = await enviarInvitacionGrupo(db, 'acct', 'conv', 'contact', 'https://app.test')
    expect(ok).toBe(false)
    expect(sendMock).not.toHaveBeenCalled()
  })
})
