-- =====================================================================
-- 321 -- Hermes: how many customers are waiting for an answer
--
-- The idea cards on the Hermes screen promise "what went unanswered, with
-- the time and the name". The panel had no way to count that: `unread_count`
-- counts what the agent has not opened, not what the customer is waiting for.
--
-- `hermes_sin_responder` returns the conversations whose LAST message came
-- from the customer since a moment (default: the start of the Guyana day) and
-- that are not closed. Read-only, SECURITY DEFINER, single-tenant like the rest
-- of the `hermes_*` family.
--
-- Assertion: supabase/staging/assertions/hermes-sin-responder.sql.
-- Rollback: ROLLBACK-321-hermes-sin-responder.sql.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.hermes_sin_responder(
  p_desde timestamptz DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_desde timestamptz := coalesce(
    p_desde,
    date_trunc('day', now() AT TIME ZONE 'America/Guyana') AT TIME ZONE 'America/Guyana'
  );
BEGIN
  RETURN (
    WITH ultimo AS (
      SELECT m.conversation_id,
             m.sender_type,
             m.created_at,
             row_number() OVER (
               PARTITION BY m.conversation_id
               ORDER BY m.created_at DESC, m.id DESC
             ) AS rn
        FROM messages m
    ), pendientes AS (
      SELECT u.conversation_id, u.created_at
        FROM ultimo u
        JOIN conversations c ON c.id = u.conversation_id
       WHERE u.rn = 1
         AND u.sender_type = 'customer'
         AND u.created_at >= v_desde
         AND c.status <> 'closed'
    )
    SELECT jsonb_build_object(
      'desde', v_desde,
      'conversaciones', (SELECT count(*) FROM pendientes),
      'mas_antiguo', (SELECT min(created_at) FROM pendientes)
    )
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.hermes_sin_responder(timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.hermes_sin_responder(timestamptz) TO service_role;
