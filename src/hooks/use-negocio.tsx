"use client";

// Configuración del negocio de la cuenta actual (tabla negocio_config).
// La carga una vez por cuenta y además reemplaza los textos de la app con
// los del negocio (p. ej. «Encargos» en vez de «Ventas»).

import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from "react";
import { NextIntlClientProvider, useLocale, useMessages } from "next-intl";
import { usePathname } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { useAuth } from "@/hooks/use-auth";
import {
  DEFAULT_NEGOCIO,
  NEGOCIO_VISTA_KEY,
  leerNegocio,
  mezclarTextos,
  type NegocioConfig,
} from "@/lib/negocio/config";

interface NegocioContextValue {
  negocio: NegocioConfig;
  /** true mientras se lee la fila de la cuenta. */
  cargando: boolean;
  /** Vuelve a leer la configuración (después de guardarla). */
  recargar: () => void;
}

const NegocioContext = createContext<NegocioContextValue>({
  negocio: DEFAULT_NEGOCIO,
  cargando: true,
  recargar: () => {},
});

export function NegocioProvider({ children }: { children: ReactNode }) {
  const pathname = usePathname();
  const { profile, profileLoading } = useAuth();
  const accountId = profile?.account_id ?? null;
  const [estado, setEstado] = useState<{ cuenta: string | null; negocio: NegocioConfig } | null>(null);
  const [version, setVersion] = useState(0);
  const recargar = useCallback(() => setVersion((v) => v + 1), []);

  useEffect(() => {
    // Sin cuenta no hay nada que leer: se usan los valores por defecto.
    if (profileLoading || !accountId) return;
    let vivo = true;
    createClient()
      .from("negocio_config")
      .select("data")
      .eq("account_id", accountId)
      .maybeSingle()
      .then(({ data, error }) => {
        if (!vivo) return;
        // Si falla la lectura, la app sigue con los valores por defecto.
        setEstado({ cuenta: accountId, negocio: error ? DEFAULT_NEGOCIO : leerNegocio(data?.data) });
      });
    return () => {
      vivo = false;
    };
  }, [accountId, profileLoading, version]);

  const cargando = profileLoading || (!!accountId && estado?.cuenta !== accountId);
  const negocio = accountId && estado?.cuenta === accountId ? estado.negocio : DEFAULT_NEGOCIO;

  // Tema y vista sencilla van en <html> para que el CSS los vea en todas
  // partes (también en diálogos). Se guardan para que el script de
  // arranque los ponga antes de pintar la próxima vez (sin parpadeo).
  useEffect(() => {
    if (cargando) return;
    const d = document.documentElement;
    if (negocio.tema) d.dataset.tema = negocio.tema;
    else delete d.dataset.tema;
    if (negocio.sencillo) d.dataset.sencillo = "";
    else delete d.dataset.sencillo;
    try {
      localStorage.setItem(NEGOCIO_VISTA_KEY, JSON.stringify({ tema: negocio.tema, sencillo: negocio.sencillo }));
    } catch {
      // Sin localStorage solo hay un parpadeo al abrir; no pasa nada más.
    }
  }, [cargando, negocio.tema, negocio.sencillo]);

  // Pestaña del navegador y app instalada con el nombre del negocio.
  useEffect(() => {
    if (!cargando) document.title = negocio.nombre;
  }, [cargando, negocio.nombre, pathname]);

  const messages = useMessages();
  const locale = useLocale();
  const mezclados = useMemo(
    () => mezclarTextos(messages as Record<string, unknown>, negocio.textos),
    [messages, negocio.textos],
  );

  const valor = useMemo(() => ({ negocio, cargando, recargar }), [negocio, cargando, recargar]);

  return (
    <NegocioContext.Provider value={valor}>
      <NextIntlClientProvider locale={locale} messages={mezclados as typeof messages}>
        {children}
      </NextIntlClientProvider>
    </NegocioContext.Provider>
  );
}

export function useNegocio(): NegocioContextValue {
  return useContext(NegocioContext);
}
