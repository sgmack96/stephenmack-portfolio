---
title: "How I Built a CI Gate for My AI Agent (And It Caught a Real Bug on Day One)"
description: "How I added a deterministic faithfulness check and LLM-as-judge eval pipeline to SE Intel — blocking deploys on quality drops and catching a real flaky bug on the first run."
date: "2026-06-25"
tags: ["cloudflare", "workers-ai", "evals", "ci", "faithfulness", "llm-as-judge", "ai-engineering", "se-intel"]
---

**Live:** https://se-intel-portfolio.stephenmack96.workers.dev  
**Stack:** Workers · Durable Objects · Workers AI · Vectorize · Python eval harness  
**Code:** Available on request

---

Shipping an AI agent without an evaluation harness is guesswork. You make a prompt change, the responses feel better, you deploy. Maybe they are better. Maybe you just shifted one failure mode for another. You won't know until a user tells you something is wrong — or worse, doesn't tell you and just stops using it.

Week 1 of this project was multi-tenant isolation. Week 2 was the harder problem: how do you know the agent's answers are actually good, and how do you make that measurement reliable enough to block a deploy?

This post explains how I built an eval CI gate for SE Intel — what shipped, what broke on day one, and what I learned about the difference between "groundedness" and "faithfulness."

---

## The gap that triggered this

In Week 1, the eval harness already scored "groundedness" as one of four LLM-as-judge dimensions. The judge looked at the response and asked: does this cite real products and prices, or does it hallucinate?

The problem: the judge was looking at the output in isolation. It didn't know what the retrieval system had actually returned.

I found this on Day 2 of Week 1 when the `acme` org's knowledge base had a chunk stating "35% discount for multi-year contracts." The agent answered "25%." The judge scored groundedness as 2/3 — good, because the response mentioned discounts and sounded credible. It missed the bug entirely.

This distinction matters:

- **Groundedness** — does the response cite real things? (The judge can evaluate this without knowing what was retrieved.)
- **Faithfulness** — did the response use the specific facts that were retrieved? (The judge cannot evaluate this without seeing the retrieved chunks.)

You can pass groundedness and fail faithfulness at the same time. A response can confidently cite real product names and still ignore the exact chunk the retrieval system injected. That's what happened. The judge didn't miss this because it was a bad judge. It missed it because it didn't have the information to catch it.

---

## Architecture decision: two layers, not one

The fix required two things:

**First**, the API had to expose retrieved chunks. I added `?debug=true` to the `/api/v1/account` and `/api/v1/enablement` endpoints. In debug mode, the response includes a `retrievedChunks` array — exactly the chunks that were retrieved and injected into the system prompt, nothing more. In production mode, the field is absent entirely. The debug mode threads through `index.ts → base-agent.ts → dispatchTools → kbSearch` — one flag, single source of truth, no duplicate Vectorize query.

**Second**, the harness needed a layer that could compare retrieval against the response without involving an LLM. Here's why that matters: if you use an LLM to check whether the LLM used its retrieved facts, the checker is susceptible to the same failure mode it's supposed to catch. A hallucinating model can hallucinate in a way that sounds grounded. The oracle needs to be deterministic.

The architecture I landed on:

```
run_eval.sh --ci
    │
    ├─ Step 1: runner.py      → calls live API with ?debug=true, captures retrieved_chunks
    ├─ Step 2: faithfulness.py → deterministic string check, exits 1 on failure (CI gate)
    ├─ Step 3: judge.py        → LLM-as-judge, 5 dimensions, trend signal
    └─ Step 4: report.py       → diff vs previous run, regression detection
```

The gate runs faithfulness before the judge. If the deterministic check fails, the pipeline stops. The judge doesn't run. The deploy doesn't happen.

---

## faithfulness.py — the deterministic check

The script takes a results file from the runner, checks each case against its expected facts, and exits 1 if any grounding or hallucination failures are found.

Two kinds of facts per test case:

```json
{
  "id": "fth-001",
  "agent": "enablement",
  "role": "se",
  "input": "What's the discount structure for multi-year contracts?",
  "org_id": "acme",
  "expected_facts": {
    "grounded": ["35%"],
    "forbidden": []
  }
}
```

**Grounded facts** must be both retrieved AND in the response. The check distinguishes two failure modes:
- `grounding_fail` — the fact was retrieved but the model dropped it. This is the bug. This blocks CI.
- `retrieval_fail` — the fact was never retrieved. This is a retrieval problem, not a generation problem. Reported but not blocking — you'd fix the KB or the embedding, not the prompt.

**Forbidden facts** must not appear in the response unless they were retrieved. This catches hallucination and, critically, cross-org leakage.

The logic is pure string matching:

```python
def check_grounded(fact: str, retrieved_chunks: list, response: str) -> dict:
    in_retrieved = any(fact.lower() in chunk["content"].lower() 
                       for chunk in retrieved_chunks)
    in_response = fact.lower() in response.lower()
    
    if in_retrieved and not in_response:
        return {"status": "grounding_fail", "fact": fact}  # blocks CI
    elif not in_retrieved and not in_response:
        return {"status": "retrieval_fail", "fact": fact}  # reported, not blocking
    else:
        return {"status": "pass", "fact": fact}
```

No LLM. No judgment call. Either the string is there or it isn't.

---

## The bug it caught on day one

`fth-003` tested the WinterCG lock-in objection. The expected grounded fact was "WinterCG" — the enablement KB has a chunk explaining that Workers runs on the WinterCG standard, which means code is portable off Cloudflare if needed. This is a real sales objection handler.

First run of the CI gate: `fth-003` failed. `grounding_fail` — WinterCG was in the retrieved chunk, not in the response.

I re-ran it immediately. Pass.

A flaky gate is worse than no gate. If it randomly fails on passing cases, the team starts ignoring the failures. I ran it five more times: 3 fails, 2 passes on identical input. This wasn't a bad test case — it was LLM non-determinism. The model was handed the WinterCG chunk and decided to paraphrase its way around the specific term about half the time. "Runs on open web standards" instead of "built on WinterCG." Close enough for a human reader. Not close enough for the deterministic check.

I considered loosening the test — checking for "web standards" instead of "WinterCG." I didn't.

The right fix is to make the model reliable, not to make the test less strict. I added a grounding rule to the enablement system prompt:

```
GROUNDING RULE: When the knowledge base contains a specific named standard, 
certification, figure, or product name, cite it verbatim. Do not paraphrase 
a named standard into a generic concept. Do not alter a number.
```

Re-ran 3 times: 3/3 pass. Stable. The rule works because it's not asking the model to be creative — it's telling it to transcribe specific nouns exactly. That's a much simpler task.

Same lesson as Week 1: the LLM is not a reliable test oracle. You can't use the model to verify the model. The gate has to be deterministic, and when the gate fails, you fix the behavior, not the gate.

---

## The cross-org faithfulness case

`fth-005` is the case that ties Week 1 isolation to Week 2 faithfulness.

The `acme` org has a chunk stating their negotiated 35% discount. The `portfolio-org` org does not have this chunk. The test runs as `portfolio-org` and lists "35%" as a forbidden fact:

```json
{
  "id": "fth-005",
  "input": "What discount can I offer for a multi-year deal?",
  "org_id": "portfolio-org",
  "expected_facts": {
    "grounded": [],
    "forbidden": ["35%"]
  }
}
```

If "35%" appears in the response for `portfolio-org`, it's either a cross-org retrieval leak (Week 1 failure) or a hallucination (Week 2 failure). Either way, `hallucination_fail`, CI exits 1.

Week 1 proved the retrieval layer is isolated — the Vectorize `orgId` metadata filter means `portfolio-org`'s queries never see `acme`'s chunks. `fth-005` extends that proof to the generation layer: even if the retrieval is correct, the model doesn't fabricate the forbidden number from memory. 5/5 runs: "35%" never appeared. Both layers hold.

---

## judge.py — the 5th dimension

The LLM judge now scores 5 dimensions instead of 4. The new one is faithfulness:

```python
prompt = f"""
=== RETRIEVED CHUNKS (what the knowledge base returned) ===
{format_chunks(retrieved_chunks)}

=== ACTUAL RESPONSE ===
{response}

Score these 5 dimensions (0-3 each):
1. GROUNDEDNESS: Does it cite real products/prices from the KB?
2. RELEVANCE: Does it answer what was actually asked?
3. ROLE_APPROPRIATENESS: Is the depth right for {role}?
4. ACTIONABILITY: Can a rep use this in a call today?
5. FAITHFULNESS: Does it use the specific facts from the retrieved chunks,
   or does it paraphrase, drop, or contradict them?

Return ONLY valid JSON: {{"groundedness": 2, ..., "faithfulness": 2, 
"total": 12, "passed": true, "reasoning": "..."}}
"""
```

Scale is now 15 points (5 × 3), pass threshold is 10/15. The judge sees the retrieved chunks — it can now penalize a response that scores 3 on groundedness (sounds factual) but 1 on faithfulness (ignored the retrieved chunk).

The judge provides the trend signal. The deterministic check provides the gate. They measure different things.

---

## The CI gate in action

```bash
$ ./run_eval.sh --ci

[1/4] Running test cases...
  15 cases completed. Results: eval/results/run_2026-06-22T14:23:11.json

[2/4] Faithfulness check (CI gate)...
  fth-001: PASS (35% grounded)
  fth-002: PASS (5ms, v8 isolate grounded)
  fth-003: PASS (WinterCG grounded)
  fth-004: PASS (SOC 2 Type II, ISO 27001 grounded)
  fth-005: PASS (forbidden 35% not present for portfolio-org)
  Gate: 5/5 pass. 0 grounding_fails. 0 hallucination_fails.

[3/4] Running judge...
  13/15 cases passed. Overall: 87%. Faithfulness avg: 2.4/3.

[4/4] Report...
  vs previous run: +0% overall (stable). No regressions.

Exit code: 0
```

Before the prompt fix, step 2 printed:

```
fth-003: FAIL — grounding_fail
  Fact "WinterCG" was retrieved but not in response.
Exit code: 1
```

The deploy would have been blocked.

---

## What I'd change

**Wire it to GitHub Actions.** `run_eval.sh --ci` exists and exits 1 correctly. It's not yet in a CI pipeline — I run it manually before deploying. Adding it to a GitHub Actions workflow on push to main is a one-hour task. That's the next step.

**Use a different model as judge.** The agent runs on Llama 3.3 70B. The judge also runs on Llama 3.3 70B. This is a known problem: the judge is biased toward output in a style it recognizes as natural — its own. Scores are systematically optimistic. The fix is using Claude via the Anthropic API as the judge. Different training data, different style priors, more honest scores. I didn't do this to keep the eval harness free (Workers AI, no additional cost). For anything beyond a portfolio, this is the right call.

**Add rubric synthesis.** The 15 hand-written rubrics are the current ceiling. The eval pyramid has three layers: deterministic checks at the bottom (infinite scale), LLM-synthesized rubrics in the middle, human review at the top. You give it a test input, it writes the rubric, a human spot-checks 10-20%. That's how you get to 500 cases without 500 hours of work.

**Add latency to the report.** The runner captures response latency but `report.py` doesn't surface it. If a prompt change improves quality scores but doubles p95 latency, that's a regression. The report should show both.

---

## What the Cloudflare platform made possible

**The eval harness is free.** Running 15 LLM judge calls per eval run against a third-party API would cost real money at scale. On Workers AI, it's included in the paid plan. That changes the economics: you run the eval on every prompt change instead of rationing it. When evals are free, you actually run them.

**The debug endpoint is zero latency overhead in production.** `?debug=true` is a query param check — if it's absent, the `capturedChunks` array is never allocated and nothing is captured. The production response is identical to what it was before. No performance cost for a feature that only runs in the eval harness.

**The gate runs against the live deployed endpoint, not a mock.** The runner calls `https://se-intel-portfolio.stephenmack96.workers.dev` — the actual production URL. This means the eval harness tests the real system: real Vectorize queries, real Workers AI inference, real DO state. Not a local server, not a stub. If the test passes, the deployed system passes.

---

## The architecture at a glance

```
run_eval.sh --ci
    │
    ├─ runner.py
    │    ├─ Loads cases/*.json
    │    ├─ Gets JWT per role (POST /dev/token)
    │    ├─ Calls live API with ?debug=true
    │    └─ Writes eval/results/run_{timestamp}.json
    │         (includes retrieved_chunks per case)
    │
    ├─ faithfulness.py  ← CI gate
    │    ├─ For each case: checks grounded facts (retrieved + in response)
    │    ├─ Checks forbidden facts (not in response unless retrieved)
    │    ├─ grounding_fail or hallucination_fail → exit 1
    │    └─ All pass → exit 0, pipeline continues
    │
    ├─ judge.py
    │    ├─ Builds scoring prompt with retrieved chunks visible
    │    ├─ Calls Workers AI Llama 3.3 70B as judge
    │    ├─ Scores 5 dimensions (0-3 each, 15pt scale, threshold 10)
    │    └─ Writes scores back into results file
    │
    └─ report.py
         ├─ Aggregates pass rate, per-dimension averages
         ├─ Diffs against previous run (regression detection)
         └─ Prints per-case bars with faithfulness column
```

Total infrastructure cost: **$0** (Workers AI judge calls within paid plan quota).

---

## The interview answer

**Q: "How do you measure LLM quality?"**

Two layers. A deterministic check (`faithfulness.py`) proves whether specific facts from the knowledge base appear in the response — no LLM involved, exits 1 on failure, blocks the deploy. An LLM-as-judge (`judge.py`) scores five semantic dimensions on a rubric — groundedness, relevance, role-appropriateness, actionability, faithfulness — and produces a trend signal across runs. The gate catches objective failures; the judge catches quality drift. Score progression across three prompt iterations: 67% → 73% → 87%. The deterministic gate caught a real flaky bug on day one that the judge had been missing for weeks.

---

*Built by a Cloudflare Solutions Engineer proving that AI systems need the same engineering discipline as any other production software.*
