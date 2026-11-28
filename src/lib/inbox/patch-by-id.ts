/**
 * Identity-preserving row patch for realtime updates.
 *
 * Realtime events carry one changed row, and remapping the whole list with
 * `array.map` gives every element a fresh identity, so every memoized row
 * re-renders (and, for the conversation list, every row loses reference
 * equality on each event). This returns the SAME array reference when there
 * is nothing to change, and otherwise a copy where only the matching element
 * is replaced.
 */
export function patchById<T extends { id: string }>(
  list: T[],
  id: string,
  patch: Partial<T>,
): T[] {
  const index = list.findIndex((item) => item.id === id);
  if (index === -1) return list;

  const current = list[index];
  const changed = (Object.keys(patch) as Array<keyof T>).some(
    (key) => !Object.is(current[key], patch[key]),
  );
  if (!changed) return list;

  const next = list.slice();
  next[index] = { ...current, ...patch };
  return next;
}
