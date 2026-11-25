import { leerMarca } from "@/lib/marca/leer";
import { COLORES_TEMA } from "@/lib/negocio/config";

// Manifest de la app instalable con el nombre, colores e ícono del negocio
// (antes era un archivo fijo de Onlinefreedom).

export const dynamic = "force-dynamic";

export async function GET() {
  const cfg = await leerMarca();
  const colores = cfg.tema ? COLORES_TEMA[cfg.tema] : { fondo: "#0A1626", principal: "#0A1626" };
  const icono = (n: number) => ({
    src: `/api/marca/icono?size=${n}`,
    sizes: `${n}x${n}`,
    type: "image/png",
    purpose: "any maskable",
  });
  return new Response(
    JSON.stringify({
      name: cfg.nombre,
      short_name: cfg.nombre,
      start_url: "/pipelines",
      scope: "/",
      display: "standalone",
      background_color: colores.fondo,
      theme_color: colores.principal,
      lang: "es-MX",
      icons: [icono(192), icono(512)],
    }),
    {
      headers: {
        "Content-Type": "application/manifest+json",
        "Cache-Control": "public, max-age=300, s-maxage=300",
      },
    },
  );
}
