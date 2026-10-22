"use client";

import { createContext, useContext } from "react";

import { useAusencia } from "@/hooks/use-ausencia";

type AwayModeValue = ReturnType<typeof useAusencia>;

const AwayModeContext = createContext<AwayModeValue | null>(null);

/** Runs the away-mode poller once for the whole dashboard shell. */
export function AwayModeProvider({ children }: { children: React.ReactNode }) {
  const value = useAusencia();
  return <AwayModeContext.Provider value={value}>{children}</AwayModeContext.Provider>;
}

export function useAwayMode(): AwayModeValue {
  const value = useContext(AwayModeContext);
  if (!value) throw new Error("useAwayMode must be used inside <AwayModeProvider>");
  return value;
}
