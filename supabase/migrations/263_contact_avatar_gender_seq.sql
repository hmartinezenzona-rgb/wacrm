-- =====================================================================
-- 263: contacts.avatar_gender + avatar_seq, so the illustrated default avatar matches the name and never repeats.
--
-- The panel draws a DiceBear "notionists" face for every customer without a photo (release f7ebf9c). It was a pure
-- hash of the contact id: masculine faces on feminine names and two customers with the same look. Now:
--   - avatar_gender ('f' | 'm' | 'n') comes from the first name, crm_avatar_genero(name): a dictionary of common
--     names (Cuban ones included), then suffix rules; anything else (emoji, business names, "Cliente") is 'n'.
--   - avatar_seq is the contact's 1-based number inside its (account, gender) group. The panel maps it to a
--     hair + background pair, so numbers never collide while a group is under its capacity. A unique index makes a
--     repeat impossible.
--   - A rename only reassigns when the stored gender was 'n' and the new name gives 'f' or 'm'; otherwise the
--     customer keeps the avatar they already have. The two columns cannot be changed directly.
-- Backfill: existing contacts numbered by created_at.
--
-- ROLLBACK: ROLLBACK-263-contact-avatar-gender-seq.sql
-- Guarded by supabase/staging/assertions/contact-avatar-gender-seq.sql
-- =====================================================================

ALTER TABLE public.contacts
  ADD COLUMN IF NOT EXISTS avatar_gender text CHECK (avatar_gender IN ('f', 'm', 'n')),
  ADD COLUMN IF NOT EXISTS avatar_seq integer CHECK (avatar_seq > 0);

CREATE OR REPLACE FUNCTION public.crm_avatar_genero(p_nombre text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
SET search_path TO 'public'
AS $function$
DECLARE
  v text;
BEGIN
  -- First run of letters, lower case, without accents.
  v := (regexp_match(lower(coalesce(p_nombre, '')), '[a-záéíóúüñ]+'))[1];
  IF v IS NULL OR length(v) < 2 THEN RETURN 'n'; END IF;
  v := translate(v, 'áéíóúüñ', 'aeiouun');

  -- Words that are not first names.
  IF v = ANY (ARRAY['cliente','clientes','mi','amor','remesas','finantial','tv','tienda','negocio','info']) THEN
    RETURN 'n';
  END IF;

  IF v = ANY (ARRAY[
      'luis','jose','juan','carlos','jorge','pedro','miguel','angel','alejandro','alexis','yoel','yoan','yoandry',
      'yasmany','osmany','ernesto','rolando','osvaldo','raul','rafael','daniel','david','dayron','adrian','eduardo',
      'frank','yunior','junior','roberto','alberto','ruben','manuel','mario','julio','cesar','hector','oscar','victor',
      'ivan','lazaro','reinaldo','armando','alain','alian','yasiel','yusniel','yordan','yordanis','yoandri','leonel',
      'ariel','fidel','abel','joel','noel','israel','gabriel','samuel','enrique','ricardo','fernando','sergio',
      'andres','tomas','nestor','humberto','wilfredo','william','michael','maykel','yasser','dairon','pablo',
      'arnaldo','orlando','lester','dennis','yuniel','yoelvis','elvis','ronny','randy','henry','harry','kevin',
      'brian','jesus','josue','luca','alexander','yoanis','yoanny','yunier','dariel','yadiel','yariel','raydel',
      'yandy','yeni','reynier','alexei','sandy','luisito','pepe','tony','andy','humbe','albert','bruce','efrain',
      'enrrique','james','jarol','jeoendri','luisi','mohamed','osmani','robert','yohandi','yankier','felipe',
      'vicente','dante','mike','steve','george','jorge','enrique','alberto','gilberto','yorge'])
  THEN RETURN 'm'; END IF;

  IF v = ANY (ARRAY[
      'carmen','maria','isabel','raquel','yudith','judith','beatriz','ines','mercedes','dolores','lourdes','marisol',
      'maribel','yamile','yanet','yaneisy','leidy','heidy','yudy','mery','nancy','miriam','mirian','liz','luz','sol',
      'ruth','esther','ester','yuleisy','arelis','yanelis','dayamis','yosleidy','yailin','yailen','yamilet',
      'idalmis','odalis','iris','rocio','belen','noemi','zoe','nicole','jennifer','katherine','karen','jasmin',
      'yasmin','yasmine','lisbet','lisset','yanelys','yuliet','yuniet','yaneidis','madelin','madeline','marlen',
      'marleny','daylin','yudelkis','yaquelin','jaquelin','rachel','mabel','gisel','yisel','marisel','anisley',
      'yarisley','marisley','yamilka','dayanis','yudmila','lilian','lily','katy','sheila','dianelys','yaritza',
      'mayelin','mailen','yanara','yulien','beyonce','yudeisy','yeny','yenny','jenny','mileidy','lisandra','yerani',
      'yuni','adriadni','aime','arianni','betty','diane','julie','leah','liah','linette','maireli','mami','marise',
      'marlene','meryen','onelsi','rubislandi','seidi','shenil','shenille','skarlett','syuni','taysuki','yane','yari',
      'yasnay','zulemysd'])
  THEN RETURN 'f'; END IF;

  IF v ~ '(a|e|is|ys|sy|dy|ey|ly|et|th|lin)$' THEN RETURN 'f'; END IF;
  IF v ~ '(o|el|on|or|er|ny|ry|ndy|an|ar|ir|ur|io)$' THEN RETURN 'm'; END IF;

  -- Names typed together with the surname ("josem", "oscarbenitez..."): a known first name at the start.
  IF v ~ '^(luis|jose|juan|carlos|jorge|pedro|miguel|angel|oscar|adrian|ernesto|rafael|daniel|david|yoel|yoan|osmany|alexis)' THEN
    RETURN 'm';
  END IF;
  IF v ~ '^(maria|carmen|isabel|yanelis|yuleisy|dayana|lisandra|yudith|beatriz|marisol)' THEN
    RETURN 'f';
  END IF;
  RETURN 'n';
END;
$function$;

COMMENT ON FUNCTION public.crm_avatar_genero(text) IS
  '263. Gender used to pick an avatar from a contact name: f, m or n (unknown). First name only; dictionary then suffix rules.';

-- Backfill before the trigger exists.
WITH g AS (
  SELECT c.id, crm_avatar_genero(c.name) AS gen, c.account_id, c.created_at
    FROM contacts c
), n AS (
  SELECT g.id, g.gen,
         row_number() OVER (PARTITION BY g.account_id, g.gen ORDER BY g.created_at, g.id) AS seq
    FROM g
)
UPDATE contacts c
   SET avatar_gender = n.gen, avatar_seq = n.seq
  FROM n
 WHERE n.id = c.id
   AND (c.avatar_gender IS NULL OR c.avatar_seq IS NULL);

CREATE UNIQUE INDEX IF NOT EXISTS contacts_avatar_gender_seq_key
  ON public.contacts (account_id, avatar_gender, avatar_seq);

CREATE OR REPLACE FUNCTION public.crm_contacts_avatar()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_gen text;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    v_gen := crm_avatar_genero(NEW.name);
    -- Keep the avatar unless an unknown gender becomes known.
    IF OLD.avatar_gender IS NOT NULL AND OLD.avatar_seq IS NOT NULL
       AND NOT (OLD.avatar_gender = 'n' AND v_gen <> 'n') THEN
      NEW.avatar_gender := OLD.avatar_gender;
      NEW.avatar_seq := OLD.avatar_seq;
      RETURN NEW;
    END IF;
  ELSE
    v_gen := crm_avatar_genero(NEW.name);
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('contact_avatar:' || coalesce(NEW.account_id::text, '') || ':' || v_gen, 0));
  NEW.avatar_gender := v_gen;
  NEW.avatar_seq := coalesce((SELECT max(c.avatar_seq) FROM contacts c
                               WHERE c.account_id IS NOT DISTINCT FROM NEW.account_id
                                 AND c.avatar_gender = v_gen), 0) + 1;
  RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.crm_contacts_avatar() IS
  '263. Sets contacts.avatar_gender / avatar_seq on insert and when a rename turns an unknown gender into a known one.';
REVOKE ALL ON FUNCTION public.crm_contacts_avatar() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS contacts_avatar ON public.contacts;
CREATE TRIGGER contacts_avatar
  BEFORE INSERT OR UPDATE OF name, avatar_gender, avatar_seq ON public.contacts
  FOR EACH ROW EXECUTE FUNCTION public.crm_contacts_avatar();
