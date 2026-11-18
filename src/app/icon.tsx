import { ImageResponse } from "next/og";

// Replaces the default Next.js favicon with the brand mark — Hostinger
// violet rounded square + white chat-square glyph — matching the
// sidebar logo in `src/components/layout/sidebar.tsx`. Next.js renders
// this at build time and auto-injects <link rel="icon"> into <head>.
//
// This route takes precedence over src/app/favicon.ico, which is the
// Next.js default and can stay on disk harmlessly (or be removed).

export const runtime = "edge";
export const size = { width: 32, height: 32 };
export const contentType = "image/png";

export default function Icon() {
  return new ImageResponse(
    (
      <div
        style={{
          width: "100%",
          height: "100%",
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
          background: "#0A1626", // Onlinefreedom
          borderRadius: 6,
        }}
      >
        <svg width="24" height="24" viewBox="-1 0 86 100">
          <circle cx="42" cy="50" r="40" fill="none" stroke="#22D3A6" strokeWidth="7" opacity="0.4" />
          <circle cx="53" cy="50" r="26" fill="none" stroke="#22D3A6" strokeWidth="7" opacity="0.7" />
          <circle cx="61" cy="50" r="13" fill="none" stroke="#22D3A6" strokeWidth="7" />
          <circle cx="66" cy="50" r="5" fill="#22D3A6" />
        </svg>
      </div>
    ),
    { ...size },
  );
}
