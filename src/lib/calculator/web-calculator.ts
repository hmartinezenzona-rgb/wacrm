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
}

export interface WebCalculatorErrorLine {
  esDia: false;
  dia: string;
  error: true;
  raw: string;
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

function calculateLine(line: WebCalculatorDraft, cupGlobalRate: number): WebCalculatorOperation {
  let fact = 0;
  let inv = 0;
  const params = line.detalle ? line.detalle.split("/") : [];

  if (line.esDirecto) {
    fact = line.monto;
  } else if (line.tipo === "CUP") {
    const costoUsdtGyd = parseFloat(params[0]) || 0;
    const tasaCupUsdt = parseFloat(params[1]) || 980;
    fact = line.monto / cupGlobalRate;
    inv = (line.monto / tasaCupUsdt) * costoUsdtGyd;
  } else if (line.tipo === "ZELLE" || line.tipo === "MLC" || line.tipo === "CLASICA" || line.tipo === "TROPICAL") {
    let pct = 0;
    let index = 0;
    if (params[0]?.includes("%")) {
      pct = parseFloat(params[0].replace("%", "")) / 100;
      index = 1;
    }
    const costoGyd = parseFloat(params[index]) || 0;
    const ventaGyd = parseFloat(params[index + 1]) || 0;
    const usdtUsados = pct > 0 ? line.monto / (1 + pct) : line.monto;
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

export function procesarTexto(text: string, tarifaCupGlobalInput: number): WebCalculatorResult {
  const cupGlobalRate = Number.isFinite(tarifaCupGlobalInput) && tarifaCupGlobalInput !== 0 ? tarifaCupGlobalInput : 3;
  let diaActual = "General";
  const operations: WebCalculatorParsedLine[] = [];
  const serviceMap = new Map<string, WebCalculatorTotals>();
  const totals: WebCalculatorTotals = { fact: 0, inv: 0, ret: 0 };

  for (const line of text.split("\n")) {
    const parsed = parsearLinea(line, diaActual);
    if (!parsed) continue;
    if (parsed.esDia) {
      diaActual = parsed.dia;
      continue;
    }
    if ("error" in parsed) {
      operations.push(parsed);
      continue;
    }

    const operation = calculateLine(parsed, cupGlobalRate);
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
