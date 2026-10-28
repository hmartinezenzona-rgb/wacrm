import { redirect } from "next/navigation";

// "Finanzas e historial" is now Finanzas > Operaciones (owner, 2026-10-28); keep old links and bookmarks working.
export default function ResumenPage() {
  redirect("/finanzas?tab=operaciones");
}
