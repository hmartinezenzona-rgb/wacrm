-- =====================================================================
-- 220 -- Users can delete their own notifications (staging first)
--
-- odd/tasks/delete-notifications.md (T1). 027 gave notifications SELECT and UPDATE policies only, so a client DELETE
-- matched no row and notifications piled up. This adds the missing DELETE policy: a user deletes only rows addressed
-- to them. No other change; anon gets nothing (the policy is TO authenticated).
-- Realtime: notifications has REPLICA IDENTITY FULL (027), so DELETE events carry the whole old row.
-- =====================================================================
DROP POLICY IF EXISTS notifications_delete ON public.notifications;
CREATE POLICY notifications_delete ON public.notifications
  FOR DELETE TO authenticated
  USING (auth.uid() = user_id);
