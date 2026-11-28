# inbox-thread-read Specification

## Purpose

Define how an inbox conversation page is read: one server-issued, cursor-paginated page of messages that already carries the signed Storage URLs for the media the page shows, so the browser can paint media without a second signing round-trip, while the members-only access model of the private `chat-media` bucket is preserved exactly.

## Requirements

### Requirement: Server-issued thread page

The panel MUST read an open conversation through a server route that returns, in one response, the requested page of messages (newest first, cursor-paginated) plus the signed media URLs for the media referenced by that same page. The browser MUST render the first paint from that single response and MUST NOT depend on a separate signing request to display the media of the first page.

#### Scenario: Opening a conversation needs one round-trip for messages and media

- GIVEN an authorised member opens a conversation whose page contains image media
- WHEN the client requests the first page
- THEN the response contains the messages and a signed URL for each of their `chat-media` objects
- AND the client renders the media from that response without calling `/api/chat-media/sign` for the first page

#### Scenario: Pagination is cursor-based and newest first

- GIVEN a conversation with more messages than one page
- WHEN the client requests the first page and then the next page with the returned cursor
- THEN messages are ordered newest first, the second page continues strictly after the first cursor, and no message is duplicated or skipped

### Requirement: Membership authorisation for signed media

The thread read route MUST authorise media exactly as the existing sign route does: it MUST verify the caller's session, assert that the requested account matches the caller's membership, and MUST only sign storage paths that belong to the caller's account. It MUST NOT return a signed URL for a path of another account, and MUST NOT return media bytes for a foreign object. The `chat-media` bucket MUST remain private.

#### Scenario: Foreign account path is not signed

- GIVEN a member of account A requests a thread page whose message row references a `chat-media` path under account B
- WHEN the route builds the signed media map
- THEN the foreign path is absent from the signed map, no signed URL is issued for it, and the account-B object remains unreachable to that caller

#### Scenario: Non-member gets no signed media

- GIVEN a caller with no membership in the conversation's account
- WHEN it requests the thread page
- THEN the request is rejected and no message and no signed URL is returned

#### Scenario: Bucket stays private

- GIVEN the signed media map returned by the route
- WHEN any client fetches a `chat-media` object without a valid signed URL
- THEN access is denied; the change does not introduce any public or token-less read path

### Requirement: Signature lifetime and refresh path

Signed URLs issued by the thread route MUST keep the existing lifetime of 3,600 seconds and MUST NOT be extended. The client MUST keep a refresh path that re-signs a URL that is near expiry or that arrived after the first page (for example through realtime), and MUST seed that path from the server-issued map to avoid re-signing media already covered by the page response.

#### Scenario: Expiring URL is refreshed without re-signing the whole page

- GIVEN a rendered page whose signed URLs approach expiry
- WHEN the client needs a fresh URL for one media item
- THEN it re-signs only that item with the 3,600 s lifetime and leaves the other items untouched

#### Scenario: Media arriving after first paint is signed on demand

- GIVEN the thread is open and a new message with media arrives through realtime
- WHEN the client needs to display it
- THEN it obtains a signed URL through the refresh path because the first page response did not include it

#### Scenario: TTL is not lengthened

- GIVEN the signed media map returned by the route
- WHEN its expiry is inspected
- THEN the lifetime is 3,600 seconds, not longer

### Requirement: Thread fetch is not delayed by unrelated client work

The client MUST start the thread page request as soon as the conversation is opened, without awaiting work that is not required to authorise the request. The change MUST record, in the change artifacts, the measured pre-fetch latency before and after this work, and MUST report the cause when that cause is outside the inbox.

#### Scenario: Fetch starts before optional client work

- GIVEN an agent opens a conversation
- WHEN the client begins loading the thread
- THEN the page request is issued before optional work such as list mapping, media signing or non-critical state preparation, and the measured pre-fetch latency is recorded

#### Scenario: Out-of-scope cause is reported, not invented

- GIVEN profiling shows the delaying work lives outside the inbox (layout, auth or bundle)
- WHEN the change concludes the pre-fetch work
- THEN the cause is reported and the measurable criterion stays recorded without an in-scope fix being claimed

### Requirement: First-page performance budget

With the baseline method (fresh session, heaviest production conversation, same 50-message page, DevTools network timeline), the first signed media request MUST start in under 1.5 seconds after the click (baseline 5.6 s), and the first page MUST transfer under 1.5 MB of media (baseline 5.3 MB).

#### Scenario: Time to first signed media

- GIVEN a fresh session and the heaviest known conversation
- WHEN the agent clicks the conversation
- THEN the first signed media request starts in under 1.5 seconds after the click

#### Scenario: First-page weight

- GIVEN the same fresh session and conversation
- WHEN the first page finishes transferring
- THEN the total media transferred for that page is under 1.5 MB

### Requirement: Measurement record

For every relevant slice, the change MUST re-run the baseline method on staging and, when the owner approves, on production, and MUST record the resulting numbers in the change artifacts. A criterion that has not been measured MUST be reported as unmeasured, never as met.

#### Scenario: Measured numbers are recorded

- GIVEN a slice that changes the read path
- WHEN it is verified
- THEN the same conversation and method are measured and the resulting times and bytes are recorded with the date

#### Scenario: Unmeasured criterion is not claimed

- GIVEN a criterion whose measurement was skipped or failed
- WHEN the change reports its results
- THEN the criterion is reported as unmeasured rather than passed

## Out of Scope

- A composite `messages(conversation_id, created_at)` index.
- Any public bucket, CDN token-less URL, or relaxation of the members-only read model.
- Supabase Storage image transformations.
- Changes to the outbound send path, templates, broadcasts and the v1 API media fields.
- Conversation-list query performance beyond realtime row patching.
