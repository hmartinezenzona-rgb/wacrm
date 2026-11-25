"use client";

// ============================================================
// Botón «Activar avisos en este celular» — edición Doña Miriam.
//
// Aparece arriba de cualquier pantalla mientras este celular no tenga los
// avisos prendidos. Un toque: pide permiso, suscribe el celular y manda un
// aviso de prueba. Si el permiso está bloqueado, explica cómo prenderlo.
// ============================================================

import { useEffect, useState } from "react";
import { Bell, BellRing, Check, Loader2 } from "lucide-react";
import { useTranslations } from "next-intl";

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
  // El texto se puede cambiar por negocio en Ajustes (textos.Avisos.pedir).
  const t = useTranslations("Avisos");
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

  const pidiendo = estado === "pedir" || estado === "activando";

  return (
    <section
      aria-label={t("titulo")}
      className="mb-5 flex flex-col gap-4 rounded-2xl border-2 border-border bg-card p-4 shadow-sm sm:flex-row sm:items-center sm:p-5"
    >
      <div className="flex min-w-0 flex-1 items-start gap-3.5 sm:items-center">
        <span
          aria-hidden
          className={`flex h-12 w-12 shrink-0 items-center justify-center rounded-full ${
            estado === "listo" ? "bg-ok-soft text-ok" : "bg-primary-soft text-primary"
          }`}
        >
          {estado === "listo" ? <Check className="h-6 w-6" strokeWidth={2.6} /> : <BellRing className="h-6 w-6" />}
        </span>
        <div className="flex min-w-0 flex-col gap-0.5">
          {pidiendo ? (
            <>
              <p className="text-base font-bold leading-snug">{t("titulo")}</p>
              <p className="text-[15px] leading-snug text-muted-foreground">{t("pedir")}</p>
            </>
          ) : estado === "listo" ? (
            <>
              <p className="text-base font-bold leading-snug">Avisos activados</p>
              <p className="text-[15px] leading-snug text-muted-foreground">
                Te mandé un aviso de prueba. Así te van a llegar.
              </p>
            </>
          ) : estado === "bloqueado" ? (
            <>
              <p className="text-base font-bold leading-snug">Los avisos están bloqueados</p>
              <p className="text-[15px] leading-snug text-muted-foreground">
                Toca el candado junto a la dirección, entra a <b>Permisos → Notificaciones</b>, elige{" "}
                <b>Permitir</b> y vuelve a abrir esta página.
              </p>
            </>
          ) : (
            <>
              <p className="text-base font-bold leading-snug">No se pudieron activar los avisos</p>
              <p className="text-[15px] leading-snug text-muted-foreground">Revisa el internet e inténtalo otra vez.</p>
            </>
          )}
        </div>
      </div>

      <div className="flex shrink-0 gap-2 sm:gap-1">
        {(pidiendo || estado === "error") && (
          <button
            type="button"
            onClick={activar}
            disabled={estado === "activando"}
            className="flex h-12 flex-1 items-center justify-center gap-2 rounded-xl bg-primary px-5 text-base font-bold text-primary-foreground transition-colors hover:bg-primary-hover active:scale-[0.98] disabled:opacity-60 sm:flex-none"
          >
            {estado === "activando" ? (
              <Loader2 className="h-5 w-5 animate-spin" aria-hidden />
            ) : (
              <Bell className="h-5 w-5" aria-hidden />
            )}
            {estado === "activando" ? "Activando…" : estado === "error" ? "Intentar otra vez" : "Activar avisos"}
          </button>
        )}
        <button
          type="button"
          onClick={cerrar}
          className="h-12 rounded-xl px-4 text-base font-semibold text-muted-foreground transition-colors hover:bg-muted hover:text-foreground"
        >
          {pidiendo || estado === "error" ? "Ahora no" : "Cerrar"}
        </button>
      </div>
    </section>
  );
}
