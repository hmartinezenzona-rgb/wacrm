import { redirect } from "next/navigation";

// The Dashboard was removed (owner, 2026-10-28); keep old links and bookmarks working.
export default function DashboardPage() {
  redirect("/tablero");
}
