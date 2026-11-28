import { beforeEach, describe, expect, it, vi } from 'vitest'

const { sendMock, puedeMock, primeraMock, construirMock } = vi.hoisted(() => ({
  sendMock: vi.fn(),
  puedeMock: vi.fn(),
  primeraMock: vi.fn(),
  construirMock: vi.fn(),
}))

vi.mock('@/lib/auth/api-context', () => ({
  requireApiKey: vi.fn(async () => ({ supabase: {}, accountId: 'acct' })),
}))
vi.mock('@/lib/whatsapp/resolve-conversation', () => ({
  resolveConversationByPhone: vi.fn(async () => ({
    conversationId: 'conv',
    contactId: 'contact',
    contactCreated: false,
  })),
}))
vi.mock('@/lib/whatsapp/send-message', async (importOriginal) => {
  const actual =
    await importOriginal<typeof import('@/lib/whatsapp/send-message')>()
  return { ...actual, sendMessageToConversation: sendMock }
})
vi.mock('@/lib/whatsapp/group-invite', () => ({
  puedeInvitarGrupo: puedeMock,
  esPrimeraRespuestaAgente: primeraMock,
  construirInvitacionGrupoConTexto: construirMock,
}))

import { POST } from './route'

const CTA = {
  kind: 'cta_url',
  body: 'Hola\n\nÚnete a nuestro grupo',
  footer: 'Remesas Ya',
  button_label: 'Unirme al grupo',
  url: 'https://app.test/grupo',
}

function request(body: unknown) {
  return new Request('https://app.test/api/v1/messages', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  })
}

beforeEach(() => {
  sendMock.mockReset()
  sendMock.mockResolvedValue({ messageId: 'm1', whatsappMessageId: 'w1' })
  puedeMock.mockReset()
  puedeMock.mockResolvedValue(true)
  primeraMock.mockReset()
  primeraMock.mockResolvedValue(true)
  construirMock.mockReset()
  construirMock.mockReturnValue(CTA)
})

describe('POST /api/v1/messages — group invite', () => {
  it('sends one interactive message with the bot text and the group button', async () => {
    const res = await POST(
      request({
        to: '+5219624564224',
        type: 'text',
        text: 'Hola',
        group_invite: true,
      }),
    )

    expect(res.status).toBe(201)
    expect(sendMock).toHaveBeenCalledWith(
      {},
      'acct',
      expect.objectContaining({
        conversationId: 'conv',
        messageType: 'interactive',
        interactivePayload: CTA,
        aiGenerated: true,
      }),
    )
    expect(await res.json()).toMatchObject({
      data: { message_id: 'm1', whatsapp_message_id: 'w1' },
    })
  })

  it('sends the normal text when the workflow does not opt in', async () => {
    const res = await POST(
      request({ to: '+5219624564224', type: 'text', text: 'Hola' }),
    )

    expect(res.status).toBe(201)
    expect(sendMock).toHaveBeenCalledWith(
      {},
      'acct',
      expect.objectContaining({ messageType: 'text', contentText: 'Hola' }),
    )
    expect(puedeMock).not.toHaveBeenCalled()
  })

  it('falls back to text when the contact cannot be invited', async () => {
    puedeMock.mockResolvedValue(false)
    const res = await POST(
      request({
        to: '+5219624564224',
        type: 'text',
        text: 'Hola',
        group_invite: true,
      }),
    )

    expect(res.status).toBe(201)
    expect(sendMock).toHaveBeenCalledWith(
      {},
      'acct',
      expect.objectContaining({ messageType: 'text', contentText: 'Hola' }),
    )
  })

  it('falls back to text when it is not the first agent reply', async () => {
    primeraMock.mockResolvedValue(false)
    const res = await POST(
      request({
        to: '+5219624564224',
        type: 'text',
        text: 'Hola',
        group_invite: true,
      }),
    )

    expect(res.status).toBe(201)
    expect(sendMock).toHaveBeenCalledWith(
      {},
      'acct',
      expect.objectContaining({ messageType: 'text' }),
    )
  })

  it('falls back to text when the combined body is over the limit', async () => {
    construirMock.mockReturnValue(null)
    const res = await POST(
      request({
        to: '+5219624564224',
        type: 'text',
        text: 'Hola',
        group_invite: true,
      }),
    )

    expect(res.status).toBe(201)
    expect(sendMock).toHaveBeenCalledWith(
      {},
      'acct',
      expect.objectContaining({ messageType: 'text' }),
    )
  })
})
