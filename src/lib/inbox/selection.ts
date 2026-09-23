/**
 * Selección múltiple del Inbox y la acción de quitar del inbox.
 *
 * Vive fuera del componente para poder probarla sin montar React, y porque la
 * parte delicada no es el pintado: es que «quitar» siga siendo exactamente lo
 * que ya era —`deleted_at = now()`— y no se confunda con el estado `closed`,
 * que en esta aplicación significa otra cosa.
 */

/** Lo que se escribe al quitar del inbox. Nunca borra la fila. */
export function parcheOcultar(ahora: Date = new Date()): {
  deleted_at: string;
} {
  return { deleted_at: ahora.toISOString() };
}

/** Lo que se escribe al deshacer. */
export function parcheRestaurar(): { deleted_at: null } {
  return { deleted_at: null };
}

/** Marca o desmarca una conversación. Devuelve un Set nuevo. */
export function alternarSeleccion(
  seleccion: ReadonlySet<string>,
  id: string,
): Set<string> {
  const siguiente = new Set(seleccion);
  if (siguiente.has(id)) siguiente.delete(id);
  else siguiente.add(id);
  return siguiente;
}

/**
 * Quita de la selección lo que ya no está en la lista.
 *
 * Hace falta porque la lista se refresca sola —realtime, o el propio refetch
 * después de ocultar—, y una conversación seleccionada puede desaparecer por
 * debajo. Sin esto el contador diría «3 seleccionadas» con dos filas visibles.
 */
export function reconciliarSeleccion(
  seleccion: ReadonlySet<string>,
  idsVisibles: Iterable<string>,
): Set<string> {
  const visibles = new Set(idsVisibles);
  const siguiente = new Set<string>();
  for (const id of seleccion) if (visibles.has(id)) siguiente.add(id);
  return siguiente;
}

/** «1 seleccionada» / «4 seleccionadas». */
export function etiquetaSeleccion(n: number): string {
  return n === 1 ? "1 seleccionada" : `${n} seleccionadas`;
}

/**
 * El texto de la confirmación. Sin nombres ni teléfonos: en bulk no aportan
 * nada y meten PII en un diálogo que no la necesita.
 */
export function textoConfirmacion(n: number): string {
  return n === 1
    ? "¿Quitar esta conversación del inbox?\n\nEl historial se conserva."
    : `¿Quitar ${n} conversaciones del inbox?\n\nEl historial se conserva.`;
}

/** El texto del aviso posterior, con el que se ofrece deshacer. */
export function textoQuitadas(n: number): string {
  return n === 1
    ? "1 conversación quitada del inbox"
    : `${n} conversaciones quitadas del inbox`;
}

/**
 * ¿Hay que soltar la conversación abierta?
 *
 * Si el usuario quita del inbox justamente la que tiene abierta, el panel de la
 * derecha se quedaría enseñando un hilo que ya no está en la lista. Se decide
 * aquí para poder probarlo.
 */
export function laAbiertaSeVa(
  idAbierta: string | null | undefined,
  idsQuitadas: Iterable<string>,
): boolean {
  if (!idAbierta) return false;
  for (const id of idsQuitadas) if (id === idAbierta) return true;
  return false;
}
