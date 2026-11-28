"use client";

// ---------------------------------------------------------------------------
// Quién lleva el hilo, visible desde la lista sin abrir la conversación.
//
// SÓLO SE PINTA LO QUE ROMPE LA NORMA
//   (nada)      el bot atiende — que es lo normal, y lo normal no se señala
//   🤖 ámbar    el bot está PAUSADO: nadie lo va a contestar solo
//   👤 azul     hay una persona dentro
//
// Antes salía un icono en TODAS las filas, incluido el caso normal. Un símbolo
// que aparece siempre deja de informar: el ojo lo descarta, y con él descarta
// los dos que sí importan. Ahora una lista tranquila está limpia, y cada icono
// que aparece significa algo.
//
// «Sin dato» tampoco pinta nada. Se confunde con el bot, y es un empate
// aceptable: en ninguno de los dos casos hay nada que hacer.
//
// DÓNDE VA
// En la segunda línea, delante del último mensaje. En la primera se estrujaba
// contra la hora en cuanto el nombre era largo, y quedaba pegado al nombre.
// Aquí tiene sitio fijo, no empuja nada y se lee en columna al recorrer la
// lista.
// ---------------------------------------------------------------------------

import { BotOff, User } from "lucide-react";
import {
  resolveConversationOwnership,
  type OwnershipEntrada,
} from "@/lib/inbox/conversation-ownership";

export function OwnershipIcon({
  conversation,
  agentName,
}: {
  conversation: OwnershipEntrada | null | undefined;
  /** Nombre de la persona asignada, si la página lo tiene a mano. */
  agentName?: string | null;
}) {
  const { ownership } = resolveConversationOwnership(conversation);

  if (ownership === "human") {
    const titulo = agentName ? `Atendida por ${agentName}` : "Atendida por una persona";
    return (
      <span
        title={titulo}
        aria-label={titulo}
        className="inline-flex shrink-0 items-center rounded-full border border-sky-500/30 bg-sky-500/15 p-0.5 text-sky-600 dark:text-sky-300"
      >
        <User className="h-3.5 w-3.5" />
      </span>
    );
  }

  if (ownership === "paused") {
    return (
      <span
        title="Bot pausado · nadie está atendiendo este chat"
        aria-label="Bot pausado"
        className="inline-flex shrink-0 items-center rounded-full border border-amber-500/40 bg-amber-500/15 p-0.5 text-amber-600 dark:text-amber-400"
      >
        <BotOff className="h-3.5 w-3.5" />
      </span>
    );
  }

  // El bot atendiendo, o sin dato: nada. Ver la cabecera.
  return null;
}
