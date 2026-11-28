"use client";

import { useTranslations } from "next-intl";
import { Bell, BellOff } from "lucide-react";
import { Button } from "@/components/ui/button";

interface NotifyToggleProps {
  /** Whether the panel action will message the customer. */
  notify: boolean;
  onChange: (notify: boolean) => void;
  disabled?: boolean;
}

/**
 * Bell toggle shown next to every panel action that can message the
 * customer (verify, force-verify, deliver, manual close). Pressed = the
 * customer is notified; the caller owns the default and sends the chosen
 * value to the route as `notify`.
 */
export function NotifyToggle({ notify, onChange, disabled }: NotifyToggleProps) {
  const t = useTranslations("Inbox.operationsPanel.notify");
  const label = notify ? t("on") : t("off");
  const Icon = notify ? Bell : BellOff;

  return (
    <Button
      type="button"
      variant="ghost"
      size="icon-sm"
      aria-pressed={notify}
      aria-label={label}
      title={label}
      disabled={disabled}
      onClick={() => onChange(!notify)}
    >
      <Icon className={notify ? "text-emerald-600 dark:text-emerald-400" : "text-muted-foreground"} aria-hidden="true" />
    </Button>
  );
}
