-- Query of the notifier's "Leer secreto" node (n8n `wGud0KGR6eMqqfMQ`), the one that runs BEFORE "Filtrar cambio de etapa"
-- (Webhook -> Leer secreto -> Filtrar -> Buscar telefono -> Enviar por WaCRM). $1 = the operation id.
-- grupo_pendientes: the OTHER members of the operation's mixed send that are neither completed nor cancelled, counted
-- when the notifier runs (0 for the last part to complete, and 0 as well for an operation with no group).
-- n8n Postgres node: no semicolon and no backslash inside the text (the comment lines below are not part of the node).
SELECT cerebro_config_get('notify_secret') AS secreto,
       cerebro_config_get('notify_secret_legacy') AS secreto_legacy,
       EXISTS (SELECT 1 FROM remittance_admin_audit a
                WHERE a.table_name = 'remittance_operations'
                  AND a.row_id::text = $1
                  AND a.action IN ('human_deposit_verification','human_forced_verification','automation_late_deposit_verification')
                  AND a.created_at >= now() - interval '15 minutes') AS verificacion_manual,
       (SELECT coalesce(json_agg(json_build_object(
                 'beneficiary_type', rb.beneficiary_type, 'name', rb.name,
                 'card_number', rb.card_number, 'phone', rb.phone,
                 'zelle_account', rb.zelle_account, 'address', rb.address, 'id_photo_wamid', rb.id_photo_wamid,
                 'reference', rb.reference, 'contact_phone', rb.contact_phone, 'amount', rb.amount) ORDER BY rb.position, rb.created_at), '[]'::json)
          FROM remittance_beneficiaries rb
         WHERE rb.operation_id::text = $1 AND rb.status = 'vigente') AS beneficiarios,
       (SELECT d.notes FROM remittance_operations o JOIN deals d ON d.id = o.deal_id
         WHERE o.id::text = $1) AS notas_deal,
       cerebro_riel_op(NULLIF($1, '')::uuid) AS riel,
       (SELECT count(*) FROM remittance_operations m
         WHERE m.mixed_group_id IS NOT NULL
           AND m.mixed_group_id = (SELECT g.mixed_group_id FROM remittance_operations g WHERE g.id::text = $1)
           AND m.id::text <> $1
           AND m.status NOT IN ('completed', 'cancelled')) AS grupo_pendientes
