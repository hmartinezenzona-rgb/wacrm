import Image from "next/image";
import { cn } from "@/lib/utils";

/**
 * La marca del negocio: el monograma OS de Osmany's Services.
 *
 * Sustituye al cuadrado violeta con el globo de mensaje que venia del
 * fork. Ese glifo, ademas, es el mismo icono que usa "Inbox" en el menu
 * lateral — la marca y una seccion compartian dibujo.
 *
 * Se usa SOLO el monograma, no el logotipo completo: a 32px, que es el
 * tamano real en el menu y en la pestana del navegador, las palabras
 * "OSMANY'S SERVICES" no se leen. El logotipo entero vive en
 * `/logo-full.png` para sitios donde hay espacio.
 *
 * `alt=""` a proposito: en los cuatro sitios donde aparece hay al lado
 * un texto que ya dice de quien es (el nombre en el menu, el titulo en
 * las pantallas de acceso), asi que la imagen es decorativa y repetirlo
 * solo anadiria ruido a un lector de pantalla.
 */
export function BrandMark({
  size = 32,
  className,
}: {
  size?: number;
  className?: string;
}) {
  return (
    <Image
      src="/logo-mark.png"
      alt=""
      width={size}
      height={size}
      // La marca esta sobre el pliegue en todas las pantallas donde sale.
      priority
      className={cn("shrink-0 rounded-lg object-cover", className)}
    />
  );
}
