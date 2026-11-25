"use client";

// ============================================================
// Menú de abajo — vista sencilla (negocio_config.sencillo) en celular.
//
// Como una app: hasta 4 secciones del negocio, ícono SIEMPRE con su
// nombre (las personas mayores no adivinan íconos solos), botones de
// 56 px de alto y la sección actual marcada con color y peso.
// El resto (Configuración, salir) sigue en el menú de la izquierda.
// ============================================================

import Link from "next/link";
import { usePathname } from "next/navigation";
import { useTranslations } from "next-intl";
import { useNegocio } from "@/hooks/use-negocio";
import { useTotalUnread } from "@/hooks/use-total-unread";
import { SECCIONES_MENU } from "./sidebar";
import { cn } from "@/lib/utils";

export function NavInferior() {
  const t = useTranslations("Sidebar");
  const pathname = usePathname();
  const { negocio } = useNegocio();
  const totalUnread = useTotalUnread();
  const items = negocio.menu.slice(0, 4).map((s) => ({ seccion: s, ...SECCIONES_MENU[s] }));
  if (items.length < 2) return null;

  return (
    <nav
      aria-label="Secciones"
      className="fixed inset-x-0 bottom-0 z-40 border-t-2 border-border bg-card pb-[env(safe-area-inset-bottom)] lg:hidden"
    >
      <div className="grid" style={{ gridTemplateColumns: `repeat(${items.length}, minmax(0, 1fr))` }}>
        {items.map((it) => {
          const activo = pathname === it.href || pathname.startsWith(it.href + "/");
          const Icono = it.icon;
          const sinLeer = it.seccion === "inbox" && totalUnread > 0;
          return (
            <Link
              key={it.href}
              href={it.href}
              aria-current={activo ? "page" : undefined}
              className={cn(
                "relative flex min-h-[60px] flex-col items-center justify-center gap-0.5 px-1 text-[13px] leading-tight",
                activo ? "font-extrabold text-primary" : "font-semibold text-muted-foreground",
              )}
            >
              <Icono className="h-6 w-6" strokeWidth={activo ? 2.6 : 2.1} aria-hidden />
              <span className="max-w-full truncate">{t(it.labelKey)}</span>
              {sinLeer && (
                <span className="absolute right-[calc(50%-22px)] top-1.5 min-w-5 rounded-full bg-primary px-1 text-center text-[11px] font-bold leading-5 text-primary-foreground">
                  {totalUnread > 99 ? "99+" : totalUnread}
                </span>
              )}
            </Link>
          );
        })}
      </div>
    </nav>
  );
}
