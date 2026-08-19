import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

// ---------------------------------------------------------------------------
// Tests for the `contact_id` send path (issue #296): sending an approved
// template to a single contact from the Contact detail view. The route must
// find-or-create the contact's conversation server-side, then run the normal
// send + persistence path — no inbound message required to bootstrap a thread.
// ---------------------------------------------------------------------------

// Records of what the route wrote, so we can assert the right rows landed.
const conversationInserts: Array<Record<string, unknown>> = []
const messageInserts: Array<Record<string, unknown>> = []

// Toggles for the per-test scenario.
let existingConversation: Record<string, unknown> | null = null
let contactRow: Record<string, unknown> | null = null
// A conversation created during the request becomes retrievable by id —
// the shared send core re-loads the conversation (with its contact) from
// just the id, so the mock must model insert-then-select-by-id.
let createdConversation: Record<string, unknown> | null = null
// The caller's profile row. The route now reads `account_role` as well
// as `account_id` — sending is agent-or-above, enforced server-side.
let profileRow: Record<string, unknown> | null = {
  account_id: 'acct-1',
  account_role: 'agent',
}
// When set, the `messages` INSERT fails — the SEND-01 path where Meta
// already accepted the message and only the persistence broke.
let messageInsertError: { message: string } | null = null

const CONTACT = {
  id: 'contact-1',
  account_id: 'acct-1',
  phone: '+15551234567',
}

// Chainable Supabase mock. A fresh builder per `.from()` call tracks whether
// `.insert()` ran so the terminal resolves to the inserted row for creates
// and the canned select row otherwise.
function makeSupabaseMock() {
  function builder(table: string) {
    let didInsert = false

    const selectResult = () => {
      switch (table) {
        case 'profiles':
          return { data: profileRow, error: null }
        case 'contacts':
          return { data: contactRow, error: null }
        case 'conversations':
          // Once created this request, a by-id reload returns it (with
          // its contact); otherwise fall back to the canned existing row.
          return { data: createdConversation ?? existingConversation, error: null }
        case 'whatsapp_config':
          return {
            data: {
              id: 'cfg-1',
              account_id: 'acct-1',
              phone_number_id: 'PNID-1',
              access_token: 'enc-token',
            },
            error: null,
          }
        case 'message_templates':
          return { data: null, error: null }
        default:
          return { data: null, error: null }
      }
    }

    const insertResult = () => {
      switch (table) {
        case 'conversations':
          return {
            data: {
              id: 'conv-new',
              account_id: 'acct-1',
              contact_id: 'contact-1',
              contact: CONTACT,
            },
            error: null,
          }
        case 'messages':
          return messageInsertError
            ? { data: null, error: messageInsertError }
            : { data: { id: 'msg-1' }, error: null }
        default:
          return { data: null, error: null }
      }
    }

    const terminal = () =>
      Promise.resolve(didInsert ? insertResult() : selectResult())

    const b: Record<string, unknown> = {}
    const chain = () => b
    for (const m of ['select', 'eq', 'in', 'order', 'limit', 'update', 'delete']) {
      b[m] = vi.fn(chain)
    }
    b.insert = vi.fn((payload: Record<string, unknown>) => {
      didInsert = true
      if (table === 'conversations') {
        conversationInserts.push(payload)
        createdConversation = {
          id: 'conv-new',
          account_id: 'acct-1',
          contact_id: 'contact-1',
          contact: CONTACT,
        }
      }
      if (table === 'messages') messageInserts.push(payload)
      return b
    })
    b.single = vi.fn(terminal)
    b.maybeSingle = vi.fn(terminal)
    b.then = (resolve: (v: unknown) => unknown) =>
      resolve(didInsert ? insertResult() : selectResult())
    return b
  }

  return {
    auth: {
      getUser: vi.fn(async () => ({
        data: { user: { id: 'user-1' } },
        error: null,
      })),
    },
    from: vi.fn((table: string) => builder(table)),
  }
}

let supabaseMock = makeSupabaseMock()

vi.mock('@/lib/supabase/server', () => ({
  createClient: vi.fn(async () => supabaseMock),
}))

vi.mock('@/lib/flows/admin-client', () => ({
  supabaseAdmin: () => ({
    from: () => {
      const b: Record<string, unknown> = {}
      const chain = () => b
      for (const m of ['update', 'eq', 'select']) b[m] = vi.fn(chain)
      b.then = (resolve: (v: unknown) => unknown) =>
        resolve({ data: null, error: null })
      return b
    },
  }),
}))

vi.mock('@/lib/whatsapp/encryption', () => ({
  decrypt: vi.fn(() => 'plaintext-token'),
  encrypt: vi.fn(() => 'enc-token'),
  isLegacyFormat: vi.fn(() => false),
}))

const { sendTemplateMessage } = vi.hoisted(() => ({
  sendTemplateMessage: vi.fn(async () => ({ messageId: 'wamid-1' })),
}))
vi.mock('@/lib/whatsapp/meta-api', () => ({
  sendTemplateMessage,
  sendTextMessage: vi.fn(),
  sendMediaMessage: vi.fn(),
}))

import { POST } from './route'

function postContactTemplate(overrides: Record<string, unknown> = {}) {
  return POST(
    new Request('http://localhost/api/whatsapp/send', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        contact_id: 'contact-1',
        message_type: 'template',
        template_name: 'order_update',
        template_language: 'en_US',
        template_message_params: { body: ['Acme', '#1234'] },
        template_params: ['Acme', '#1234'],
        ...overrides,
      }),
    }),
  )
}

describe('POST /api/whatsapp/send — contact_id template path', () => {
  beforeEach(() => {
    conversationInserts.length = 0
    messageInserts.length = 0
    existingConversation = null
    createdConversation = null
    contactRow = CONTACT
    profileRow = { account_id: 'acct-1', account_role: 'agent' }
    messageInsertError = null
    supabaseMock = makeSupabaseMock()
    sendTemplateMessage.mockClear()
  })

  afterEach(() => {
    vi.clearAllMocks()
  })

  it('creates a conversation for a contact with none, then sends the template', async () => {
    const res = await postContactTemplate()
    const json = await res.json()

    expect(res.status).toBe(200)
    expect(json.success).toBe(true)
    expect(json.whatsapp_message_id).toBe('wamid-1')

    // A conversation was created for this contact.
    expect(conversationInserts).toHaveLength(1)
    expect(conversationInserts[0]).toMatchObject({
      account_id: 'acct-1',
      contact_id: 'contact-1',
    })

    // The template was sent to the contact's number.
    expect(sendTemplateMessage).toHaveBeenCalledTimes(1)
    const args = (sendTemplateMessage.mock.calls[0] as unknown[])[0] as Record<
      string,
      unknown
    >
    // Meta wants the bare E.164 digits — sanitizePhoneForMeta strips the '+'.
    expect(args.to).toBe('15551234567')
    expect(args.templateName).toBe('order_update')

    // The outbound message was persisted under the new conversation.
    expect(messageInserts).toHaveLength(1)
    expect(messageInserts[0]).toMatchObject({
      conversation_id: 'conv-new',
      content_type: 'template',
      template_name: 'order_update',
      sender_type: 'agent',
    })
  })

  it('reuses an existing conversation instead of creating a duplicate', async () => {
    existingConversation = {
      id: 'conv-existing',
      account_id: 'acct-1',
      contact_id: 'contact-1',
      contact: CONTACT,
    }

    const res = await postContactTemplate()
    expect(res.status).toBe(200)

    expect(conversationInserts).toHaveLength(0)
    expect(messageInserts[0]).toMatchObject({ conversation_id: 'conv-existing' })
  })

  it('404s when the contact is not in the caller account', async () => {
    contactRow = null

    const res = await postContactTemplate()
    const json = await res.json()

    expect(res.status).toBe(404)
    expect(json.error).toMatch(/contact not found/i)
    expect(sendTemplateMessage).not.toHaveBeenCalled()
  })

  it('400s when neither conversation_id nor contact_id is provided', async () => {
    const res = await POST(
      new Request('http://localhost/api/whatsapp/send', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ message_type: 'template', template_name: 'x' }),
      }),
    )
    expect(res.status).toBe(400)
  })
})

// ---------------------------------------------------------------------------
// SEC-01 — sending is authorized server-side, not just in the UI.
//
// The dashboard gates the composer with `useCan("send-messages")`, but a
// UI gate is a convenience, not a boundary: anyone can POST here directly.
// RLS covers the rows this route reads and writes — it does not cover Meta,
// which is where the irreversible part happens. So the role is checked here,
// before anything can reach a customer.
// ---------------------------------------------------------------------------

describe('POST /api/whatsapp/send — role authorization', () => {
  beforeEach(() => {
    conversationInserts.length = 0
    messageInserts.length = 0
    existingConversation = {
      id: 'conv-1',
      account_id: 'acct-1',
      contact_id: 'contact-1',
      contact: CONTACT,
    }
    createdConversation = null
    contactRow = CONTACT
    profileRow = { account_id: 'acct-1', account_role: 'agent' }
    messageInsertError = null
    supabaseMock = makeSupabaseMock()
    sendTemplateMessage.mockClear()
  })

  afterEach(() => {
    vi.clearAllMocks()
  })

  function postFromConversation() {
    return POST(
      new Request('http://localhost/api/whatsapp/send', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          conversation_id: 'conv-1',
          message_type: 'template',
          template_name: 'order_update',
          template_language: 'en_US',
          template_params: ['Acme'],
        }),
      }),
    )
  }

  // SEC-01A
  it('403s a viewer, and nothing reaches Meta or the messages table', async () => {
    profileRow = { account_id: 'acct-1', account_role: 'viewer' }

    const res = await postFromConversation()
    const json = await res.json()

    expect(res.status).toBe(403)
    expect(json.error).toMatch(/role/i)
    expect(sendTemplateMessage).not.toHaveBeenCalled()
    expect(messageInserts).toHaveLength(0)
  })

  // SEC-01B / C / D
  it.each(['agent', 'admin', 'owner'])('allows %s', async (role) => {
    profileRow = { account_id: 'acct-1', account_role: role }

    const res = await postFromConversation()

    expect(res.status).toBe(200)
    expect(sendTemplateMessage).toHaveBeenCalledTimes(1)
  })

  // SEC-01E — fail closed.
  it.each([
    ['a missing role', { account_id: 'acct-1' }],
    ['a null role', { account_id: 'acct-1', account_role: null }],
    ['an unknown role', { account_id: 'acct-1', account_role: 'superuser' }],
    ['an empty role', { account_id: 'acct-1', account_role: '' }],
  ])('403s on %s rather than waving it through', async (_label, row) => {
    profileRow = row

    const res = await postFromConversation()

    expect(res.status).toBe(403)
    expect(sendTemplateMessage).not.toHaveBeenCalled()
    expect(messageInserts).toHaveLength(0)
  })

  it('still 403s the unlinked-profile case with its own message', async () => {
    profileRow = null

    const res = await postFromConversation()
    const json = await res.json()

    expect(res.status).toBe(403)
    expect(json.error).toMatch(/not linked to an account/i)
    expect(sendTemplateMessage).not.toHaveBeenCalled()
  })

  it('refuses a viewer on the contact_id path too', async () => {
    profileRow = { account_id: 'acct-1', account_role: 'viewer' }

    const res = await POST(
      new Request('http://localhost/api/whatsapp/send', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          contact_id: 'contact-1',
          message_type: 'text',
          content_text: 'hola',
        }),
      }),
    )

    expect(res.status).toBe(403)
    // No conversation was opened on the way to being refused.
    expect(conversationInserts).toHaveLength(0)
    expect(sendTemplateMessage).not.toHaveBeenCalled()
  })
})

// ---------------------------------------------------------------------------
// SEND-01 — "Meta refused" and "Meta accepted, we failed to record it" are
// different failures and must not look alike on the wire.
//
// The core sends to Meta first and inserts the `messages` row after. When
// that insert fails, the customer already has the message and the endpoint
// still answers 500. A caller that reads that as "the send failed" and
// retries delivers the same thing twice — which for a delivery proof means
// the customer gets the transfer screenshot again.
// ---------------------------------------------------------------------------

describe('POST /api/whatsapp/send — distinguishing post-Meta failures', () => {
  beforeEach(() => {
    conversationInserts.length = 0
    messageInserts.length = 0
    existingConversation = {
      id: 'conv-1',
      account_id: 'acct-1',
      contact_id: 'contact-1',
      contact: CONTACT,
    }
    createdConversation = null
    contactRow = CONTACT
    profileRow = { account_id: 'acct-1', account_role: 'agent' }
    messageInsertError = null
    supabaseMock = makeSupabaseMock()
    sendTemplateMessage.mockClear()
  })

  afterEach(() => {
    vi.clearAllMocks()
  })

  function postImage() {
    return POST(
      new Request('http://localhost/api/whatsapp/send', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          conversation_id: 'conv-1',
          message_type: 'template',
          template_name: 'order_update',
          template_language: 'en_US',
          template_params: ['Acme'],
        }),
      }),
    )
  }

  // SEND-01A
  it('reports meta_error with NO wamid when Meta refuses', async () => {
    sendTemplateMessage.mockRejectedValueOnce(
      new Error('(#131047) Re-engagement message'),
    )

    const res = await postImage()
    const json = await res.json()

    expect(res.status).toBe(502)
    expect(json.code).toBe('meta_error')
    // Nothing was delivered, so there must be no id suggesting otherwise.
    expect(json).not.toHaveProperty('whatsapp_message_id')
  })

  // SEND-01B / SEND-01C
  it('reports db_error WITH the wamid when Meta accepted but the insert failed', async () => {
    messageInsertError = { message: 'timeout' }

    const res = await postImage()
    const json = await res.json()

    expect(res.status).toBe(500)
    expect(json.code).toBe('db_error')
    // The proof of delivery. Its presence is what tells the caller
    // "do not send this again".
    expect(json.whatsapp_message_id).toBe('wamid-1')
    // And the old shape still works for anything that only reads `error`.
    expect(json.error).toMatch(/sent to Meta but failed to save/i)
  })

  it('carries the machine code on validation failures too', async () => {
    const res = await POST(
      new Request('http://localhost/api/whatsapp/send', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          conversation_id: 'conv-1',
          message_type: 'image',
          // no media_url
        }),
      }),
    )
    const json = await res.json()

    expect(res.status).toBe(400)
    expect(json.code).toBe('bad_request')
    expect(json).not.toHaveProperty('whatsapp_message_id')
  })

  it('a successful send is unchanged', async () => {
    const res = await postImage()
    const json = await res.json()

    expect(res.status).toBe(200)
    expect(json.success).toBe(true)
    expect(json.whatsapp_message_id).toBe('wamid-1')
    expect(json).not.toHaveProperty('code')
  })
})
