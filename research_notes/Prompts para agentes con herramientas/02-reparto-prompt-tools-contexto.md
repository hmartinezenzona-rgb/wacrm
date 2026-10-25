# Dividing instructions between system prompt, tool descriptions, and per-turn context

Scope: where different kinds of instruction content belong in a tool-calling LLM agent, for a practitioner moving content out of an overloaded system prompt (concrete case: 16 tools, ~56k-char Spanish system prompt, DeepSeek via n8n, WhatsApp remittance agent, plus a code node injecting context notes every turn).

## What belongs in a TOOL DESCRIPTION vs the system prompt — and does it move the needle on tool selection?

### Takeaway
All three vendors treat the tool description as a first-class, model-facing instruction surface — not documentation — and Anthropic has a measured result showing that rewriting tool descriptions (not adding system-prompt rules) was what fixed a frontier-model tool-use regression. The dividing line in every source is the same: put *when/how to use this specific tool, its parameters, caveats, and boundaries from other tools* in the tool description; keep *cross-tool policy, role, tone, and business rules that apply regardless of which tool is called* in the system prompt.

### Cited Findings
- Anthropic's guidance for tool definitions: give "extremely detailed descriptions," 3-4+ sentences, explaining what the tool does, **when to use it, and when not to**, what each parameter means and how it affects behavior, and important caveats — "imagine you are explaining it to a new, remote-working colleague." — [Writing effective tools for AI agents — Anthropic](https://www.anthropic.com/engineering/writing-tools-for-agents)
- Direct measured claim: "Claude Sonnet 3.5 achieved state-of-the-art performance on the SWE-bench Verified evaluation after we made precise refinements to tool descriptions, dramatically reducing error rates and improving task completion" — the fix was tool-description quality, not system-prompt additions — [Writing effective tools for AI agents — Anthropic](https://www.anthropic.com/engineering/writing-tools-for-agents)
- Anthropic ran held-out evals comparing human-written vs. Claude-optimized Slack/Asana tool descriptions and reported "substantial" accuracy gains from optimization alone — [Writing effective tools for AI agents — Anthropic](https://www.anthropic.com/engineering/writing-tools-for-agents)
- Anthropic names the anti-pattern of "overlapping functionality" between tools as something that "confuses agent decision-making," and recommends namespacing (prefixing by service or resource, e.g. `asana_search`, `asana_projects_search`) to delineate tool boundaries at the description/name level, not in prose rules elsewhere — [Writing effective tools for AI agents — Anthropic](https://www.anthropic.com/engineering/writing-tools-for-agents)
- Anthropic separately warns against "low-signal responses" (returning raw IDs like `uuid`/`mime_type` instead of semantic names) and "opaque errors" (unhelpful codes instead of actionable guidance) as tool-design anti-patterns, distinct from system-prompt wording — [Writing effective tools for AI agents — Anthropic](https://www.anthropic.com/engineering/writing-tools-for-agents)
- OpenAI's Agents SDK frames the "instructions" parameter (system prompt) as the place for "behavior, tone, and capabilities," and classifies tools into data/action/orchestration categories, implying each tool's own semantics (not the prompt) carry the detail of what it retrieves or does — [A Practical Guide to Building AI Agents — OpenAI](https://openai.com/business/guides-and-resources/a-practical-guide-to-building-ai-agents/)
- DeepSeek's own documentation is explicit that the function `description` field "is not documentation for humans — it is instructions for the model," that the model "decides when to call a tool by reading it," and that "vague descriptions are the top reason a model ignores a tool or picks the wrong one." It contrasts a bad description ("gets data") with a good one ("Look up the latest shipping and fulfillment status for a U.S. ecommerce order") — [DeepSeek API docs — Function Calling](https://api-docs.deepseek.com/guides/function_calling)
- Google ADK's guidance: "The agent understands the function by reading its docstring, so it has to be detailed — including arguments, returns, types, and purpose," and tools should return consistent structures like `{"status": "success/error", ...}` so the agent can handle results — again, tool-level, not prompt-level — [Tools Make an Agent — Google Cloud](https://cloud.google.com/blog/topics/developers-practitioners/tools-make-an-agent-from-zero-to-assistant-with-adk)

### Inferences
- The consistent split across Anthropic, OpenAI, Google, and DeepSeek: **tool description = "how/when to use *this* tool, parameter semantics, caveats, boundary vs. sibling tools, output contract."** **System prompt = "role, tone, cross-tool policy, business rules that hold regardless of which tool fires."** Any paragraph in the system prompt that only exists to explain what a specific tool returns or when to call it is a candidate to move into that tool's `description`/parameter docs.
- Because tool descriptions are loaded into context on every turn exactly as written, they function as a second, parallel instruction channel — duplicating a tool's semantics in the system prompt *and* in its description is redundant token spend and a source of the "contradictory rules" anti-pattern (see Q6).

### Gaps
- No vendor source gives a numeric before/after score specifically for a 16-tool agent; the SWE-bench figure is a holistic benchmark score, not an isolated tool-selection accuracy metric.

## How many tools can a model reliably choose among before selection accuracy drops? (BFCL, ToolBench, provider guidance)

### Takeaway
There is no universal hard cap, but every source agrees performance degrades as the visible tool count grows past roughly 15-25 tools, with measured double-digit percentage-point degradation reported in a 2026 tool-selection paper benchmarked on BFCL and ToolBench; at 16 tools, the user's agent is inside the "generally fine but should watch" range per these numbers, not past a documented cliff.

### Cited Findings
- General finding (secondary synthesis of BFCL-related discussion): "performance declines after 20-25 functions due to cognitive overload" as available tool count increases, though most frameworks don't impose a hard cap — [BFCL discussion synthesis via web search, citing gorilla.cs.berkeley.edu BFCL materials]
- A 2026 paper, "How Many Tools Should an LLM Agent See? A Chance-Corrected Answer," benchmarked adaptive tool-shortlisting against fixed-size tool lists on BFCL (370 tools) and ToolBench (3,251 tools): on BFCL, an adaptive agent matched a fixed 50-tool list's 90.8% coverage while presenting only ~7.4 tools on average (90.3±2.4% coverage at K=7.4) — [How Many Tools Should an LLM Agent See? arXiv 2605.24660](https://arxiv.org/html/2605.24660)
- The same paper shows a downstream accuracy effect directly caused by distractor tool count: with Claude Sonnet 4.6, when the correct tool was presented in a short adaptive list the model picked it correctly 93.1% of the time, vs. 87.1% with a fixed 5-tool list — a 6-percentage-point accuracy drop attributable purely to more candidate tools being visible — [How Many Tools Should an LLM Agent See? arXiv 2605.24660](https://arxiv.org/html/2605.24660)
- On ToolBench's harder queries (correct tool ranked 6th-20th by relevance), a fixed K=5 tool list found the correct tool 0% of the time, while an adaptive approach searching to K≈5.7 found it 16.7% of the time — illustrating that a too-small fixed list, not just a too-large one, also hurts selection — [How Many Tools Should an LLM Agent See? arXiv 2605.24660](https://arxiv.org/html/2605.24660)
- Google ADK's architectural guidance: "Stuffing all tools into a single agent's system prompt degrades reasoning quality, especially in long-running contexts," which is why ADK promotes multi-agent delegation to focused sub-agents with narrower toolsets — [Deep Dive into Google's ADK](https://medium.com/@kamilmatejuk/deep-dive-into-googles-agent-development-kit-73995c803c2d) (secondary source summarizing ADK docs — treat as practitioner commentary, not a primary Google benchmark)

### Inferences
- 16 tools sits comfortably below every degradation threshold cited above (20-25 functions per the BFCL-adjacent synthesis; the arXiv paper's gains come from cutting lists that start at 50-3,251 tools down to ~5-7). This suggests the user's 16-tool count is not itself the accuracy bottleneck — the 56k-character system prompt is far more likely to be the dominant problem per Q3/Q5 below.
- The ToolBench "fixed K=5 found 0%" result is a caution against over-correcting: if the practitioner's instinct is to hide/group tools aggressively to shrink the visible set, under-exposing relevant tools is also measured to hurt accuracy, not just over-exposing them.

### Gaps
- No source gives a DeepSeek-specific or n8n-AI-Agent-node-specific tool-count accuracy curve; all numeric findings above are from Claude/Claude-Sonnet-4.6 and generic BFCL/ToolBench evaluations, not reproduced on DeepSeek models. This should be flagged as a cross-model extrapolation, not a DeepSeek-verified number.

## What is "context engineering" per Anthropic/OpenAI/Google, and what do they say about just-in-time retrieval vs. preloading everything in the system prompt?

### Takeaway
Anthropic's canonical definition: context engineering is "the set of strategies for curating and maintaining the optimal set of tokens... during inference," and its primary published recommendation for agents handling runtime state is a "just-in-time" strategy — keep lightweight identifiers/references in context and load full content only when needed — rather than preloading everything into the system prompt.

### Cited Findings
- Anthropic's framing: context engineering is "the natural progression of prompt engineering"; the shift for long-horizon, multi-turn agents is from "how to write a good prompt" to "what configuration of context is most likely to generate the desired behavior at each step" — [Effective context engineering for AI agents — Anthropic](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents)
- On "right altitude": system prompts should be "specific enough to guide behavior effectively, yet flexible enough to provide the model with strong heuristics," organized into distinct sections (e.g. `<background_information>`, `<instructions>`, tool guidance) using XML tags or Markdown headers — [Effective context engineering for AI agents — Anthropic](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents)
- Just-in-time vs. preloading, stated directly: "Rather than pre-processing all relevant data up front, agents built with the 'just-in-time' approach maintain lightweight identifiers... and dynamically load data into context at runtime," trading some runtime latency for "progressive disclosure" — incremental discovery of relevant context instead of dumping it all in at once — [Effective context engineering for AI agents — Anthropic](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents)
- Anthropic's recommended compromise is explicitly a **hybrid**, not an all-or-nothing choice: "retrieving some data up front for speed, and pursuing further autonomous exploration at its discretion" — [Effective context engineering for AI agents — Anthropic](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents)
- For state that must persist across a long task without permanently occupying the context window, Anthropic recommends structured note-taking: the agent "regularly writes notes persisted to memory outside of the context window," and sub-agent architectures where a specialist "returns only a condensed, distilled summary of its work (often 1,000-2,000 tokens)" to the coordinator — [Effective context engineering for AI agents — Anthropic](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents)
- Compaction (used when context nears its limit) is described as "summarizing its contents, and reinitiating a new context window with the summary," with the practical tip to "maximize recall... then iterate to improve precision" when writing the compaction prompt — [Effective context engineering for AI agents — Anthropic](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents)
- OpenAI's framing of system-prompt-adjacent content: "instructions" are the system prompt defining behavior/tone/capabilities and are called the "#1 success factor"; separately, tools are split into data tools (retrieve context/info), action tools (take actions), and orchestration tools (call other agents) — implying retrieval of context is a *tool's* job, not something to preload wholesale into the instructions — [A Practical Guide to Building AI Agents — OpenAI](https://openai.com/business/guides-and-resources/a-practical-guide-to-building-ai-agents/)
- Google ADK practitioner guidance converges on the same preload-vs-retrieve tension: large static instruction blocks "stuffing all tools" degrade reasoning in long-running contexts, favoring narrower sub-agents over one maximal system prompt — [Deep Dive into Google's ADK](https://medium.com/@kamilmatejuk/deep-dive-into-googles-agent-development-kit-73995c803c2d) (secondary/practitioner source)

### Inferences
- A 56k-character Spanish system prompt is, by Anthropic's own definition, the opposite of "right altitude" and the opposite of just-in-time loading — it is exhaustive preloading. The documented fix pattern (sections with explicit tags/headers, just-in-time retrieval for anything not needed on every turn, and sub-agent delegation for specialized workflows) directly targets this shape of problem.
- The business-rule content most likely to safely leave the system prompt for a WhatsApp remittance agent is anything that is (a) only relevant for specific message types/flows, (b) retrievable on demand (e.g., current exchange rates, compliance thresholds per country, document checklists) rather than needed on literally every turn — that content is a just-in-time/tool-retrieval candidate, not a system-prompt resident.

### Gaps
- Anthropic's article does not give a recommended token/character ceiling for system prompts; OpenAI's community-sourced practitioner number (500-3,000 tokens for the core prompt, see Q6) is the only concrete figure found, and it is explicitly a practitioner convergence estimate, not an OpenAI-published hard limit.

## Where should per-turn injected state/dynamic context live — system prompt, user turn, or tool result? Is system-prompt placement measurably worse?

### Takeaway
Every source that addresses this converges on the same rule: keep the system prompt (and tool definitions) as a **static, cacheable prefix**, and inject all per-turn/dynamic state (timestamps, session data, retrieved records, "context notes") into the **user turn or a tool result**, appended after the cache boundary — mutating the system prompt per turn is named explicitly as a cost and latency anti-pattern because it breaks prompt caching, not merely a style preference.

### Cited Findings
- Architecture pattern named directly: "Every agent request has two fundamentally different parts: a static prefix that stays identical across turns (system instructions, tool definitions) and a dynamic suffix that grows with every turn (user messages, assistant responses, tool outputs)" — [Prompt Caching in Agentic AI Systems](https://unscriptedcoding.medium.com/prompt-caching-in-agentic-ai-systems-1f4b78c65ea5)
- Named anti-pattern, specific to this user's setup: "injecting a timestamp or request ID into the system prompt, building system prompts with f-strings that include session-specific data, and appending per-user context to a shared instruction block" are called out as "what kills cache hit rates in practice" — the recommended alternative is to "pass per-user data as a user turn message" — [Prompt Caching in Agentic AI Systems](https://unscriptedcoding.medium.com/prompt-caching-in-agentic-ai-systems-1f4b78c65ea5)
- Explicit rule for updating state without breaking the cache: "append a reminder tag to the next user message so that the prefix stays untouched," rather than editing the system prompt — [Prompt Caching in Agentic AI Systems](https://unscriptedcoding.medium.com/prompt-caching-in-agentic-ai-systems-1f4b78c65ea5)
- Recommended prompt ordering: system instructions/behavioral rules at the top (fixed), tool definitions next (fixed), retrieved/reference context after that (kept stable where possible), and conversation history/tool outputs at the bottom as the dynamic suffix — [Prompt Caching in Agentic AI Systems](https://unscriptedcoding.medium.com/prompt-caching-in-agentic-ai-systems-1f4b78c65ea5)
- n8n-specific guidance repeats the same shape in different language: "the two most common system prompt mistakes are being too vague... and being too long," and recommends summarizing/truncating growing history rather than letting dynamic content accumulate in the main instruction channel; it also recommends context isolation via sub-agent nodes so a given sub-agent's context window only carries what it needs — [n8n AI Agents Tutorial](https://www.width.ai/post/n8n-ai-agents-tutorial-master-system-user-prompts-2026); [Context Engineering for LLMs — n8n blog](https://blog.n8n.io/context-engineering-llm/)
- n8n guidance also flags the "lost in the middle" risk directly: "large language models struggle with information buried in the middle of long prompts," recommending the most important instructions go at the top and bottom — relevant to where a code-node-injected context block should be placed relative to a 56k-char prompt — [n8n AI Agents Tutorial](https://www.width.ai/post/n8n-ai-agents-tutorial-master-style-user-prompts-2026)

### Inferences
- The user's current architecture (56k-char system prompt + a code node injecting context notes every turn) likely means per-turn notes are either appended to the system prompt text or sent as a separate message depending on how the n8n AI Agent node is wired; per the caching/architecture sources, the per-turn notes should go into the user-turn content (or a dedicated tool-result-like block), never concatenated into the system prompt string itself, both for cache-hit economics and for avoiding "lost in the middle" dilution of a prompt that is already far longer than any recommended ceiling.
- This is presented as "evidence that system-prompt placement is worse" in the specific sense of token cost and cache-hit rate (an operational/economic measurement), not as a controlled accuracy study; no source in this research ran a controlled A/B comparing task accuracy for "same dynamic content in system prompt" vs "same content in user turn." Treat the caching claims as well-evidenced engineering practice, and the accuracy-degradation claim for system-prompt placement specifically as inferred/plausible rather than directly measured.

### Gaps
- No primary-vendor (Anthropic/OpenAI/Google/DeepSeek) documentation was found that explicitly states "dynamic state in the system prompt produces lower accuracy than the same state in a user message," with a controlled measurement. The strongest evidence found is about cache-hit rate and cost (a secondary/practitioner source, not a provider primary source), plus the general "lost in the middle" positional-bias finding (also sourced from a secondary n8n practitioner guide rather than a primary research paper in this pass). This is a genuine evidence gap and should be flagged as such rather than overstated.

## Structure and delimiters (XML tags, Markdown headings) — evidence they improve adherence?

### Takeaway
Anthropic's primary context-engineering guidance explicitly recommends organizing prompts into distinct, delimited sections using XML tags or Markdown headers, framing this as part of achieving the "right altitude," but the research in this pass did not surface a controlled quantitative benchmark isolating the adherence gain from delimiters alone (as distinct from the gain from better content).

### Cited Findings
- "Prompts should be organized into distinct sections (like background information, instructions, tool guidance, output description, etc) and use techniques like XML tagging or Markdown headers to delineate these sections" — [Effective context engineering for AI agents — Anthropic](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents)
- Anthropic's companion guidance for tools recommends "canonical examples" over exhaustive edge-case lists, implying structured illustrative content (clearly separated from rules) is preferred to prose enumeration — [Effective context engineering for AI agents — Anthropic](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents)
- OpenAI's GPT-5 prompting guidance (cited in Q6) discusses prompt structure mainly in terms of instruction count and specificity rather than delimiter syntax specifically — [GPT-5 prompting guide — OpenAI developer cookbook, via search synthesis](https://developers.openai.com/cookbook/examples/gpt-5/gpt-5_prompting_guide)

### Inferences
- Given Anthropic explicitly recommends XML/Markdown sectioning as an engineering practice (not hedged as speculative), it is reasonable to apply it when restructuring the 56k-char prompt — but this note should present it as "Anthropic's documented recommendation," not as an isolated, benchmarked effect size, since no number was found quantifying "adherence improvement from delimiters alone."

### Gaps
- Did not find a benchmark that isolates delimiter formatting as the sole independent variable (vs. content quality/length) for adherence; this would require a dedicated search pass (e.g., looking for "prompt formatting ablation" studies) not completed within this research's budget.

## Anti-patterns explicitly named by providers for agent prompts

### Takeaway
The clearest, most directly sourced anti-patterns across providers are: (1) tools that are redundant 1:1 wrappers around API endpoints rather than a few high-impact tools, (2) overlapping tool functionality, (3) contradictory or conflicting system-prompt rules that force the model to spend reasoning effort reconciling them, and (4) long system prompts that bury the most important instructions in the middle instead of the top/bottom.

### Cited Findings
- "More tools don't always lead to better outcomes. A common error we've observed is tools that merely wrap existing software functionality or API endpoints" — recommendation is "a few thoughtful tools targeting specific high-impact workflows" — [Writing effective tools for AI agents — Anthropic](https://www.anthropic.com/engineering/writing-tools-for-agents)
- "Overlapping functionality" between tools is named as something that "confuses agent decision-making" — [Writing effective tools for AI agents — Anthropic](https://www.anthropic.com/engineering/writing-tools-for-agents)
- "Inefficient context use" (e.g., returning all records instead of providing search/filter tools) and "low-signal responses" (raw UUIDs/mime types instead of semantic identifiers) and "opaque errors" are named tool-design anti-patterns — [Writing effective tools for AI agents — Anthropic](https://www.anthropic.com/engineering/writing-tools-for-agents)
- OpenAI's GPT-5 prompting guide gives a worked adversarial example of contradictory rules in the same prompt ("Never schedule an appointment without explicit patient consent" vs. "auto-assign the earliest same-day slot without contacting the patient") and states that "poorly constructed prompts with contradictory or vague instructions can be more damaging" for strongly instruction-following models, because the model "spends reasoning tokens trying to reconcile them instead of choosing one at random" — [GPT-5 prompting guide, via community synthesis](https://community.openai.com/t/prompt-anti-patterns-when-more-instructions-may-harm-model-performance/1372460)
- Named anti-pattern: stacking mutually exclusive tone/behavior demands in one prompt ("concise, comprehensive, friendly, direct, step-by-step, non-technical, expert-level, empathetic, formal") and the specific contradictory-constraint example "Be concise, but thorough" are called harmful; practitioner-reported remedy is capping at "5-8 high-priority rules," with core prompt length converging around 500-3,000 tokens excluding tool schemas — [GPT-5 prompting guide discussion, via webiano.digital commentary](https://webiano.digital/gpt-5-5-needs-cleaner-prompts-not-longer-instructions/) (secondary commentary, not the primary OpenAI document itself — flagged accordingly)
- n8n-specific: "the two most common system prompt mistakes are being too vague... and being too long, the prompt consumes a large portion of your context window before any task input is added"; and "don't upload a book into a prompt and expect accurate results... use RAG instead of stuffing everything into the system message, as too much data causes hallucinations" — [n8n AI Agents Tutorial](https://www.width.ai/post/n8n-ai-agents-tutorial-master-system-user-prompts-2026)

### Inferences
- The "5-8 high-priority rules" and "500-3,000 token core prompt" figures are the only concrete numeric prompt-length guidance found in this research; they come from secondary/practitioner commentary on OpenAI's GPT-5 guide, not from an OpenAI primary-source number, so they should be cited as "practitioner convergence" rather than an official OpenAI limit.
- A 56k-character prompt (roughly 10,000-14,000+ tokens by typical ratios) is an order of magnitude beyond even the generous end of that practitioner range, which is independent corroborating evidence (alongside the context-engineering and caching sources above) that length/contradiction, not tool count, is the primary structural risk in the described setup.

### Gaps
- No primary OpenAI, Anthropic, or Google document found in this pass states a numeric system-prompt length ceiling; the token-count figures above are secondary/practitioner estimates and should be presented to the user as such, not as vendor-mandated limits.
- DeepSeek-specific prompt-length or anti-pattern guidance beyond function-calling description quality (Q1) was not located in this pass; DeepSeek's documentation found here is scoped to function/tool description writing only.

---

## Source list (primary vs. secondary)

**Primary (vendor-published):**
- [Effective context engineering for AI agents — Anthropic](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents) (2026 Anthropic engineering blog)
- [Writing effective tools for AI agents — Anthropic](https://www.anthropic.com/engineering/writing-tools-for-agents)
- [A Practical Guide to Building AI Agents — OpenAI](https://openai.com/business/guides-and-resources/a-practical-guide-to-building-ai-agents/)
- [DeepSeek API docs — Function Calling](https://api-docs.deepseek.com/guides/function_calling)
- [Agents — OpenAI Agents SDK docs](https://openai.github.io/openai-agents-python/agents/)

**Research paper (arXiv, 2026):**
- [How Many Tools Should an LLM Agent See? A Chance-Corrected Answer — arXiv 2605.24660](https://arxiv.org/html/2605.24660)

**Secondary / practitioner commentary (used only where no primary source was found, flagged inline above):**
- [Prompt Caching in Agentic AI Systems](https://unscriptedcoding.medium.com/prompt-caching-in-agentic-ai-systems-1f4b78c65ea5)
- [n8n AI Agents Tutorial: Master System & User Prompts (2026)](https://www.width.ai/post/n8n-ai-agents-tutorial-master-system-user-prompts-2026)
- [Context Engineering for LLMs: Strategies and Patterns — n8n blog](https://blog.n8n.io/context-engineering-llm/)
- [Deep Dive into Google's Agent Development Kit](https://medium.com/@kamilmatejuk/deep-dive-into-googles-agent-development-kit-73995c803c2d)
- [Tools Make an Agent: From Zero to Assistant with ADK — Google Cloud blog](https://cloud.google.com/blog/topics/developers-practitioners/tools-make-an-agent-from-zero-to-assistant-with-adk)
- [GPT-5 prompt anti-pattern discussion — OpenAI developer community](https://community.openai.com/t/prompt-anti-patterns-when-more-instructions-may-harm-model-performance/1372460)
- [GPT-5.5 needs cleaner prompts, not longer instructions](https://webiano.digital/gpt-5-5-needs-cleaner-prompts-not-longer-instructions/)

## Overall gaps worth flagging to the user
1. No source gives DeepSeek-model-specific numbers for tool-count degradation or prompt-length ceilings — all quantitative benchmarks found (BFCL/ToolBench/SWE-bench) were run on Claude or generic leaderboard models, not DeepSeek. Treat cross-model extrapolation to the DeepSeek/n8n setup as directionally useful, not DeepSeek-verified.
2. The claim "dynamic state in the system prompt produces worse task accuracy than the same state in a user turn" is well evidenced for *caching cost/latency* but not found as a controlled *accuracy* study from a primary provider in this pass.
3. No primary-vendor numeric system-prompt length ceiling exists; the 500-3,000 token / 5-8 rule figures are practitioner estimates, cited as such.
