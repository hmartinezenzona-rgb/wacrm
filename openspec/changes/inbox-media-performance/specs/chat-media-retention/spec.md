# chat-media-retention Specification

## Purpose

Define the storage retention behaviour of the private `chat-media` bucket: a recurring job deletes stored media objects and their thumbnail siblings once they are older than the retention window (90 days), so bucket size stays under control at the current ingest rate, while every message row, every message text and the `media_url` compatibility field survive unchanged. Deletion is by object age only, runs batched and rate-limited with a per-run object cap, supports a non-destructive dry run, and never weakens the members-only access model of the private bucket.

## Requirements

### Requirement: Objects older than the retention window are deleted

Stored objects in `chat-media` whose age exceeds the retention window (90 days) MUST be deleted by the retention job. The retention window MUST be measured from the object's own creation or last-modified time in Storage. Retention is a product decision: conversations older than the window lose their media files.

#### Scenario: Old object is deleted

- GIVEN a stored object in `chat-media` whose age is older than 90 days
- WHEN the retention job runs
- THEN that object is deleted from the bucket

#### Scenario: Object inside the window is kept

- GIVEN a stored object in `chat-media` whose age is younger than 90 days
- WHEN the retention job runs
- THEN that object is not deleted and remains readable

#### Scenario: Boundary is the configured window

- GIVEN an object whose age is exactly at the retention boundary
- WHEN the retention job selects objects for deletion
- THEN the selection follows the configured window deterministically and the same object is never selected and skipped inconsistently between runs

### Requirement: Thumbnails are deleted together with their original

When a stored object is deleted by retention, its thumbnail sibling MUST be deleted in the same operation. A thumbnail MUST NOT outlive its original object, and a deletion MUST NOT leave an orphan thumbnail in the bucket.

#### Scenario: Original and thumbnail are removed together

- GIVEN an image object older than the retention window and its sibling thumbnail
- WHEN the retention job deletes the original
- THEN both the original and the thumbnail are removed from the bucket

#### Scenario: No orphan thumbnail remains

- GIVEN the retention job has completed a run
- WHEN the remaining thumbnails are listed
- THEN no thumbnail exists whose original object was deleted by that run

### Requirement: Message rows and message text are never deleted

Retention MUST NOT delete, truncate or alter message rows. Message text, message metadata other than the storage-derived fields, and every conversation MUST remain intact. `messages.media_url` MUST stay untouched, so existing readers (receipts, ID photo, Cerebro, and other SQL functions that read it) keep working on a purged message.

#### Scenario: Message row survives its media

- GIVEN a message whose media object is deleted by retention
- WHEN the job completes
- THEN the message row still exists with its text, and every other message in the conversation is untouched

#### Scenario: media_url is preserved

- GIVEN a message whose stored object was deleted
- WHEN its row is read after the run
- THEN `media_url` holds the same value it held before the run and no existing reader of that field changes behaviour

#### Scenario: Conversation membership is unchanged

- GIVEN a conversation older than the retention window
- WHEN retention deletes its media
- THEN the conversation and all of its message rows remain present and readable

### Requirement: Deletion is by object age only

Selection MUST be based solely on object age. The job MUST NOT select objects by conversation, by account, by media type, by message status other than the pending exclusion, or by any other business criterion. Two objects of different accounts, conversations or media types at the same age MUST be treated identically.

#### Scenario: Same age means same treatment across accounts

- GIVEN two objects with the same age in two different account prefixes
- WHEN the retention job runs
- THEN both are either deleted or kept together, based only on age

#### Scenario: Media type does not affect selection

- GIVEN an image, an audio file, a video and a document older than the retention window
- WHEN the retention job runs
- THEN all four are selected for deletion on age alone

#### Scenario: Conversation size does not affect selection

- GIVEN an old conversation with many media objects and another with one
- WHEN the retention job runs
- THEN selection depends only on each object's age, not on how many objects a conversation holds

### Requirement: Batched execution with a per-run object cap

The job MUST run in batches and MUST enforce a per-run cap on the number of objects deleted. It MUST be rate-limited and MUST be able to stop when its time or batch budget is exhausted without leaving partial or corrupted deletions; the next run continues the work. The job MUST run inside the existing recurring worker and MUST NOT make the panel's request path wait for it.

#### Scenario: Cap is respected

- GIVEN more eligible objects than the configured per-run cap
- WHEN the retention job runs once
- THEN at most the capped number of objects is deleted and the remaining eligible objects stay in the bucket

#### Scenario: Work resumes on the next run

- GIVEN a run that stopped at its cap or budget with eligible objects left
- WHEN the next scheduled run executes
- THEN it continues deleting eligible objects without requiring manual intervention

#### Scenario: Retention does not block the request path

- GIVEN the recurring worker is processing retention
- WHEN an agent opens a conversation in the panel
- THEN the panel's read path does not wait for the retention work

### Requirement: Dry run is non-destructive and predicts the real run

The job MUST support a dry-run mode. A dry run MUST perform no deletion, MUST leave the bucket byte-identical, and MUST report the same object count that the real run would delete on the same state.

#### Scenario: Dry run deletes nothing

- GIVEN a bucket with eligible objects
- WHEN the job runs in dry-run mode
- THEN no object is deleted and the bucket's objects and bytes are identical before and after

#### Scenario: Dry-run count matches the real run

- GIVEN a completed dry run reporting a deletion count
- WHEN the same state is processed by a real run, within the same cap and window
- THEN the real run deletes exactly the reported count

#### Scenario: Dry run is safe in production

- GIVEN the job runs in dry-run mode against the production bucket
- WHEN it completes
- THEN production media is unaffected and the reported counts are available for review

### Requirement: Pending media is never deleted

An object belonging to a message row whose media status is still `pending` MUST NOT be deleted by retention, even if the object's age exceeds the window. Objects whose media is `ready`, `failed`, or has no media status MUST be eligible on age alone.

#### Scenario: Pending row's object survives

- GIVEN an object older than the retention window whose message row has media status `pending`
- WHEN the retention job runs
- THEN the object is kept and the row can still settle to `ready` or `failed`

#### Scenario: Settled and legacy rows are eligible

- GIVEN objects older than the window whose rows are `ready`, `failed` or have no media status
- WHEN the retention job runs
- THEN each of them is eligible for deletion on age alone

### Requirement: Idempotent repeated runs

Running the job more than once on the same day MUST delete nothing extra. A second run on unchanged state MUST delete zero objects, and repeated runs MUST NOT delete objects that the first run kept, nor produce errors when an object was already removed.

#### Scenario: Second run deletes nothing

- GIVEN a successful retention run
- WHEN the job runs again later the same day with no new eligible objects
- THEN it deletes zero objects and reports no error

#### Scenario: Already-deleted object is tolerated

- GIVEN an object that a previous run already deleted
- WHEN the job encounters it in an overlapping selection
- THEN the run completes without failing and without side effects on other objects

### Requirement: Purged media renders as unavailable

After retention deletes an object, the thread MUST render that media as unavailable for the user. It MUST NOT render a broken image, an infinite loading spinner, or a console error. The message MUST stay visible and its text MUST stay readable. `messages.media_url` MUST NOT be changed to achieve this.

#### Scenario: Purged image shows an unavailable state

- GIVEN a message whose stored image was deleted by retention
- WHEN the agent opens the conversation
- THEN the bubble shows the media as unavailable, the message text is readable, and no broken image or endless spinner appears

#### Scenario: Purged audio or video does not spin forever

- GIVEN a message whose stored audio or video was deleted by retention
- WHEN the agent opens the conversation
- THEN the media control shows an unavailable state rather than a perpetual loading indicator, and the page logs no uncaught error

#### Scenario: Pages without purged media are unaffected

- GIVEN a conversation whose media is all inside the retention window
- WHEN the agent opens it
- THEN every media item renders exactly as it does today

### Requirement: Members-only access model is unchanged

Retention MUST NOT weaken the members-only read model of the private `chat-media` bucket (`chat-media-private`, migration 261). Retention work MUST use privileged server-side access only inside the job and MUST NOT make any object, prefix or list publicly reachable, and MUST NOT change bucket policies or signed URL lifetimes for panel users.

#### Scenario: Bucket stays private after retention

- GIVEN retention has run
- WHEN a non-member requests a purged or retained object's path
- THEN the request is refused exactly as before and no bytes or listings are exposed

#### Scenario: Retention does not alter panel access rules

- GIVEN a signed-in member of the owning account
- WHEN they read a retained object after a retention run
- THEN access and signed URL lifetime are the same as before the change

### Requirement: Steady-state bucket size stays under 700 MB

With the current ingest rate of approximately 200 MB per month and the 90-day window, steady-state `chat-media` usage MUST stay below 700 MB.

#### Scenario: Steady state stabilises below the ceiling

- GIVEN ingest continues at approximately 200 MB per month and retention runs on schedule at 90 days
- WHEN the window has filled
- THEN the bucket's stored size stabilises below 700 MB instead of growing without bound

#### Scenario: Growth is visible before the ceiling is reached

- GIVEN usage trends toward the ceiling because ingest increased
- WHEN retention runs and reports its counts
- THEN the reported stored size makes the trend observable before the 1 GB plan limit is hit

### Requirement: Window and cap are configuration

The retention window and the per-run object cap MUST be configuration values, not hard-coded constants. Changing either MUST change the job's behaviour without a code change to the job's logic, and an invalid configuration value MUST be rejected rather than silently applied.

#### Scenario: Changing the window changes selection

- GIVEN the configured retention window is changed from 90 days to another value
- WHEN the job runs
- THEN selection follows the new window and no code change to the job's logic is required

#### Scenario: Changing the cap changes per-run volume

- GIVEN the configured per-run cap is changed
- WHEN the job runs
- THEN at most the newly configured number of objects is deleted in that run

#### Scenario: Invalid configuration is rejected

- GIVEN a non-positive window, a non-positive cap or a malformed value
- WHEN the job starts
- THEN it refuses to run rather than deleting an unintended set of objects

## Out of Scope

- Deleting message rows, message text or conversations.
- Deleting objects in any bucket other than `chat-media`.
- Compressing or re-encoding originals.
- Moving media to external storage or an archive tier.
- Changing the signed URL TTL.
- Changing the private-bucket access model (`chat-media-private`, migration 261).
- Recovering or restoring media that retention already deleted.
