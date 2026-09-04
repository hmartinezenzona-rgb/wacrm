import type { CSSProperties } from "react";
import { cn } from "@/lib/utils";

/** Gris pizarra: para una etapa sin color, o un deal sin etapa. */
const COLOR_POR_DEFECTO = "#64748b"

interface StageBadgeProps {
  name: string
  /** El hex de `pipeline_stages.color`. */
  color?: string | null
  className?: string
}

/**
 * La pastilla con el nombre de la etapa, en su color.
 *
 * El color no se aplica aqui sino en la clase `.etapa` de globals.css, que
 * mezcla este hex con blanco o negro segun el modo. Ese reparto es
 * deliberado: si el componente calculara el color, habria que pasarle el modo
 * y volver a renderizar al cambiarlo. Asi lo resuelve el navegador en la
 * cascada, y la pastilla cambia sola.
 */
export function StageBadge({ name, color, className }: StageBadgeProps) {
  return (
    <span
      className={cn(
        "pastilla-color inline-flex shrink-0 items-center rounded-full border px-2 py-0.5 text-[11px] leading-tight font-medium",
        className,
      )}
      style={{ "--tono": color ?? COLOR_POR_DEFECTO } as CSSProperties}
    >
      {name}
    </span>
  )
}
