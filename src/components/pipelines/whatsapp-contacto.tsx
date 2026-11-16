"use client";

// ============================================================
// Ficha de cotización → WhatsApp (edición AP Suministros).
//
// Las solicitudes que llegan por la página no tienen chat: el cliente
// nunca escribió por WhatsApp. WhatsApp solo deja que el negocio escriba
// primero con un mensaje aprobado (plantilla), y libre solo si el cliente
// escribió en las últimas 24 h. Este bloque resuelve eso con un botón:
//   - Ventana abierta (escribió hace < 24 h) → "Abrir chat".
//   - Ventana cerrada o sin chat → "Escribir por WhatsApp": manda la
//     plantilla ap_solicitud_recibida con nombre y folio ya puestos y
//     abre el chat; cuando el cliente conteste, ya se platica libre.
//     Si esa plantilla aún no está aprobada, deja elegir otra.
// ============================================================

import { useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { Loader2, MessageCircle } from "lucide-react";
import { toast } from "sonner";
import type { Contact, MessageTemplate } from "@/types";
import { TemplatePicker, type TemplateSendValues } from "@/components/inbox/template-picker";
import { sessionWindowFrom } from "@/lib/inbox/session-window";
import { fetchLastCustomerMessageAt } from "@/lib/inbox/last-customer-message";

const PLANTILLA = "ap_solicitud_recibida";

export function folioDeNotas(notes?: string | null): string | null {
  return /\bAP-[A-Z0-9]{4,}\b/i.exec(notes ?? "")?.[0]?.toUpperCase() ?? null;
}

export function WhatsappContacto({
  contact,
  folio,
  canSend = true,
}: {
  contact: Contact | null;
  folio: string | null;
  canSend?: boolean;
}) {
  const supabase = useMemo(() => createClient(), []);
  const router = useRouter();
  const [cargando, setCargando] = useState(true);
  const [convId, setConvId] = useState<string | null>(null);
  const [abierta, setAbierta] = useState(false);
  const [plantilla, setPlantilla] = useState<MessageTemplate | null>(null);
  const [enviando, setEnviando] = useState(false);
  const [elegir, setElegir] = useState(false);

  const contactId = contact?.id ?? null;

  useEffect(() => {
    if (!contactId) {
      // eslint-disable-next-line react-hooks/set-state-in-effect
      setCargando(false);
      return;
    }
    let cancel = false;
    (async () => {
      setCargando(true);
      const [{ data: conv }, { data: tpl }] = await Promise.all([
        supabase
          .from("conversations")
          .select("id")
          .eq("contact_id", contactId)
          .is("deleted_at", null)
          .order("last_message_at", { ascending: false })
          .limit(1)
          .maybeSingle(),
        supabase
          .from("message_templates")
          .select("*")
          .eq("name", PLANTILLA)
          .eq("status", "APPROVED")
          .limit(1)
          .maybeSingle(),
      ]);
      let open = false;
      if (conv?.id) {
        const at = await fetchLastCustomerMessageAt(supabase, conv.id);
        open = sessionWindowFrom(at).state === "open";
      }
      if (cancel) return;
      setConvId(conv?.id ?? null);
      setAbierta(open);
      setPlantilla((tpl as MessageTemplate | null) ?? null);
      setCargando(false);
    })();
    return () => {
      cancel = true;
    };
  }, [contactId, supabase]);

  async function irAlChat() {
    if (!contactId) return;
    const { data } = await supabase
      .from("conversations")
      .select("id")
      .eq("contact_id", contactId)
      .is("deleted_at", null)
      .order("last_message_at", { ascending: false })
      .limit(1)
      .maybeSingle();
    router.push(data?.id ? `/inbox?c=${data.id}` : "/inbox");
  }

  async function enviar(t: MessageTemplate, values: TemplateSendValues) {
    if (!contactId) return;
    setEnviando(true);
    try {
      const res = await fetch("/api/whatsapp/send", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          contact_id: contactId,
          message_type: "template",
          template_name: t.name,
          template_language: t.language,
          template_message_params: {
            body: values.body,
            headerText: values.headerText,
            buttonParams: values.buttonParams,
          },
          template_params: values.body,
        }),
      });
      const payload = await res.json().catch(() => ({}));
      if (!res.ok) {
        toast.error(`No se pudo enviar: ${payload?.error || `HTTP ${res.status}`}`);
        return;
      }
      toast.success("Mensaje enviado por WhatsApp");
      await irAlChat();
    } catch {
      toast.error("No se pudo enviar: sin conexión");
    } finally {
      setEnviando(false);
    }
  }

  function escribir() {
    if (plantilla) {
      const nombre = (contact?.name || "").split(" ")[0] || "buen día";
      enviar(plantilla, { body: [nombre, folio || "de cotización"] } as TemplateSendValues);
    } else {
      setElegir(true);
    }
  }

  if (!contact) return null;

  const sinTelefono = !contact.phone;

  return (
    <div className="rounded-lg border border-emerald-500/30 bg-emerald-500/5 p-3">
      <div className="flex items-center gap-2">
        <MessageCircle className="h-4 w-4 shrink-0 text-emerald-500" />
        <span className="min-w-0 flex-1 truncate text-sm font-medium text-foreground">
          WhatsApp {contact.phone ? `· ${contact.phone}` : ""}
        </span>
        {cargando ? (
          <Loader2 className="h-4 w-4 animate-spin text-muted-foreground" />
        ) : sinTelefono ? (
          <span className="text-xs text-muted-foreground">Sin teléfono</span>
        ) : abierta && convId ? (
          <button
            type="button"
            onClick={() => router.push(`/inbox?c=${convId}`)}
            className="h-8 shrink-0 rounded-md bg-emerald-600 px-3 text-xs font-semibold text-white hover:bg-emerald-700"
          >
            Abrir chat
          </button>
        ) : (
          <button
            type="button"
            disabled={!canSend || enviando}
            onClick={escribir}
            className="flex h-8 shrink-0 items-center gap-1.5 rounded-md bg-emerald-600 px-3 text-xs font-semibold text-white hover:bg-emerald-700 disabled:opacity-50"
          >
            {enviando && <Loader2 className="h-3.5 w-3.5 animate-spin" />}
            Escribir por WhatsApp
          </button>
        )}
      </div>
      {!cargando && !sinTelefono && !abierta && (
        <p className="mt-1.5 text-xs text-muted-foreground">
          {convId
            ? "El cliente no ha escrito en las últimas 24 h. "
            : "Este cliente llegó por la página y aún no tiene chat. "}
          {plantilla
            ? `Se le manda un saludo aprobado por WhatsApp${folio ? ` con su folio ${folio}` : ""}; cuando conteste ya pueden platicar libre.`
            : "WhatsApp pide empezar con un mensaje aprobado: al tocar el botón eliges cuál."}
          {convId && (
            <>
              {" "}
              <button type="button" onClick={irAlChat} className="text-emerald-600 underline-offset-2 hover:underline">
                Ver el chat
              </button>
            </>
          )}
        </p>
      )}
      <TemplatePicker open={elegir} onOpenChange={setElegir} onSelect={enviar} />
    </div>
  );
}
