// ---------------------------------------------------------------------------
// ¿Quién lleva esta conversación ahora mismo?
//
// Una sola función para toda la app. Antes esto se deducía a ojo mirando el
// último mensaje, y eso es justo lo que NO se puede hacer: el último mensaje es
// historia, no propiedad. Una conversación donde escribió un humano hace tres
// días la lleva el bot si nadie está asignado y la IA está activa.
//
// LAS TRES REGLAS, en este orden
//   human   hay una persona asignada, O una persona respondió a mano
//   paused  la IA está apagada y nadie se ha hecho cargo
//   bot     la IA está activa, nadie asignado y sin pausa
//
// LO DE «UNA PERSONA RESPONDIÓ A MANO» NO ES UN ADORNO
// Se comprobó contra el flujo real del CRM: cuando un admin escribe desde el
// panel, `pauseAiOnAgentSend` escribe
//     ai_autoreply_disabled = true
//     ai_handoff_reason     = 'agent_replied'
//     ai_handoff_at         = now()
// y **NO toca `assigned_agent_id`**. Verificado además en producción el 6-sep:
// tras un envío manual la conversación quedó pausada y SIN asignar.
//
// Con la regla ingenua («humano = asignado»), ese chat se pintaría como «IA
// pausada», que es justo lo contrario de lo que pasó: hay una persona dentro.
// Por eso `agent_replied` cuenta como propiedad humana.
//
// `agent_replied` es una señal limpia: sólo la escribe el envío manual de una
// persona. El traspaso del propio bot deja `ai_handoff_summary` sin razón, y la
// pausa manual del panel no escribe ninguna. Comprobado en el código.
//
// Todo lo demás sale de `assigned_agent_id` y `ai_autoreply_disabled`, que son
// las mismas condiciones que usa el auto-reply para callarse y las que mira el
// Cerebro en `Contexto conversacion`. No se inventa una cuarta verdad.
//
// «paused» merece más atención que «bot»: es un hilo que alguien silenció y
// pudo quedarse olvidado. Nadie lo va a contestar solo.
// ---------------------------------------------------------------------------

export type ConversationOwnership = "bot" | "human" | "paused" | "unknown";

export type OwnershipEntrada = {
  /** `conversations.assigned_agent_id` */
  assigned_agent_id?: string | null;
  /** `conversations.ai_autoreply_disabled` */
  ai_autoreply_disabled?: boolean | null;
  /** `conversations.ai_handoff_reason` — `agent_replied` si escribió una persona. */
  ai_handoff_reason?: string | null;
};

/** La razón que escribe `pauseAiOnAgentSend` cuando un admin responde a mano. */
export const RAZON_RESPONDIO_PERSONA = "agent_replied";

export type OwnershipResuelto = {
  ownership: ConversationOwnership;
  /** El id de la persona asignada, si la hay. Para buscarle el nombre. */
  agentId: string | null;
};

/**
 * El estado ACTUAL del hilo. No mira mensajes, ni fechas, ni quién habló el
 * último: sólo el estado que decide si el bot puede contestar.
 */
export function resolveConversationOwnership(
  conversacion: OwnershipEntrada | null | undefined,
): OwnershipResuelto {
  if (!conversacion) return { ownership: "unknown", agentId: null };

  const asignado = conversacion.assigned_agent_id ?? null;
  if (asignado) return { ownership: "human", agentId: asignado };

  const pausada = conversacion.ai_autoreply_disabled === true;

  // Una persona escribió a mano: el hilo tiene dueño aunque nadie lo haya
  // asignado. Se exige que siga pausada: si la IA volvió a estar activa, el
  // relevo terminó y contesta el bot.
  if (pausada && conversacion.ai_handoff_reason === RAZON_RESPONDIO_PERSONA) {
    return { ownership: "human", agentId: null };
  }

  if (pausada) return { ownership: "paused", agentId: null };

  // `undefined` es «la fila no traía el campo», no «está activa». Sin ese dato
  // no se afirma que conteste el bot.
  if (conversacion.ai_autoreply_disabled === false) {
    return { ownership: "bot", agentId: null };
  }

  return { ownership: "unknown", agentId: null };
}
