// ============================================================
// Un envío humano toma la conversación: el bot se calla.
//
// EL CASO QUE ABRE ESTE FICHERO
// -----------------------------
// 4-sep-2026. Un operador entró a atender una conversación que llevaba el bot y
// escribió cinco mensajes. El bot siguió activo y contestó tres veces por
// encima: el «Ok gracias» del cliente era para el operador y lo respondió el
// bot, y el mensaje siguiente del cliente fue «Disculpe mande un mensaje
// equivocado». Estaba hablando con dos.
//
// Medido después sobre 31 días de `messages`: 44 respuestas del bot salieron
// dentro de los 5 minutos siguientes a un mensaje humano, en 35 conversaciones.
//
// ESTO YA EXISTÍA A MEDIAS
// ------------------------
// `sendMessageToConversation` ya pausa los `flow_runs` activos cuando escribe
// un agente, con este comentario:
//
//     "the agent stepping in is the strongest 'yield, human is here' signal"
//
// El razonamiento es correcto y se aplicaba a los flows, no al bot. Esto
// extiende la misma señal al bot.
//
// POR QUÉ AQUÍ Y NO EN EL CORE COMPARTIDO
// ----------------------------------------
// `sendMessageToConversation` lo llaman DOS caminos: el panel (sesión humana
// verificada con `supabase.auth.getUser()`) y la API pública
// (`requireApiKey`, que es el Cerebro). Ponerlo en el core haría que el bot se
// pausara a sí mismo con cada respuesta.
//
// La distinción no es una heurística sobre el contenido del mensaje: es el tipo
// de autenticación de la ruta. Son dos puertas distintas.
//
// LA PAUSA NO CADUCA — DECISIÓN DEL DUEÑO (6-sep-2026)
// ----------------------------------------------------
// Si una persona tomó el chat, el sistema no decide por reloj que dejó de
// atenderlo. Se reanuda con la acción explícita que ya existe en la bandeja
// («Reanudar IA»), que además limpia la asignación y el motivo del relevo.
// La asignación manual sí caduca a los 10 minutos, y eso no cambia: son dos
// cosas distintas, y por eso esto NO toca `assigned_agent_id`.
//
// LO QUE ESTO NO CUBRE
// --------------------
// La carrera de dentro del turno: el cliente escribe, el Cerebro tarda 17
// segundos de mediana en contestar, y la persona escribe en medio. Cuando eso
// pasa, esta pausa llega tarde porque el turno ya estaba en marcha. Eso lo
// cierra la valla final de propiedad, en el propio Cerebro, justo antes de
// enviar (`cerebro_valla_de_propiedad`).
// ============================================================
import type { SupabaseClient } from '@supabase/supabase-js'

/** Por qué se pausó. La ruta de reanudar limpia este campo junto al resto. */
export const AGENT_REPLIED_REASON = 'agent_replied'

/**
 * Marca la conversación como atendida por una persona.
 *
 * Best-effort a propósito: si esto falla, el mensaje del operador YA salió y no
 * se le puede devolver un error por algo que no le impide trabajar. Se registra
 * y se sigue.
 */
export async function pauseAiOnAgentSend(
  supabase: SupabaseClient,
  conversationId: string
): Promise<{ paused: boolean; alreadyPaused: boolean }> {
  try {
    const { data: conv, error: readErr } = await supabase
      .from('conversations')
      .select('ai_autoreply_disabled')
      .eq('id', conversationId)
      .single()

    if (readErr || !conv) {
      console.error(
        '[inbox] pause-ai-on-agent-send: no se pudo leer la conversación:',
        readErr?.message
      )
      return { paused: false, alreadyPaused: false }
    }

    // Ya estaba pausada: no se vuelve a escribir. Pisar `ai_handoff_at` borraría
    // cuándo se relevó de verdad, y ese dato es el que se audita después.
    if (conv.ai_autoreply_disabled) {
      return { paused: true, alreadyPaused: true }
    }

    const { error: writeErr } = await supabase
      .from('conversations')
      .update({
        ai_autoreply_disabled: true,
        ai_handoff_reason: AGENT_REPLIED_REASON,
        ai_handoff_at: new Date().toISOString(),
      })
      .eq('id', conversationId)

    if (writeErr) {
      console.error(
        '[inbox] pause-ai-on-agent-send: no se pudo pausar:',
        writeErr.message
      )
      return { paused: false, alreadyPaused: false }
    }

    return { paused: true, alreadyPaused: false }
  } catch (err) {
    console.error('[inbox] pause-ai-on-agent-send lanzó:', err)
    return { paused: false, alreadyPaused: false }
  }
}
