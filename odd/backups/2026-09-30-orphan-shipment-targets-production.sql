-- Backup of the 14 orphaned cerebro_objetivo_envio rows DELETED from PRODUCTION
-- (hqztotshnlzaiziwjyzh) on 2026-09-30, with the user's explicit go-ahead
-- ("respecto a los objetivos huerfanos puede borrarlos").
-- Criteria: cerrado_en IS NULL, deal_id IS NULL, fijado_en older than 3 days, and
-- the conversation has no open remittance_operation. All were bare USD quotes that
-- never became a remesa (the A3 pattern); left alone they could raise a false
-- "deposito incompleto / de mas" on that customer's next deposit.
-- To restore: run this INSERT against production.
INSERT INTO cerebro_objetivo_envio (conversation_id, monto, moneda, fijado_en, deal_id, cerrado_en, pedido) VALUES
  ('5c6ad481-451a-4221-b871-34aa68066320', 325000, 'GYD', '2026-08-27T14:27:23.01615+00:00', NULL, NULL, '1,250 USD'),
  ('da820eba-beb3-473a-9f09-3c28cee43f6b', 15600, 'GYD', '2026-09-05T19:09:05.729257+00:00', NULL, NULL, '60 USD'),
  ('20846eef-735c-42b3-be16-0b11234e4071', 35100, 'GYD', '2026-09-06T12:23:26.398833+00:00', NULL, NULL, '135 USD'),
  ('242f3b2d-9b55-4ef9-96f3-327926f99a9c', 26000, 'GYD', '2026-09-22T17:51:30.628375+00:00', NULL, NULL, '100 USD'),
  ('7e739c0c-805b-418e-852a-c83140d8e4eb', 26000, 'GYD', '2026-08-30T22:33:21.352838+00:00', NULL, NULL, '100 USD'),
  ('2b4fa1bc-2fae-4398-bafb-64ba0d47a6f8', 39000, 'GYD', '2026-09-17T21:34:48.044007+00:00', NULL, NULL, '150 USD'),
  ('72240415-f365-4998-b398-2edbe1697c25', 26000, 'GYD', '2026-08-25T16:50:22.914095+00:00', NULL, NULL, '100 USD'),
  ('142e413f-a28f-4e77-8885-db33c3f65a53', 10920, 'GYD', '2026-09-26T20:23:54.42971+00:00', NULL, NULL, '42 USD'),
  ('912e186c-95f5-4de4-8ed4-ee881e08c453', 13000, 'GYD', '2026-09-13T12:57:10.473556+00:00', NULL, NULL, '50 USD'),
  ('78153eea-eba7-48b4-b0b1-bfea1abd30ff', 20800, 'GYD', '2026-08-29T16:41:36.477743+00:00', NULL, NULL, '80 USD'),
  ('75da2275-55e1-40de-9ad2-5efb49cbd4f8', 10400, 'GYD', '2026-09-17T14:50:10.4183+00:00', NULL, NULL, '40 USD'),
  ('0947eaa3-6e11-41b0-92da-0924ed312599', 520000, 'GYD', '2026-08-27T12:51:23.297384+00:00', NULL, NULL, '2,000 USD'),
  ('20368b78-d732-4143-88d6-f8b48b41efb1', 325000, 'GYD', '2026-09-02T01:54:28.99498+00:00', NULL, NULL, '1,250 USD'),
  ('2d5d3e6d-e3d3-428a-9073-7cceecfbbef5', 26000, 'GYD', '2026-09-24T16:34:45.797105+00:00', NULL, NULL, '100 USD');
