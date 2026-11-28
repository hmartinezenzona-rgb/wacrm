# media-ingest Specification

## Purpose

Define the inbound WhatsApp media lifecycle: the panel-visible message is inserted first as `pending`, the file is downloaded, stored and thumbnailed asynchronously, the row transitions to `ready` or `failed`, a sweeper retries unfinished rows within Meta's media-id window, bot-facing dispatches happen only after the media settles, and historical objects are backfilled with metadata and thumbnails.

## Requirements

### Requirement: Insert first, process media after

For an inbound message carrying media, the webhook MUST insert the message row with media status `pending` before downloading from Meta or uploading to Storage, so the panel can see the message through realtime immediately. The download, the Storage upload, the thumbnail generation and the metadata update MUST run after the insert and MUST NOT block the insert. Duplicate webhook deliveries MUST be deduplicated on `messages[].id` before insert, as today.

#### Scenario: Pending message is visible before its file exists

- GIVEN an inbound media message from Meta
- WHEN the webhook process begins
- THEN the message row is inserted with status `pending` and appears in the open thread before the file download and upload finish

#### Scenario: Duplicate delivery inserts once

- GIVEN the same WhatsApp message delivered twice
- WHEN both deliveries are processed
- THEN only one message row exists and the media processing for it runs idempotently

#### Scenario: Media update is idempotent per message

- GIVEN a media message whose processing is retried or repeated
- WHEN the update runs again
- THEN the same row reaches the same terminal state without creating a second row or a second stored object

### Requirement: Ready or failed transition

Media processing MUST end by updating the message row to `ready` when the download, upload and thumbnail succeed, or to `failed` when they cannot be completed. It MUST record the storage path, thumbnail path (when generated), mime type, byte size, width and height when known. On failure the message MUST still be stored, and the legacy media reference MUST remain the fallback.

#### Scenario: Successful ingestion becomes ready

- GIVEN a pending media message whose download, upload and thumbnail succeed
- WHEN processing completes
- THEN the row status is `ready` with storage path, thumbnail path, mime, size, width and height recorded

#### Scenario: Thumbnail failure does not lose the message

- GIVEN thumbnail generation fails but the original upload succeeded
- WHEN processing completes
- THEN the row becomes `ready` with the storage path and no thumbnail path, and the message remains usable

#### Scenario: Unrecoverable failure becomes failed

- GIVEN the download or upload cannot be completed within the retry window
- WHEN processing gives up
- THEN the row status is `failed`, the message is still present, and the legacy media reference remains available as the fallback

### Requirement: Bot-facing dispatch only after media settles

The `message.received` event to the Cerebro, and every dependent dispatch (automations, flows, the AI auto-reply), MUST be emitted only after the media message has reached `ready` or `failed`. The panel-visible insert MUST happen first, but it MUST NOT trigger these dispatches. A dispatch MUST NOT observe a media message in `pending` state.

#### Scenario: Bot event waits for a receipt image

- GIVEN an inbound media message that is a deposit receipt
- WHEN the message row is inserted as `pending`
- THEN no bot-facing dispatch is emitted until the media reaches `ready` or `failed`

#### Scenario: Bot event sees the settled media

- GIVEN a media message whose status becomes `ready`
- WHEN the bot-facing dispatch fires
- THEN the dispatch observes the settled media metadata and can read the receipt image

#### Scenario: Failed media still dispatches once

- GIVEN a media message whose status becomes `failed`
- WHEN the bot-facing dispatch fires
- THEN it fires exactly once, after the failure, and no further dispatch is emitted for that message

### Requirement: Sweeper settles stale pending rows

A sweeper MUST retry rows left in `pending` after the request lifetime, while the Meta media identifier is still inside Meta's 7-day window. Rows that cannot be completed before that window closes MUST be settled to `failed`. The sweeper MUST be idempotent and MUST NOT create duplicate rows or duplicate stored objects.

#### Scenario: Stale pending row is retried and settles ready

- GIVEN a row left `pending` because the function ended before finishing
- WHEN the sweeper runs while the Meta media id is still valid
- THEN it retries the download, upload and thumbnail and the row settles to `ready` or `failed`

#### Scenario: Expired media id settles failed

- GIVEN a pending row whose Meta media id is older than the 7-day window
- WHEN the sweeper runs
- THEN it does not retry the expired id and settles the row to `failed`

#### Scenario: Sweeper is safe to re-run

- GIVEN the sweeper has already settled a row
- WHEN it runs again
- THEN it makes no further change and creates no duplicate data

### Requirement: Additive media metadata columns

The change MUST add nullable media columns to `messages` — storage path, thumbnail path, mime, byte size, width, height and media status (`pending | ready | failed`) — without changing existing columns. `messages.media_url` MUST keep its role as the compatibility field and MUST keep being written. The migration MUST be additive, MUST ship with a rollback script, and MUST verify with a self-reverting assertion ending `ALL PASS (rolled back on purpose)`.

#### Scenario: Columns are additive

- GIVEN a database that already has `messages`
- WHEN the migration is applied
- THEN the new columns exist and are nullable, and every existing column, including `media_url`, is unchanged

#### Scenario: Rollback is clean

- GIVEN the migration was applied
- WHEN the rollback script runs
- THEN the additive columns and any sweeper support objects are removed and no reader depends solely on them

#### Scenario: Existing readers show no new diff

- GIVEN the functions that read `messages.media_url`
- WHEN compared after the migration
- THEN no new DIFF is reported for them

### Requirement: Thumbnails generated at ingest

Images and stickers MUST get a sibling thumbnail object generated at ingest, stored in the same private bucket under the same account prefix, never replacing the original. Thumbnail generation MUST use `sharp` as an explicit dependency. A thumbnail failure MUST NOT fail the message.

#### Scenario: Thumbnail is a sibling in the same prefix

- GIVEN an ingested image under an account prefix
- WHEN its thumbnail is generated
- THEN a sibling object exists in the same private bucket and the same account prefix, and the original is untouched

#### Scenario: Stickers get thumbnails too

- GIVEN an ingested sticker
- WHEN the media is processed
- THEN a thumbnail is generated for it as for images

#### Scenario: Thumbnail failure is non-fatal

- GIVEN `sharp` cannot load or generation fails
- WHEN media is processed
- THEN the message is still stored and reaches `ready` without a thumbnail path

### Requirement: History backfill

The change MUST provide a one-off backfill that fills the media metadata and thumbnails for existing `chat-media` objects. It MUST be batched, resumable, idempotent per object, and MUST have a dry-run mode. It MUST run on staging before production, and production only with the owner's go-ahead. After it runs, every historical image MUST have a thumbnail or a recorded reason why it does not, and the dry-run counts MUST match the real run.

#### Scenario: Backfill covers every historical image

- GIVEN existing historical image objects
- WHEN the backfill runs to completion
- THEN each object has a thumbnail or a recorded reason for having none, and the counts are reported

#### Scenario: Dry run matches the real run

- GIVEN a completed dry run reporting its counts
- WHEN the same batch is run for real
- THEN the counts match, and any difference is explained

#### Scenario: Resume does not repeat work

- GIVEN an interrupted backfill
- WHEN it is resumed
- THEN already-processed objects are skipped and no duplicate thumbnails are created

### Requirement: Originals are never re-encoded

The ingest path MUST NOT re-encode or compress original media. Originals MUST remain byte-identical to what Meta delivered.

#### Scenario: Stored original matches the source

- GIVEN an inbound media object
- WHEN it is stored after this change
- THEN the stored bytes are identical to the downloaded bytes

## Out of Scope

- Video posters or frame thumbnails (they need ffmpeg), PDF previews, and audio waveforms.
- Re-encoding or compressing originals.
- Changes to the outbound send path, templates, broadcasts, flow editor media, or v1 API media fields beyond reading the new columns where free.
- Removing the legacy `/api/whatsapp/media/<mediaId>` route.
