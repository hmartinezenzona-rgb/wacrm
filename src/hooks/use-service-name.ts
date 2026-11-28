"use client";

import { useTranslations } from "next-intl";
import { operationServiceId, resolveServiceId, type OperationNameInput } from "@/lib/service-name";

/** Name of a service key of either vocabulary, from the `ServiceNames` catalog; an unknown key prints as it is. */
export function useServiceName(): (key: string | null | undefined) => string {
  const t = useTranslations("ServiceNames");
  return (key) => {
    const id = resolveServiceId(key);
    return id ? t(id) : (key ?? "");
  };
}

/** Name of an operation, with the database's precedence (see `operationServiceId`). */
export function useOperationServiceName(): (operation: OperationNameInput) => string {
  const t = useTranslations("ServiceNames");
  return (operation) => t(operationServiceId(operation));
}
