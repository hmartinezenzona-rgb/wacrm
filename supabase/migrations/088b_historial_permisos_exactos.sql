-- =====================================================================
-- 088b — Devolverle a `cerebro_dashboard_historial` sus permisos EXACTOS
--
--   YA APLICADA EN PRODUCCION EL 14-AGO-2026. NO LA REPITAS.
--
-- QUE PASO
--
--   La 088 tuvo que DROPear la funcion (cambia el tipo de retorno) y
--   volverla a crear. Los permisos de antes eran:
--
--     postgres=X | authenticated=X | service_role=X      <- sin PUBLIC
--
--   y los de despues resultaron ser:
--
--     =X (PUBLIC) | postgres=X | authenticated=X | service_role=X
--
--   O sea que la funcion nueva nacio ejecutable por **anon**: cualquiera
--   con la clave publica del navegador —que va dentro del bundle, no es
--   secreta— podia pedir el historial SIN iniciar sesion y leer nombres
--   de clientes, telefonos, montos y tarjetas enmascaradas.
--
--   Se creia que la 064 lo impedia con `ALTER DEFAULT PRIVILEGES ...
--   REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC`. **No basta**: se ha
--   comprobado hoy que una funcion creada por esta via sale igualmente
--   con EXECUTE para PUBLIC. La leccion para las migraciones que vengan:
--   el REVOKE explicito no es opcional, y hay que MIRAR el ACL despues
--   de crear, no darlo por hecho.
--
-- COMO SE MIRA
--
--   SELECT p.oid::regprocedure::text,
--          array_to_string(p.proacl,' | '),
--          has_function_privilege('anon', p.oid, 'EXECUTE') AS anon
--     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--    WHERE n.nspname = 'public' AND p.proname = '<la funcion>';
--
--   Despues de esta migracion: `anon` = false, y el ACL queda letra por
--   letra igual al de `cerebro_dashboard_resumen`, que nunca se toco.
--
-- LO QUE ESTE HALLAZGO DEJA ABIERTO (no se toca aqui, esta anotado en
-- PENDIENTES): hay mas funciones del esquema public que `anon` puede
-- ejecutar, entre ellas `cerebro_outbox_encolar` — o sea, encolar un
-- mensaje de WhatsApp sin iniciar sesion. Nacieron asi despues de la
-- 064. Hay que revisarlas una por una antes de revocar nada, porque
-- alguna puede estar en uso.
--
-- ROLLBACK: ninguno. Esto solo quita un permiso que nunca debio existir.
-- =====================================================================

REVOKE EXECUTE ON FUNCTION
  public.cerebro_dashboard_historial(date, date, text, integer, integer)
FROM PUBLIC, anon;

NOTIFY pgrst, 'reload schema';
