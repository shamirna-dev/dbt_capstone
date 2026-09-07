# AI-Accelerated Data SDLC / STLC on Snowflake

An AI-augmented delivery pipeline for data engineering work, built entirely on
Snowflake. Six agents take a business request in prose through to a governed,
tested, incrementally-refreshing medallion pipeline — with a human approval gate
before anything is materialised, and a citation trail from every generated
artifact back to the document clause that authorised it.

**Domain:** consolidating accounts-payable invoices from four ERP systems (SAP,
Oracle EBS, Infor Baan IV, Workday Financials) into a conformed reporting layer.

---

## Deploy order

Requires a Snowflake account with Cortex enabled, `ACCOUNTADMIN`, and a warehouse
named `COMPUTE_WH`. Replace the connection name with your own.

```powershell
$c = "igtstwc-td17035"

snow sql -c $c -f sql\01_foundation.sql        # database, schemas, run log, domain seed
snow sql -c $c -f sql\02_knowledge_layer.sql   # KB tables, chunker, retrieval
snow sql -c $c -f sql\03_knowledge_seed.sql    # the six governing documents
snow sql -c $c -f sql\04_search_service.sql    # chunk + build Cortex Search index
snow sql -c $c -f sql\05_agent_framework.sql   # LLM entry point, run logger, intake
snow sql -c $c -f sql\06_agent_req2story.sql   # agent 1: requirements
snow sql -c $c -f sql\07_agent_scaffold.sql    # agent 2: ETL scaffolding
snow sql -c $c -f sql\08_retrieve_multi.sql    # multi-query retrieval
snow sql -c $c -f sql\09_materialize.sql       # approval gate, deploy, Silver DT
snow sql -c $c -f sql\10_agent_testgen.sql     # agent 3: test generation
snow sql -c $c -f sql\11_defect_injection.sql  # suite validation harness
snow sql -c $c -f sql\12_dbt_export.sql        # export dbt project to a stage
snow sql -c $c -f sql\13_agent_synthdata.sql   # agent 4: synthetic test data
snow sql -c $c -f sql\14_agent_defect_triage.sql # agent 5: defect triage + labels
snow sql -c $c -f sql\15_orchestration.sql     # stage procedures + Snowflake Task DAG
snow sql -c $c -f sql\16_eval_harness.sql      # evaluation harness
snow sql -c $c -f sql\17_gold_layer.sql        # Gold review layer (BR-006)
snow sql -c $c -f sql\18_metrics_views.sql     # dashboard views
```

Note `07` must run before `08` only in the sense that both must exist before the
build stage is called; `08` redefines the retrieval strategy that `07` uses.

### Run it end to end

```sql
CALL CAPSTONE_AI_DLC.AGENTS.STAGE_REQUIREMENTS('REQ-101','MANUAL');
CALL CAPSTONE_AI_DLC.AGENTS.STAGE_REQUIREMENTS('REQ-102','MANUAL');  -- expect refusal
CALL CAPSTONE_AI_DLC.AGENTS.STAGE_REQUIREMENTS('REQ-103','MANUAL');
CALL CAPSTONE_AI_DLC.AGENTS.STAGE_BUILD('MANUAL');
-- human reviews ARTIFACTS.GENERATED_CODE here
CALL CAPSTONE_AI_DLC.AGENTS.STAGE_DEPLOY('your.name','60 minutes');
CALL CAPSTONE_AI_DLC.AGENTS.STAGE_QA('MANUAL', TRUE);
CALL CAPSTONE_AI_DLC.AGENTS.VALIDATE_TEST_SUITE();        -- injected-defect validation
CALL CAPSTONE_AI_DLC.AGENTS.TRIAGE_MUTATION_FAILURES();   -- labelled triage eval
CALL CAPSTONE_AI_DLC.AGENTS.AGENT_SYNTHDATA(16,'MANUAL');
CALL CAPSTONE_AI_DLC.AGENTS.EVAL_ALL();
```

### Dashboard

```powershell
cd app; snow streamlit deploy --replace -c $c
```

### Orchestration

- **n8n** (primary): see [`n8n/README.md`](n8n/README.md). Two importable
  workflows. Owns the human approval gate and notifications.
- **Snowflake Tasks** (equivalent): `T_SDLC_BUILD → T_SDLC_DEPLOY → T_SDLC_QA →
  T_SDLC_TRIAGE`, created suspended. Same stage procedures, no second runtime.

---

## What is where

| Path | Contents |
|---|---|
| `sql/` | All 18 deployment scripts, in run order |
| `dbt_project/` | Generated dbt project: 3 AI-generated staging models, Silver DT, schema tests |
| `n8n/` | Two workflow JSONs, setup guide, SQL API verification script |
| `app/` | Streamlit dashboard |
| `docs/CAPSTONE.md` | The write-up: architecture, evidence, findings, limitations |

---

## Headline results

All measured on this account. Methods and caveats travel with each number in
`METRICS.V_EVAL_SUMMARY` and on the dashboard's Evidence tab.

| Metric | Result | Evidence strength |
|---|---|---|
| Injected defects caught by generated tests | 7 / 7 | Objective |
| Caught by the *expected* taxonomy category | 7 / 7 | Objective |
| Governance controls upheld | 5 / 5 | Objective |
| Citation validity (cited chunk ids that exist) | 163 / 163 | Objective |
| Generated tests that compile | 28 / 28 | Objective |
| Triage category accuracy | 6 / 7 (85.7%) | n=7, indicative |
| Triage severity accuracy | 5 / 7 (71.4%) | n=7, indicative |
| Story quality (LLM judge, mean of 4 dimensions) | 4.0 / 5 | Weakest |
| Total LLM cost for the full run | ~$0.63 estimated | 123,939 tokens |

**No productivity or defect-reduction percentage is reported.** This build had no
human-baseline control arm, so any such figure would be invented. See
[`docs/CAPSTONE.md`](docs/CAPSTONE.md) for why that matters.

---

## The one thing worth looking at first

Ask the platform to do something the governing documents prohibit:

```sql
CALL CAPSTONE_AI_DLC.AGENTS.STAGE_REQUIREMENTS('REQ-102','MANUAL');
```

`REQ-102` is a reasonable-sounding service desk ticket asking to add Workday
invoices to the consolidated table. The PRD blocks Workday pending a signed Data
Processing Agreement. The agent returns zero stories and quotes the clause. The
build agent refuses it independently. No Workday code exists, and no Workday row
reaches the conformed layer.

An ungrounded model writes that backlog happily. That gap is the point of the RAG
layer.
