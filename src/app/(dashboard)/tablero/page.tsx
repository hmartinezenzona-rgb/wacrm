"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { useTranslations } from "next-intl";
import { Loader2 } from "lucide-react";
import { createClient } from "@/lib/supabase/client";
import { PageHeader, PageShell } from "@/components/layout/page-header";
import { OperationsBoard } from "@/components/tablero/operations-board";
import type { BoardOperation, ServiceFilter } from "@/lib/tablero/board";
import { BoardFetchError, fetchBoard } from "@/lib/tablero/fetch";

const REFRESH_MS = 20_000;

type LoadState = "loading" | "ok" | "error" | "forbidden";

// Read-only operations board. Every account member can open it; the RPC
// itself refuses anyone else. Refreshes every 20 s and when the window
// regains focus; nothing on it changes an operation.
export default function TableroPage() {
  const t = useTranslations("Tablero");
  const [operations, setOperations] = useState<BoardOperation[]>([]);
  const [filter, setFilter] = useState<ServiceFilter>("all");
  const [state, setState] = useState<LoadState>("loading");
  const [now, setNow] = useState(() => new Date());
  const inFlight = useRef(false);

  const load = useCallback(async () => {
    if (inFlight.current) return;
    inFlight.current = true;
    try {
      const rows = await fetchBoard(createClient());
      setOperations(rows);
      setNow(new Date());
      setState("ok");
    } catch (err) {
      console.error("[tablero]", err);
      setState(err instanceof BoardFetchError && err.kind === "forbidden" ? "forbidden" : "error");
    } finally {
      inFlight.current = false;
    }
  }, []);

  useEffect(() => {
    void load();
    const timer = setInterval(() => void load(), REFRESH_MS);
    const onFocus = () => void load();
    window.addEventListener("focus", onFocus);
    return () => {
      clearInterval(timer);
      window.removeEventListener("focus", onFocus);
    };
  }, [load]);

  return (
    <PageShell>
      <PageHeader title={t("title")} description={t("description")} />
      {state === "forbidden" ? (
        <p role="alert" className="text-muted-foreground text-sm">{t("forbidden")}</p>
      ) : state === "loading" ? (
        <p className="text-muted-foreground flex items-center gap-2 text-sm">
          <Loader2 className="size-4 animate-spin" aria-hidden="true" />
          {t("loading")}
        </p>
      ) : (
        <>
          {state === "error" ? (
            <p role="alert" className="text-sm text-red-600 dark:text-red-400">{t("loadError")}</p>
          ) : null}
          <OperationsBoard operations={operations} filter={filter} onFilterChange={setFilter} now={now} />
        </>
      )}
    </PageShell>
  );
}
