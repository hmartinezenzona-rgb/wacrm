import { redirect } from "next/navigation";

// The weekly calculator is now Finanzas > Semana (owner, 2026-10-28); keep old links and bookmarks working.
export default function CalculadoraPage() {
  redirect("/finanzas?tab=semana");
}
