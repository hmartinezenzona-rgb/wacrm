import { redirect } from "next/navigation";

// "Finanzas e historial" is now Finanzas > Cierres (its history search lives there); keep old links and bookmarks working.
export default function ResumenPage() {
  redirect("/finanzas?tab=cierres");
}
