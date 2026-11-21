"use client";

// Configuración del negocio de la cuenta actual (tabla negocio_config).
// La carga una vez por cuenta y además reemplaza los textos de la app con
// los del negocio (p. ej. «Encargos» en vez de «Ventas»).

import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from "react";
import { NextIntlClientProvider, useLocale, useMessages } from "next-intl";
import { createClient } from "@/lib/supabase/client";
import { useAuth } from "@/hooks/use-auth";
import { DEFAULT_NEGOCIO, leerNegocio, mezclarTextos, type NegocioConfig } from "@/lib/negocio/config";

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
