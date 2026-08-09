-- =====================================================================
-- 048 — Punto de entrada del vigilante de promociones
--
--   YA APLICADA EN PRODUCCION EL 9-AGO-2026. NO LA EJECUTES DE NUEVO.
--
-- Complementa la 047. El workflow de n8n llama SOLO a esta funcion, con
-- el JSON que produce su parser. Un unico nodo Postgres en vez de tres,
-- que es menos superficie donde equivocarse.
--
-- Workflow: `Vigilante - promociones de Etecsa`  vk6aEa4bOZtl5xSz
-- Respaldo del JSON: ROLLBACK-vigilante-promos-etecsa.json
--
-- ROLLBACK
--   Desactivar el workflow en n8n.
--   DROP FUNCTION IF EXISTS cerebro_promo_revision(jsonb);
-- =====================================================================

CREATE OR REPLACE FUNCTION cerebro_promo_revision(p_datos jsonb)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_res text;
BEGIN
  -- Deja constancia de que el vigilante paso por aqui, encuentre o no
  -- promocion. **Esto es lo que impide que el scraper muera en
  -- silencio**: si esta marca se queda vieja, esta roto.
  INSERT INTO cerebro_config (clave, valor, descripcion)
  VALUES ('promo_etecsa_ultima_revision', now()::text,
          'Ultima vez que el vigilante de promociones leyo etecsa.cu con exito. Si lleva mas de 2 dias sin moverse, el scraper esta roto.')
  ON CONFLICT (clave) DO UPDATE SET valor = now()::text, actualizado = now();

  IF coalesce((p_datos->>'ok')::boolean, false) THEN
    SELECT cerebro_promo_registrar(
      (p_datos->>'min_cup')::numeric,
      (p_datos->>'max_cup')::numeric,
      (p_datos->>'multiplicador')::numeric,
      (p_datos->>'desde')::date,
      (p_datos->>'hasta')::date,
      p_datos->>'titulo',
      p_datos->>'url',
      p_datos->>'texto') INTO v_res;
    RETURN v_res;
  END IF;

  RETURN 'revision hecha, sin promocion legible';
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING '[cerebro] revision de promo fallo: %', SQLERRM;
  RETURN 'fallo: ' || SQLERRM;
END $$;


-- ---------------------------------------------------------------------
-- VIGILAR QUE EL VIGILANTE SIGA VIVO
-- ---------------------------------------------------------------------
--   SELECT valor::timestamptz AS ultima_revision,
--          now() - valor::timestamptz AS hace_cuanto
--     FROM cerebro_config WHERE clave='promo_etecsa_ultima_revision';
--
-- Corre cada 12 h. Si `hace_cuanto` pasa de 2 dias, algo va mal:
-- etecsa.cu caido, el workflow desactivado, o la credencial rota.
--
-- **No pasa nada grave si se rompe**: sin promo vigente confirmada, el
-- bot vuelve a derivar las recargas a una persona, que es como estaba
-- antes. Nunca cotiza con un dato viejo.
-- =====================================================================
