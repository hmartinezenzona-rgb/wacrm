import { ImageResponse } from "next/og";
import { leerMarca } from "@/lib/marca/leer";

// Ícono cuadrado del negocio en PNG, del tamaño pedido (?size=192).
// Lo usan la pestaña, la app instalada (manifest) y los avisos. Sale de
// negocio_config.icono; sin ícono, el de Onlinefreedom.

export const dynamic = "force-dynamic";

const TAMANOS = [32, 48, 64, 96, 180, 192, 512];

export async function GET(request: Request) {
  const pedido = Number(new URL(request.url).searchParams.get("size")) || 192;
  const lado = TAMANOS.reduce((a, b) => (Math.abs(b - pedido) < Math.abs(a - pedido) ? b : a));
  const { icono } = await leerMarca();

  const contenido = icono ? (
    // eslint-disable-next-line @next/next/no-img-element, jsx-a11y/alt-text
    <img src={icono} width={lado} height={lado} />
  ) : (
    <div
      style={{
        width: "100%",
        height: "100%",
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        background: "#0A1626",
      }}
    >
      <svg width={lado * 0.62} height={lado * 0.62} viewBox="-1 0 86 100">
        <circle cx="42" cy="50" r="40" fill="none" stroke="#22D3A6" strokeWidth="7" opacity="0.4" />
        <circle cx="53" cy="50" r="26" fill="none" stroke="#22D3A6" strokeWidth="7" opacity="0.7" />
        <circle cx="61" cy="50" r="13" fill="none" stroke="#22D3A6" strokeWidth="7" />
        <circle cx="66" cy="50" r="5" fill="#22D3A6" />
      </svg>
    </div>
  );

  return new ImageResponse(contenido, {
    width: lado,
    height: lado,
    headers: { "Cache-Control": "public, max-age=300, s-maxage=300" },
  });
}
