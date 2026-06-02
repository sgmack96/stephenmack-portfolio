---
title: "How I Built a Role-Gated Multi-Agent Sales Intelligence Platform on Cloudflare Workers"
description: "Every architecture decision behind SE Intel — Durable Objects for agent state, three-tier RAG with namespace filtering, streaming SSE, LTM extraction, and an LLM-as-judge eval harness."
date: "2026-06-02"
tags: ["cloudflare", "workers", "ai", "durable-objects", "vectorize", "rag"]
---

**Live:** https://se-intel-portfolio.stephenmack96.workers.dev  
**Stack:** Workers · Durable Objects · Workers AI · Vectorize · KV · D1 · Hono

---

I built SE Intel as a portfolio project to prove I can ship production AI systems — not demos, not prototypes, actual deployed software with auth, memory, streaming, observability, and an evaluation harness. This post explains every architecture decision and what I learned along the way.

---

## What it does

SE Intel is a two-agent system for sales teams at Cloudflare. Two agents, one platform, five roles with different access levels:

**AccountIntelAgent** — pre-call research. Give it a company name or a tech stack description, get back competitive positioning, discovery questions, and Cloudflare opportunities grounded in real product documentation.

**EnablementAgent** — sales coaching. Ask it how to handle an objection, get the 4-part response framework with specific proof points. Ask for a POC migration plan, get a week-by-week breakdown pulled from the SE knowledge base. Ask about discount approval as a manager, get the actual pricing tiers — but only if your JWT says you're a `sales_manager`.

Here's what a full request looks like end-to-end:

```
Browser
  │
  ├─ POST /api/v1/account/stream
  │    Authorization: Bearer <HS256 JWT>
  │
  ▼
Cloudflare Worker (Hono router)
  ├─ extractUserContext()     → decode + verify JWT → UserContext{userId, role, orgId}
  ├─ checkRateLimit()         → KV sliding window → 429 if exceeded
  └─ stub.fetch("/stream")    → forward to Durable Object for this userId
       │
       ▼
  AccountIntelAgent (Durable Object)
  ├─ memory.getHistory()      → SQLite: last 20 turns for this threadId
  ├─ ltm.formatForPrompt()    → KV: stored facts about this user
  ├─ buildSystemPrompt()      → role-specific instructions + LTM injection
  ├─ dispatchTools()
  │    ├─ fetchNews()         → NewsAPI (se/tam/manager only)
  │    ├─ kbSearch()          → Vectorize RAG (namespace-filtered by role)
  │    └─ webSearch()         → DuckDuckGo → fallback to KB if empty
  ├─ AI.run(stream: true)     → Workers AI Llama 3.3 70B → ReadableStream
  ├─ SSE stream → Worker → Browser (tokens arrive as they generate)
  └─ state.waitUntil()
       ├─ memory.append()     → SQLite: persist both turns
       ├─ writeAuditEvent()   → D1: full audit log entry
       └─ ltm.extractAndRemember() → Workers AI extraction → KV facts
```

---

## Architecture decision 1: Durable Objects for agent state

The most important decision in the whole system. I could have put agent logic directly in the Worker — most demos do. Here's why I didn't.

A Worker is stateless by design. Every request might hit a different isolate in a different data center. That's great for throughput, but it means conversation history is hard. The standard workaround is to store history in KV or D1 and read it on every request. That works, but it has a race condition: if a user sends two messages quickly, both requests might read the same history, process in parallel, and write conflicting state back.

Durable Objects solve this permanently. Each user gets exactly one DO instance, identified by their `userId`. The DO is single-threaded — requests to the same instance are serialized automatically by the runtime. No locks, no transactions, no race conditions. Alice's `AccountIntelAgent` instance can never run concurrently with itself. And because each DO has its own embedded SQLite storage (10GB per instance), Alice's conversation history is physically isolated from Bob's at the storage layer, not just logically separated by a key prefix.

The operational story is also good: idle DOs hibernate and cost nothing. A user who hasn't chatted in a week isn't keeping anything alive.

The tradeoff I accepted: DOs add latency for the first request to a cold instance (a few hundred milliseconds to restore state). For a chat interface where the first response takes 10+ seconds anyway due to LLM generation time, that's invisible.

---

## Architecture decision 2: Three-tier knowledge base with role-gated namespaces

The KB is 102 chunks of hand-written content embedded with BGE-base-en-v1.5 (768 dimensions) and stored in Vectorize. Three namespaces:

- **`public`** (80 chunks) — Cloudflare product overviews, pricing tiers, competitor comparisons. Every role can query this.
- **`se_only`** (12 chunks) — POC patterns, architecture deep-dives, technical objection handling, integration complexity maps. SE, TAM, and manager only.
- **`manager_only`** (10 chunks) — Discount approval tiers, champion-building frameworks, deal strategy, escalation playbooks. Manager only.

The access control is enforced at two layers. `ROLE_KB_ACCESS` in `types/index.ts` defines the mapping:

```typescript
export const ROLE_KB_ACCESS: Record<Role, KBNamespace[]> = {
  ae:            ["public"],
  csm:           ["public"],
  se:            ["public", "se_only"],
  tam:           ["public", "se_only"],
  sales_manager: ["public", "se_only", "manager_only"],
};
```

But I don't stop there. The KB search tool re-checks this at execution time:

```typescript
const allowedNamespaces = ROLE_KB_ACCESS[role];
if (namespace && !allowedNamespaces.includes(namespace)) {
  console.warn(`Role ${role} attempted to access ${namespace} — denied`);
  return null;
}
```

Why enforce it twice? Because defense in depth matters more than DRY code when the constraint is access control. If a bug in the orchestrator somehow passes the wrong role, the tool itself still rejects the query. The Vectorize filter clause (`{ filter: { namespace: ns } }`) is the third layer — even if both code checks failed, Vectorize would only return chunks that match the namespace filter.

The retrieval flow: embed the query with BGE, query Vectorize with `topK: 5` and cosine similarity, filter by role-allowed namespaces, inject the top results into the system prompt before the LLM call. This is standard RAG. What's less standard is querying multiple namespaces in parallel using `Promise.all` and merging results sorted by score before injecting.

One thing I got wrong and fixed: I initially stored chunk content separately from the vectors, which meant a second lookup to fetch the actual text after retrieval. Always store `content` in vector metadata — it avoids an extra round trip.

---

## Architecture decision 3: JWT auth with three validation paths

Auth has to work in three contexts:

1. **Production** — behind Cloudflare Access, which validates the JWT before the request hits the Worker. The Worker just parses the already-verified `cf-access-jwt-assertion` header.
2. **Portfolio** — no Access setup, but I still want to demo RBAC. The Worker issues and validates its own HS256 JWTs via `POST /dev/token`. Signing key lives in `wrangler secret`.
3. **Local dev** — no JWT at all, just `X-Dev-User-*` headers. Gated behind `ENVIRONMENT === "development"` so it's impossible to use in production or portfolio.

The key design constraint: **RBAC is enforced at tool execution time, not just at the auth layer**. `extractUserContext()` determines *who* you are. But even after that, every tool checks the role again before executing. This means an AE with a valid SE JWT (if one was somehow issued) still can't access `se_only` KB content — the tool would reject it.

I used HS256 instead of RS256 for the portfolio environment because HS256 verification works entirely in the Workers SubtleCrypto API with no external calls. A production deployment would use Cloudflare Access with RS256 and JWKS verification.

---

## Architecture decision 4: Streaming with Server-Sent Events

The default pattern for Workers AI: call `AI.run()`, wait 10-20 seconds, return the full JSON response. The UX is terrible — a spinner for 15 seconds, then everything appears at once.

The fix is `stream: true` in the `AI.run()` call. This returns a `ReadableStream` instead of waiting for the full generation. Workers AI streams in SSE format internally — we parse the `data:` lines and re-emit our own events:

```
data: {"type":"tools","toolsUsed":["kb_search"]}   ← fires after tool dispatch
data: {"type":"token","text":"Cloud"}               ← one per token
data: {"type":"token","text":"flare Workers"}
data: {"type":"done","latencyMs":5381}              ← stream end
```

The tool event fires before the first token. This matters for UX — the UI can show tool badges ("kb_search") immediately, before any text appears, so the user knows *why* the response is taking a moment.

In the Worker, the streaming route passes the DO's `ReadableStream` straight through to the browser without buffering:

```typescript
const doResp = await stub.fetch(new Request("https://do-internal/stream", {...}));
return new Response(doResp.body, {  // pass body directly, don't buffer
  headers: { "Content-Type": "text/event-stream", ... }
});
```

One gotcha: in the DO's streaming handler, memory writes and audit log happen after `writer.close()` via `state.waitUntil()`. Without `waitUntil`, the DO isolate can be killed before async work completes — a silent failure that produces no errors, just missing data.

---

## Architecture decision 5: Long-term memory with LLM extraction

The `LongTermMemory` class had `remember()`, `recall()`, and `formatForPrompt()`. But nothing was ever calling `remember()`. Memory was always empty. Facts were being injected into system prompts but the injected string was always blank.

The fix is `extractAndRemember()` — a short LLM call that runs after every response:

```typescript
const prompt = `Extract 0-2 memorable personal facts about the user from this exchange.
USER MESSAGE: "${userMessage.slice(0, 400)}"
AGENT RESPONSE: "${agentResponse.slice(0, 300)}"

Good facts: named accounts, preferences, upcoming events, named contacts.
Bad facts: questions asked, generic product info, role (already known).

Return ONLY: {"facts": ["fact 1"]} or {"facts": []}`;
```

The model is conservative — it only extracts things that are clearly personal and specific. That's correct behavior. The alternative — extracting everything — produces noise that degrades future responses.

Two bugs I hit building this:

**Bug 1: Fire-and-forget in a Durable Object dies early.** My first implementation used `.catch(() => {})` on the extraction call. The extraction silently produced zero results every time. Root cause: when a DO returns a `Response`, the runtime can terminate the isolate before any pending async work completes. The fix is `state.waitUntil(promise)`.

**Bug 2: Workers AI returns objects, not strings.** When calling `AI.run()` with a system prompt instructing the model to return JSON, the `response` field is sometimes a parsed JSON object, not a string. My code was doing `JSON.parse(result.response)` which threw `TypeError: Cannot parse [object Object]`. The fix:

```typescript
if (typeof responseField === "object") {
  parsed = responseField as { facts?: unknown };  // already parsed
} else if (typeof responseField === "string") {
  parsed = JSON.parse(responseField);             // needs parsing
}
```

Both bugs are silent — no thrown errors, just empty results. These are the worst kind.

---

## The evaluation harness

Shipping agents without evals is guesswork. I built a three-step Python harness:

```
runner.py → judge.py → report.py
```

**runner.py** — iterates over 15 test cases (8 for AccountIntelAgent, 7 for EnablementAgent), gets a JWT for each required role, calls the live API, records response text, tools used, and latency.

**judge.py** — for each result, builds a structured scoring prompt and calls Workers AI as the judge. Four dimensions scored 0-3 each (12 points max): Groundedness, Relevance, Role-appropriateness, Actionability. Pass threshold: 8/12.

**report.py** — prints per-case scores, per-agent averages, and diffs against the previous run. Exit code 1 if overall pass rate drops below 80%.

The test cases intentionally test RBAC: `acc-006` and `acc-001` are the same question asked by an AE vs an SE. If the system is working, the SE gets a more technical response using `se_only` KB chunks. The judge's `role_appropriateness` dimension will penalize an over-technical response to an AE. These paired cases are the most valuable in the suite.

One honest limitation: using the same model as both agent and judge introduces self-grading bias. The right fix is using a different model as judge. I didn't do this to keep the eval harness free, but it's the right call for anything beyond a portfolio.

---

## What Cloudflare's platform made possible

**No cold starts meant streaming felt natural.** On Lambda, streaming reduces perceived latency but TTFB is still 1-2 seconds for cold starts on top of LLM generation time. On Workers, TTFB on the stream endpoint is under 100ms. The streaming UX only works if the connection itself is fast.

**Durable Objects made per-user isolation trivial.** On a traditional stack, you'd use Redis with a user-keyed prefix, worry about TTL management, and deal with the race condition on concurrent writes. Durable Objects are the right abstraction: one object, one user, serialized access, embedded storage. The code is simpler and the correctness guarantee is stronger.

**Vectorize namespace filtering is a first-class feature.** I'm using metadata filter queries (`{ filter: { namespace: "se_only" } }`) to enforce RBAC at the vector search layer. The filter doesn't noticeably increase query latency.

**Workers AI made the eval harness free.** Running 15 LLM judge calls per eval run against a third-party API would cost real money at scale. On Workers AI, it's free within the paid plan quota. That changes the economics of running evals frequently.

---

## What I'd change

**Reranking.** After Vectorize returns the top 5 chunks by cosine similarity, a second pass with a cross-encoder model would re-score them for actual relevance. I skipped this because 102 chunks is small enough that embedding similarity works well. At 10,000+ chunks it would matter.

**The extraction model is too conservative.** It extracts preferences reliably but misses deal context. I'd add deal context explicitly to the good examples list and test against a rubric.

**No conversation reset UI.** A "New conversation" button would take 10 lines of JS.

**Self-grading bias in the eval judge.** The right fix is Claude as judge — cleaner scores, directly relevant to Anthropic target roles.

---

## The stack

| Layer | What | Why |
|-------|------|-----|
| Compute | Cloudflare Workers | Zero cold starts, global in one command |
| Agent state | Durable Objects (SQLite) | Per-user isolation, serialized access, no race conditions |
| Inference | Workers AI Llama 3.3 70B | Free on paid plan, edge-collocated |
| Embeddings | Workers AI BGE-base-en-v1.5 | No external call for embedding |
| Vector search | Cloudflare Vectorize | Cosine similarity + namespace filtering |
| Long-term memory | Workers KV | Globally replicated, shared across agents |
| Audit log | D1 (SQLite) | Every request logged |
| Rate limiting | Workers KV | Sliding window per user, role-based limits |
| Auth | HS256 JWT / CF Access | No external auth service |
| Routing | Hono | TypeScript-native, Workers-compatible |
| Eval harness | Python (httpx + python-dotenv) | TypeScript agents, Python evals |

Total infrastructure cost at portfolio scale: **$0**.

---

*Built by a Cloudflare Solutions Engineer who got tired of seeing AI demos that never ship.*
