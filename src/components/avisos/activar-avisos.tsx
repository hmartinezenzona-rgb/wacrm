"use client";

// ============================================================
// Botón «Activar avisos en este celular» — edición Doña Miriam.
//
// Aparece arriba de cualquier pantalla mientras este celular no tenga los
// avisos prendidos. Un toque: pide permiso, suscribe el celular y manda un
// aviso de prueba. Si el permiso está bloqueado, explica cómo prenderlo.
// ============================================================

import { useEffect, useState } from "react";
import { BellRing, X } from "lucide-react";

type Estado = "oculto" | "pedir" | "activando" | "listo" | "bloqueado" | "error";
const CLAVE_CERRADO = "avisos-cerrado-hasta";

function base64ABytes(b64: string): Uint8Array<ArrayBuffer> {
  const relleno = "=".repeat((4 - (b64.length % 4)) % 4);
  const crudo = atob((b64 + relleno).replace(/-/g, "+").replace(/_/g, "/"));
  const bytes = new Uint8Array(new ArrayBuffer(crudo.length));
  for (let i = 0; i < crudo.length; i++) bytes[i] = crudo.charCodeAt(i);
  return bytes;
}

async function guardar(sub: PushSubscription) {
  const r = await fetch("/api/avisos/suscribir", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ subscription: sub.toJSON(), dispositivo: navigator.userAgent }),
  });
  if (!r.ok) throw new Error("No se pudo guardar");
}

export function ActivarAvisos() {
  const [estado, setEstado] = useState<Estado>("oculto");

  useEffect(() => {
    const soportado = "serviceWorker" in navigator && "PushManager" in window && "Notification" in window;
    if (!soportado) return;
    let cancelado = false;
    (async () => {
      try {
        const reg = await navigator.serviceWorker.register("/sw.js");
        const sub = await reg.pushManager.getSubscription();
        if (cancelado) return;
        if (sub && Notification.permission === "granted") {
          guardar(sub).catch(() => {}); // por si el servidor la perdió
          return;
        }
        let hasta = 0;
        try {
          hasta = Number(localStorage.getItem(CLAVE_CERRADO) || 0);
        } catch {}
        if (Date.now() < hasta) return;
        setEstado(Notification.permission === "denied" ? "bloqueado" : "pedir");
      } catch {
        /* sin service worker no hay avisos; el CRM sigue funcionando */
      }
    })();
    return () => {
      cancelado = true;
    };
  }, []);

  async function activar() {
    setEstado("activando");
    try {
      const permiso = await Notification.requestPermission();
      if (permiso !== "granted") return setEstado("bloqueado");
      const reg = await navigator.serviceWorker.ready;
      const { publica } = await fetch("/api/avisos/llave").then((r) => r.json());
      const sub =
        (await reg.pushManager.getSubscription()) ||
        (await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: base64ABytes(publica) }));
      await guardar(sub);
      await fetch("/api/avisos/probar", { method: "POST" });
      setEstado("listo");
      setTimeout(() => setEstado("oculto"), 8000);
    } catch {
      setEstado("error");
    }
  }

  function cerrar() {
    try {
      localStorage.setItem(CLAVE_CERRADO, String(Date.now() + 3 * 86400000));
    } catch {}
    setEstado("oculto");
  }

  if (estado === "oculto") return null;

  return (
    <div className="mb-4 flex items-start gap-3 rounded-xl border border-primary/40 bg-primary/10 p-4">
      <BellRing className="mt-0.5 h-6 w-6 shrink-0 text-primary" />
      <div className="flex min-w-0 flex-1 flex-col gap-2">
        {estado === "pedir" || estado === "activando" ? (
          <>
            <p className="text-base font-semibold">Recibe un aviso en este celular cada vez que llegue un encargo</p>
            <button
              type="button"
              onClick={activar}
              disabled={estado === "activando"}
              className="h-12 self-start rounded-lg bg-primary px-5 text-base font-bold text-primary-foreground disabled:opacity-60"
            >
              {estado === "activando" ? "Activando…" : "🔔 Activar avisos"}
            </button>
          </>
        ) : estado === "listo" ? (
          <p className="text-base font-semibold">¡Listo! Te mandé un aviso de prueba. Así te van a llegar los encargos.</p>
        ) : estado === "bloqueado" ? (
          <p className="text-base">
            Los avisos están bloqueados en este navegador. Toca el candado junto a la dirección, entra a{" "}
            <b>Permisos → Notificaciones</b>, elige <b>Permitir</b> y vuelve a abrir esta página.
          </p>
        ) : (
          <p className="text-base">
            No se pudieron activar los avisos.{" "}
            <button type="button" onClick={activar} className="font-semibold text-primary underline">
              Intentar otra vez
            </button>
          </p>
        )}
      </div>
      <button
        type="button"
        onClick={cerrar}
        aria-label="Cerrar"
        className="flex h-9 w-9 shrink-0 items-center justify-center rounded-md text-muted-foreground hover:bg-muted"
      >
        <X className="h-5 w-5" />
      </button>
    </div>
  );
}
