-- 321: the counter agrees with a hand count over the same definition and
-- follows the window it is given. Self-reverting.
DO $$
DECLARE
  v_desde timestamptz := date_trunc('day', now() AT TIME ZONE 'America/Guyana') AT TIME ZONE 'America/Guyana';
  v jsonb;
  v_fail text := '';
  v_n bigint;
BEGIN
  v := hermes_sin_responder(NULL);
  IF jsonb_typeof(v) <> 'object' THEN v_fail := v_fail || ' 1:tipo'; END IF;
  IF (v->>'desde')::timestamptz <> v_desde THEN v_fail := v_fail || ' 2:desde'; END IF;

  SELECT count(*) INTO v_n
    FROM conversations c
   WHERE c.status <> 'closed'
     AND (SELECT m.sender_type
            FROM messages m
           WHERE m.conversation_id = c.id
           ORDER BY m.created_at DESC, m.id DESC
           LIMIT 1) = 'customer'
     AND (SELECT m.created_at
            FROM messages m
           WHERE m.conversation_id = c.id
           ORDER BY m.created_at DESC, m.id DESC
           LIMIT 1) >= v_desde;

  IF (v->>'conversaciones')::bigint <> v_n THEN v_fail := v_fail || ' 3:conteo'; END IF;

  -- A window in the future cannot have anything waiting.
  IF (hermes_sin_responder(now() + interval '1 day')->>'conversaciones')::bigint <> 0 THEN
    v_fail := v_fail || ' 4:futuro';
  END IF;

  IF v_fail <> '' THEN RAISE EXCEPTION '321 FAIL:%', v_fail; END IF;
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
