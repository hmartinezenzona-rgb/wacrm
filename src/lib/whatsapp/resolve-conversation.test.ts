import { describe, expect, it } from 'vitest';
import type { SupabaseClient } from '@supabase/supabase-js';

import { resolveConversationByPhone } from './resolve-conversation';
import { SendMessageError } from './send-message';

// ------------------------------------------------------------
// Chainable Supabase stub, scripted per table. Terminal methods
// (like/maybeSingle/single) resolve to configured data; the builder
// itself is thenable so an awaited `update().eq()` resolves cleanly.
// ------------------------------------------------------------
type ContactRow = { id: string; phone: string; name?: string | null };

interface Script {
  config?: { user_id: string } | null; // whatsapp_config.maybeSingle
  contactCandidates?: ContactRow[]; // contacts .like (same every call)
  /** Per-call `.like` results — overrides contactCandidates. Lets a
   *  test simulate "miss, then hit" for the unique-race path. */
  contactCandidatesByCall?: ContactRow[][];
  insertedContactId?: string; // contacts insert -> single
  insertContactError?: { code?: string } | null;
  existingConversation?: { id: string } | null; // conversations select.maybeSingle
  /** Per-call conversation lookups — para el camino de carrera perdida. */
  existingConversationByCall?: ({ id: string } | null)[];
  insertedConversationId?: string; // conversations insert -> single
  insertConversationError?: { code?: string } | null;
}

/**
 * @param spy si se pasa, recibe los metodos encadenados sobre
 *            `conversations` en un select — para afirmar que la busqueda
 *            usa `.limit(1)` y nunca vuelve a `.single()`.
 */
function makeDb(script: Script, spy?: string[]): SupabaseClient {
  let table = '';
  let mode: 'select' | 'insert' | 'update' = 'select';
  let likeCalls = 0;
  let convLookups = 0;

  const note = (m: string) => {
    if (spy && table === 'conversations' && mode === 'select') spy.push(m);
  };

  const builder: Record<string, unknown> = {
    select: () => builder,
    insert: () => {
      mode = 'insert';
      return builder;
    },
    update: () => {
      mode = 'update';
      return builder;
    },
    eq: () => builder,
    order: () => {
      note('order');
      return builder;
    },
    limit: (n: number) => {
      note(`limit(${n})`);
      return builder;
    },
    like: () => {
      const data = script.contactCandidatesByCall
        ? (script.contactCandidatesByCall[likeCalls] ?? [])
        : (script.contactCandidates ?? []);
      likeCalls++;
      return Promise.resolve({ data, error: null });
    },
    maybeSingle: () => {
      if (table === 'whatsapp_config')
        return Promise.resolve({ data: script.config ?? null, error: null });
      if (table === 'conversations' && mode === 'select') {
        note('maybeSingle');
        const data = script.existingConversationByCall
          ? (script.existingConversationByCall[convLookups] ?? null)
          : (script.existingConversation ?? null);
        convLookups++;
        return Promise.resolve({ data, error: null });
      }
      return Promise.resolve({ data: null, error: null });
    },
    single: () => {
      if (table === 'contacts' && mode === 'insert') {
        if (script.insertContactError)
          return Promise.resolve({
            data: null,
            error: script.insertContactError,
          });
        return Promise.resolve({
          data: { id: script.insertedContactId },
          error: null,
        });
      }
      if (table === 'conversations' && mode === 'insert') {
        if (script.insertConversationError)
          return Promise.resolve({
            data: null,
            error: script.insertConversationError,
          });
        return Promise.resolve({
          data: { id: script.insertedConversationId },
          error: null,
        });
      }
      return Promise.resolve({ data: null, error: null });
    },
    // Thenable: `await db.from().update().eq()` lands here.
    then: (resolve: (v: { data: null; error: null }) => void) =>
      resolve({ data: null, error: null }),
  };

  return {
    from: (t: string) => {
      table = t;
      mode = 'select';
      return builder;
    },
  } as unknown as SupabaseClient;
}

describe('resolveConversationByPhone', () => {
  it('rejects an invalid phone before any DB call', async () => {
    const db = {
      from() {
        throw new Error('should not query');
      },
    } as unknown as SupabaseClient;
    await expect(
      resolveConversationByPhone(db, 'acct', 'not-a-phone')
    ).rejects.toBeInstanceOf(SendMessageError);
  });

  it('fails with whatsapp_not_configured when no config owner exists', async () => {
    const db = makeDb({ config: null });
    await resolveConversationByPhone(db, 'acct', '+14155550123').catch(
      (e: SendMessageError) => {
        expect(e.code).toBe('whatsapp_not_configured');
        expect(e.status).toBe(400);
      }
    );
    await expect(
      resolveConversationByPhone(db, 'acct', '+14155550123')
    ).rejects.toBeInstanceOf(SendMessageError);
  });

  it('returns the existing contact + conversation without creating', async () => {
    const db = makeDb({
      config: { user_id: 'owner-1' },
      contactCandidates: [{ id: 'c1', phone: '14155550123' }],
      existingConversation: { id: 'cv1' },
    });
    const res = await resolveConversationByPhone(
      db,
      'acct',
      '+1 (415) 555-0123'
    );
    expect(res).toEqual({
      conversationId: 'cv1',
      contactId: 'c1',
      contactCreated: false,
    });
  });

  it('creates contact + conversation when none exist', async () => {
    const db = makeDb({
      config: { user_id: 'owner-1' },
      contactCandidates: [],
      insertedContactId: 'c2',
      existingConversation: null,
      insertedConversationId: 'cv2',
    });
    const res = await resolveConversationByPhone(
      db,
      'acct',
      '+14155550199',
      'Jane'
    );
    expect(res).toEqual({
      conversationId: 'cv2',
      contactId: 'c2',
      contactCreated: true,
    });
  });

  it('re-resolves an existing contact when the insert loses a unique race', async () => {
    // First lookup misses (→ we attempt an insert), the insert hits a
    // 23505 unique violation, and the post-race re-lookup now returns
    // the row a concurrent writer created.
    const db = makeDb({
      config: { user_id: 'owner-1' },
      contactCandidatesByCall: [[], [{ id: 'c-raced', phone: '14155550123' }]],
      insertContactError: { code: '23505' },
      existingConversation: { id: 'cv-raced' },
    });
    const res = await resolveConversationByPhone(db, 'acct', '+14155550123');
    expect(res.contactId).toBe('c-raced');
    expect(res.contactCreated).toBe(false);
    expect(res.conversationId).toBe('cv-raced');
  });

  // ----------------------------------------------------------
  // El fallo del 24-ago-2026: la busqueda de conversacion usaba
  // `.single()`, que da error cuando hay MAS de una fila. El codigo
  // leia ese error como "no existe" y creaba otra, asi que en cuanto
  // habia dos, cada mensaje creaba una mas — 29 chats en una tarde.
  // ----------------------------------------------------------
  it('busca la conversacion con limit(1), nunca con single()', async () => {
    const spy: string[] = [];
    const db = makeDb(
      {
        config: { user_id: 'owner-1' },
        contactCandidates: [{ id: 'c-1', phone: '14155550123' }],
        existingConversation: { id: 'cv-1' },
      },
      spy,
    );

    await resolveConversationByPhone(db, 'acct', '+14155550123');

    expect(spy).toContain('limit(1)');
    expect(spy).toContain('order');
    // `single()` reventaria con duplicados; ese era exactamente el bug.
    expect(spy).not.toContain('single');
  });

  it('re-resuelve la conversacion cuando el insert pierde la carrera', async () => {
    // Con el indice unico de la migracion 094, dos entregas concurrentes
    // para un contacto nuevo hacen que una de las dos choque con 23505.
    // Debe quedarse con la conversacion que creo la otra, no tumbar el
    // envio ni tirar el mensaje.
    const db = makeDb({
      config: { user_id: 'owner-1' },
      contactCandidates: [{ id: 'c-1', phone: '14155550123' }],
      existingConversationByCall: [null, { id: 'cv-ganadora' }],
      insertConversationError: { code: '23505' },
    });

    const res = await resolveConversationByPhone(db, 'acct', '+14155550123');

    expect(res.conversationId).toBe('cv-ganadora');
    expect(res.contactId).toBe('c-1');
  });

  it('sigue fallando si el insert de conversacion muere por otra causa', async () => {
    const db = makeDb({
      config: { user_id: 'owner-1' },
      contactCandidates: [{ id: 'c-1', phone: '14155550123' }],
      existingConversationByCall: [null, null],
      insertConversationError: { code: '42501' },
    });

    await expect(
      resolveConversationByPhone(db, 'acct', '+14155550123'),
    ).rejects.toBeInstanceOf(SendMessageError);
  });
});
