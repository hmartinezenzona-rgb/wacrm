-- 087 — Una referencia IMPOSIBLE no se registra como deposito normal
--
-- EL CASO (13-ago-2026, sanzjuanpastor / 5927669918)
-- Mando una CAPTURA DE OTRA CONVERSACION de WhatsApp que dentro tenia la FOTO
-- de un comprobante de MMG. Un recibo dentro de una foto dentro de una captura.
-- La vision se invento las dos cifras: registro **5.000 GYD con ref
-- 10319372234891** cuando el comprobante de la imagen decia **26.000 y
-- 10395727229361**. Resultado: un deal fantasma en "Por verificar", un
-- "Recibimos su deposito de 5,000 GYD" al cliente que era falso, y el vigilante
-- avisando tres veces (16, 136 y 256 minutos) por alguien ya atendido.
--
-- LA SENAL, Y POR QUE NO CADUCA
-- El TransID de MMG es un contador que SOLO CRECE. Los 724 recibidos van de
-- 10378363543358 (31-dic-2025) a 21396936623433 (3-ago-2026). Un numero POR
-- DEBAJO del menor que ha existido nunca no puede ser un TransID.
--   los 724 reales           -> pasan
--   10319372234891 (inventado) -> NO pasa
--   10395727229361 (el de la foto, real) -> pasa
--
-- NO se fija la longitud a proposito: el propio proyecto tiene escrito que el
-- TransID paso de 10 digitos en 2025 a 14 en 2026 ("nunca fijar longitud").
-- Comparar por VALOR contra el suelo aguanta ese cambio y cualquier otro
-- crecimiento futuro.
--
-- LO QUE ESTO NO ES
-- No valida que el deposito EXISTA: de eso ya se encarga el cruce contra el
-- libro de MMG. Un digito mal leido —como el 20397544023399 del 10-ago— sigue
-- pasando este filtro, y es correcto: ese lo caza el cruce. Aqui solo se para lo
-- que NO PUEDE SER un TransID.
--
-- QUE PASA CUANDO NO PASA
-- El deal va a INCIDENCIA en vez de a "Por verificar", con el motivo escrito en
-- las notas. Asi lo mira una persona, y de paso el vigilante de depositos sin
-- cruzar —que solo mira "Por verificar"— deja de avisar por un fantasma.
--
-- El suelo vive en cerebro_config para poder moverlo sin desplegar.
--
-- REVERSION
--   Quitar el bloque de cerebro_registrar_deposito y DROP FUNCTION.

INSERT INTO cerebro_config (clave, valor, descripcion)
VALUES ('transid_minimo', '10378363543358',
        'El TransID de MMG mas bajo que se ha recibido jamas (31-dic-2025). El contador '
        'solo crece, asi que cualquier referencia por debajo de esto es imposible y casi '
        'seguro se la invento la vision leyendo una captura o una foto de otra pantalla. '
        'Medido el 14-ago-2026 sobre los 724 depositos del libro: los 724 pasan.')
ON CONFLICT (clave) DO NOTHING;

CREATE OR REPLACE FUNCTION public.cerebro_transid_plausible(p_ref text)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT CASE
    -- Sin referencia no hay nada que juzgar: no se cambia el comportamiento
    -- de los caminos que registran un deposito sin ella.
    WHEN NULLIF(btrim(coalesce(p_ref, '')), '') IS NULL THEN true
    WHEN btrim(p_ref) !~ '^[0-9]+$' THEN false
    ELSE btrim(p_ref)::numeric >= COALESCE(
           NULLIF(cerebro_config_get('transid_minimo'), '')::numeric, 10378363543358)
  END;
$fn$;

REVOKE ALL ON FUNCTION public.cerebro_transid_plausible(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_transid_plausible(text) TO service_role;

DO $mig$
DECLARE v_def text; v_ini text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'cerebro_registrar_deposito';
  v_ini := v_def;

  IF position('  -- (a) Idempotencia.' in v_def) = 0 THEN
    RAISE EXCEPTION 'no aparece el ancla de idempotencia';
  END IF;

  v_def := replace(v_def, '  -- (a) Idempotencia.',
'  -- REFERENCIA IMPOSIBLE (087). El TransID de MMG solo crece: por debajo del
  -- suelo historico no puede existir. El 13-ago la vision saco 10319372234891
  -- de una captura de otro chat que contenia la foto de un comprobante, y de
  -- paso invento el importe. Aqui no se valida que el deposito exista —eso es
  -- el cruce contra el libro—, solo que el numero PUEDA ser un TransID.
  IF NOT cerebro_transid_plausible(NULLIF(substring(v_nota from ''Ref: ([0-9]+)''), '''')) THEN
    p_stage := ''da7b3e24-9222-4150-8be8-d7f7378e16aa''::uuid;
    v_nota := v_nota || chr(10)
      || ''REFERENCIA IMPOSIBLE: ese numero no puede ser un TransID de MMG. El contador ''
      || ''solo crece y este queda por debajo de todos los recibidos, asi que casi seguro ''
      || ''lo leyo la vision de una CAPTURA o de una foto de otra pantalla, no de un ''
      || ''comprobante directo. NO se ha registrado como deposito normal: mire la imagen y ''
      || ''pidale al cliente el comprobante original antes de dar nada por recibido.'';
  END IF;

  -- (a) Idempotencia.');

  IF v_def = v_ini THEN
    RAISE EXCEPTION 'no se sustituyo nada';
  END IF;
  EXECUTE v_def;
END $mig$;