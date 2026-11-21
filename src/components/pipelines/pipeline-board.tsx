"use client";

import { useMemo, useState } from "react";
import {
  DndContext,
  DragOverlay,
  KeyboardSensor,
  MouseSensor,
  TouchSensor,
  useSensor,
  useSensors,
  useDroppable,
  useDraggable,
  closestCorners,
  type DragEndEvent,
  type DragStartEvent,
} from "@dnd-kit/core";
import type { Deal, PipelineStage } from "@/types";
import { DealCard } from "./deal-card";
import { ChevronRight, Plus } from "lucide-react";
import { useAuth } from "@/hooks/use-auth";
import { formatCurrency } from "@/lib/currency";
import { useTranslations } from "next-intl";
import { useNegocio } from "@/hooks/use-negocio";
import { textoBoton } from "@/lib/negocio/config";

interface PipelineBoardProps {
  stages: PipelineStage[];
  deals: Deal[];
  onDealMoved: (dealId: string, newStageId: string) => void;
  onAddDeal: (stageId: string) => void;
  onEditDeal: (deal: Deal) => void;
  /**
   * Deals with a delivery proof prepared but not yet sent. Drafts live
   * in the page's session memory, so the board is told rather than
   * reading it off the deal row — there is nothing on the row to read.
   */
  dealsWithProof?: ReadonlySet<string>;
}

export function PipelineBoard({
  stages,
  deals,
  onDealMoved,
  onAddDeal,
  onEditDeal,
  dealsWithProof,
}: PipelineBoardProps) {
  const { defaultCurrency } = useAuth();
  const [activeDealId, setActiveDealId] = useState<string | null>(null);

  const sortedStages = useMemo(
    () => [...stages].sort((a, b) => a.position - b.position),
    [stages],
  );

  const dealsByStage = useMemo(() => {
    const map = new Map<string, Deal[]>();
    for (const stage of sortedStages) map.set(stage.id, []);
    for (const deal of deals) {
      const bucket = map.get(deal.stage_id);
      if (bucket) bucket.push(deal);
    }
    return map;
  }, [sortedStages, deals]);

  const sensors = useSensors(
    // Mouse: 5px activation distance avoids clicks being interpreted as drags.
    useSensor(MouseSensor, { activationConstraint: { distance: 5 } }),
    // Touch (celular): hay que DEJAR PRESIONADA la tarjeta ~0.4 s para
    // arrastrarla. Deslizar normal solo recorre el tablero; antes, al
    // deslizar para ver otra columna, el dedo agarraba una tarjeta y la movía.
    useSensor(TouchSensor, { activationConstraint: { delay: 400, tolerance: 8 } }),
    // Keyboard drag support: focus a card, Space to pick up, arrows to move,
    // Space to drop, Escape to cancel.
    useSensor(KeyboardSensor),
  );

  const activeDeal = activeDealId
    ? deals.find((d) => d.id === activeDealId) ?? null
    : null;

  function handleDragStart(event: DragStartEvent) {
    setActiveDealId(String(event.active.id));
  }

  function handleDragEnd(event: DragEndEvent) {
    setActiveDealId(null);
    const { active, over } = event;
    if (!over) return;
    const dealId = String(active.id);
    const targetStageId = String(over.id);

    const deal = deals.find((d) => d.id === dealId);
    if (!deal || deal.stage_id === targetStageId) return;
    if (!sortedStages.some((s) => s.id === targetStageId)) return;

    onDealMoved(dealId, targetStageId);
  }

  function handleDragCancel() {
    setActiveDealId(null);
  }

  return (
    <DndContext
      sensors={sensors}
      collisionDetection={closestCorners}
      onDragStart={handleDragStart}
      onDragEnd={handleDragEnd}
      onDragCancel={handleDragCancel}
    >
      {/* snap-x + snap-mandatory on mobile so swipes land the next
          stage cleanly at the viewport edge instead of mid-column.
          Disabled on lg+ where snapping would interfere with the
          natural layout. The board can still overflow horizontally on
          lg+ once a pipeline has many stages (columns keep a 260px
          min-width), so a thin scrollbar stays visible on desktop. */}
      <div className="pipeline-scroll flex snap-x snap-mandatory gap-2 overflow-x-auto pb-4 lg:snap-none">
        {sortedStages.map((stage) => {
          const stageDeals = dealsByStage.get(stage.id) ?? [];
          const totalValue = stageDeals.reduce(
            (s, d) => s + Number(d.value || 0),
            0,
          );
          return (
            <StageColumn
              key={stage.id}
              stage={stage}
              deals={stageDeals}
              totalValue={totalValue}
              currency={defaultCurrency}
              onAddDeal={onAddDeal}
              onEditDeal={onEditDeal}
              dealsWithProof={dealsWithProof}
              nextStage={siguienteEtapa(sortedStages, stage)}
              onMove={onDealMoved}
            />
          );
        })}
      </div>

      <DragOverlay
        dropAnimation={{
          duration: 200,
          easing: "cubic-bezier(0.2, 0, 0, 1)",
        }}
      >
        {activeDeal ? (
          <div className="opacity-90">
            <DealCard
              deal={activeDeal}
              stage={
                sortedStages.find((s) => s.id === activeDeal.stage_id) ?? null
              }
              onEdit={() => {}}
              hasProof={dealsWithProof?.has(activeDeal.id)}
              isOverlay
            />
          </div>
        ) : null}
      </DragOverlay>

      <style jsx>{`
        .pipeline-scroll {
          scroll-behavior: smooth;
        }
        /* On touch devices the peek/snap layout already signals there's
           more to swipe, so the scrollbar is hidden for a clean look.
           On desktop (mouse) the board can overflow with many stages
           and there is no peek hint, so keep a thin, themed scrollbar
           visible to make the overflow discoverable and usable. */
        @media (hover: none), (pointer: coarse) {
          .pipeline-scroll::-webkit-scrollbar {
            height: 0;
            display: none;
          }
          .pipeline-scroll {
            scrollbar-width: none;
          }
        }
        @media (hover: hover) and (pointer: fine) {
          .pipeline-scroll {
            scrollbar-width: thin;
            scrollbar-color: var(--border) transparent;
          }
          .pipeline-scroll::-webkit-scrollbar {
            height: 8px;
          }
          .pipeline-scroll::-webkit-scrollbar-track {
            background: transparent;
          }
          .pipeline-scroll::-webkit-scrollbar-thumb {
            background-color: var(--border);
            border-radius: 9999px;
          }
          .pipeline-scroll::-webkit-scrollbar-thumb:hover {
            background-color: var(--muted-foreground);
          }
        }
      `}</style>
    </DndContext>
  );
}

function StageColumn({
  stage,
  deals,
  totalValue,
  currency,
  onAddDeal,
  onEditDeal,
  dealsWithProof,
  nextStage,
  onMove,
}: {
  stage: PipelineStage;
  deals: Deal[];
  totalValue: number;
  currency: string;
  onAddDeal: (stageId: string) => void;
  onEditDeal: (deal: Deal) => void;
  dealsWithProof?: ReadonlySet<string>;
  nextStage: PipelineStage | null;
  onMove: (dealId: string, newStageId: string) => void;
}) {
  const t = useTranslations("Pipelines.board");
  const { setNodeRef, isOver } = useDroppable({ id: stage.id });

  return (
    // On mobile each column is `w-[85vw]` (with a reasonable min/max)
    // so the next column's edge peeks in — a "there's more here" hint.
    // snap-start lands each column cleanly when swiping. On lg+ we
    // restore the flex-1 share-the-row behavior. The droppable ref is
    // on the inner messages region below — intentionally NOT here, so
    // a drag over the column header doesn't highlight the whole column.
    <div className="flex w-[82vw] min-w-[248px] max-w-[300px] shrink-0 snap-start flex-col rounded-xl bg-muted/40 p-2 lg:w-auto lg:max-w-none lg:flex-1 lg:basis-[230px] lg:shrink lg:snap-none">
      {/* Encabezado compacto: punto de color, nombre, cuántas y total */}
      <div className="px-1.5 pb-2 pt-1">
        <div className="flex items-center gap-2">
          <span
            aria-hidden
            className="h-2 w-2 shrink-0 rounded-full"
            style={{ backgroundColor: stage.color }}
          />
          <h3 className="truncate text-[13px] font-semibold text-foreground">
            {stage.name}
          </h3>
          <span className="ml-auto shrink-0 text-xs font-medium tabular-nums text-muted-foreground">
            {deals.length}
          </span>
        </div>
        <p className="mt-0.5 pl-4 text-[11px] tabular-nums text-muted-foreground">
          {totalValue > 0 ? formatCurrency(totalValue, currency) : "\u2014"}
        </p>
      </div>

      <div
        ref={setNodeRef}
        className={`flex min-h-[120px] flex-1 flex-col gap-1.5 rounded-lg transition-colors ${
          isOver ? "bg-primary/10 outline outline-2 outline-dashed outline-primary/60" : ""
        }`}
      >
        {deals.length === 0 ? (
          <div className="flex flex-1 items-center justify-center rounded-lg border border-dashed border-border/70 py-8 text-[11px] text-muted-foreground">
            {t("dropDealHere")}
          </div>
        ) : (
          deals.map((deal) => (
            <DraggableDealCard
              key={deal.id}
              deal={deal}
              stage={stage}
              onEdit={onEditDeal}
              hasProof={dealsWithProof?.has(deal.id)}
              nextStage={nextStage}
              onMove={onMove}
            />
          ))
        )}
      </div>

      <button
        type="button"
        onClick={() => onAddDeal(stage.id)}
        className="mt-1.5 flex items-center gap-1 rounded-md px-2 py-1.5 text-xs text-muted-foreground hover:bg-muted hover:text-foreground"
      >
        <Plus className="h-3.5 w-3.5" />
        {t("addDeal")}
      </button>
    </div>
  );
}

// La columna que sigue, para el botón de un toque. No se ofrece pasar a
// una columna de cancelados: cancelar se hace desde la ficha (pide confirmar).
function siguienteEtapa(stages: PipelineStage[], stage: PipelineStage): PipelineStage | null {
  const i = stages.findIndex((s) => s.id === stage.id);
  const next = i >= 0 ? stages[i + 1] : undefined;
  if (!next || /cancel|perdid|lost/i.test(next.name) || /cancel|perdid|lost/i.test(stage.name)) return null;
  return next;
}

// Texto blanco u oscuro según qué tan claro sea el color de la columna.
function colorTexto(hex: string): string {
  const m = /^#?([0-9a-f]{6})$/i.exec(hex || "");
  if (!m) return "#fff";
  const n = parseInt(m[1], 16);
  const lum = (0.299 * (n >> 16) + 0.587 * ((n >> 8) & 255) + 0.114 * (n & 255)) / 255;
  return lum > 0.6 ? "#0b0d12" : "#fff";
}

function DraggableDealCard({
  deal,
  stage,
  onEdit,
  hasProof,
  nextStage,
  onMove,
}: {
  deal: Deal;
  stage: PipelineStage;
  onEdit: (deal: Deal) => void;
  hasProof?: boolean;
  nextStage: PipelineStage | null;
  onMove: (dealId: string, newStageId: string) => void;
}) {
  const { attributes, listeners, setNodeRef, isDragging } = useDraggable({
    id: deal.id,
  });
  const { negocio } = useNegocio();

  return (
    <div
      ref={setNodeRef}
      {...listeners}
      {...attributes}
      // `manipulation` deja deslizar el tablero con el dedo; el arrastre
      // solo empieza tras dejar presionado (TouchSensor). Sin menú ni
      // selección de texto al presionar largo.
      className="select-none [-webkit-touch-callout:none]"
      style={{ opacity: isDragging ? 0.3 : 1, touchAction: "manipulation" }}
    >
      <DealCard
        deal={deal}
        stage={stage}
        onEdit={onEdit}
        hasProof={hasProof}
        footerAction={
          nextStage ? (
            <button
              type="button"
              // Que el botón no arranque un arrastre ni abra la ficha.
              onPointerDown={(e) => e.stopPropagation()}
              onTouchStart={(e) => e.stopPropagation()}
              onMouseDown={(e) => e.stopPropagation()}
              onKeyDown={(e) => e.stopPropagation()}
              onClick={(e) => {
                e.stopPropagation();
                onMove(deal.id, nextStage.id);
              }}
              className="mt-2 flex h-8 w-full items-center justify-center gap-1 rounded-md border border-border text-xs font-semibold text-foreground/90 transition-colors hover:border-transparent active:scale-[0.98] [@media(hover:hover)]:hover:[background-color:var(--siguiente)] [@media(hover:hover)]:hover:[color:var(--siguiente-texto)]"
              style={{ ["--siguiente" as string]: nextStage.color, ["--siguiente-texto" as string]: colorTexto(nextStage.color) }}
            >
              {textoBoton(negocio, nextStage.name)}
              <ChevronRight className="h-3.5 w-3.5" />
            </button>
          ) : null
        }
      />
    </div>
  );
}
