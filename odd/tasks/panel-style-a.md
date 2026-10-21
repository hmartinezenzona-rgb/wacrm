# Panel style A

## Objective

Apply the owner-approved "style A" look (mockup board "Estilo A · Chat real", https://claude.ai/artifact/Mupn2qd7d6BzKkDhFw4Pc9)
to the real panel, as a visual-only change, and show it on a local panel against staging for the owner's review.

## Scope

- In: theme tokens (light and dark), fonts, sidebar look, inbox list/thread/composer/contact-panel spacing and
  surfaces, status chip colors, amounts typography.
- Out: any behavior, copy, icon or order change; the operations panel (src/components/inbox/operations/*) keeps
  every icon, label, order and behavior (owner rule, 2026-10-21). New features (status chip in the conversation
  list) wait for an explicit go-ahead.

## Design tokens (style A)

- Light: ground #F2F5F4, card #FFFFFF, muted #F2F5F4/#EEF3F1, border #DCE4E1, foreground #14211E, muted text
  #5B6B66, primary #0B7A69 (hover #08594D, soft #E0F2EE), sidebar #0F2622 with text #CFE3DD and active #1D3C36.
- Status: info #1F5FAF on #DDEBFA; attention #8A5300 on #FDF0DC; success #23733A on #E2F3E6; danger #A8322A on
  #FBE4E2; violet (ready) #5B3FB0 on #ECE7FB.
- Fonts: Figtree (body), Bricolage Grotesque (headings and amounts), JetBrains Mono (cards, phones, TransID).
- Dark: same hues, dark teal neutrals (derived), primary #2BB39B.

## Constraints

- TDD: existing tests must stay green; add tests only where a class or token contract is asserted. Strict TDD for any
  logic (none expected).
- Staging/local review first; production publish only with the owner's go-ahead.

## Tasks

- [x] S1 Theme + fonts + shell (sidebar, header) restyle; a "teal" theme as default; dark variant.
- [x] S2 Inbox restyle (list rows, thread header, bubbles, AI banner, composer, contact panel surfaces, status chips)
      without touching operations panel structure/icons.
- [ ] S3 Local panel against staging for the owner; adjustments from feedback.
- [x] S4 (owner go-ahead 2026-10-21) Conversation list shows the open operation's status chip only (no amount), from
      existing data, no extra request per row.
- [x] S5 (owner 2026-10-21) Every accent theme (violet, emerald, cobalt, amber, rose, teal) gets the style A treatment
      in its own hue: tinted dark sidebar, hue-tinted neutrals, accent primary; light and dark.

## Progress

- 2026-10-21 created.
- 2026-10-21 S1 90f2c9e, S2 8c9f377 (writer): teal theme default, fonts, sidebar, inbox surfaces; operations panel only
  className on remittance-operation-card.tsx. vitest 3036. Local panel on :3100 against staging; 3 PRUEBA fixtures.
- 2026-10-21 owner feedback: wants the operation status visible in the list (S4) and the appearance picker to keep
  working with style A per color (S5): today sidebar and neutrals stay teal for every accent.

- 2026-10-21 S5 e824aed (--tint-h per theme), S4 chip from crm_tablero_operaciones (one RPC + realtime refetch).

## Next step

S1+S2 (delegated writer).
