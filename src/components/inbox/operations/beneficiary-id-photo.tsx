"use client";

import { useState } from "react";
import { useTranslations } from "next-intl";
import { IdCard } from "lucide-react";
import { IdPhotoPicker } from "./id-photo-picker";
import { corregirBeneficiario } from "@/lib/remittance-operations/commands";

interface BeneficiaryIdPhotoProps {
  beneficiaryId: string;
  conversationId: string;
  idPhotoWamid: string | null;
  idPhotoUrl: string | null;
  /** Only an editor can choose the photo; everyone else just sees whether it is there. */
  editable: boolean;
  onChanged: () => void;
}

/**
 * The cash recipient's ID photo row on the card: "Ver ID" (or the missing note) and, for an editor, the picker
 * that chooses the photo from the conversation's images ("Elegir del chat" / "Cambiar"). A choice is stored at once
 * through the beneficiary correction and the card refreshes.
 */
export function BeneficiaryIdPhoto({
  beneficiaryId,
  conversationId,
  idPhotoWamid,
  idPhotoUrl,
  editable,
  onChanged,
}: BeneficiaryIdPhotoProps) {
  const t = useTranslations("Inbox.operationsPanel");
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handlePick(wamid: string) {
    setError(null);
    setPending(true);
    const result = await corregirBeneficiario(beneficiaryId, { id_photo_wamid: wamid });
    setPending(false);
    if (!result.ok) {
      setError(result.error);
      return;
    }
    onChanged();
  }

  return (
    <div className="space-y-0.5">
      <div className="flex flex-wrap items-center gap-x-1">
        {idPhotoUrl ? (
          <a
            href={idPhotoUrl}
            target="_blank"
            rel="noopener noreferrer"
            className="flex items-center gap-2 px-2 text-xs font-medium text-primary underline-offset-2 hover:underline"
          >
            <IdCard className="size-3.5" aria-hidden="true" />
            {t("viewIdPhoto")}
          </a>
        ) : (
          <p className="flex items-center gap-2 px-2 text-xs text-amber-600 dark:text-amber-400">
            <IdCard className="size-3.5" aria-hidden="true" />
            {t("idPhotoMissing")}
          </p>
        )}
        {editable && (
          <IdPhotoPicker
            conversationId={conversationId}
            selectedWamid={idPhotoWamid}
            label={idPhotoUrl ? t("idPhotoChange") : t("idPhotoPick")}
            disabled={pending}
            onPick={(wamid) => void handlePick(wamid)}
          />
        )}
      </div>
      {error && (
        <p role="alert" className="px-2 text-xs text-destructive">
          {error}
        </p>
      )}
    </div>
  );
}

interface IdPhotoFormRowProps {
  conversationId: string;
  /** The wamid chosen so far in the form (null = none). */
  value: string | null;
  disabled?: boolean;
  onChange: (wamid: string) => void;
}

/** The same control inside the edit and add forms: the choice only fills the form; the form's check sends it. */
export function IdPhotoFormRow({ conversationId, value, disabled = false, onChange }: IdPhotoFormRowProps) {
  const t = useTranslations("Inbox.operationsPanel");
  return (
    <div className="flex flex-wrap items-center gap-x-1">
      <p className="flex items-center gap-2 px-1 text-xs text-muted-foreground">
        <IdCard className="size-3.5" aria-hidden="true" />
        {value ? t("idPhotoChosen") : t("idPhotoMissing")}
      </p>
      <IdPhotoPicker
        conversationId={conversationId}
        selectedWamid={value}
        label={value ? t("idPhotoChange") : t("idPhotoPick")}
        disabled={disabled}
        onPick={onChange}
      />
    </div>
  );
}
