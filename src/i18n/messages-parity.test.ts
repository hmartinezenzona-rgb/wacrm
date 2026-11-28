import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import {
  parse,
  TYPE,
  type MessageFormatElement,
} from "@formatjs/icu-messageformat-parser";
import { describe, expect, it } from "vitest";

const MESSAGES_DIR = join(process.cwd(), "messages");
const EN_PATH = join(MESSAGES_DIR, "en.json");
const ES_PATH = join(MESSAGES_DIR, "es.json");

type Catalog = { [key: string]: string | Catalog };

function load(path: string): Catalog {
  return JSON.parse(readFileSync(path, "utf8")) as Catalog;
}

/** Flattens a nested catalog into dotted key path -> message string. */
function flatten(node: Catalog, prefix = ""): Map<string, string> {
  const out = new Map<string, string>();
  for (const [key, value] of Object.entries(node)) {
    const path = prefix ? `${prefix}.${key}` : key;
    if (typeof value === "string") out.set(path, value);
    else for (const [k, v] of flatten(value, path)) out.set(k, v);
  }
  return out;
}

/**
 * Canonical structure of one ICU message: every argument with its kind,
 * every plural/select branch selector, and every rich-text tag name.
 * Translatable literal text is deliberately ignored.
 */
function signature(elements: MessageFormatElement[], scope = ""): string[] {
  const out: string[] = [];
  for (const el of elements) {
    switch (el.type) {
      case TYPE.argument:
        out.push(`${scope}arg:${el.value}`);
        break;
      case TYPE.number:
        out.push(`${scope}number:${el.value}`);
        break;
      case TYPE.date:
        out.push(`${scope}date:${el.value}`);
        break;
      case TYPE.time:
        out.push(`${scope}time:${el.value}`);
        break;
      case TYPE.pound:
        out.push(`${scope}#`);
        break;
      case TYPE.tag:
        out.push(`${scope}tag:${el.value}`);
        out.push(...signature(el.children, scope));
        break;
      case TYPE.select:
      case TYPE.plural: {
        const kind = el.type === TYPE.plural ? "plural" : "select";
        out.push(`${scope}${kind}:${el.value}`);
        for (const [selector, option] of Object.entries(el.options)) {
          out.push(`${scope}${kind}:${el.value}[${selector}]`);
          out.push(
            ...signature(option.value, `${scope}${kind}:${el.value}[${selector}]/`),
          );
        }
        break;
      }
      default:
        break; // literal text
    }
  }
  return out.sort();
}

/**
 * Some catalog strings are intentionally not valid ICU (WhatsApp template
 * placeholders like {{1}} and HTML-like tags with attributes). For those the
 * placeholders and tags must still survive translation verbatim.
 */
function rawTokens(message: string): string[] {
  return (message.match(/\{\{[^}]*\}\}|<\/?[a-zA-Z][^>]*>|\{[^{}]*\}/g) ?? []).sort();
}

describe("messages catalog parity (es vs en)", () => {
  it("messages/es.json exists", () => {
    expect(existsSync(ES_PATH)).toBe(true);
  });

  it("has exactly the same key paths as en.json", () => {
    const en = [...flatten(load(EN_PATH)).keys()].sort();
    const es = existsSync(ES_PATH)
      ? [...flatten(load(ES_PATH)).keys()].sort()
      : [];
    const enSet = new Set(en);
    const esSet = new Set(es);
    expect({
      missingInEs: en.filter((k) => !esSet.has(k)),
      extraInEs: es.filter((k) => !enSet.has(k)),
    }).toEqual({ missingInEs: [], extraInEs: [] });
  });

  it("keeps the same ICU arguments, plural/select branches and tags in every string", () => {
    const en = flatten(load(EN_PATH));
    const es = existsSync(ES_PATH) ? flatten(load(ES_PATH)) : new Map();
    const mismatches: string[] = [];
    for (const [key, enMessage] of en) {
      const esMessage = es.get(key);
      if (esMessage === undefined) continue; // reported by the key test
      let enSig: string[];
      let esSig: string[];
      try {
        enSig = signature(parse(enMessage, { requiresOtherClause: false }));
      } catch {
        // en is not plain ICU: compare the raw placeholders and tags instead.
        enSig = rawTokens(enMessage);
        esSig = rawTokens(esMessage);
        if (JSON.stringify(enSig) !== JSON.stringify(esSig)) {
          mismatches.push(`${key}: en=${JSON.stringify(enSig)} es=${JSON.stringify(esSig)}`);
        }
        continue;
      }
      try {
        esSig = signature(parse(esMessage, { requiresOtherClause: false }));
      } catch (error) {
        mismatches.push(`${key}: es is not valid ICU (${String(error)})`);
        continue;
      }
      if (JSON.stringify(enSig) !== JSON.stringify(esSig)) {
        mismatches.push(`${key}: en=${JSON.stringify(enSig)} es=${JSON.stringify(esSig)}`);
      }
    }
    expect(mismatches).toEqual([]);
  });

  it("has no empty translated strings", () => {
    if (!existsSync(ES_PATH)) return expect(existsSync(ES_PATH)).toBe(true);
    const empty = [...flatten(load(ES_PATH))]
      .filter(([, v]) => v.trim() === "")
      .map(([k]) => k);
    expect(empty).toEqual([]);
  });
});
