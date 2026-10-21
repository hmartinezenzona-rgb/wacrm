import { describe, expect, it, vi } from "vitest";
import { BoardFetchError, fetchBoard } from "./fetch";

const row = {
  operation_id: "op-1", conversation_id: "conv-1", contact_name: "Ana", contact_phone: "592",
  service_type: "remesa", delivery_method: "zelle", status: "incident", quoted_source_amount: "30000.50",
  source_currency: "GYD", created_at: "2026-10-05T10:00:00Z", completed_at: null,
  state_since: "2026-10-05T11:00:00Z", beneficiaries_complete: false,
};

describe("fetchBoard", () => {
  it("calls the board RPC on the caller's client and maps rows", async () => {
    const rpc = vi.fn().mockResolvedValue({ data: [row], error: null });
    const result = await fetchBoard({ rpc } as never);
    expect(rpc).toHaveBeenCalledWith("crm_tablero_operaciones");
    expect(result).toEqual([
      {
        operationId: "op-1", conversationId: "conv-1", contactName: "Ana", contactPhone: "592",
        serviceType: "remesa", deliveryMethod: "zelle", status: "incident", quotedSourceAmount: 30000.5,
        sourceCurrency: "GYD", createdAt: "2026-10-05T10:00:00Z", completedAt: null,
        stateSince: "2026-10-05T11:00:00Z", beneficiariesComplete: false,
        beneficiaryTypes: [], quotedDestinationAmount: null, destinationCurrency: null,
        recipientLabel: null, recipientCount: 0, mixedGroupId: null,
      },
    ]);
  });

  it("maps the informative fields of the board RPC (258)", async () => {
    const rpc = vi.fn().mockResolvedValue({
      data: [{
        ...row, beneficiary_types: ["zelle", "clasica"], quoted_destination_amount: "70.5", destination_currency: "USD",
        recipient_label: "Maria Perez", recipient_count: 2, mixed_group_id: "grp-1",
      }],
      error: null,
    });
    const [mapped] = await fetchBoard({ rpc } as never);
    expect(mapped).toMatchObject({
      beneficiaryTypes: ["zelle", "clasica"], quotedDestinationAmount: 70.5, destinationCurrency: "USD",
      recipientLabel: "Maria Perez", recipientCount: 2, mixedGroupId: "grp-1",
    });
  });

  it("defaults the informative fields when the RPC predates 258 (null array, missing keys)", async () => {
    const rpc = vi.fn().mockResolvedValue({ data: [{ ...row, beneficiary_types: null, recipient_count: null }], error: null });
    const [mapped] = await fetchBoard({ rpc } as never);
    expect(mapped).toMatchObject({
      beneficiaryTypes: [], quotedDestinationAmount: null, destinationCurrency: null,
      recipientLabel: null, recipientCount: 0, mixedGroupId: null,
    });
  });

  it("returns an empty board for null data", async () => {
    const rpc = vi.fn().mockResolvedValue({ data: null, error: null });
    expect(await fetchBoard({ rpc } as never)).toEqual([]);
  });

  it("maps a permission error to forbidden", async () => {
    const rpc = vi.fn().mockResolvedValue({ data: null, error: { code: "42501", message: "insufficient_privilege" } });
    await expect(fetchBoard({ rpc } as never)).rejects.toMatchObject({ kind: "forbidden" });
  });

  it("maps any other error to failed", async () => {
    const rpc = vi.fn().mockResolvedValue({ data: null, error: { code: "XX000", message: "boom" } });
    const err = await fetchBoard({ rpc } as never).catch((e) => e);
    expect(err).toBeInstanceOf(BoardFetchError);
    expect(err.kind).toBe("failed");
  });
});
