-- =====================================================================
-- ROLLBACK 263: removes the avatar trigger, its functions, the unique index and the two columns. The panel falls
-- back to the contact-id hash when the columns are missing.
-- =====================================================================

DROP TRIGGER IF EXISTS contacts_avatar ON public.contacts;
DROP FUNCTION IF EXISTS public.crm_contacts_avatar();
DROP INDEX IF EXISTS public.contacts_avatar_gender_seq_key;
DROP FUNCTION IF EXISTS public.crm_avatar_genero(text);
ALTER TABLE public.contacts DROP COLUMN IF EXISTS avatar_seq, DROP COLUMN IF EXISTS avatar_gender;
