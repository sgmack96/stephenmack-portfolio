---
title: "Multi-Tenant Isolation in an Edge AI System — Three Layers, Three Probes, Zero Trust"
description: "How I isolated RAG, memory, and audit data by organization in a multi-agent AI platform on Cloudflare Workers. Every isolation boundary is proven by a deterministic probe — no LLM in the test path."
date: "2026-06-18"
tags: ["cloudflare", "workers", "ai", "multi-tenancy", "isolation", "durable-objects", "vectorize", "security"]
---

**Live:** https://se-intel-portfolio.stephenmack96.workers.dev
**Code:** https://github.com/sgmack96/ai-dev/tree/main/projects/se-intel
**Stack:** Workers · Durable Objects · Workers AI · Vectorize · KV · D1 · Hono

---

## The problem

If you're building a multi-tenant AI system — one where multiple organizations share the same deployment — you have a data isolation problem that most tutorials skip entirely.

A traditional SaaS app has one data layer: a database with a `WHERE org_id = ?` clause. An AI system has at least three:

1. **RAG knowledge base** — vector embeddings that get retrieved and injected into the LLM context
2. **Conversation memory** — chat history (short-term) and personal facts (long-term)
3. **Audit trail** — who asked what, which tools ran, what data was accessed

If you isolate one layer but not the others, you still have a data leak. An org-scoped database doesn't help if the vector search returns another org's chunks. A filtered vector search doesn't help if the memory system stores facts under a shared user key.

This post walks through how I isolated all three layers in [SE Intel](https://se-intel-portfolio.stephenmack96.workers.dev), a multi-agent revenue intelligence platform running on Cloudflare Workers. Every isolation boundary has a deterministic probe that proves it works — no LLM in the test path.

---

## The architecture (before isolation)

SE Intel has three AI agents — AccountIntelAgent (pre-call research), EnablementAgent (product coaching), and TranscriptAgent (post-call analysis). Each agent is a Cloudflare Durable Object with:

- **Short-term memory:** SQLite embedded in the DO (conversation history, last 20 turns)
- **Long-term memory:** Workers KV (personal facts extracted by a background LLM call, shared across agents)
- **RAG:** Vectorize index with 105 chunks across three role-gated namespaces (public, se_only, manager_only)
- **Audit:** D1 database logging every request with user, role, org, agent type, tools used, and latency

Authentication is JWT-based — Cloudflare Access in production, self-issued HS256 tokens in portfolio mode. The JWT carries `userId`, `orgId`, and `role` as claims.

Before this week, `orgId` existed in the JWT and flowed through `UserContext` into every request — but nothing downstream actually enforced it. The claim existed without the enforcement.

---

## Layer 1: RAG isolation (Vectorize metadata filter)

### The gap

The Vectorize index stores all chunks in one shared index, separated by role-namespace (`public`, `se_only`, `manager_only`). Before isolation, `kbSearch` filtered by namespace only — any org could retrieve any org's chunks.

### The fix

Added `orgId` to chunk metadata at seed time and a metadata filter at query time:

```typescript
// src/tools/kb-search.ts:94
const results = await env.VECTORIZE.query(queryVector, {
  topK: 5,
  filter: {
    namespace: ns,
    orgId: { $in: [orgId, "global"] }  // caller's org + shared product docs
  },
  returnMetadata: "all",
});
```

The `"global"` sentinel means shared product documentation (Workers pricing, competitive comparisons) is accessible to every org. Org-specific content (negotiated discounts, custom deal terms) is visible only to that org.

### The decision

**One shared index with metadata filtering** rather than a separate Vectorize index per org. One seed script, one wrangler binding, one place to update content. The trade-off: isolation is logical (enforced at query time), not physical (separate indexes). A chunk seeded with the wrong `orgId` leaks silently. That risk lives in the data pipeline, not the query layer.

### The probe

```sh
curl -X POST /admin/kb-probe \
  -d '{"query":"negotiated discount","role":"se","orgId":"acme"}'
# → { "isolationOk": true, "matchCount": 4, "leakedChunks": 0 }

curl -X POST /admin/kb-probe \
  -d '{"query":"negotiated discount","role":"se","orgId":"portfolio-org"}'
# → { "isolationOk": true, "matchCount": 3, "leakedChunks": 0 }
# acme's private chunk is absent despite being the highest-scoring result
```

`/admin/kb-probe` calls `kbSearchRaw` directly — the same retrieval function the agents use, minus the LLM. It returns raw chunks with their `orgId` metadata. If any returned chunk belongs to a different org, `isolationOk` is `false`.

### What I learned the hard way

The first isolation test went through the LLM. I seeded an acme-only chunk stating "35% negotiated discount," then asked the agent: "What discount did acme negotiate?" The agent answered "25%." I thought the filter had failed.

It hadn't. The chunk was retrieved correctly. The LLM just didn't use it faithfully — it conflated the retrieved content with its training data and drifted to a plausible-but-wrong number.

**An LLM is not a reliable test oracle for your infrastructure.** If your isolation test goes through the model, a hallucination can mask a real bug or mask a working fix. Any correctness property you need to verify deterministically has to be tested below the model layer. That's why every probe in this system bypasses the LLM entirely.

---

## Layer 2: Memory isolation (DO key scheme + KV prefix)

### The gap

Short-term memory (conversation history) lived in Durable Objects keyed by `userId` only — `idFromName("alice")`. Long-term memory (personal facts) lived in KV keyed by `ltm:{userId}:{factId}`. If `alice` existed in both `acme` and `portfolio-org`, they'd share the same DO and the same KV facts.

### The fix

**Short-term:** DO keys changed from `idFromName(userId)` to `idFromName(`${orgId}:${userId}`)` across all 7 DO lookup sites. Each org+user combination now gets a physically separate DO instance with its own SQLite.

```typescript
// src/index.ts:175 — before
const doId = c.env.ACCOUNT_AGENT.idFromName(userContext.userId);

// src/index.ts:175 — after
const doId = c.env.ACCOUNT_AGENT.idFromName(`${userContext.orgId}:${userContext.userId}`);
```

**Long-term:** `LongTermMemory` constructor takes `orgId` as a second parameter. KV keys changed from `ltm:{userId}:{factId}` to `ltm:{orgId}:{userId}:{factId}`.

```typescript
// src/memory/long-term.ts:53
private indexKey(): string {
  return `ltm:${this.orgId}:${this.userId}:__index`;
}
```

### The decision

**Full physical isolation per org** (Option B) rather than shared DOs with logical filtering (Option A). In production, `alice@acme` and `alice@portfolio-org` are different people. The DO and KV boundaries should reflect the tenant, not just the username.

The trade-off: changing `idFromName` keys orphans all existing DO instances. The old DOs (keyed by `userId` alone) still exist but are never referenced — they hibernate at $0 and eventually get garbage collected. In production, this would require a data migration plan. **Key scheme decisions are architectural commitments.**

### The probe

```sh
curl -X POST /admin/memory-probe \
  -d '{"userId":"probe-user","orgA":"acme","orgB":"portfolio-org"}'
# → { "isolationOk": true, "orgACanRead": true, "orgBCanRead": false }
```

`/admin/memory-probe` writes a test fact under `orgA`, reads it back (asserts found), then reads as `orgB` (asserts not found). Cleans up after itself.

---

## Layer 3: Audit isolation (parameterized SQL + role-split)

### The gap

The audit log already had an `org_id` column, an index on `(org_id, timestamp DESC)`, and an INSERT that bound `orgId` on every request — all since Day 1. The gap was the **read path**: there was no endpoint that enforced the org boundary on a query.

### The fix

Two new endpoints.

**`GET /api/v1/audit`** — user-accessible, org-scoped read. `orgId` comes from the JWT, never from the request. The caller cannot request another org's data.

Role-split logic:
- `sales_manager` sees all rows for their org — `WHERE org_id = ?`
- Everyone else sees only their own rows — `WHERE org_id = ? AND user_id = ?`

```typescript
// src/index.ts — audit endpoint
let query = `SELECT ... FROM audit_log WHERE org_id = ?`;
const params = [userContext.orgId];

if (userContext.role !== "sales_manager") {
  query += ` AND user_id = ?`;
  params.push(userContext.userId);
}

query += ` ORDER BY timestamp DESC LIMIT ?`;
params.push(limit);
```

**`POST /admin/audit-probe`** — deterministic isolation test.

### The probe

```sh
curl -X POST /admin/audit-probe \
  -d '{"orgA":"acme","orgB":"portfolio-org"}'
# → { "isolationOk": true, "crossOrgLeaked": 0, "orgARowCount": 1, "orgBRowCount": 16 }
```

The probe counts rows per org, fetches orgA's most recent row ID, then confirms orgB's scoped query cannot return it. No fake data written — the query binding itself is the proof.

---

## The end-to-end test

One script, three probes, one command:

```sh
./tests/isolation-test.sh

# SE Intel — Multi-Tenancy Isolation Test
# Target: https://se-intel-portfolio.stephenmack96.workers.dev
#
# Layer 1: RAG (Vectorize)
#   → kb-probe         ✓ PASS — isolationOk: true
#
# Layer 2: Memory (DO + KV)
#   → memory-probe     ✓ PASS — isolationOk: true
#
# Layer 3: Audit (D1)
#   → audit-probe      ✓ PASS — isolationOk: true
#
# ALL ISOLATION TESTS PASSED — 3/3 layers verified
# No LLM in the test path. Every assertion is deterministic.
```

CI-compatible: `./tests/isolation-test.sh --ci` exits 1 on any failure.

---

## The isolation model — summary

| Layer | Storage | Isolation mechanism | Boundary type | Probe |
|-------|---------|-------------------|---------------|-------|
| RAG | Vectorize (shared index) | `orgId` metadata filter + `"global"` sentinel | Logical (query-time) | `/admin/kb-probe` |
| Short-term memory | DO SQLite | `idFromName(orgId:userId)` — separate DO per org+user | Physical (separate instance) | `/admin/memory-probe` |
| Long-term memory | Workers KV | `ltm:{orgId}:{userId}:{factId}` key prefix | Logical (key-space partition) | `/admin/memory-probe` |
| Audit | D1 SQLite | `WHERE org_id = ?` bound parameter + role-split read | Logical (query-time) | `/admin/audit-probe` |

Every request passes through five independent checkpoints: network edge auth (Cloudflare Access), JWT verification (Worker middleware), rate limiting (KV), permission checks on each data source (tool layer), and the storage address itself (DO key + KV prefix + Vectorize filter + D1 WHERE clause). A failure at any single layer doesn't compromise the others.

---

## What's still missing

**Per-org rate limiting.** The rate limiter is currently keyed by `userId` only — it prevents individual user abuse but doesn't prevent one org with 50 users from consuming a disproportionate share of compute. A second tier (`rl-org:${orgId}:${bucket}`) with an aggregate cap would close that gap.

**Seed validation in CI.** The Vectorize metadata filter is only as strong as the metadata on the seed data. A chunk seeded with the wrong `orgId` leaks silently. A seed validator that asserts every chunk has a valid `orgId` before deployment would catch this.

**LLM faithfulness.** Retrieval is correct (proven by the probes), but the LLM doesn't always ground its response in the retrieved chunks. A faithfulness eval — part of Week 2's work — will close the loop between correct retrieval and correct generation.

---

## The interview answer

> "How do you keep customer data isolated in a multi-tenant AI system?"

Three layers, not one. RAG isolation via Vectorize metadata filtering — one shared index with an `orgId` filter and a `"global"` sentinel for shared content. Memory isolation via org-scoped DO keys and KV prefixes — each org+user gets a physically separate conversation store and a partitioned fact store. Audit isolation via parameterized D1 queries with role-based depth — managers see org-wide, individuals see their own. Every layer has a deterministic probe that bypasses the LLM entirely. One test script runs all three probes and asserts `isolationOk: true` across the board. The probes are the proof, not the model.
