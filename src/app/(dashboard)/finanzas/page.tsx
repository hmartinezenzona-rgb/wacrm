import { redirect } from "next/navigation";
import { FinanzasView } from "@/components/finanzas/finanzas-view";
import { parseFinanzasTab } from "@/lib/finanzas/tabs";

export default async function FinanzasPage({
  searchParams,
}: {
  searchParams: Promise<{ [key: string]: string | string[] | undefined }>;
}) {
  const { tab } = await searchParams;
  // The Operaciones tab is gone (its history search moved into Cierres): keep old links and bookmarks working.
  if (tab === "operaciones") redirect("/finanzas?tab=cierres");
  return <FinanzasView tab={parseFinanzasTab(tab)} />;
}
