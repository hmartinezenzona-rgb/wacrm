-- Backup of 5 stale cerebro_beneficiario_parcial rows deleted from PRODUCTION on 2026-09-30.
-- Each belongs to a conversation with no open remesa and holds a Zelle account already registered on a
-- closed remesa of that conversation (seed of the zombie-remesa bug fixed by migration 155).
-- Restore by running this file against production.
INSERT INTO cerebro_beneficiario_parcial (conversation_id, tarjeta, celular, actualizado, zelle_nombre, zelle_cuenta, zelle_nombre_cuenta) VALUES
  ('07953f92-a100-4cce-b3b4-ee6ee92bf33b', NULL, NULL, '2026-09-29T20:22:07.724449+00:00', NULL, 'garzonyankiel5@gmail.com', NULL),
  ('26b6e7bb-d8a8-4d13-be9c-2c98f0ae73f6', NULL, NULL, '2026-09-28T17:11:27.756735+00:00', NULL, '4075350482', NULL),
  ('40e6ab76-9597-4a2b-bf18-96450476a8bb', NULL, NULL, '2026-09-29T04:04:53.975638+00:00', NULL, '8133617809', NULL),
  ('2e10a8f3-1de7-4bbc-8b0b-78a9be54d1bf', NULL, NULL, '2026-09-29T23:45:01.537118+00:00', NULL, '3059899361', NULL),
  ('b341b43a-19d4-49d5-98cf-7b0aa23335cd', NULL, NULL, '2026-09-30T14:17:02.639657+00:00', NULL, 'reynieroliverosromero@gmail.com', NULL)
ON CONFLICT (conversation_id) DO NOTHING;
