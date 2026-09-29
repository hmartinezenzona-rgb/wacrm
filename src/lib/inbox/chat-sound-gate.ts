/**
 * Decide cuándo debe sonar el aviso de mensaje nuevo en el inbox (B1.5).
 *
 * Vive fuera del hook de audio, igual que `selection.ts`, para poder
 * probar la regla sin montar React ni un <audio>. La regla es simple a
 * propósito: solo suena para mensajes ENTRANTES del cliente, nunca para
 * la conversación que el agente tiene abierta ahora mismo, y nunca para
 * nada anterior o igual al último "marcar todas como leídas" — así el
 * aviso no puede volver a sonar por mensajes que ya se marcaron leídos.
 */

export interface ChatMessageForSoundGate {
  sender_type: string;
  conversation_id: string;
  /** ISO timestamp, e.g. `message.created_at`. */
  created_at: string;
}

export interface ChatSoundGate {
  /**
   * Marca "leído hasta ahora". Cualquier mensaje con `created_at` <=
   * este instante deja de sonar, aunque llegue (o vuelva a llegar) por
   * el canal de realtime después de esta llamada.
   */
  muteUntilNow(now?: number): void;
  /** true si el mensaje debe disparar el sonido de aviso. */
  shouldRing(
    message: ChatMessageForSoundGate,
    activeConversationId: string | null,
  ): boolean;
}

export function createChatSoundGate(): ChatSoundGate {
  let mutedAt = 0;

  return {
    muteUntilNow(now: number = Date.now()) {
      mutedAt = now;
    },
    shouldRing(message, activeConversationId) {
      if (message.sender_type !== "customer") return false;
      if (
        activeConversationId !== null &&
        message.conversation_id === activeConversationId
      ) {
        return false;
      }
      const createdAtMs = new Date(message.created_at).getTime();
      if (Number.isFinite(createdAtMs) && createdAtMs <= mutedAt) {
        return false;
      }
      return true;
    },
  };
}
