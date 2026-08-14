-- 085 — Bajar el ruido del vigilante de chats atascados
--
-- EL PROBLEMA, MEDIDO EL 14-ago-2026
-- De los 58 avisos del 13-ago, 24 eran chat_atascado. Y los 11 avisos
-- chat_atascado de TODA la historia son la MISMA clienta, Inelvis:
--   2 legitimos  -> tenia 2 operaciones abiertas, esperaba de verdad
--   9 de ruido   -> 0 operaciones abiertas, y venian de un "Gracia" escrito
--                   once minutos DESPUES de completarse su remesa
-- El aviso se repetia cada 60 min durante 8 horas por el mismo mensaje.
--
-- POR QUE NO BASTA ANADIR LA "s"
-- Osmany: "agregarle la s no resuelve nada, si escribe mal el gracia u otra
-- cosa se dispara igual". Tiene razon: la lista de palabras es un juego del
-- topo. Aqui van DOS capas independientes, y ninguna puede callar el PRIMER
-- aviso de nadie.
--
-- CAPA 1 — la raiz de la palabra, no la palabra
--   `gracias` -> `gra[cs]ias?`  cubre gracia, gracias, grasia, grasias.
--   Sigue siendo texto, pero deja de fallar por una letra.
--
-- CAPA 2 — el ESTADO del cliente decide cada cuanto se REPITE
--   Con operacion abierta (dinero en juego): cada 60 min, como hasta hoy.
--   Sin operacion abierta: cada 360 min (clave
--   `chat_atascado_repetir_sin_operacion_min`).
--   EL PRIMER AVISO SALE SIEMPRE, con operacion o sin ella. Esto NO decide a
--   quien se avisa, solo cada cuanto se INSISTE. Por eso es seguro: el caso que
--   daba miedo —un cliente NUEVO, con cero operaciones, al que se ignora— sigue
--   generando su aviso. Lo unico que se pierde es el machaqueo.
--
-- Se descarto la regla de estado PURA (no avisar si no hay operacion abierta):
-- la 062 ya la midio el 10-ago contra 12 casos reales y fallaba en los dos
-- limites. Un cliente nuevo tiene cero operaciones y merece el aviso igual.
--
-- COMO SE APLICA, Y POR QUE ASI
-- La funcion viva NO coincide con la del fichero 062 (4.704 caracteres
-- normalizados frente a 4.191): ha cambiado desde entonces. Asi que esta
-- migracion NO reescribe el cuerpo a mano — lee la definicion VIVA, aplica
-- reemplazos de texto exacto y la vuelve a crear. Si un ancla no aparece,
-- aborta entera y no toca nada.
--
-- REVERSION
--   Los reemplazos inversos, o restaurar desde el fichero 062 comprobando antes
--   que nadie mas la haya tocado.

DO $mig$
DECLARE
  v_def text;
  v_ini text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'cerebro_avisar_chats_atascados';
  IF v_def IS NULL THEN
    RAISE EXCEPTION 'no existe cerebro_avisar_chats_atascados';
  END IF;
  v_ini := v_def;

  -- (1) La variable nueva
  v_def := replace(v_def,
    '  v_min int; v_repetir int; v_ahora_gy timestamp;',
    '  v_min int; v_repetir int; v_repetir_sin_op int; v_ahora_gy timestamp;');

  -- (2) Su valor, de cerebro_config
  v_def := replace(v_def,
    $a$  v_repetir := COALESCE(p_repetir_min, NULLIF(cerebro_config_get('chat_atascado_repetir_min'), '')::int, 60);$a$,
    $a$  v_repetir := COALESCE(p_repetir_min, NULLIF(cerebro_config_get('chat_atascado_repetir_min'), '')::int, 60);
  v_repetir_sin_op := COALESCE(NULLIF(cerebro_config_get('chat_atascado_repetir_sin_operacion_min'), '')::int, v_repetir);$a$);

  -- (3) CAPA 1: la raiz en la lista exacta
  v_def := replace(v_def,
    $a$'^(|ok|oka|okay|okey|oki|vale|listo|dale|gracias|muchas gracias|'$a$,
    $a$'^(|ok|oka|okay|okey|oki|vale|listo|dale|gra[cs]ias?|muchas gra[cs]ias?|'$a$);

  -- (4) CAPA 1: la raiz en el regex de cortesia
  v_def := replace(v_def,
    $a$'(gracias|thank|okay|okey|^ok\M|vale|perfecto|listo|bendicion|saludos|besos)'$a$,
    $a$'(gra[cs]ias?|thank|okay|okey|^ok\M|vale|perfecto|listo|bendicion|saludos|besos)'$a$);

  -- (5) CAPA 2: el intervalo de REPETICION depende del estado del cliente
  v_def := replace(v_def,
    '                AND a2.ultimo > now() - make_interval(mins => v_repetir))',
    '                AND a2.ultimo > now() - make_interval(mins =>
                      CASE WHEN EXISTS (SELECT 1 FROM remittance_operations o
                                         WHERE o.conversation_id = v.id
                                           AND o.status NOT IN (''completed'',''cancelled''))
                           THEN v_repetir ELSE v_repetir_sin_op END))');

  IF v_def = v_ini THEN
    RAISE EXCEPTION 'ningun ancla aplico: la funcion viva no es la esperada';
  END IF;
  IF position('v_repetir_sin_op' in v_def) = 0
     OR position('gra[cs]ias?' in v_def) = 0
     OR position('remittance_operations o' in v_def) = 0 THEN
    RAISE EXCEPTION 'faltan cambios: alguno de los cinco anclajes no aparecio';
  END IF;

  EXECUTE v_def;
END $mig$;