// ============================================================
// Configuración por negocio (tabla negocio_config, migración 332).
//
// Lo que cambia de un negocio a otro vive aquí como datos, no en el
// código: logo, secciones del menú, textos, botones de cada columna,
// qué se resume en la tarjeta y qué dicen los avisos. Todos los
// negocios usan el mismo CRM; cada cuenta lee su fila.
//
// Si la fila no existe o le falta algo, se usa lo de DEFAULT_NEGOCIO.
// ============================================================

/** Secciones del menú que se pueden prender por negocio. */
export const SECCIONES = ["pipelines", "inbox", "catalogo", "cocinar", "menu", "contacts"] as const;
export type Seccion = (typeof SECCIONES)[number];

export interface ColumnaConfig {
  /** Texto del botón de un toque que pasa la tarjeta A esta columna. */
  boton?: string;
  /** Días en esta columna para marcar la tarjeta como estancada. */
  alerta_dias?: number | null;
}

export interface DestacarConfig {
  /** Etiqueta de la línea en las notas («Llamada: …»). */
  clave: string;
  /** Cómo se muestra en la tarjeta («Llamada»). */
  etiqueta: string;
}

/** Paletas de color por negocio (bloques html[data-tema=…] en globals.css). */
export const TEMAS = ["cubano", "industrial", "verde", "taqueria"] as const;
export type Tema = (typeof TEMAS)[number];

/** localStorage: {tema, sencillo} de la última cuenta, para pintarlos antes de cargar. */
export const NEGOCIO_VISTA_KEY = "wacrm.negocio.vista";

export type TipoGrupo = "uno" | "opcional" | "extra";

export interface GrupoPedido {
  /** Clave corta que se guarda en menu_items.grupo («arroz»). */
  id: string;
  /** Cómo lo ve el dueño («Arroz»). */
  nombre: string;
  /** uno = escoge 1 (obligatorio) · opcional = 1 o nada · extra = se cobra aparte. */
  tipo: TipoGrupo;
}

export interface PedidoConfig {
  /** Lo que vende, en singular y plural («charola» / «charolas»). */
  uno: string;
  varios: string;
  /** Partes de cada unidad, en orden. */
  grupos: GrupoPedido[];
}

export interface NegocioConfig {
  nombre: string;
  /** Paleta del negocio; null = la que elija cada usuario en Apariencia. */
  tema: Tema | null;
  /** Vista sencilla para celular: menú de abajo, letra grande, pedidos en pestañas. */
  sencillo: boolean;
  pedido: PedidoConfig;
  logo: { src: string; ancho: number; alto: number };
  menu: Seccion[];
  /** Textos que reemplazan a los de messages/es.json, con la misma forma ({ Sidebar: { pipelines: "Ventas" } }). */
  textos: Record<string, unknown>;
  tarjeta: {
    /** Líneas de las notas que se juntan en una línea corta («Giro», «Reto»). */
    resumen: string[];
    /** Líneas que se muestran aparte y resaltadas. */
    destacar: DestacarConfig[];
  };
  /** Por nombre de columna (sin importar mayúsculas ni acentos). */
  columnas: Record<string, ColumnaConfig>;
  avisos: {
    nuevo: { titulo: string; resumen: string[] };
    seguimiento: { columna: string; dias: number; singular: string; plural: string } | null;
  };
}

/** Grupos de Doña Miriam: los mismos que usa la base si no hay otros (migración 336). */
export const GRUPOS_INICIALES: GrupoPedido[] = [
  { id: "arroz", nombre: "Arroz", tipo: "uno" },
  { id: "carne", nombre: "Carne", tipo: "uno" },
  { id: "vianda", nombre: "Vianda", tipo: "uno" },
  { id: "potaje", nombre: "Potaje", tipo: "opcional" },
  { id: "extra", nombre: "Extras", tipo: "extra" },
];

export const DEFAULT_NEGOCIO: NegocioConfig = {
  nombre: "Onlinefreedom",
  tema: null,
  sencillo: false,
  pedido: { uno: "charola", varios: "charolas", grupos: GRUPOS_INICIALES },
  logo: { src: "/logo-onlinefreedom.svg", ancho: 262, alto: 64 },
  menu: ["pipelines", "inbox", "contacts"],
  textos: {},
  tarjeta: { resumen: [], destacar: [] },
  columnas: {},
  avisos: {
    nuevo: { titulo: "Nueva tarjeta", resumen: [] },
    seguimiento: null,
  },
};

const esObjeto = (x: unknown): x is Record<string, unknown> =>
  typeof x === "object" && x !== null && !Array.isArray(x);

const listaDeTextos = (x: unknown): string[] =>
  Array.isArray(x) ? x.filter((v): v is string => typeof v === "string" && v.trim() !== "") : [];

/** Quita acentos y mayúsculas para comparar nombres de columna. */
export function normalizar(s: string): string {
  return s
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "")
    .toLowerCase()
    .replace(/\s+/g, " ")
    .trim();
}

/** Convierte lo que venga de la base en una configuración completa y segura. */
export function leerNegocio(raw: unknown): NegocioConfig {
  const d = DEFAULT_NEGOCIO;
  if (!esObjeto(raw)) return d;

  const logo = esObjeto(raw.logo) ? raw.logo : {};
  const menu = listaDeTextos(raw.menu).filter((s): s is Seccion => (SECCIONES as readonly string[]).includes(s));
  const tarjeta = esObjeto(raw.tarjeta) ? raw.tarjeta : {};
  const avisos = esObjeto(raw.avisos) ? raw.avisos : {};
  const nuevo = esObjeto(avisos.nuevo) ? avisos.nuevo : {};
  const seg = esObjeto(avisos.seguimiento) ? avisos.seguimiento : null;

  const columnas: Record<string, ColumnaConfig> = {};
  if (esObjeto(raw.columnas)) {
    for (const [nombre, v] of Object.entries(raw.columnas)) {
      if (!esObjeto(v)) continue;
      columnas[normalizar(nombre)] = {
        boton: typeof v.boton === "string" && v.boton.trim() ? v.boton.trim() : undefined,
        alerta_dias: typeof v.alerta_dias === "number" && v.alerta_dias >= 0 ? v.alerta_dias : null,
      };
    }
  }

  const destacar: DestacarConfig[] = Array.isArray(tarjeta.destacar)
    ? tarjeta.destacar
        .filter(esObjeto)
        .filter((x) => typeof x.clave === "string" && x.clave.trim())
        .map((x) => ({
          clave: String(x.clave).trim(),
          etiqueta: typeof x.etiqueta === "string" && x.etiqueta.trim() ? x.etiqueta.trim() : String(x.clave).trim(),
        }))
    : [];

  const pedido = esObjeto(raw.pedido) ? raw.pedido : {};
  const textoO = (x: unknown, def: string) => (typeof x === "string" && x.trim() ? x.trim() : def);
  const vistos = new Set<string>();
  const grupos: GrupoPedido[] = Array.isArray(pedido.grupos)
    ? pedido.grupos
        .filter(esObjeto)
        .map((g) => {
          const nombre = textoO(g.nombre, "");
          const id = claveGrupo(typeof g.id === "string" && g.id.trim() ? g.id : nombre);
          const tipo: TipoGrupo = g.tipo === "opcional" || g.tipo === "extra" ? g.tipo : "uno";
          return { id, nombre: nombre || id, tipo };
        })
        .filter((g) => g.id && !vistos.has(g.id) && vistos.add(g.id))
    : [];

  return {
    nombre: typeof raw.nombre === "string" && raw.nombre.trim() ? raw.nombre.trim() : d.nombre,
    tema: (TEMAS as readonly unknown[]).includes(raw.tema) ? (raw.tema as Tema) : null,
    sencillo: raw.sencillo === true,
    pedido: {
      uno: textoO(pedido.uno, d.pedido.uno),
      varios: textoO(pedido.varios, d.pedido.varios),
      grupos: grupos.length ? grupos : d.pedido.grupos,
    },
    logo: {
      src: typeof logo.src === "string" && logo.src.trim() ? logo.src.trim() : d.logo.src,
      ancho: typeof logo.ancho === "number" ? logo.ancho : d.logo.ancho,
      alto: typeof logo.alto === "number" ? logo.alto : d.logo.alto,
    },
    menu: menu.length ? menu : d.menu,
    textos: esObjeto(raw.textos) ? raw.textos : {},
    tarjeta: { resumen: listaDeTextos(tarjeta.resumen), destacar },
    columnas,
    avisos: {
      nuevo: {
        titulo: typeof nuevo.titulo === "string" && nuevo.titulo.trim() ? nuevo.titulo.trim() : d.avisos.nuevo.titulo,
        resumen: listaDeTextos(nuevo.resumen),
      },
      seguimiento:
        seg && typeof seg.columna === "string" && seg.columna.trim()
          ? {
              columna: seg.columna.trim(),
              dias: typeof seg.dias === "number" && seg.dias > 0 ? seg.dias : 3,
              singular: typeof seg.singular === "string" && seg.singular.trim() ? seg.singular.trim() : "tarjeta",
              plural: typeof seg.plural === "string" && seg.plural.trim() ? seg.plural.trim() : "tarjetas",
            }
          : null,
    },
  };
}

/** Clave de grupo que acepta la base: minúsculas, sin acentos, a-z 0-9 _ («Guarnición» → «guarnicion»). */
export function claveGrupo(s: string): string {
  return normalizar(s)
    .replace(/[^a-z0-9]+/g, "_")
    .replace(/^_+|_+$/g, "")
    .slice(0, 30);
}

/** Primera letra en mayúscula («charola» → «Charola»). */
export function capital(s: string): string {
  return s ? s.charAt(0).toUpperCase() + s.slice(1) : s;
}

/** «1 charola», «3 charolas». */
export function cuantas(cfg: NegocioConfig, n: number): string {
  return `${n} ${n === 1 ? cfg.pedido.uno : cfg.pedido.varios}`;
}

/** Configuración de una columna por su nombre (o vacía). */
export function columna(cfg: NegocioConfig, nombre?: string | null): ColumnaConfig {
  return (nombre && cfg.columnas[normalizar(nombre)]) || {};
}

/** Texto del botón de un toque que pasa la tarjeta a la columna `siguiente`. */
export function textoBoton(cfg: NegocioConfig, siguiente: string): string {
  return columna(cfg, siguiente).boton || `Pasar a ${siguiente}`;
}

/** Valor de una línea «Clave: valor» de las notas (la última si hay varias). */
export function datoDeNotas(notes: string | null | undefined, clave: string): string {
  const k = normalizar(clave) + ":";
  let valor = "";
  for (const l of (notes ?? "").split("\n")) {
    const t = l.trim();
    if (normalizar(t).startsWith(k)) valor = t.slice(t.indexOf(":") + 1).trim();
  }
  return valor;
}

/** Junta varias líneas de las notas en un texto corto («taquería · no contesta a tiempo»). */
export function resumenDeNotas(notes: string | null | undefined, claves: string[]): string {
  return claves
    .map((c) => datoDeNotas(notes, c))
    .filter(Boolean)
    .join(" · ");
}

/** Mezcla dos objetos de textos: lo de `encima` gana. */
export function mezclarTextos<T extends Record<string, unknown>>(base: T, encima: Record<string, unknown>): T {
  const out: Record<string, unknown> = { ...base };
  for (const [k, v] of Object.entries(encima)) {
    out[k] = esObjeto(v) && esObjeto(out[k]) ? mezclarTextos(out[k] as Record<string, unknown>, v) : v;
  }
  return out as T;
}
