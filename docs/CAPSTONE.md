# Capstone: AI-Accelerated Data SDLC / STLC

**Author:** Shamirna Antony, Lead Technical Consultant
**Submission track:** Option 04 — Case Study AI Challenge (open assessment, no
approval gate). Reframable as Option 01 if attached to a client engagement.
**Platform:** Snowflake only, plus n8n for orchestration as required by the brief.

---

## 1. The problem

Data engineering delivery has the same lifecycle as software delivery, but the
tooling for AI acceleration mostly assumes application code. The artifacts here
are different: a source-to-target mapping, a conformance transformation, a data
quality assertion, a synthetic dataset, a triaged pipeline failure.

The concrete scenario is one I have seen repeatedly. A finance team consolidates
accounts payable across several ERPs. An acquisition adds a fourth. Every source
encodes payment terms, approval status and cost centres differently. The rules
live in a PRD, a data contract, a coding standard, a pattern library, a test
taxonomy and a normalisation spec — six documents, none of which an LLM has ever
seen. Getting a new source onboarded is weeks of reading documents, writing
mappings, writing tests, and finding out in production which rule was missed.

**The question this capstone answers:** can AI agents do that work in a way that
is *verifiable* — where every generated artifact traces to the clause that
authorised it, where the tests are proven capable of failing, and where the agent
refuses work the documentation prohibits?

---

## 2. Scope decision: one platform

The brief allowed multiple platforms. I deliberately used one.

Everything runs inside Snowflake: generation (Cortex `COMPLETE`), retrieval
(Cortex Search), agents (stored procedures), the pipeline (Dynamic Tables),
artifact storage, the run log, the evaluation harness, and the dashboard
(Streamlit in Snowflake). There is no external orchestrator holding state, no
vector database, no separate application tier.

This is not minimalism for its own sake. It buys three things that matter in a
regulated data estate:

1. **The data never leaves.** Generation happens next to the data being described.
2. **Agents are database objects.** They are versionable, grantable, and callable
   over the SQL API. `GRANT USAGE ON PROCEDURE` is the entire access model.
3. **The audit trail is a table.** `METRICS.AGENT_RUN_LOG` holds the prompt, the
   retrieved citations, the model, the tokens, the cost, the latency and the
   outcome of every run — queryable with SQL, joinable to the artifacts.

### Where n8n fits, honestly

n8n is in the architecture because the brief asked for it. It would be dishonest
to pretend it was load-bearing without qualification.

Everything the workflows do can be done by the Snowflake Task DAG in
`sql/15_orchestration.sql`, and both call the same five stage procedures. n8n
genuinely earns its place on exactly two things:

- **The human approval gate.** A Wait node blocks the pipeline until a reviewer
  calls its resume URL. Generated code sits at `DRAFT` until then. Snowflake Tasks
  cannot wait for a person, so `T_SDLC_DEPLOY` auto-approves — which is precisely
  the compromise n8n removes.
- **Outbound notification and severity-based escalation.**

Both paths ship. Every run records which orchestrator invoked it. A team that does
not need a human gate or Slack alerts should use the Task DAG and run one fewer
runtime; that is a legitimate answer and the reason the DAG exists.

---

## 3. Architecture

```
GOVERNANCE                        AGENTS                      ARTIFACTS
  KNOWLEDGE_DOCS  ──chunk──▶ KNOWLEDGE_CHUNKS
                                   │
                              KB_SEARCH  (Cortex Search: hybrid lexical+semantic)
                                   │
                          RETRIEVE_MULTI (one query per fact needed)
                                   │
  TARGET_CONTRACT ─────────────────┼──▶ AGENT_REQ2STORY    ──▶ USER_STORIES
  REQUIREMENT_INTAKE ──────────────┼──▶ AGENT_SCAFFOLD     ──▶ GENERATED_CODE
  DEFECT_CATALOGUE ────────────────┼──▶ AGENT_TESTGEN      ──▶ TEST_CASES
  TRIAGE_GROUND_TRUTH ─────────────┼──▶ AGENT_SYNTHDATA    ──▶ SYNTH_BATCHES
                                   └──▶ AGENT_DEFECT_TRIAGE──▶ DEFECTS
                                   │
                          every run ▼
                          METRICS.AGENT_RUN_LOG  (prompt, citations, tokens, cost)

PIPELINE:  BRONZE_{SAP,ORACLE,BAAN}  ──▶ STG_* (views)
                                     ──▶ SILVER_AP_INVOICES  (DT, 60 min, INCREMENTAL)
                                     ──▶ GOLD_AP_INVOICE_REVIEW (DT, DOWNSTREAM)
```

### The six agents

| Agent | SDLC phase | Input | Output | Verification |
|---|---|---|---|---|
| `AGENT_REQ2STORY` | Requirements | Prose request | Cited user stories with source-to-target mappings | Citation validity; governance refusal; LLM judge |
| `AGENT_SCAFFOLD` | Build | Source system + contract | Snowflake SQL + derived dbt model | `EXPLAIN` compile check against the live account |
| `AGENT_TESTGEN` | QA | Contract + taxonomy | Executable assertions with declared failure modes | Compile check, then injected-defect validation |
| `AGENT_SYNTHDATA` | Test data | Schema + rules | Synthetic Bronze rows | PII collision scan; edge-case coverage assertion |
| `AGENT_DEFECT_TRIAGE` | Operations | Failure signal | Category, severity, root cause, remediation | Accuracy against a labelled ground-truth set |
| Dashboard + eval harness | Reporting | Run log + artifacts | Measured metrics with methods and caveats | — |

### Four design decisions that carry the weight

**Generated code is data first, files second.** Agents write into
`ARTIFACTS.GENERATED_CODE` with a status of `DRAFT → APPROVED → MATERIALIZED`.
`APPROVE_CODE` refuses to approve anything whose compile check failed;
`MATERIALIZE_STAGING` only reads `APPROVED` rows. The approval gate is enforced by
the data model, not by convention.

**Physical SQL is generated; dbt jinja is derived.** The agent emits plain SQL
against real table names, which is compile-checked with `EXPLAIN`. A deterministic
function then rewrites physical names into `source()` and `ref()` calls. Generating
jinja directly would have produced artifacts nothing could verify — dbt is not
installed in this environment, so a jinja model would have been unvalidated text.
This way the dbt file inherits a real compile guarantee.

**Retrieval is one query per fact, not one query per task.** The first scaffolding
run retrieved five chunks for one broad question and none of them was the
normalisation mapping table. The model then inferred a payment-terms mapping from
sample rows — which happened to be correct — and an approval-status mapping which
was wrong and would have written NULL into a `NOT NULL` contract column.
`RETRIEVE_MULTI` issues a targeted query per fact and merges the deduplicated
chunk set, taking retrieval from 5 chunks to 17. Recall was the bottleneck, not
the model.

**Every agent records its citations.** This is the governance property made
queryable. `METRICS.V_TRACEABILITY` joins any artifact to the chunk and document
that authorised it, and flags citations that do not resolve. 163 of 163 citations
resolve to a real chunk.

---

## 4. Evidence

Four evaluation families, ordered by how much they actually prove. The framework
document this capstone follows quotes figures like "60% faster" and "40% fewer
defects". None of those are reproduced here, because nothing in this build
measured them.

### 4.1 Injected-defect validation — strongest evidence

The test taxonomy states: *a test that cannot be made to fail by any injected
defect is a tautology and must be removed.* That rule is what makes generated
tests verifiable rather than decorative.

Seven defect classes are catalogued in `GOVERNANCE.DEFECT_CATALOGUE`, each with
the mutation SQL and the taxonomy category that should detect it. For each, the
harness resets a sandbox copy of Silver, injects the defect, runs the suite, and
records what fired. Silver is a Dynamic Table and cannot be mutated, so assertions
are re-pointed at `PIPELINE_TEST` by qualified-name substitution — which is why the
generator was required to fully qualify every table.

| Injected defect | Expected category | Caught | By expected category | Tests that fired |
|---|---|---|---|---|
| `NULL_REQUIRED_COLUMN` | NOT_NULL | yes | yes | 1 |
| `DUPLICATE_GRAIN_KEY` | UNIQUENESS | yes | yes | 2 |
| `UNPERMITTED_CURRENCY` | ACCEPTED_VALUES | yes | yes | 1 |
| `NON_POSITIVE_AMOUNT` | BOUNDARY | yes | yes | 1 |
| `DUE_DATE_BEFORE_INVOICE_DATE` | BOUNDARY | yes | yes | 1 |
| `SILENT_ROW_LOSS` | RECONCILIATION | yes | yes | 1 |
| `ORPHANED_SILVER_ROW` | REFERENTIAL | yes | yes | 2 |

**7/7 caught, 7/7 by the expected category.** The second column matters: a suite
that failed everything would score 7/7 on catching but would be worthless. One or
two tests firing per defect, not twenty, is the signal that the assertions are
specific.

`SILENT_ROW_LOSS` is the one to note. It reproduces the `UNION` instead of
`UNION ALL` defect that the PRD records as having silently dropped 4% of rows in a
previous release — the class of bug that passes every column-level check and is
only caught by reconciliation.

**What this does not prove:** coverage of failure modes nobody anticipated. Seven
classes drawn from a taxonomy is coverage of the known unknowns.

### 4.2 Governance controls — objective, binary

| Check | Result |
|---|---|
| Requirements agent refused the blocked source | pass |
| Zero stories written for it | pass |
| Build agent independently refused it | pass |
| Zero code artifacts generated for it | pass |
| Zero rows for it in the conformed layer | pass |

The blocked source is Workday: the PRD marks it MEDIUM priority and *"explicitly
blocked pending a signed Data Processing Agreement… Do not build Workday
transformations in this release."* `REQ-102` is a plausible service desk ticket
asking for exactly that.

The build agent is deliberately invoked for Workday in `STAGE_BUILD` rather than
skipped, so the refusal is recorded in the run log instead of hidden by control
flow. A skip proves nothing; a logged refusal with a quoted clause proves the
control fired.

**Caveat:** one blocked request in the corpus. This demonstrates the control
works; it does not establish a refusal rate.

### 4.3 Deterministic checks

| Metric | Result | Method |
|---|---|---|
| Citation validity | 163/163 | Every cited chunk id looked up in `KNOWLEDGE_CHUNKS` |
| Generated test compile rate | 28/28 | `EXPLAIN` against the live account |
| Clean-run pass rate | 27/27 applicable | Suite executed against the real conformed layer |

Citation validity detects fabricated references, not misreadings — it proves the
cited chunk exists, not that it supports the claim.

One test is excluded from the pass rate and the exclusion is recorded in the data:
`freshness_within_60_minutes` is correctly authored but cannot pass against a
static fixture dated 2025-06-01. It is marked `ENV_EXCEPTION` automatically
whenever the suite is regenerated, so the exclusion is reproducible rather than a
manual step someone forgets. Deleting it would have been the dishonest option.

`TYPE_VIOLATION` has no tests. That is correct rather than a gap: the Bronze
amount and date columns are already typed `NUMBER` and `DATE`, so there is no
text-to-typed parse that could silently produce NULLs.

### 4.4 Triage accuracy — labelled, but small

Failure signals from each injected defect are triaged **without telling the agent
which defect was injected**, and the predicted category and severity are compared
against `GOVERNANCE.TRIAGE_GROUND_TRUTH`, which was written before the agent ran.

| Metric | Before | After | Change |
|---|---|---|---|
| Category accuracy | 5/7 (71.4%) | 6/7 (85.7%) | +1 |
| Severity accuracy | 5/7 (71.4%) | 5/7 (71.4%) | — |
| Mean stated confidence | 0.921 | 0.929 | — |

The improvement came from defining the categories in the prompt. The initial
misses were not reasoning failures: the agent classified `NULL_REQUIRED_COLUMN` as
`LOGIC_ERROR` because an incomplete status mapping *is* a logic fault, while the
ground truth labels by symptom. The taxonomy was genuinely underspecified about
whether to classify by cause or symptom. Fixing the specification, not relabelling
the ground truth, is the honest correction — and it is recorded as a before/after
pair in `METRICS.TRIAGE_EVAL_HISTORY`.

**Two things to be candid about:**

- **n=7.** Each item is worth 14 percentage points. These are indicative numbers,
  not accuracy claims. I stopped after one principled iteration because further
  tuning against seven examples is overfitting, not improvement.
- **The agent is overconfident.** Mean stated confidence 0.93 against category
  accuracy 0.86 and severity accuracy 0.71. It escalates severity, twice rating
  `HIGH` conditions as `CRITICAL`. This is a direct argument for treating triage
  output as a starting point for a human, and the alert built by the n8n watchdog
  says so explicitly in its body text.

The residual category miss is `ORPHANED_SILVER_ROW`, predicted `LOGIC_ERROR`
instead of `REFERENTIAL`. Two checks fire for that defect — referential and
reconciliation — and the agent reasons from the reconciliation symptom. That is a
defensible reading of an ambiguous signal rather than a clear error.

Root-cause quality is better than the category score suggests. For the NULL defect
the agent identified unmapped Baan approval codes as the cause, cited the mapping
chunk, and recommended quarantining unmapped statuses per the documented rule —
which is the correct remediation.

### 4.5 Story quality — weakest evidence, and it found the most interesting bug

An LLM judge scores the backlog 1–5 on grounding, testability, absence of invented
values, and completeness. This is a model grading a model with no human
adjudication, and it is labelled as the weakest evidence in the harness.

| Dimension | Before | After |
|---|---|---|
| grounding | 4 | 4 |
| testability | 4 | 4 |
| no_invention | 3 | **5** |
| completeness | 3 | 3 |
| **mean** | **3.5** | **4.0** |

The judge flagged five invented values in the first backlog. Investigating them
found that **four were defects in my own governing corpus, not in the agent:**

1. **BR-006 demanded a high-value invoice flag that no data contract had a column
   for, and never said which layer it belonged to.** The agent resolved the
   contradiction by inventing `HIGH_VALUE_FLAG` on `SILVER_AP_INVOICES` — which
   would have breached the Silver conformance contract.
2. **BR-006 said "invoice-date spot rate" while BR-NORM-001 publishes rates frozen
   for the whole reporting year.** There is no per-date rate table. The document
   asked for something that does not exist.
3. **PRD BR-007 stated Baan uses single-character approval codes**, which
   BR-NORM-001 explicitly contradicts — those belong to Baan 4.6, not the 4.7c
   extracts being received.

Fixing the documents took `no_invention` from 3 to 5 and eliminated all five
invented values. BR-006 now states the flag lives in Gold and that Silver is not
extended with derived reporting attributes; `sql/17_gold_layer.sql` implements
that decision as `GOLD_AP_INVOICE_REVIEW`.

**This is the most useful finding in the whole build.** Grounded generation
faithfully propagates documentation defects. RAG does not make an agent correct —
it makes the agent as correct as the corpus. Which means the corpus needs
evaluating, and an eval harness that only scores the model will never find these.

`completeness` stayed at 3. The judge notes some rules get thinner acceptance
criteria than others. I added an explicit completeness instruction to the prompt,
which changed the backlog shape — 17 more granular stories instead of 6 broad
ones — without moving the score. That is an honest negative result.

### 4.6 A separate finding worth recording

The very first scaffolding run exposed a conflict between the governing documents
and the actual data. BR-NORM-001 as I originally wrote it listed Baan payment
terms as `T30`/`T45`/`T60` and approval codes as single characters. The real
extract contains `N30`/`N60` and `POSTED`/`APPROVED`/`PENDING`.

The agent followed the data over the document and invented `N30 → NET30`. It was
right by luck — and it silently violated the instruction to use only documented
mappings, which is the same failure mode BR-005 warns about in a different guise.

I corrected the documents to describe the real system, because a knowledge base
that disagrees with reality is worse than none. But the lesson stands: an agent
given a document that contradicts the data will quietly pick one, and you will not
know which unless you check.

---

## 5. Cost

| Agent | Runs | Tokens | Est. USD |
|---|---|---|---|
| `AGENT_DEFECT_TRIAGE` | 7 | 40,422 | 0.206 |
| `AGENT_REQ2STORY` | 7 | 34,853 | 0.178 |
| `AGENT_SCAFFOLD` | 4 | 28,529 | 0.146 |
| `AGENT_TESTGEN` | 1 | 10,659 | 0.054 |
| `AGENT_SYNTHDATA` | 1 | 9,476 | 0.048 |
| **Total** | **20** | **123,939** | **~0.63** |

These are **estimates** derived from token counts and the rates in
`GOVERNANCE.PLATFORM_CONFIG`, not billed figures, and they are labelled as
estimates everywhere they surface. Warehouse compute for the Dynamic Tables, the
Cortex Search index and the test runs is not included. Reconcile against
`ACCOUNT_USAGE` before quoting them.

The useful observation is not the absolute number. It is that per-run cost
attribution exists at all: `V_COST_ATTRIBUTION` breaks spend down by SDLC phase,
agent and orchestrator, which is what makes "is this agent worth running on every
commit?" an answerable question rather than a debate.

---

## 6. What I deliberately did not claim

**No productivity uplift figure.** There was no human control arm. To claim "40%
faster" I would need the same six requirements implemented by an engineer under
comparable conditions, with time recorded. I did not run that experiment, so I
have no such number, and inventing one would undermine everything else in this
document.

What can be said precisely: 20 agent runs produced 17 user stories, 6 code
artifacts, 28 executable tests, a validated synthetic dataset and 7 triaged
defects, for roughly 123,939 tokens and about $0.63 of estimated model spend, with
every artifact traceable to a governing clause. Whether that is faster than a
human is a question this build did not measure.

**No defect-reduction figure.** The suite catches 7/7 injected defects. That is a
statement about anticipated failure modes in a controlled harness, not a
prediction of production defect rates.

---

## 7. Limitations

- **Corpus scale.** Six documents, 23 chunks, one 50-row domain. Retrieval quality
  on a corpus of thousands of documents is a different problem, and multi-query
  retrieval would need a reranking budget.
- **Eval set size.** n=7 for triage, n=7 for mutation, one blocked request. Enough
  to demonstrate mechanisms, not enough for confident rates.
- **`dbt build` was never executed.** dbt is not installed here. Generated SQL is
  verified by `EXPLAIN` and by materialising it in Snowflake, which is stronger
  than a dbt parse, but the dbt project itself has not been run.
- **The n8n leg was not executed end to end.** The workflow JSON is valid and the
  SQL API request shape is verified correct — endpoint, headers, body and callable
  procedures. The final authenticated call requires attaching a network policy to
  the account, which is a security change that belongs to whoever owns the account.
  `n8n/verify_sql_api.ps1` closes that gap in about a minute.
- **`AGENT_EVAL_SET` was not usable as intended.** The workshop dataset in
  `COCO_WORKSHOP` is a text-to-SQL eval set (question, expected SQL, expected
  grain), not a requirements-to-stories set. Rather than pretend it fit, I built
  purpose-specific labelled sets — `DEFECT_CATALOGUE` and `TRIAGE_GROUND_TRUTH` —
  and left the workshop set unused.
- **Single-model.** Everything runs on `claude-sonnet-4-5` at temperature 0.
  `claude-3-5-sonnet` is not available on this account and `claude-4-sonnet` is in
  legacy state. No cross-model comparison was run, and the judge is the same model
  family as the generator, which is a known weakness of LLM-as-judge.

## 8. Extension points, not built

Named because they are the obvious next questions, and it is better to scope them
out explicitly than to imply coverage:

- **Playwright / UI testing.** Out of scope; this is a data pipeline with no UI
  beyond the dashboard.
- **Jira / Azure DevOps integration.** `ARTIFACTS.USER_STORIES` is shaped to map
  onto a work item, but no connector was built.
- **GitHub PR automation.** The dbt project is exported to a stage and pulled to a
  working copy; committing and opening a PR is left to normal CI.
- **Schema drift detection.** The triage agent has a `SCHEMA_DRIFT` category but
  nothing generates that signal yet. A `TARGET_CONTRACT`-versus-`INFORMATION_SCHEMA`
  comparison would feed it.
- **Cross-source duplicate enforcement.** The PRD says monitor but do not enforce,
  so a monitoring check was generated and enforcement was not.

---

## 9. What I would tell a client

Three things transferred from this build:

1. **Ground the agents in the project's own documents, and evaluate the documents
   too.** The single highest-value finding here was that the corpus contradicted
   itself in three places, and the agent's "hallucinations" were faithful
   renderings of those contradictions. An accelerator that only evaluates the
   model will ship those straight into production.

2. **Make the tests prove they can fail.** Generated tests that compile and pass
   look like coverage and can be worth nothing. Injecting the defect classes you
   care about and confirming the right test fires is cheap, objective, and the only
   evidence I would present to a QA lead.

3. **Keep the approval gate in the data model.** `DRAFT → APPROVED → MATERIALIZED`
   with a compile-status precondition means the gate cannot be bypassed by someone
   in a hurry. A gate that lives only in a workflow diagram is not a gate.

And one caution: the agents here are confidently wrong often enough to matter. The
triage agent states 0.93 confidence while being 0.86 accurate on category and 0.71
on severity. Ship this as a tool that drafts and evidences, with a human deciding
— not as a tool that decides.
