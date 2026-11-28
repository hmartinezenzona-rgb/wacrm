# chat-media-delivery Specification

## Purpose

Define how stored chat media reaches the browser in the inbox: signed Storage URLs delivered directly with Range support, a single download per media item, thumbnails with reserved dimensions, play-on-demand audio and video, the byte proxy only as a fallback, and unchanged legacy Meta media delivery — all under the existing members-only access model of the private `chat-media` bucket.

## Requirements

### Requirement: Private bucket, members-only access preserved

`chat-media` MUST remain private, and read access MUST stay limited to authorised members of the owning account under the `chat-media-private` model (migration 261). This change MUST NOT weaken it. A non-member, and a member of a different account, MUST receive neither a signed URL nor bytes for a foreign object.

#### Scenario: Non-member gets no signed URL and no bytes

- GIVEN an authenticated user who is not a member of the object's account
- WHEN it requests the signed URL or the proxy path for that object
- THEN it receives no signed URL, the proxy returns an authorisation failure, and no object bytes are returned

#### Scenario: Member of another account is refused

- GIVEN a member of account A requests a `chat-media` object under account B
- WHEN the signing or delivery path runs
- THEN the request is refused before any URL or bytes are produced, and the private bucket policy is unchanged

#### Scenario: Members of the owning account keep access

- GIVEN an authorised member of the owning account
- WHEN it requests a signed URL for an object in the conversation it can read
- THEN it receives a signed URL with the 3,600 s lifetime and can fetch the object

### Requirement: Direct signed delivery

For images, audio, video and documents stored in `chat-media`, the inbox MUST use the signed Storage URL as the source on first render. It MUST NOT route those objects through the byte proxy when signing succeeds. The signed Storage URL's native Range support MUST be relied on for seeking, and the change MUST NOT require the proxy to implement Range streaming.

#### Scenario: Image loads from the signed URL

- GIVEN a message with an avatar or image in `chat-media` and a signed URL available
- WHEN the bubble renders
- THEN the image element's source is the signed URL and no request is made to `/api/chat-media/...`

#### Scenario: Audio and video play directly from the signed URL

- GIVEN a message with audio or video in `chat-media` and a signed URL available
- WHEN the agent plays it
- THEN the media element reads from the signed URL, seeking works through Storage Range handling, and the proxy is not used

#### Scenario: Documents download directly

- GIVEN a message with a document in `chat-media` and a signed URL available
- WHEN the agent downloads it
- THEN the download uses the signed URL and the proxy is not used

### Requirement: One download per media item

Each media item MUST be downloaded at most once per open of the thread. When signing succeeds there MUST be zero byte-proxy requests for `chat-media` objects (baseline 29). An item MUST NOT start on one source and switch to another after it has begun loading.

#### Scenario: No duplicate downloads

- GIVEN a conversation page containing several media items and signing succeeds
- WHEN the page renders and the media load
- THEN each item is transferred once and the network timeline shows zero `/api/chat-media/...` requests for those items

#### Scenario: No source switch mid-load

- GIVEN an item whose signed URL is available before it starts loading
- WHEN it begins loading
- THEN it loads from the signed URL from the start and never re-requests the same bytes from another source

### Requirement: Proxy is fallback only

The `/api/chat-media/[...path]` byte proxy MUST remain available but MUST be used only when signing fails or no signed URL can be obtained for an object. Its existing behaviour MUST NOT change, and the legacy `/api/whatsapp/media/<mediaId>` route MUST keep working unchanged for messages already delivered through it.

#### Scenario: Signing failure falls back to the proxy

- GIVEN a `chat-media` object whose signing fails
- WHEN the bubble renders or the agent plays it
- THEN the request goes to `/api/chat-media/...` and the media is delivered

#### Scenario: Legacy Meta media still renders

- GIVEN a message whose media has no `chat-media` object and resolves through `/api/whatsapp/media/<mediaId>`
- WHEN it is displayed or played
- THEN it loads from the legacy route exactly as before

### Requirement: Thumbnails with reserved dimensions and lazy loading

The thread MUST render images from the sibling thumbnail object when one exists, as a signed URL from the same private bucket and same account prefix. Image elements MUST carry explicit `width` and `height` so space is reserved, and MUST use `loading="lazy"`. The full-size object MUST load only when the agent opens or expands the image.

#### Scenario: Thumbnail first, full object on open

- GIVEN a message with an image that has a thumbnail path
- WHEN the thread renders the bubble
- THEN the image element uses the thumbnail's signed URL with explicit width and height and `loading="lazy"`, and the full-size object is not requested until the agent opens it

#### Scenario: Missing thumbnail falls back

- GIVEN a message with an image and no thumbnail path
- WHEN the bubble renders
- THEN the image element uses the next available source (storage path, then `media_url`) without failing the render

#### Scenario: Off-screen images are not fetched

- GIVEN a page where some image bubbles are outside the viewport
- WHEN the page finishes painting
- THEN only the thumbnail bytes for images near or in the viewport are requested

### Requirement: Play-on-demand audio and video

Audio and video elements MUST use `preload="none"` or `preload="metadata"` so their media bytes are transferred only on play. Their poster or full bytes MUST NOT be preloaded.

#### Scenario: Audio bytes are not fetched before play

- GIVEN a page with audio messages and no playback
- WHEN the page finishes painting
- THEN no audio media bytes are requested beyond what metadata preload allows

#### Scenario: Video bytes are not fetched before play

- GIVEN a page with video messages and no playback
- WHEN the page finishes painting
- THEN no video media bytes are requested

### Requirement: No Storage transformations, no re-encoding

The change MUST NOT use Supabase Storage image transformations, because they require a plan the project does not have. Thumbnails MUST be produced at ingest time and stored as sibling objects; originals MUST be kept byte-identical, with no re-encoding or compression.

#### Scenario: Thumbnail comes from ingest, not from a transform

- GIVEN a request for a thumbnail
- WHEN the URL is built
- THEN it points to the stored sibling thumbnail object and does not use a Storage transformation parameter

#### Scenario: Original bytes are unchanged

- GIVEN an object that existed before the change
- WHEN it is displayed or downloaded after the change
- THEN its bytes are identical to the bytes before the change

### Requirement: Media metadata compatibility
`messages.media_url` MUST remain the compatibility field, kept written on every existing path and read by existing readers (receipts, ID photo, Cerebro, and other SQL functions) without changing them. New media columns MUST be additive and nullable. Readers MUST prefer the new metadata when present and MUST fall back to `media_url` when it is null.

#### Scenario: Legacy rows render from media_url

- GIVEN a message whose new media columns are null and whose `media_url` is set
- WHEN the bubble renders
- THEN it resolves the media from `media_url` exactly as before

#### Scenario: New metadata takes precedence when present

- GIVEN a message with a storage path and/or thumbnail path in the new columns
- WHEN the bubble renders
- THEN it uses the new metadata first and does not need `media_url` for that object

#### Scenario: Existing media_url readers are unaffected

- GIVEN an SQL function or source file that reads `messages.media_url`
- WHEN the change ships
- THEN its behaviour and its comparison results are unchanged

### Requirement: Pending and failed media states are visible

While a media message is still ingesting, its bubble MUST show a pending state; when ingestion has failed, it MUST show a failed state. A message MUST NOT render as a broken or silent empty media element in either state.

#### Scenario: Pending media shows a downloading state

- GIVEN a media message whose status is `pending`
- WHEN the bubble renders
- THEN it shows the downloading state and does not show a broken media element

#### Scenario: Failed media shows a failure state

- GIVEN a media message whose status is `failed`
- WHEN the bubble renders
- THEN it shows the failure state and keeps the legacy proxy URL available as the last fallback

### Requirement: First-page media weight

The first page of the heaviest production conversation MUST transfer under 1.5 MB of media (baseline 5.3 MB), achieved through thumbnails, lazy loading and play-on-demand, not by altering originals.

#### Scenario: First-page weight is under budget

- GIVEN a fresh session and the heaviest known conversation
- WHEN the first page finishes painting
- THEN the media transferred totals under 1.5 MB

## Out of Scope

- Making the bucket public, or any relaxation of the members-only read model.
- Supabase Storage image transformations (they need the Pro plan).
- Video posters or frame thumbnails (they need ffmpeg), PDF previews, and audio waveforms.
- Re-encoding or compressing originals.
- Removing the `/api/chat-media/[...path]` proxy or the `/api/whatsapp/media/<mediaId>` legacy route.
- Making the byte proxy stream Range responses; the proxy is out of the hot path after this change.
