import { Fragment } from 'react';

/**
 * WhatsApp-style inline formatting, as the phone app renders it:
 * `*bold*`, `_italic_` and `~strike~`. The markers only count when they wrap
 * non-empty text on the same line, which is enough for the messages the bot
 * and the agents send; anything else stays literal.
 */
export type TextSegment = {
  type: 'text' | 'bold' | 'italic' | 'strike';
  text: string;
};

const TOKEN = /(\*[^*\n]+\*|_[^_\n]+_|~[^~\n]+~)/g;

export function parseWhatsAppText(input: string): TextSegment[] {
  const segments: TextSegment[] = [];
  let last = 0;

  for (const match of input.matchAll(TOKEN)) {
    const index = match.index ?? 0;
    if (index > last) {
      segments.push({ type: 'text', text: input.slice(last, index) });
    }
    const raw = match[0];
    const marker = raw[0];
    const inner = raw.slice(1, -1);
    // A marker that wraps whitespace is literal text, as in WhatsApp: "* hola *"
    // is not bold.
    if (inner.trim() === '' || inner.trim() !== inner) {
      segments.push({ type: 'text', text: raw });
    } else {
      segments.push({
        type: marker === '*' ? 'bold' : marker === '_' ? 'italic' : 'strike',
        text: inner,
      });
    }
    last = index + raw.length;
  }

  if (last < input.length) {
    segments.push({ type: 'text', text: input.slice(last) });
  }

  // Merge adjacent literal chunks so "** a * b" stays one text segment.
  const merged: TextSegment[] = [];
  for (const segment of segments) {
    const previous = merged[merged.length - 1];
    if (previous && previous.type === 'text' && segment.type === 'text') {
      previous.text += segment.text;
    } else {
      merged.push(segment);
    }
  }

  return merged;
}

export function WhatsAppText({ text }: { text: string }) {
  const segments = parseWhatsAppText(text);
  if (segments.length === 1 && segments[0].type === 'text') {
    return <>{segments[0].text}</>;
  }
  return (
    <>
      {segments.map((segment, index) => {
        if (segment.type === 'bold') return <strong key={index}>{segment.text}</strong>;
        if (segment.type === 'italic') return <em key={index}>{segment.text}</em>;
        if (segment.type === 'strike') return <s key={index}>{segment.text}</s>;
        return <Fragment key={index}>{segment.text}</Fragment>;
      })}
    </>
  );
}
