-- ROLLBACK of 220_notifications_delete_policy.sql: removes the DELETE policy; notifications go back to being undeletable
-- from the client (SELECT and UPDATE policies from 027 are untouched).
DROP POLICY IF EXISTS notifications_delete ON public.notifications;
