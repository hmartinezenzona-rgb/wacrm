import { FinanzasView } from "@/components/finanzas/finanzas-view";
import { parseFinanzasTab } from "@/lib/finanzas/tabs";

export default async function FinanzasPage({
  searchParams,
}: {
  searchParams: Promise<{ [key: string]: string | string[] | undefined }>;
}) {
  const { tab } = await searchParams;
  return <FinanzasView tab={parseFinanzasTab(tab)} />;
}
