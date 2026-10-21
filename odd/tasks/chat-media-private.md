# chat-media private

## Objective

Customer media (receipts, voice notes, ID and delivery photos) in the `chat-media` bucket stops being reachable by
anyone holding or guessing a URL: the bucket becomes private and every consumer reads through authenticated access.

## Problem and why

- 2026-10-21: bucket public, 4,506 objects / 608 MB, predictable names (`account-<uuid>/<ms>-wa-<waMediaId>.<ext>`).
  Phase 1 (migration 260, live) stopped anonymous listing; any known or guessed `/object/public/` URL still opens.
- `/api/whatsapp/media/[mediaId]` streams Meta media to any logged-in user without checking the media belongs to their
  account and marks the response `Cache-Control: public`.
- Owner: "sigue con lo que falta de este tema" (2026-10-21).

## Scope

- In: app compatibility (display, outbound send, template headers, v1 API), the WhatsApp media route fix, making
  `chat-media` private (migration 261), and members-only listing for `avatars` / `flow-media` (migration 262, buckets
  stay public: avatars are meant to be public and Meta fetches flow media by link).
- Out: rewriting the 1,459+ stored `media_url` values (the app maps the stored public-URL shape at read time);
  n8n (Cerebro downloads media from Meta by the `-wa-<id>` filename; sender, notifier and repartos workflows were
  scanned 2026-10-21 and reference no media).

## Design

- Stored `media_url` keeps its current shape. A helper maps a chat-media URL (public shape) to the same-origin proxy
  `/api/chat-media/<path>`; everything else passes through unchanged.
- `/api/chat-media/[...path]`: session required; the first folder must be `account-<caller account_id>` (403
  otherwise, 404 if missing, path traversal refused); downloads with the service role; `Cache-Control: private`.
- Outbound (`uploadMediaForSend`): chat-media is downloaded with the service role instead of an anonymous fetch; the
  `link` fallback uses a signed URL. Template headers: same download; links re-signed at send time.
- v1 API returns a signed URL for chat-media `media_url`.
- Order: app first (works with the bucket public or private), then migration 261. Rollback of 261 = public again.

## Constraints

- Strict TDD (vitest, `npx vitest run`); `npx tsc --noEmit`. Staging before production; owner go-ahead before each
  production step (panel publish, each migration). Owner logs in himself for the browser check.
- Delivery follows the repo practice: release branch `release/prod-<topic>` from the served sha + cherry-picks via
  `wacrm-publicar-panel`; no pull requests. The ~400-line ODD heuristic is advisory.

## Tasks

- [x] M1 Scan the other n8n workflows for media references (none).
- [x] M2 App compatibility + WhatsApp media route fix (TDD), work-unit commits.
- [x] M3 Staging: migration 261 on staging; owner checks the panel against staging (chat images, audio, receipts,
      delivery proof, sending an image).
- [ ] M4 Production: publish the panel, then migration 261 (separate go-aheads); HTTP check public URL -> refused,
      panel still shows media.
- [ ] M5 Migration 262: members-only listing for avatars / flow-media.

## Acceptance criteria

- With the bucket private: panel shows every media kind; sending images/documents/voice to WhatsApp works; template
  headers send; a public URL returns an error; another account's path returns 403.
- `/api/whatsapp/media/[mediaId]` refuses media not referenced by the caller's account and is not publicly cacheable.

## Applicable checks

- `npx vitest run`, `npx tsc --noEmit`; staging migration cycle; HTTP probes (staging, then production).

## Progress

- 2026-10-21 created; M1 done (K4ijL3NzmY1VX7XI, wGud0KGR6eMqqfMQ, 5YseDUEC5IAaiofF: no media references).

- 2026-10-21 M2 (writer, TDD; 4c2e1c4 87cefa2 917114d 4aec00a 7b1eb96 916ad5d + ceabcc0): proxy route with
  session, folder-account check, single Range; toChatMediaSrc at every display point (also template-manager and
  step3-personalize previews); outbound service-role read + signed link fallback; template headers; v1 signed URLs;
  WhatsApp media route ownership + private cache. Parent review found server reads were not scoped to the sending
  account -> fixed in ceabcc0 (assertChatMediaAccount, foreign path refused). vitest 3010/3010, tsc clean, eslint
  clean. Risk assessment: medium.
- 2026-10-21 M3: 261 (e102c5e) on staging, assertion RED then GREEN, cycle OK. HTTP: an uncached public URL now
  answers 400 Bucket not found; an object fetched in the last hour is still served by the Supabase CDN cache.
  Local panel against staging (panel-local-staging.sh now loads the optional staging service key): owner confirmed
  photos show and voice notes play; dev log shows /api/chat-media 200 (images) and 206 (audio ranges). Sending was
  not tested on staging (Meta test number); covered by unit tests, to check in production.

## Next step

M4: release branch from the served sha + cherry-picks, compile, owner go-ahead, publish; then 261 in production
with its own go-ahead; send a real image to the owner and probe a public URL.
