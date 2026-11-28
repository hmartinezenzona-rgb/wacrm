-- =====================================================================
-- Cutover 2026-09-27 — STEP 7b (WRITE): turn the operations panel on.
--
-- The in-chat operations panel (and every /api/remittance-operations route)
-- is gated per user by profiles.beta_features containing 'operations_panel'.
-- On 2026-09-26 production had 5 profiles, all with an empty list: without
-- this, nobody sees the panel on Monday. Run after the code deploy.
-- Idempotent: only adds the flag to profiles that do not have it.
-- =====================================================================
UPDATE profiles
   SET beta_features = array_append(coalesce(beta_features, ARRAY[]::text[]), 'operations_panel')
 WHERE NOT ('operations_panel' = ANY (coalesce(beta_features, ARRAY[]::text[])));

SELECT coalesce(full_name, email) AS profile, account_role, beta_features FROM profiles ORDER BY account_role;

-- To turn it off for ONE user without redeploying:
--   UPDATE profiles SET beta_features = array_remove(beta_features, 'operations_panel') WHERE user_id = '<uuid>';
