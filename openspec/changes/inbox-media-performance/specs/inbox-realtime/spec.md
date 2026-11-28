# inbox-realtime Specification

## Purpose

Define how the inbox stays current and stays cheap to render: message UPDATEs are subscribed per open conversation while message INSERTs stay account-wide for the sound, list preview and unknown-conversation hydration, the conversation list patches the affected row instead of remapping the whole array, message bubbles are memoized, grouping is recomputed only when the message list changes, and the thread is virtualized while keeping scroll-to-bottom, older-page loading and jump-to-message behaviour.

## Requirements

### Requirement: Per-conversation message subscription

Message **UPDATEs** MUST be subscribed with a server-side filter scoped to the open conversation (`conversation_id=eq.<id>`), so row changes (delivery status, and later media settlement) reach the open thread without any other conversation's UPDATEs being delivered to it. Message **INSERTs** MUST stay subscribed account-wide, by design: the chat sound, the conversation-list preview and the hydration of unknown conversations all depend on new messages from conversations that are not open, so the INSERT stream cannot be scoped to one conversation without regressing those behaviours. An inserted message of the open conversation MUST be applied to that thread; an INSERT from another conversation MUST NOT be appended to the open thread, but it MUST still update the conversation list (and ring the sound when the gate allows). No UPDATE from another conversation MUST reach the open thread's subscription.

#### Scenario: Only the open conversation's updates arrive

- GIVEN an open conversation and another conversation whose rows change
- WHEN those conversations' message rows are updated
- THEN no `messages` UPDATE from the other conversation reaches the open thread's filtered subscription

#### Scenario: Insert of the open conversation appears

- GIVEN an open conversation
- WHEN a new message for it is inserted
- THEN the open thread receives it through the account-wide INSERT subscription and appends it

#### Scenario: Insert from another conversation leaves the open thread untouched

- GIVEN an open conversation and another conversation receiving a new message
- WHEN that INSERT arrives on the account-wide subscription
- THEN the open thread does not append it, while the conversation list patches its row and the sound gate may ring

#### Scenario: Insert for an unknown conversation hydrates the list

- GIVEN a conversation that is not yet in the list
- WHEN its first message INSERT arrives
- THEN the inbox fetches that conversation so it surfaces with its contact joined

#### Scenario: Subscription is released on close

- GIVEN an open conversation with an active filtered UPDATE subscription
- WHEN the agent opens a different conversation or leaves the inbox
- THEN the previous filtered subscription is released and a new one is scoped to the newly opened conversation, while the account-wide INSERT subscription continues

### Requirement: Row-level conversation list patching

A `conversations` change MUST patch only the affected row, matched by id, instead of rebuilding the whole conversation array. The conversation list MAY keep its account-wide `conversations` subscription, because unread counts and last message still depend on it.

#### Scenario: Update patches one row

- GIVEN a conversation list of many rows
- WHEN one conversation row changes
- THEN only that row is replaced by id and the other rows keep their identity

#### Scenario: New conversation is inserted

- GIVEN the list is rendered
- WHEN a new conversation row is delivered
- THEN exactly one row is inserted and existing rows keep their identity

#### Scenario: Unread counts and last message stay live

- GIVEN a conversation receiving messages elsewhere
- WHEN its row changes
- THEN the list reflects the updated unread count and last message through the account-wide `conversations` subscription

### Requirement: Memoized bubbles and scoped grouping

Message bubbles MUST be memoized so an unrelated state change does not re-render every bubble of the open thread. Message grouping MUST be recomputed only when the message list changes, not on every render.

#### Scenario: Unrelated state change does not re-render bubbles

- GIVEN a rendered thread
- WHEN an unrelated component state changes
- THEN bubbles whose props did not change do not re-render

#### Scenario: Grouping recomputes only on message list change

- GIVEN a rendered thread with computed groups
- WHEN a render is triggered without a change to the message list
- THEN the grouping is reused rather than recomputed

### Requirement: Virtualized thread

The thread MUST mount only the messages in or near the viewport. Virtualization MUST preserve scroll-to-bottom on open and on new messages, loading an older page when scrolled to the top, and jump-to-message for a specific message. A scroll, anchor or jump regression MUST be treated as a defect, not an accepted trade-off.

#### Scenario: Only visible messages are mounted

- GIVEN a conversation of over a thousand messages
- WHEN the thread opens
- THEN only the messages in or near the viewport are mounted, and the first page paints without mounting the full history

#### Scenario: Scroll-to-bottom on open

- GIVEN an open conversation
- WHEN the thread finishes its first paint
- THEN it is scrolled to the newest message

#### Scenario: Older page loads at the top

- GIVEN the thread is scrolled to its top and older messages exist
- WHEN the agent scrolls further up
- THEN the next older page is requested and prepended without losing the current scroll position

#### Scenario: Jump to message works

- GIVEN a target message inside the loaded history
- WHEN the agent jumps to it
- THEN the thread scrolls to that message and it is mounted and visible

#### Scenario: New message keeps the view anchored

- GIVEN the agent is reading near the bottom of the thread
- WHEN a new message arrives
- THEN the view stays anchored to the current context unless the agent was already at the bottom

### Requirement: Realtime media resolves without reload

A pending media message delivered through realtime MUST render its pending state, and when its row later changes to `ready`, the open thread MUST pick up the new metadata and resolve its media without a full page reload. When it changes to `failed`, the open thread MUST show the failure state.

#### Scenario: Pending becomes ready in place

- GIVEN an open thread showing a pending media message
- WHEN the row transitions to `ready`
- THEN the bubble updates in place and resolves its media, with no full reload

#### Scenario: Pending becomes failed in place

- GIVEN an open thread showing a pending media message
- WHEN the row transitions to `failed`
- THEN the bubble shows the failure state

## Out of Scope

- A Realtime Broadcast migration; filtered postgres_changes is sufficient at this volume.
- Conversation list query performance beyond the row patch.
- Changes to the outbound send path, templates and broadcasts.
