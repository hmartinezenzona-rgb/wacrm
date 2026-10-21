"use client";

import { useMemo } from "react";
import { contactAvatarDataUri, type AvatarGender } from "@/lib/avatars/contact-avatar";
import { cn } from "@/lib/utils";

interface ContactAvatarProps {
  /** Stable identity for the illustration: contact id, else conversation id or name. */
  seed: string;
  name: string;
  /** Gender group inferred from the name (`contacts.avatar_gender`); drives the hair pool. */
  gender?: AvatarGender | null;
  /** 1-based number inside the (account, gender) group (`contacts.avatar_seq`); keeps avatars distinct. */
  seq?: number | null;
  /** Real photo, when the contact has one. Wins over the illustration. */
  imageUrl?: string | null;
  /** Text shown if the illustration cannot be generated. Defaults to the name's first letter. */
  fallback?: string;
  /** Sizing, background and text styles of the circle, as at each call site. */
  className?: string;
}

/**
 * Customer avatar: real photo if any, otherwise a locally generated
 * illustrated face, otherwise the initial (the pre-illustration look).
 */
export function ContactAvatar({ seed, name, gender, seq, imageUrl, fallback, className }: ContactAvatarProps) {
  const generated = useMemo(() => {
    if (imageUrl) return null;
    try {
      return contactAvatarDataUri(seed, gender, seq);
    } catch {
      return null;
    }
  }, [imageUrl, seed, gender, seq]);

  return (
    <div
      className={cn(
        "flex shrink-0 items-center justify-center overflow-hidden rounded-full",
        className,
      )}
    >
      {imageUrl ? (
        <img src={imageUrl} alt={name} className="h-full w-full object-cover" />
      ) : generated ? (
        <img src={generated} alt="" className="h-full w-full object-cover" />
      ) : (
        (fallback ?? name.charAt(0).toUpperCase())
      )}
    </div>
  );
}
