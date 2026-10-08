import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { SERVICE_IDS, SERVICE_NAMES_ES, operationServiceId, resolveServiceId, serviceNameEs } from "./service-name";

describe("resolveServiceId", () => {
  it.each([
    // ledger keys
    ["CUP", "cup"],
    ["ZELLE", "zelle"],
    ["MLC", "mlc"],
    ["CLASICA", "clasica"],
    ["TROPICAL", "tropical"],
    ["USDT", "usdt"],
    ["EFECTIVO", "efectivo_usd"],
    ["RECARGA", "recarga"],
    ["SALDO_MOVIL", "saldo"],
    ["SALDO MOVIL", "saldo"],
    ["Saldo Móvil", "saldo"],
    ["COMBO", "combo"],
    ["VISA", "visa"],
    ["DIRECTO", "tramites"],
    // delivery methods / beneficiary types / OperationService
    ["cuban_card", "cup"],
    ["zelle", "zelle"],
    ["clasica", "clasica"],
    ["tropical", "tropical"],
    ["efectivo_usd", "efectivo_usd"],
    ["recarga", "recarga"],
    ["combo", "combo"],
    ["visa", "visa"],
    ["saldo", "saldo"],
    ["multiple_distribution", "mixed"],
    // service types
    ["remesa", "remesa"],
    ["traduccion", "traduccion"],
    ["mexico", "mexico"],
    // canonical ids resolve to themselves
    ["tramites", "tramites"],
    ["mixed", "mixed"],
  ])("%s -> %s", (key, id) => {
    expect(resolveServiceId(key)).toBe(id);
  });

  it("is case-insensitive and trims", () => {
    expect(resolveServiceId("  Zelle ")).toBe("zelle");
    expect(resolveServiceId("Cuban_Card")).toBe("cup");
  });

  it("returns null for unknown, empty or missing input", () => {
    expect(resolveServiceId("whatever")).toBeNull();
    expect(resolveServiceId("")).toBeNull();
    expect(resolveServiceId(null)).toBeNull();
    expect(resolveServiceId(undefined)).toBeNull();
    expect(resolveServiceId("constructor")).toBeNull();
  });
});

describe("operationServiceId", () => {
  it("lets recarga/combo/visa/saldo win over the delivery method and the beneficiaries", () => {
    expect(operationServiceId({ serviceType: "recarga", deliveryMethod: "zelle" })).toBe("recarga");
    expect(operationServiceId({ serviceType: "combo", deliveryMethod: "cuban_card" })).toBe("combo");
    expect(operationServiceId({ serviceType: "visa" })).toBe("visa");
    expect(operationServiceId({ serviceType: "saldo", beneficiaryTypes: ["recarga"] })).toBe("saldo");
  });

  it("names a remittance by its delivery method", () => {
    expect(operationServiceId({ serviceType: "remesa", deliveryMethod: "cuban_card" })).toBe("cup");
    expect(operationServiceId({ serviceType: "remesa", deliveryMethod: "zelle" })).toBe("zelle");
    expect(operationServiceId({ serviceType: "remesa", deliveryMethod: "efectivo_usd" })).toBe("efectivo_usd");
  });

  it("names a remittance with several kinds of beneficiary as mixed, and multiple_distribution too", () => {
    expect(operationServiceId({ serviceType: "remesa", beneficiaryTypes: ["cuban_card", "zelle"] })).toBe("mixed");
    expect(operationServiceId({ serviceType: "remesa", deliveryMethod: "multiple_distribution" })).toBe("mixed");
  });

  it("uses the single beneficiary type like the database does (rows win over the delivery method)", () => {
    expect(operationServiceId({ serviceType: "remesa", beneficiaryTypes: ["zelle", "zelle"] })).toBe("zelle");
    expect(operationServiceId({ serviceType: "remesa", deliveryMethod: "cuban_card", beneficiaryTypes: ["zelle"] })).toBe("zelle");
  });

  it("falls back to the generic remittance when nothing names the rail", () => {
    expect(operationServiceId({ serviceType: "remesa" })).toBe("remesa");
    expect(operationServiceId({ serviceType: "remesa", deliveryMethod: null, beneficiaryTypes: [] })).toBe("remesa");
    expect(operationServiceId({ serviceType: "remesa", deliveryMethod: "unknown_rail" })).toBe("remesa");
  });

  it("names traduccion and mexico by their service type", () => {
    expect(operationServiceId({ serviceType: "traduccion" })).toBe("traduccion");
    expect(operationServiceId({ serviceType: "mexico", deliveryMethod: "cuban_card" })).toBe("mexico");
  });
});

describe("Spanish names", () => {
  it("are the owner's canonical spellings", () => {
    expect(SERVICE_NAMES_ES).toEqual({
      cup: "CUP",
      zelle: "Zelle",
      clasica: "Clásica",
      tropical: "Tropical",
      mlc: "MLC",
      usdt: "USDT",
      efectivo_usd: "Efectivo USD",
      recarga: "Recarga",
      saldo: "Saldo móvil",
      combo: "Combo",
      visa: "Visa",
      tramites: "Trámites",
      traduccion: "Traducción",
      mexico: "México",
      mixed: "Remesa mixta",
      remesa: "Remesa",
    });
  });

  it("serviceNameEs names any key and returns null for an unknown one", () => {
    expect(serviceNameEs("SALDO_MOVIL")).toBe("Saldo móvil");
    expect(serviceNameEs("DIRECTO")).toBe("Trámites");
    expect(serviceNameEs("nope")).toBeNull();
  });

  it("match the ServiceNames namespace of messages/es.json and en.json has the same ids", () => {
    const es = JSON.parse(readFileSync(join(process.cwd(), "messages/es.json"), "utf8")).ServiceNames;
    const en = JSON.parse(readFileSync(join(process.cwd(), "messages/en.json"), "utf8")).ServiceNames;
    expect(es).toEqual(SERVICE_NAMES_ES);
    expect(Object.keys(en).sort()).toEqual([...SERVICE_IDS].sort());
    expect(en).toMatchObject({
      cup: "CUP", zelle: "Zelle", clasica: "Clásica", tropical: "Tropical", mlc: "MLC", usdt: "USDT",
      efectivo_usd: "Cash USD", recarga: "Top-up", saldo: "Mobile balance", combo: "Combo", visa: "Visa",
      tramites: "Paperwork", traduccion: "Translation", mexico: "Mexico", mixed: "Mixed remittance", remesa: "Remittance",
    });
  });
});
