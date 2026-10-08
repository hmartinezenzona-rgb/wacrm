// ============================================================
// GET /api/remittance-operations/chat-images?conversationId=<uuid>
//
// The picker for a cash recipient's ID photo: the image messages of one
// conversation, newest first, via crm_imagenes_de_conversacion (migration
// 233). Uses the caller's own SESSION Supabase client (never service role)
// so the RPC applies the same membership check as the other panel reads, and
// is gated behind the operations_panel beta flag like its siblings.
// ============================================================

import { NextResponse } from "next/server";
import { requireRole, toErrorResponse } from "@/lib/auth/account";
import type { ChatImage, ChatImageRpcRow } from "@/lib/remittance-operations/types";
import {
  UUID_RE,
  isOperationsPanelEnabled,
  rpcErrorResponse,
} from "@/lib/remittance-operations/route-helpers";

export async function GET(request: Request) {
  try {
    const ctx = await requireRole("viewer");
    const conversationId = new URL(request.url).searchParams.get("conversationId");

    if (!conversationId || !UUID_RE.test(conversationId)) {
      return NextResponse.json(
        { error: "conversationId must be a UUID" },
        { status: 400 },
      );
    }

    const enabled = await isOperationsPanelEnabled(ctx.supabase, ctx.userId);
    if (!enabled) {
      return NextResponse.json({ error: "Not found" }, { status: 404 });
    }

    const { data, error } = await ctx.supabase.rpc("crm_imagenes_de_conversacion", {
      p_conversation_id: conversationId,
    });
    if (error) {
      const errorResponse = rpcErrorResponse(error);
      if (errorResponse) return errorResponse;
      console.error("[remittance-operations chat-images GET] RPC error:", error);
      throw new Error("chat images read failed");
    }

    const images: ChatImage[] = ((data ?? []) as ChatImageRpcRow[]).map((row) => ({
      id: row.id,
      wamid: row.message_id,
      createdAt: row.created_at,
      senderType: row.sender_type,
      mediaUrl: row.media_url,
    }));
    return NextResponse.json(
      { images },
      { headers: { "Cache-Control": "private, no-store" } },
    );
  } catch (error) {
    return toErrorResponse(error);
  }
}
