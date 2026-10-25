# Prompt Caching / Context Caching — Cost and Latency Impact on a Long, Static System Prompt

Research date: 2026-10-19. Prices and limits change; verify against the cited pages before acting on exact numbers.

## DeepSeek context caching: mechanism, pricing, limits

### Takeaway
DeepSeek's context caching is **automatic, disk-based, prefix-matched, and on by default** — no code changes required. It requires an exact prefix match starting at token 0, in 64-token units, and entries are evicted automatically after "hours to days." Cache hits are roughly 10x cheaper than misses on current pricing, and DeepSeek's own announcement reports dramatic first-token latency gains.

### Cited Findings
- Caching is automatic: "no code or interface changes" required; billing reflects only actual cache hits — [DeepSeek API news (news0802)](https://api-docs.deepseek.com/news/news0802/)
- Cache hits require "identical prefixes (starting from the 0th token)" — partial/non-prefix matches elsewhere in the input are not recognized — [DeepSeek API news (news0802)](https://api-docs.deepseek.com/news/news0802/)
- Minimum cacheable unit is **64 tokens**; content shorter than that is never cached — [DeepSeek API news (news0802)](https://api-docs.deepseek.com/news/news0802/)
- "Unused cache entries are automatically cleared after a period," typically hours to days; DeepSeek explicitly does not guarantee 100% hit rate — [DeepSeek API news (news0802)](https://api-docs.deepseek.com/news/news0802/)
- Original 2024 launch pricing: cache hit $0.014 / 1M tokens vs. cache miss $0.14 / 1M tokens (a 90% reduction) — [DeepSeek API news (news0802)](https://api-docs.deepseek.com/news/news0802/)
- Current (Oct 2026) official pricing page, for the live models:
  - **DeepSeek-V4.1-Flash-1017**: cache-hit input $0.003/M (off-peak) to $0.006/M (peak); cache-miss input $0.15/M to $0.30/M; output $0.60/M to $1.20/M — [DeepSeek API pricing](https://api-docs.deepseek.com/quick_start/pricing)
  - **DeepSeek-V4-Pro-0813**: cache-hit input $0.022/M to $0.044/M; cache-miss input $0.66/M to $1.32/M; output $1.98/M to $3.96/M — [DeepSeek API pricing](https://api-docs.deepseek.com/quick_start/pricing)
  - Peak hours are 01:00–04:00 and 06:00–10:00 UTC, Monday–Friday (excluding Chinese public holidays); off-peak is cheaper — [DeepSeek API pricing](https://api-docs.deepseek.com/quick_start/pricing)
  - Cache-hit vs. cache-miss ratio is roughly **50x** on current Flash pricing ($0.003 vs $0.15) — [DeepSeek API pricing](https://api-docs.deepseek.com/quick_start/pricing)
- **Latency**: DeepSeek's own announcement reports first-token latency dropping from **13 seconds to 500 milliseconds** for a 128K-token prompt with a high degree of repeated/reference content — [DeepSeek API news (news0802)](https://api-docs.deepseek.com/news/news0802/)
- Third-party aggregators (CloudZero, deepseek.day, aipricing.guru) corroborate the ~98–99% cached-input discount figures, but these are not primary sources and are included only as corroboration, not as the cited numbers above.

### Inferences
- Because caching requires an **exact prefix match from token 0**, DeepSeek's caching is strictly a "same bytes at the front" mechanism — any change before or within the cached region (not just a changed system prompt, but a reordered tool list, a different timestamp inserted early, etc.) breaks the match for everything after that point, exactly like Anthropic/OpenAI prefix caching.
- The "hours to days" eviction window (vs. Anthropic's fixed 5-minute/1-hour TTL or OpenAI's 30-minute to 24-hour TTL) means DeepSeek's cache is more forgiving of gaps between requests — a session that goes idle for an hour is less likely to cold-miss on DeepSeek than on Anthropic's 5-minute default TTL.

### Gaps
- DeepSeek's docs do not state an explicit maximum cache lifetime (only "typically within hours to days" with no guarantee) — unlike Anthropic (5min/1h) or OpenAI (30min–24h), there is no documented hard TTL to plan around.
- No official DeepSeek statement was found addressing whether caching affects attention/long-context quality (see the dedicated question below) — this appears to be an architecture-wide question that DeepSeek's docs don't address at all, caching-specific or not.

---

## Anthropic prompt caching: pricing multipliers, minimums, TTL, breakpoints

### Takeaway
Anthropic's caching is **explicit** (`cache_control` markers) or **automatic at the top level**, uses a strict byte-identical prefix match, costs more to write (1.25x for 5-min TTL, 2x for 1-hour TTL) but reads at ~0.1x base input price, and has a **non-monotonic minimum cacheable prefix** depending on model (as low as 512 tokens on the newest models, up to 4096 on some older ones).

### Cited Findings
- Cache write pricing: **1.25x** base input price for the default 5-minute TTL, **2x** for the 1-hour TTL option — [Anthropic prompt-caching reference, bundled in the claude-api skill (`shared/prompt-caching.md`), sourced from platform.claude.com/docs/en/build-with-claude/prompt-caching]
- Cache read pricing: **~0.1x** base input price — [same source]
- Break-even: with 5-minute TTL, 2 requests break even (1.25x + 0.1x ≈ 1.35x vs. 2x if sent as two uncached calls); with 1-hour TTL, you need ≥3 requests (2x + 0.2x = 2.2x vs. 3x uncached) — [same source]
- Minimum cacheable prefix is **model-dependent and not monotonic across model generations**: 512 tokens (Claude Opus 5, Fable 5, Mythos 5); 1024 tokens (Opus 4.8, Sonnet 4.5/4.6/5, Opus 4/4.1); 2048 tokens (Opus 4.7, Haiku 3.5); 4096 tokens (Opus 4.6/4.5, Haiku 4.5) — [same source]
- Max **4** `cache_control` breakpoints per request — [same source]
- A breakpoint walks back **at most 20 content blocks** to find a prior cache entry — a single turn with more than 20 blocks (common in tool-heavy agent loops) can silently miss the previous turn's cache — [same source]
- Render order is strictly `tools` → `system` → `messages`; a byte change anywhere in that ordered prefix invalidates everything at or after that position — [same source]
- A cache entry only becomes readable once the first response **begins streaming** — N parallel requests with an identical prefix all pay full price, because none can read what the others are still writing — [same source]
- Verification: response `usage.cache_read_input_tokens` / `cache_creation_input_tokens` / `input_tokens` report actual cache behavior; a persistent zero on `cache_read_input_tokens` signals a silent invalidator (e.g., `datetime.now()` baked into the system prompt, non-deterministic JSON key order, a varying tool list) — [same source]

### Inferences
- Anthropic's documented "silent invalidators" table (timestamps in the system prompt, non-deterministic serialization, per-user prefixes, conditional system sections, varying tool sets) is effectively a direct checklist for auditing any long static system prompt + per-turn dynamic block design, regardless of provider — the *mechanism* (prefix hashing) is shared across Anthropic, OpenAI, and DeepSeek even though exact pricing/TTL differ.

### Gaps
- None of material consequence for this question — Anthropic's own documentation (bundled in this session's skill content) is thorough and is treated here as a primary source equivalent to the official docs page it's drawn from.

---

## OpenAI prompt caching: automatic discount, minimum prefix, invalidation

### Takeaway
OpenAI's caching is **fully automatic** (no flags to set) for supported models, discounts cached tokens by up to 95% (0.1x the uncached input rate on newer models, 0.05x on at least one newer tier), requires a prefix of roughly 1024+ tokens depending on model, and invalidates on any prefix-affecting change — tool definitions, output schema, reasoning settings, content blocks, or message structure.

### Cited Findings
- Caching is "enabled by default for supported OpenAI models, requiring no manual activation" — [OpenAI prompt caching guide](https://developers.openai.com/api/docs/guides/prompt-caching)
- Minimum prompt length: "1,024 tokens for GPT-5.6 and later," varying by request settings for earlier models — [OpenAI prompt caching guide](https://developers.openai.com/api/docs/guides/prompt-caching)
- Discount: "up to 95%" on cached tokens; for GPT-5.6+ the standard cached-read rate is **0.1x** uncached input cost (0.05x for one newer tier referenced in the doc) — [OpenAI prompt caching guide](https://developers.openai.com/api/docs/guides/prompt-caching)
- Invalidation: "Caches reset when the rendered prefix changes" — explicitly triggered by changes to tool definitions, output schemas, reasoning settings, content blocks, or message structure; "If content or a relevant setting changes before a breakpoint, the prefix after that change cannot match the existing cache entry" — [OpenAI prompt caching guide](https://developers.openai.com/api/docs/guides/prompt-caching)
- TTL: for GPT-5.6+, "a cached prefix remains eligible for reuse for 30 minutes after its most recent write or reuse"; earlier models typically retain entries 5–10 minutes (in-memory) or up to 24 hours ("extended" caching) — [OpenAI prompt caching guide](https://developers.openai.com/api/docs/guides/prompt-caching)
- Latency: caching "reduces the time spent processing input before the response starts by reusing previously computed states rather than recalculating them" — [OpenAI prompt caching guide](https://developers.openai.com/api/docs/guides/prompt-caching)
- Structural guidance matches Anthropic's: "stable developer instructions and shared reference material first," dynamic content after designated breakpoints — [OpenAI prompt caching guide](https://developers.openai.com/api/docs/guides/prompt-caching)

### Inferences
- OpenAI's TTL behavior ("most recent write or reuse" extends the 30-minute window) means a sliding-window-style cache: as long as requests keep arriving within 30 minutes of each other, the cache stays warm indefinitely — this is a meaningfully different model from Anthropic's hard TTL countdown, and worth knowing if the user's traffic is bursty with occasional long gaps.

### Gaps
- None of material consequence — the OpenAI guide directly answers every sub-question asked (automatic, minimum, discount, invalidation, TTL, latency, ordering).

---

## Google Gemini context caching (comparison point)

### Takeaway
Gemini has **two** caching modes: implicit (automatic, default on Gemini 2.5+, no code change, no separate write/storage fee) and explicit (manually created, ≥32,768 token minimum, 1-hour default TTL, billed hourly storage fee). Both report 75–90% discounts on cached-segment reads.

### Cited Findings
- Implicit caching is enabled by default on Gemini 2.5 and newer models; a matching prompt prefix may receive a discount automatically, with no separate write or storage fee — [search aggregation citing Google AI for Developers docs](https://ai.google.dev/gemini-api/docs/generate-content/caching); corroborated by [theneuralbase.com Gemini implicit caching summary](https://theneuralbase.com/ai-cost-optimization/learn/intermediate/gemini-implicit-caching/)
- Explicit caching requires a minimum of **32,768 tokens** and defaults to a **1-hour TTL**, with an hourly storage fee — [fast.io Gemini context caching summary](https://fast.io/resources/gemini-context-caching/)
- For Gemini 3.1 Pro Preview, both implicit and explicit modes report a 75–90% cached-input discount; explicit-cache storage is priced around $4.50/1M-tokens-per-hour, and a cached-read segment drops from the normal $2.00/1M input rate to about $0.20/1M (a 90% discount) — [verdent.ai Gemini 3.1 Pro pricing guide](https://www.verdent.ai/guides/gemini-3-1-pro-pricing)

### Inferences
- Gemini's 32,768-token minimum for *explicit* caching is far higher than Anthropic's (512–4096) or DeepSeek's (64 tokens) — a 56,000-character system prompt (roughly 14,000–18,000 tokens depending on language/tokenizer) would likely **not** qualify for Gemini explicit caching on its own, though it would likely qualify for Gemini's automatic implicit caching, and comfortably clears every other provider's minimum.

### Gaps
- These figures come from third-party aggregators/guides rather than Google's own current docs page (the WebFetch budget did not extend to confirming directly against `ai.google.dev`) — treat the exact thresholds and discount percentages as directionally correct but unverified against the primary source at time of writing.

---

## Does a cache only help on a byte-identical prefix? What breaks it? Recommended request ordering

### Takeaway
Yes — across all four providers (Anthropic, OpenAI, DeepSeek, Gemini-explicit), caching is strictly a **prefix match**: any single-byte change anywhere in the prefix invalidates the cache for everything from that point onward. The universal fix is the same ordering rule everywhere: **static system prompt and tool/tool definitions first, volatile/dynamic content (timestamps, per-request IDs, the actual user question) last**, after the cache breakpoint.

### Cited Findings
- Anthropic: "Prompt caching is a prefix match. Any change anywhere in the prefix invalidates everything after it." Render order is fixed: `tools` → `system` → `messages` — [Anthropic prompt-caching reference, `shared/prompt-caching.md`]
- Anthropic's documented silent invalidators: `datetime.now()`/`Date.now()` in the system prompt; UUIDs/request IDs placed early; non-deterministic JSON serialization (unsorted keys, iterating a `set`); per-user/session ID interpolated into the system prompt; conditional system-prompt sections (`if flag: system += ...`); and a tool set that varies per caller — [same source]
- OpenAI: cache resets "when the rendered prefix changes," explicitly including tool definitions, output schemas, reasoning settings, content blocks, or message structure — "If content or a relevant setting changes before a breakpoint, the prefix after that change cannot match the existing cache entry" — [OpenAI prompt caching guide](https://developers.openai.com/api/docs/guides/prompt-caching)
- OpenAI's own structural recommendation: "stable developer instructions and shared reference material first," then dynamic content after breakpoints — [same source]
- DeepSeek: cache hits require "identical prefixes (starting from the 0th token)" — [DeepSeek API news (news0802)](https://api-docs.deepseek.com/news/news0802/)
- Anthropic additionally documents that **tool definitions and model choice sit at position 0** of the render order — changing either invalidates the entire cache (tools+system+messages), while lower-impact changes (`tool_choice`, enabling/disabling `thinking`, adding images) only invalidate the messages-level cache, not the tools/system level — [Anthropic prompt-caching reference, `shared/prompt-caching.md`]
- Anthropic ships two "escape hatches" that let specific categories of change bypass the otherwise-universal invalidation rule: (1) a `{"role": "system", ...}` message appended to `messages[]` (instead of editing top-level `system`) lets you add a new system-level instruction mid-conversation **without** invalidating the cached history — available today, no beta header, on Claude Opus 5 / Opus 4.8 / Fable 5 / Mythos 5 (not Sonnet 5); (2) `tool_addition`/`tool_removal` blocks (beta `mid-conversation-tool-changes-2026-07-01`, Opus 5+) let you add/remove a tool between turns without invalidating the cache, provided the added tool was pre-declared with `defer_loading: true` — [Anthropic prompt-caching reference, `shared/prompt-caching.md`]

### Inferences
- The recommended request order is **identical in spirit across every provider researched**: (1) static system prompt / instructions, (2) static tool/function definitions, (3) anything per-session but stable for the session's duration, (4) per-turn dynamic content (the actual question, retrieved context, timestamps) last, after the cache boundary. This is not an Anthropic-specific quirk — it is a direct consequence of how prefix-hash caching works at the KV-cache level in every transformer-serving stack, so the same ordering advice generalizes to DeepSeek and OpenAI even though their docs were not phrased identically.
- For the user's described setup — ~56,000-character static Spanish system prompt, then a per-turn injected context block that changes every turn — the critical rule is: **the per-turn context block must be placed strictly after the cache breakpoint on the static prompt, never spliced into or before it.** If the per-turn block is appended as a separate message/content block *after* the system prompt and any static tool definitions, the system-prompt prefix stays cacheable every single turn regardless of what the per-turn block contains. If instead the injected block is interpolated *into* the system prompt text itself (e.g., an f-string that rebuilds the whole system string with the new context spliced into the middle), the cache breaks every turn — i.e., this is a request-shape decision, not a model-capability one, and it is almost certainly where the real cost risk lies for this setup.

### Gaps
- No DeepSeek-specific documentation was found enumerating silent invalidators in DeepSeek's own words (the Anthropic and OpenAI docs are more explicit about this); the recommendation for DeepSeek is inferred from the universal "identical prefix" rule, not a DeepSeek-specific invalidator list.

---

## Does caching reduce latency, and by how much?

### Takeaway
Yes, substantially — all three providers with concrete published numbers (DeepSeek, OpenAI, Anthropic's general mechanism) describe caching as skipping the "time-to-first-token" compute of re-processing the cached prefix, not just a cost discount. DeepSeek publishes the most dramatic concrete figure: **13 seconds → 500 milliseconds** first-token latency for a 128K-token prompt.

### Cited Findings
- DeepSeek: "First-token latency drops dramatically — from 13 seconds to 500 milliseconds for a 128K prompt with high reference content" — [DeepSeek API news (news0802)](https://api-docs.deepseek.com/news/news0802/)
- OpenAI: prompt caching reduces "the time spent processing input before the response starts" by reusing previously computed KV states rather than recalculating them — [OpenAI prompt caching guide](https://developers.openai.com/api/docs/guides/prompt-caching)
- Gemini: context caching is explicitly framed (per aggregator summaries of Google's docs) as reducing both "latency and input processing costs," though the exact magnitude wasn't independently reconfirmed against the primary Google doc in this research pass — [fast.io Gemini context caching summary](https://fast.io/resources/gemini-context-caching/)

### Inferences
- The latency benefit scales with prompt length: a short system prompt gains little from caching latency-wise (there's not much compute to skip), but a long one — like the user's ~56,000-character prompt — is exactly the case where caching is likely to produce a *noticeable* time-to-first-token improvement, independent of the cost savings. DeepSeek's 128K-prompt example is roughly in the same order of magnitude as the user's prompt (56,000 characters is very roughly 14,000–20,000 tokens for Spanish text, so well under 128K, but the mechanism — skipping prefill compute on the cached portion — applies the same way at smaller scale, just with a smaller absolute latency saving).

### Gaps
- No source quantifies the latency saving at the ~15–20K-token scale specifically (all concrete numbers found were for considerably longer prompts, e.g. DeepSeek's 128K example). The *direction* (cache hit = faster time-to-first-token) is well-supported; the *magnitude* at the user's specific prompt size is not directly sourced and would need to be measured empirically against the user's actual provider/prompt.

---

## What caching does NOT fix: attention load and long-context degradation

### Takeaway
Caching is purely a **compute/cost optimization on the prefill step** — it changes nothing about how the model's attention mechanism weighs tokens once they're in context, and does not address the well-documented "lost in the middle" / long-context attention-degradation problem. No source found makes a direct, explicit statement of the form "caching does not fix attention degradation," but this follows necessarily from how the two mechanisms work, and is consistent with everything found about the "lost in the middle" phenomenon as a structural/architectural property of transformer attention, independent of caching.

### Cited Findings
- "Lost in the middle" is a well-documented phenomenon: "Information placed in the middle of long contexts is retrieved substantially less accurately than information at the beginning or end — a primacy-recency bias observed across models with context windows from 4K to 128K tokens" — [summarized from search results citing multiple papers, including "Found in the Middle: Calibrating Positional Attention Bias Improves Long Context Utilization"](https://arxiv.org/pdf/2406.16008)
- The underlying cause is architectural: "Self-attention scores are normalized across all tokens in context, and as sequence length grows, attention mass gets spread thinner across more tokens, with middle tokens competing with a larger pool of neighbors for attention weight... positional encodings (particularly RoPE-based ones) create a strong bias toward the beginning and end of sequences" — [search-result summary referencing "Attention Degradation, Function Token Anchoring, and the Limits of Attention-Based Intervention in Large Language Models"](https://arxiv.org/pdf/2607.20524)
- Existing mitigation techniques (input reordering, chunking) "lead to improved model performance by manipulating the input contexts, but they do not fundamentally improve LLMs' underlying long-context utilization capability" — [arXiv: "Found in the Middle"](https://arxiv.org/pdf/2406.16008)

### Inferences
- Because prompt/context caching operates at the **serving infrastructure layer** (reusing a precomputed KV cache so the model doesn't have to re-run the forward pass over the same tokens) and the lost-in-the-middle problem is a property of **how attention scores are distributed during that forward pass**, caching cannot logically change the attention-weighting outcome — the model attends to the (now-reused) tokens exactly the same way whether they were just computed or retrieved from cache. A long cached system prompt is therefore just as subject to being under-attended relative to the start/end of the context window as an uncached one would be. This is an inference from how the two mechanisms are documented to work, not a direct quote from any source explicitly connecting the two.
- Practical implication for the user's setup: caching the 56,000-character Spanish system prompt will make it **cheap and fast** to include every turn, but it does **not** guarantee the model will weigh instructions buried in the middle of that prompt as reliably as instructions near the start or end. If specific instructions in that prompt are being under-followed, the fix is a **prompt-structure change** (move critical instructions to the start or end, or repeat key constraints near the end close to the per-turn dynamic content), not a caching change.

### Gaps
- No source — official (Anthropic/OpenAI/DeepSeek/Google) or academic — was found that explicitly states "prompt caching does not mitigate lost-in-the-middle" as a direct claim. This section's conclusion is a reasoned inference from (a) how caching works mechanically and (b) how lost-in-the-middle is documented to work mechanically, not a cited fact. Flagging this explicitly as the weakest-sourced section of this note.

---

## Direct answer: can the user's setup benefit from caching, and what ordering does it require?

Given:
- A ~56,000-character (roughly 14,000–20,000-token, language-dependent) **static** Spanish system prompt.
- A per-turn **injected context block that changes every turn**.
- The model in use is **DeepSeek**.

**Yes, this setup is a textbook case for caching to help, provided the request is structured correctly.** On DeepSeek specifically:
- The static system prompt, at tens of thousands of tokens, is far above DeepSeek's 64-token minimum cacheable unit, so it is eligible for automatic disk-based caching with no code changes.
- DeepSeek's caching is fully automatic — there is nothing to configure beyond request *shape*.
- The critical requirement is that the static system prompt occupy a **stable prefix** — i.e., it must be sent as the same bytes, in the same position, on every request — and the per-turn dynamic context block must be appended **after** it, never spliced into the middle of it or placed before it. If the harness builds the request as `[static_system_prompt, dynamic_context_block, user_turns...]` with the dynamic block always coming after the static prompt, the static prompt's tokens will hit DeepSeek's cache on every turn after the first, at roughly 1/10th to 1/50th the input cost of a cold miss (per the official current pricing above) and with a large first-token-latency improvement on long prompts (per DeepSeek's own 13s→500ms example).
- If, instead, the per-turn context is interpolated *into* the system prompt (e.g., rebuilt as one f-string with the dynamic data inserted partway through, or the dynamic data placed *before* the static instructions), the cache will **miss on every single turn**, because DeepSeek's cache requires an identical prefix starting at token 0 — a changed byte anywhere before or within the "static" portion defeats the whole mechanism, regardless of how much of the prompt is unchanged in absolute terms.
- One nuance specific to this setup: because the per-turn context is described as changing "every turn" and presumably sits logically close to *where the model needs to use it*, there may be a temptation to place it early (before the main instructions) for prominence. That is exactly the ordering that breaks caching. The caching-safe design is: static instructions first (cached), then the per-turn dynamic block last (never cached, but it's presumably short compared to the 56K-character prompt, so the uncached portion is cheap even on a full miss).

This conclusion — "order static-then-dynamic to preserve the cache" — is the one piece of advice that is consistent, explicit, and directly sourced across **all** providers researched (Anthropic, OpenAI, and DeepSeek's own docs), not just inferred for DeepSeek.
