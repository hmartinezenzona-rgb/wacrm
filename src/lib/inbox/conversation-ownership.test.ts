// Quién lleva el hilo AHORA. No quién habló el último.
//
// La prueba que importa es la de abajo del todo: una conversación donde
// escribió una persona hace días la lleva el bot si nadie está asignado y la
// IA está activa. Deducir la propiedad del historial es exactamente el error
// que esta función existe para impedir.
import { describe, expect, it } from "vitest";
import { resolveConversationOwnership } from "./conversation-ownership";

describe("resolveConversationOwnership", () => {
  it("humano cuando hay alguien asignado", () => {
    const r = resolveConversationOwnership({
      assigned_agent_id: "377b0c8c-c025-46ff-8088-7a929080831e",
      ai_autoreply_disabled: false,
    });
    expect(r.ownership).toBe("human");
    expect(r.agentId).toBe("377b0c8c-c025-46ff-8088-7a929080831e");
  });

  it("humano gana al bot", () => {
    expect(
      resolveConversationOwnership({
        assigned_agent_id: "alguien",
        ai_autoreply_disabled: false,
      }).ownership,
    ).toBe("human");
  });

  it("humano gana también a la pausa: si hay dueño, el hilo tiene dueño", () => {
    expect(
      resolveConversationOwnership({
        assigned_agent_id: "alguien",
        ai_autoreply_disabled: true,
      }).ownership,
    ).toBe("human");
  });

  it("un envío manual del admin cuenta como HUMANO, aunque no asigne a nadie", () => {
    // Es lo que hace `pauseAiOnAgentSend` de verdad: pausa y escribe la razón,
    // sin tocar `assigned_agent_id`. Verificado en producción el 6-sep.
    const r = resolveConversationOwnership({
      assigned_agent_id: null,
      ai_autoreply_disabled: true,
      ai_handoff_reason: "agent_replied",
    });
    expect(r.ownership).toBe("human");
    expect(r.agentId).toBeNull(); // no hay a quién nombrar, y no se inventa
  });

  it("el traspaso del propio bot (sin razón) es pausa, no humano", () => {
    expect(
      resolveConversationOwnership({
        assigned_agent_id: null,
        ai_autoreply_disabled: true,
        ai_handoff_reason: null,
      }).ownership,
    ).toBe("paused");
  });

  it("«agent_replied» con la IA ya activa NO es humano: el relevo terminó", () => {
    expect(
      resolveConversationOwnership({
        assigned_agent_id: null,
        ai_autoreply_disabled: false,
        ai_handoff_reason: "agent_replied",
      }).ownership,
    ).toBe("bot");
  });

  it("el flujo completo: envío manual -> humano, Reanudar IA -> bot", () => {
    const trasEnvioManual = {
      assigned_agent_id: null,
      ai_autoreply_disabled: true,
      ai_handoff_reason: "agent_replied",
    };
    expect(resolveConversationOwnership(trasEnvioManual).ownership).toBe("human");
    // «Reanudar IA» limpia razón y pausa, y suelta cualquier asignación
    const trasReanudar = {
      assigned_agent_id: null,
      ai_autoreply_disabled: false,
      ai_handoff_reason: null,
    };
    expect(resolveConversationOwnership(trasReanudar).ownership).toBe("bot");
  });

  it("pausada gana al bot", () => {
    expect(
      resolveConversationOwnership({
        assigned_agent_id: null,
        ai_autoreply_disabled: true,
      }).ownership,
    ).toBe("paused");
  });

  it("bot cuando la IA está activa y nadie asignado", () => {
    expect(
      resolveConversationOwnership({
        assigned_agent_id: null,
        ai_autoreply_disabled: false,
      }).ownership,
    ).toBe("bot");
  });

  it("reanudar devuelve el hilo al bot", () => {
    const pausada = { assigned_agent_id: null, ai_autoreply_disabled: true };
    expect(resolveConversationOwnership(pausada).ownership).toBe("paused");
    // «Reanudar IA» limpia la pausa y suelta la asignación
    const reanudada = { assigned_agent_id: null, ai_autoreply_disabled: false };
    expect(resolveConversationOwnership(reanudada).ownership).toBe("bot");
  });

  it("sin el dato, no se afirma nada", () => {
    expect(resolveConversationOwnership({}).ownership).toBe("unknown");
    expect(resolveConversationOwnership(null).ownership).toBe("unknown");
    expect(resolveConversationOwnership(undefined).ownership).toBe("unknown");
  });

  it("el historial NO decide: un mensaje humano viejo no hace al hilo humano", () => {
    // La función ni siquiera recibe mensajes. Esta prueba fija el contrato:
    // si alguien añade `last_message` a la entrada esperando que cambie el
    // resultado, esto se lo recuerda.
    // El historial NO forma parte de la entrada, a propósito: por eso este
    // campo extra no cambia nada.
    const conMensajeHumanoViejo = {
      assigned_agent_id: null,
      ai_autoreply_disabled: false,
      last_human_message_at: "2026-09-01T10:00:00Z",
    };
    expect(resolveConversationOwnership(conMensajeHumanoViejo).ownership).toBe("bot");
  });
});
