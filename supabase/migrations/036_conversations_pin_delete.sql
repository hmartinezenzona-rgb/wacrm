ALTER TABLE conversations
  ADD COLUMN IF NOT EXISTS deleted_at timestamptz,
  ADD COLUMN IF NOT EXISTS pinned_at  timestamptz;

CREATE INDEX IF NOT EXISTS idx_conversations_visibles
  ON conversations (account_id, last_message_at DESC)
  WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_conversations_fijadas
  ON conversations (account_id, pinned_at DESC)
  WHERE deleted_at IS NULL AND pinned_at IS NOT NULL;

COMMENT ON COLUMN conversations.deleted_at IS
  'Borrado suave: oculta el chat de la lista. NUNCA se borra la fila: messages va en CASCADE y deals bloquea el borrado.';
COMMENT ON COLUMN conversations.pinned_at IS
  'Fijado: el chat sube al principio de la lista. Se ordena por esta fecha descendente, NULLS LAST.';
