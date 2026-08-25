-- ============================================================
-- 094 — Una conversacion por (cuenta, contacto), sostenida por la base
--
-- EL PORQUE
--
-- "Una conversacion por (account_id, contact_id)" era, hasta hoy, solo
-- una convencion escrita en los comentarios del codigo. Nada en la base
-- la defendia: `conversations` tenia indices por account_id y por
-- contact_id, ninguno unico.
--
-- El 24-ago-2026 un cliente nuevo (+592 693 0995) escribio tres mensajes
-- en tres segundos. Dos entregas del webhook corrieron a la vez, ninguna
-- vio la conversacion que estaba creando la otra, y se crearon dos con
-- 60 ms de diferencia. A partir de ahi el fallo se alimento solo: el
-- lookup usaba `.single()`, que da error con MAS de una fila, y el
-- codigo leia ese error como "no existe" y creaba otra. Salio un chat
-- por mensaje — 29 en una tarde — y como el Cerebro usa el
-- `conversation_id` como `session_id` de su memoria, el bot arranco de
-- cero casi cada vez: el cliente tuvo que repetir cuatro veces el nombre
-- del beneficiario y la remesa se entrego sin beneficiario registrado.
--
-- ORDEN DE APLICACION — IMPORTANTE
--
-- Esta migracion va DESPUES de desplegar el codigo que sabe recuperarse
-- de la violacion de unicidad (findConversationForContact + el rescate
-- por 23505 en el webhook y en resolve-conversation.ts). Con el codigo
-- viejo, este indice convertiria la carrera en un mensaje PERDIDO —
-- peor que el chat duplicado que arregla.
--
-- Requiere ademas que no queden duplicados: los 29 chats del caso se
-- consolidaron el 25-ago-2026 (respaldo en
-- cerebro-fase1/respaldos/RESPALDO-chats-duplicados-5926930995-20260825.json).
-- La comprobacion de abajo lo verifica y aborta si aparece alguno nuevo.
-- ============================================================

DO $$
DECLARE
  n int;
BEGIN
  SELECT count(*) INTO n FROM (
    SELECT account_id, contact_id
      FROM conversations
     WHERE contact_id IS NOT NULL
     GROUP BY account_id, contact_id
    HAVING count(*) > 1
  ) d;

  IF n > 0 THEN
    RAISE EXCEPTION
      'Hay % pares (account_id, contact_id) con mas de una conversacion. Consolidalos antes de crear el indice.', n;
  END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS ux_conversations_account_contact
    ON public.conversations (account_id, contact_id)
 WHERE contact_id IS NOT NULL;

COMMENT ON INDEX public.ux_conversations_account_contact IS
  'Una conversacion por (cuenta, contacto). El codigo ya lo asumia; desde 094 la base lo garantiza. Ver 094_una_conversacion_por_contacto.sql.';
