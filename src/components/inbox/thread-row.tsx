"use client";

import { memo, useMemo } from "react";
import { useTranslations } from "next-intl";
import { cn } from "@/lib/utils";
import type { Message, MessageReaction } from "@/types";
import { MessageActions } from "./message-actions";
import { MessageBubble } from "./message-bubble";
import { buildReplyPreview } from "./reply-quote";

interface ThreadRowProps {
  message: Message;
  /** The message this one replies to, when it is loaded. */
  replyParent?: Message | null;
  reactions?: MessageReaction[];
  currentUserId?: string;
  /** Renders the jump-to target ring (slice 4 wires this to Virtuoso). */
  highlighted?: boolean;
  /** Contact display name, used for the quoted author label. */
  contactDisplayName: string;
  /** Stable, id-based callbacks so memo can actually bail out. */
  onReply: (message: Message) => void;
  onReact: (messageId: string, emoji: string) => void;
  onTogglePill: (messageId: string, emoji: string) => void;
  onJump: (messageId: string) => void;
}

function ThreadRowBase({
  message,
  replyParent,
  reactions,
  currentUserId,
  highlighted = false,
  contactDisplayName,
  onReply,
  onReact,
  onTogglePill,
  onJump,
}: ThreadRowProps) {
  const t = useTranslations("Inbox.messageThread");
  const tQuote = useTranslations("Inbox.replyQuote");

  const reply = useMemo(() => {
    if (!replyParent) return null;
    const parentIsAgent =
      replyParent.sender_type === "agent" || replyParent.sender_type === "bot";
    return {
      authorLabel: parentIsAgent ? t("me") : contactDisplayName,
      preview: buildReplyPreview(replyParent, tQuote),
    };
  }, [replyParent, contactDisplayName, t, tQuote]);

  return (
    <div
      data-message-id={message.id}
      className={cn(
        "scroll-mt-24 rounded-xl transition-shadow duration-300",
        highlighted && "ring-2 ring-primary ring-offset-2 ring-offset-background",
      )}
    >
      <MessageActions
        message={message}
        onReply={() => onReply(message)}
        onReact={(emoji: string) => onReact(message.id, emoji)}
      >
        <MessageBubble
          message={message}
          reply={reply}
          reactions={reactions}
          currentUserId={currentUserId}
          onToggleReaction={(emoji: string) => onTogglePill(message.id, emoji)}
          onJumpToReply={
            message.reply_to_message_id
              ? () => onJump(message.reply_to_message_id!)
              : undefined
          }
        />
      </MessageActions>
    </div>
  );
}

/**
 * One thread row (actions + bubble) memoized on its props. The thread passes
 * stable id-based callbacks and keeps `message` references stable, so an
 * unrelated state change in the thread does not re-render every bubble.
 */
export const ThreadRow = memo(ThreadRowBase);
