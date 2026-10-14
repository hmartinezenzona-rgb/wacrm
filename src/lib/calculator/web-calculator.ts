export type WebCalculatorService =
  | "CUP" | "ZELLE" | "MLC" | "TROPICAL" | "CLASICA" | "USDT"
  | "SALDO MOVIL" | "RECARGA" | "DESCONOCIDO";

export interface WebCalculatorOperation {
  esDia: false;
  dia: string;
  cliente: string;
  monto: number;
  montoOrig: string;
  tipo: WebCalculatorService | string;
  detalle: string;
  fact: number;
  inv: number;
  retorno: number;
  esDirecto: boolean;
  raw: string;
  /** 1-based line number of this line in the text (identity of the manual ledger entry, migration 228). */
  linea: number;
}

export interface WebCalculatorErrorLine {
  esDia: false;
  dia: string;
  error: true;
  raw: string;
  linea: number;
}

export type WebCalculatorParsedLine = WebCalculatorOperation | WebCalculatorErrorLine;

interface WebCalculatorDraft {
  esDia: false;
  dia: string;
  cliente: string;
  monto: number;
  montoOrig: string;
  tipo: WebCalculatorService | string;
  detalle: string;
  esDirecto: boolean;
  raw: string;
  linea?: number;
}

export interface WebCalculatorTotals {
  fact: number;
  inv: number;
  ret: number;
}

export interface WebCalculatorServiceTotals extends WebCalculatorTotals {
  name: string;
}

export interface WebCalculatorResult {
  operations: WebCalculatorParsedLine[];
  services: WebCalculatorServiceTotals[];
  totals: WebCalculatorTotals;
}

export function parseMonto(raw: string | undefined): number {
  if (!raw) return 0;
  const normalized = raw.toLowerCase().replace("gyd", "").trim();
  if (normalized.endsWith("k")) return parseFloat(normalized.replace("k", "")) * 1000;
  return parseFloat(normalized.replace(/,/g, ""));
}

function serviceFrom(typeRaw: string): WebCalculatorService {
  if (typeRaw.includes("CUP")) return "CUP";
  if (typeRaw.includes("ZELLE")) return "ZELLE";
  if (typeRaw.includes("MLC")) return "MLC";
  if (typeRaw.includes("TROPI")) return "TROPICAL";
  if (typeRaw.includes("CLASICA") || typeRaw.includes("CLÁSICA")) return "CLASICA";
  if (typeRaw.includes("USDT") || typeRaw.includes("USD")) return "USDT";
  if (typeRaw.includes("SALDO") || typeRaw.includes("MOVIL") || typeRaw.includes("MÓVIL")) return "SALDO MOVIL";
  if (typeRaw.includes("REC")) return "RECARGA";
  return "DESCONOCIDO";
}

function isDirectService(line: string): boolean {
  return /(visa|ext|trabajo|estudiante|trad|combo|pasaje)/i.test(line);
}

export function parsearLinea(linea: string, diaActual: string):
  | { esDia: true; dia: string }
  | { esDia: false; error: true; raw: string; dia: string }
  | WebCalculatorDraft
  | null {
  const limpia = linea.replace(/^[•\-*]\s*/, "").trim();
  if (!limpia) return null;

  if (/^(lunes|martes|miercoles|miércoles|jueves|viernes|sabado|sábado|domingo)/i.test(limpia)) {
    return { esDia: true, dia: limpia };
  }

  if (isDirectService(limpia)) {
    const matchDirect = limpia.match(/^([A-Za-zÁ-ÿ\s]+?)\s+(.+?)\s+([\d\.,]+[kK]?\s*(?:gyd)?)$/i);
    if (matchDirect) {
      return {
        esDia: false,
        dia: diaActual,
        cliente: matchDirect[1].trim(),
        monto: parseMonto(matchDirect[3]),
        montoOrig: matchDirect[3],
        tipo: `DIRECTO (${matchDirect[2].trim().toUpperCase()})`,
        detalle: "Ganancia Directa",
        esDirecto: true,
        raw: linea,
      };
    }
  }

  const match = limpia.match(/^([A-Za-zÁ-ÿ\s]+?)\s+([\d\.,]+[kK]?)\s*([A-Za-zÁ-ÿ\s]+?)(?:\s*\((.*?)\))?$/);
  if (!match) return { esDia: false, esDirecto: false, error: true, raw: linea, dia: diaActual };

  return {
    esDia: false,
    esDirecto: false,
    dia: diaActual,
    cliente: match[1].trim(),
    monto: parseMonto(match[2]),
    montoOrig: match[2],
    tipo: serviceFrom((match[3] || "").toUpperCase()),
    detalle: match[4] || "",
    raw: linea,
  };
}

/** The numbers of a line's parenthesised detail, read ONCE for both the formulas and the rates a line is quoted with. */
function detailParams(tipo: string, detalle: string) {
  const params = detalle ? detalle.split("/") : [];
  // ZELLE / MLC / CLASICA / TROPICAL: an optional leading "N%" discount shifts the rates one place (parseFloat, so "3,5%" is 3).
  const discounted = (tipo === "ZELLE" || tipo === "MLC" || tipo === "CLASICA" || tipo === "TROPICAL") && !!params[0]?.includes("%");
  const discountPct = discounted ? parseFloat(params[0].replace("%", "")) : 0;
  const index = discounted ? 1 : 0;
  return { params, discountPct: discountPct > 0 ? discountPct : 0, index };
}

function calculateLine(line: WebCalculatorDraft & { linea: number }, cupGlobalRate: number): WebCalculatorOperation {
  let fact = 0;
  let inv = 0;
  const { params, discountPct, index } = detailParams(line.tipo, line.detalle);

  if (line.esDirecto) {
    fact = line.monto;
  } else if (line.tipo === "CUP") {
    const costoUsdtGyd = parseFloat(params[0]) || 0;
    const tasaCupUsdt = parseFloat(params[1]) || 980;
    fact = line.monto / cupGlobalRate;
    inv = (line.monto / tasaCupUsdt) * costoUsdtGyd;
  } else if (line.tipo === "ZELLE" || line.tipo === "MLC" || line.tipo === "CLASICA" || line.tipo === "TROPICAL") {
    const costoGyd = parseFloat(params[index]) || 0;
    const ventaGyd = parseFloat(params[index + 1]) || 0;
    const usdtUsados = discountPct > 0 ? line.monto / (1 + discountPct / 100) : line.monto;
    inv = usdtUsados * costoGyd;
    fact = line.monto * ventaGyd;
  } else if (line.tipo === "USDT") {
    const costoGyd = parseFloat(params[0]) || 0;
    const ventaGyd = parseFloat(params[1]) || 0;
    inv = line.monto * costoGyd;
    fact = line.monto * ventaGyd;
  } else if (line.tipo === "RECARGA" || line.tipo === "SALDO MOVIL") {
    const usdtCostoUnit = parseFloat(params[0]) || 0;
    const ventaUnitGyd = parseMonto(params[1] || "0");
    const costoUsdtGyd = parseFloat(params[2]) || 0;
    inv = line.monto * usdtCostoUnit * costoUsdtGyd;
    fact = line.monto * ventaUnitGyd;
  }

  return { ...line, fact, inv, retorno: fact - inv };
}

/** The rates a typed manual line was quoted with. */
export interface ManualLineRates {
  /** "Compra USDT (GYD)": cost per USDT, first rate of the detail. */
  buy: number | null;
  /** Sale rate of the line (Zelle-like services and USDT); null for CUP. */
  sell: number | null;
  /** "Venta USDT (CUP)": CUP per USDT of the investment (CUP lines only). */
  cupRate: number | null;
  /** Discount in percent of a ZELLE / MLC / CLASICA / TROPICAL line ("3%/..." -> 3); 0 when none. */
  discountPct: number;
}

function positiveOrNull(value: string | undefined): number | null {
  const number = parseFloat(value ?? "");
  return Number.isFinite(number) && number > 0 ? number : null;
}

/**
 * The rates a manual line carries in its text, read with the SAME parser and the SAME detail rules `procesarTexto` costs
 * it with. `null` when the text is not an operation of a rated service (day header, unreadable line, direct service,
 * RECARGA / SALDO MOVIL) or carries no buy rate.
 */
export function parseManualLineRates(rawLine: string | null | undefined): ManualLineRates | null {
  if (!rawLine) return null;
  const parsed = parsearLinea(rawLine, "");
  if (!parsed || parsed.esDia || "error" in parsed || parsed.esDirecto) return null;
  const tipo = parsed.tipo;
  if (!["CUP", "ZELLE", "MLC", "CLASICA", "TROPICAL", "USDT"].includes(tipo)) return null;

  const { params, discountPct, index } = detailParams(tipo, parsed.detalle);
  const buy = positiveOrNull(params[index]);
  if (buy === null) return null;
  if (tipo === "CUP") return { buy, sell: null, cupRate: positiveOrNull(params[1]), discountPct: 0 };
  return { buy, sell: positiveOrNull(params[index + 1]), cupRate: null, discountPct };
}

export function procesarTexto(text: string, tarifaCupGlobalInput: number): WebCalculatorResult {
  const cupGlobalRate = Number.isFinite(tarifaCupGlobalInput) && tarifaCupGlobalInput !== 0 ? tarifaCupGlobalInput : 3;
  let diaActual = "General";
  const operations: WebCalculatorParsedLine[] = [];
  const serviceMap = new Map<string, WebCalculatorTotals>();
  const totals: WebCalculatorTotals = { fact: 0, inv: 0, ret: 0 };

  for (const [index, line] of text.split("\n").entries()) {
    const parsed = parsearLinea(line, diaActual);
    if (!parsed) continue;
    if (parsed.esDia) {
      diaActual = parsed.dia;
      continue;
    }
    if ("error" in parsed) {
      operations.push({ ...parsed, linea: index + 1 });
      continue;
    }

    const operation = calculateLine({ ...parsed, linea: index + 1 }, cupGlobalRate);
    operations.push(operation);
    totals.fact += operation.fact;
    totals.inv += operation.inv;
    totals.ret += operation.retorno;
    const category = operation.esDirecto ? "TRÁMITES / COMBOS / SERVICIOS" : operation.tipo;
    const current = serviceMap.get(category) ?? { fact: 0, inv: 0, ret: 0 };
    current.fact += operation.fact;
    current.inv += operation.inv;
    current.ret += operation.retorno;
    serviceMap.set(category, current);
  }

  return {
    operations,
    services: [...serviceMap.entries()].map(([name, values]) => ({ name, ...values })),
    totals,
  };
}
