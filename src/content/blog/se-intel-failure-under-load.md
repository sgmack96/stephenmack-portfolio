---
title: "Failure Under Load: Fixing a Race Condition and Adding AI Fallbacks"
description: "How I hardened SE Intel against two production failure modes: a KV rate limiter that lost counts under concurrency, and Workers AI failures that needed a 70B → 8B → canned-response fallback chain."
date: "2026-07-17"
tags: ["cloudflare", "workers", "durable-objects", "workers-ai", "reliability", "fallbacks", "rate-limiting", "se-intel"]
---

**Live:** https://se-intel-portfolio.stephenmack96.workers.dev  
**Build log:** [/projects/se-intel-build-log](/projects/se-intel-build-log)  
**Stack:** Cloudflare Workers · Durable Objects · Workers AI · Vectorize · D1 · KV · Hono  
**Code:** Available on request

---

Week 4 of SE Intel was about one production question: **what happens under failure or load?**

Two things shipped:

1. I replaced a KV-backed rate limiter with a Durable Object after finding a real lost-update race under concurrent requests.
2. I added a three-tier AI fallback chain: primary 70B model, fallback 8B model, then a canned degraded response if both fail.

Both changes matter because they turn reliability claims into something testable. "We have rate limiting" is not enough if the counter loses half its increments under concurrency. "We handle model failures" is not enough if the user sees a 500 when Workers AI is unavailable.

---

## Part 1: The KV counter race

The original rate limiter used Workers KV as a per-user sliding-window counter.

The flow was simple:

```ts
const current = await env.RATE_LIMIT_KV.get(key);
const count = current ? parseInt(current, 10) : 0;

if (count >= limit) {
  return { allowed: false, remaining: 0, resetAt };
}

await env.RATE_LIMIT_KV.put(key, String(count + 1), { expirationTtl: 120 });
```

That works when requests arrive one at a time. It fails under concurrency.

If 20 requests hit the same key at the same time, they can all read the same starting value:

```txt
Request A: KV.get("rl:alice:123") → 0
Request B: KV.get("rl:alice:123") → 0
Request C: KV.get("rl:alice:123") → 0

Request A: KV.put("rl:alice:123", "1")
Request B: KV.put("rl:alice:123", "1")
Request C: KV.put("rl:alice:123", "1")
```

The counter ends at `1`, not `3`.

This is a classic **lost update**. KV is excellent for low-latency, read-heavy workloads. It is not an atomic counter. There is no built-in compare-and-swap, no transaction boundary around read-modify-write, and no atomic increment primitive.

The live bug was not theoretical. With 25 near-simultaneous requests, the counter landed around 10 instead of ~25. That means the limiter was silently letting traffic through under the exact condition where it mattered most.

---

## The fix: move the counter into a Durable Object

I replaced the KV counter with a new Durable Object: `RateLimiterDO`.

The important design choice: **one DO instance per user**, keyed by `userId`.

```ts
export async function checkRateLimit(
  userId: string,
  role: Role,
  env: Env
): Promise<RateLimitResult> {
  const id = env.RATE_LIMITER.idFromName(userId);
  const stub = env.RATE_LIMITER.get(id);

  const resp = await stub.fetch(new Request("https://rate-limiter/check", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ role }),
  }));

  return resp.json<RateLimitResult>();
}
```

Inside the Durable Object, the counter is just normal storage:

```ts
private async check(role: Role): Promise<RateLimitResult> {
  const limit = RATE_LIMITS[role];
  const bucket = Math.floor(Date.now() / 60_000);
  const key = `rl:${bucket}`;

  const count = (await this.ctx.storage.get<number>(key)) ?? 0;

  if (count >= limit) {
    return { allowed: false, remaining: 0, resetAt };
  }

  await this.ctx.storage.put(key, count + 1);

  return { allowed: true, remaining: limit - (count + 1), resetAt };
}
```

For this access pattern, the Durable Object is the right primitive because all checks for the same user route to the same object instance. That serializes the read/compare/write sequence for that user's counter. No distributed lock. No compare-and-swap. No retry loop.

This is not "Durable Objects magically solve all races." The guarantee is scoped: competing writes for the same counter must route to the same object instance. That is why the keying decision matters.

---

## Verification

After deployment, I ran the same concurrency test against the live Worker.

Role: `ae`  
Limit: 20 requests/minute

Result:

```txt
20 concurrent GET /api/v1/audit requests → all 200
Request 21 → 429
Request 22 → 429
Request 23 → 429
Request 24 → 429
Request 25 → 429
```

Baseline probes also passed after deployment:

```txt
health-probe.sh    → 4/4 PASS
isolation-test.sh  → 3/3 PASS
```

Deployed Worker version: `a84d9523`

The before/after is the whole point:

| Version | Result under concurrency |
|---|---|
| KV counter | 25 requests counted as ~10 |
| Durable Object counter | 20 requests counted exactly, request 21 rejected |

---

## Part 2: What happens when Workers AI fails?

Before Week 4, the answer was weak: the user got a 500 or a broken Server-Sent Events stream.

That is not production behavior. A model provider will eventually fail, timeout, or return an unexpected error. The app needs a defined degraded mode.

I added a three-tier fallback chain:

| Tier | Trigger | Model/response | Metric status |
|---|---|---|---|
| 1 | Normal path | Llama 3.3 70B | `success` |
| 2 | Primary fails, or debug header is set | Llama 3.1 8B | `fallback` |
| 3 | Both models fail | Canned degraded response | `error` |

The normal path is:

```txt
try 70B
  └─ if it fails: try 8B
       └─ if it fails: return canned degraded response
```

The key is that `fallback` is not treated as `error`. If the 70B is down but the 8B responds, the system worked in degraded mode. The health scorecard should be able to distinguish that from a full outage.

---

## Debug toggle: forcing degraded mode on demand

Waiting for a real outage is a bad test strategy. I added a debug header:

```txt
X-Debug-Fallback: true
```

The request path is:

```txt
Client request
  → index.ts reads X-Debug-Fallback
  → sends forceFallback: true to the Durable Object
  → base-agent.ts skips the 70B
  → calls the 8B fallback model directly
```

I used a header instead of a query parameter because this is an operational/debug behavior, not user-facing state. A query string is easy to copy, share, and accidentally turn into a "broken on purpose" URL. A header is invisible in the browser URL and better suited to test tooling.

---

## Streaming fallback

SE Intel supports token-by-token streaming over Server-Sent Events. The fallback chain had to work there too.

When forced fallback is enabled on the streaming endpoint, the stream emits a model event before the first token:

```txt
data: {"type":"model","model":"@cf/meta/llama-3.1-8b-instruct-fp8","reason":"forced_fallback"}
data: {"type":"token","text":"Hello"}
data: {"type":"done","latencyMs":725,"model":"@cf/meta/llama-3.1-8b-instruct-fp8"}
```

One important boundary: if the primary model fails **after tokens have already streamed**, I do not switch models mid-answer. At that point the user has partial text from the 70B. Splicing in tokens from an 8B model would produce incoherent output. The fallback chain is for failures before generation begins, not for stitching together two different model outputs mid-sentence.

---

## The bug that proved the chain

During testing, I used the wrong Workers AI model identifier:

```txt
Wrong:   @cf/meta/llama-3.1-8b-instruct
Correct: @cf/meta/llama-3.1-8b-instruct-fp8
```

The wrong name caused the fallback model call to fail. The chain correctly fell through to Tier 3 and returned the canned degraded response.

That was an accidental but valuable test. It proved the full path works:

```txt
primary skipped → fallback model fails → canned degraded response succeeds
```

After fixing the model name, forced fallback worked as intended:

```txt
Normal request:          @cf/meta/llama-3.3-70b-instruct-fp8-fast
Forced fallback request: @cf/meta/llama-3.1-8b-instruct-fp8
Streaming fallback:      model event → 8B tokens → done event
```

Final deployed Worker version: `f1e1a899`

---

## Why not a circuit breaker?

A circuit breaker would track model failures over time and temporarily stop calling a failing model after a threshold is crossed.

That would avoid this problem:

```txt
70B is down for 10 minutes
Every request wastes 1-2 seconds trying 70B
Then every request falls back to 8B
```

For a high-traffic system, a circuit breaker is the right next step. It prevents repeated slow failures and reduces pressure on a degraded provider.

For this system today, the try/catch fallback chain is enough. SE Intel is a portfolio-scale deployment with sub-100 users, not a high-throughput AI gateway. The simpler design gives me a working failure mode and a live demo without adding premature state management.

If I built the circuit breaker next, I would probably store circuit state in KV with a short TTL, not a Durable Object. Circuit breaking is inherently approximate: you are making a temporary bet that a provider is unhealthy. That does not require the same exactness as a billing counter or rate limiter.

---

## What Cloudflare made easy

Cloudflare's primitives map cleanly to the two problems:

- **Durable Objects** for per-user coordination and serialized counters
- **Workers AI** for both the primary and fallback models
- **AI Gateway metadata** to distinguish normal calls from fallback calls
- **D1** for metrics and audit records
- **Workers** for the routing layer and debug header handling

The biggest lesson: the right primitive depends on the failure mode.

KV was the wrong primitive for an exact counter under concurrent writes. It is still the right primitive for long-term memory facts and other read-heavy data. Durable Objects were right for per-user coordination. A fallback model was right for model degradation. A circuit breaker is probably right later, but not before real failure data exists.

---

## What I'd change next

1. **Add a circuit breaker** once there is enough failure data to tune thresholds.
2. **Add provider fallback** beyond Workers AI: for example, Workers AI → Anthropic/OpenAI through AI Gateway → canned response.
3. **Add a dedicated fallback probe** to CI so the debug path is tested automatically.
4. **Expose fallback rates in the health scorecard** so `fallback` becomes a first-class reliability signal, not just a row in D1.

---

## The interview answer

If someone asks, "What happens when your model provider fails?" my answer is now concrete:

> "I built a three-tier fallback chain: primary 70B model, fallback 8B model, and a canned degraded response if both fail. There's a debug header that lets me skip the primary and demo degraded mode on demand. Metrics distinguish `success`, `fallback`, and `error`, so I can measure provider reliability instead of guessing. In the same week, I found and fixed a real concurrency bug in the rate limiter by moving the counter from KV to a Durable Object, then verified it with a live concurrency test."

That is the difference between a demo and a production system. A demo works when everything is healthy. A production system has a defined behavior when something is not.

---

**Sources:**

- [Cloudflare Durable Objects documentation](https://developers.cloudflare.com/durable-objects/)
- [Cloudflare Workers KV documentation](https://developers.cloudflare.com/kv/)
- [Cloudflare Workers AI model catalog](https://developers.cloudflare.com/workers-ai/models/)
- [Cloudflare AI Gateway documentation](https://developers.cloudflare.com/ai-gateway/)
- [Martin Fowler — Circuit Breaker](https://martinfowler.com/bliki/CircuitBreaker.html)
