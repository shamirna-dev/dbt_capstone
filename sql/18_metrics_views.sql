-- =====================================================================
-- 18_metrics_views.sql -- what the dashboard reads
--
-- Every view here reports something that was actually measured on this
-- account. There is no view that computes a productivity uplift, because
-- nothing in this build measured one: there is no human-baseline control
-- arm, so any such figure would be invented. What is reported instead is
-- throughput, cost, correctness against labelled sets, and the governance
-- controls firing.
-- =====================================================================

USE DATABASE CAPSTONE_AI_DLC;
USE SCHEMA METRICS;

-- ---------------------------------------------------------------------
-- Per-agent execution profile. REJECTED is separated from FAILED: a
-- governance refusal is a correct outcome and must not be counted as an
-- error, or the platform looks unreliable when it is behaving properly.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW V_AGENT_PERFORMANCE AS
SELECT
    AGENT_NAME,
    SDLC_PHASE,
    COUNT(*)                                   AS RUNS,
    COUNT_IF(STATUS = 'SUCCESS')               AS SUCCEEDED,
    COUNT_IF(STATUS = 'REJECTED')              AS REFUSED_ON_GOVERNANCE,
    COUNT_IF(STATUS = 'FAILED')                AS FAILED,
    ROUND(COUNT_IF(STATUS = 'SUCCESS')
          / NULLIF(COUNT_IF(STATUS <> 'REJECTED'), 0), 4) AS SUCCESS_RATE_EXCL_REFUSALS,
    SUM(TOTAL_TOKENS)                          AS TOTAL_TOKENS,
    ROUND(AVG(TOTAL_TOKENS))                   AS AVG_TOKENS,
    ROUND(SUM(EST_USD), 4)                     AS EST_USD_TOTAL,
    ROUND(AVG(LATENCY_MS) / 1000.0, 1)         AS AVG_SECONDS,
    ROUND(MAX(LATENCY_MS) / 1000.0, 1)         AS MAX_SECONDS
FROM AGENT_RUN_LOG
GROUP BY 1, 2;

-- ---------------------------------------------------------------------
-- Artifact throughput by SDLC phase. Counts what exists, not what it saved.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW V_SDLC_THROUGHPUT AS
SELECT 'REQUIREMENTS' AS PHASE, 'user stories'          AS ARTIFACT,
       COUNT(*)::NUMBER AS PRODUCED,
       COUNT_IF(STATUS = 'DRAFT')::NUMBER AS AWAITING_REVIEW
FROM CAPSTONE_AI_DLC.ARTIFACTS.USER_STORIES
UNION ALL
SELECT 'BUILD', 'staging models + dbt files',
       COUNT(*), COUNT_IF(STATUS = 'DRAFT')
FROM CAPSTONE_AI_DLC.ARTIFACTS.GENERATED_CODE
UNION ALL
SELECT 'QA', 'data quality tests',
       COUNT(*), COUNT_IF(STATUS = 'DRAFT')
FROM CAPSTONE_AI_DLC.ARTIFACTS.TEST_CASES
UNION ALL
SELECT 'TEST_DATA', 'synthetic batches',
       COUNT(*), 0
FROM CAPSTONE_AI_DLC.ARTIFACTS.SYNTH_BATCHES
UNION ALL
SELECT 'OPERATIONS', 'triaged defects',
       COUNT(*), COUNT_IF(STATUS = 'OPEN')
FROM CAPSTONE_AI_DLC.ARTIFACTS.DEFECTS;

-- ---------------------------------------------------------------------
-- Evaluation results with their method and caveat attached. The caveat
-- travels with the number on purpose - a metric shown without how it was
-- measured is how the marketing figures in the source framework came about.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW V_EVAL_SUMMARY AS
SELECT
    EVAL_FAMILY,
    METRIC_NAME,
    METRIC_VALUE,
    NUMERATOR,
    DENOMINATOR,
    CASE EVAL_FAMILY
        WHEN 'MUTATION'      THEN 'Objective - injected defects'
        WHEN 'GOVERNANCE'    THEN 'Objective - binary control check'
        WHEN 'CITATION'      THEN 'Objective - deterministic lookup'
        WHEN 'TESTGEN'       THEN 'Objective - compiler'
        WHEN 'TRIAGE'        THEN 'Labelled set, n=7 - indicative only'
        WHEN 'STORY_QUALITY' THEN 'LLM-as-judge - weakest evidence'
        ELSE 'unclassified'
    END AS EVIDENCE_STRENGTH,
    METHOD,
    CAVEAT,
    MEASURED_AT
FROM EVAL_RESULTS;

-- ---------------------------------------------------------------------
-- Test suite coverage and the clean-run result. ENV_EXCEPTION tests are
-- shown but excluded from the pass rate, with the reason visible.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW V_TEST_COVERAGE AS
WITH latest AS (
    SELECT TEST_ID, OUTCOME, FAIL_ROW_COUNT,
           ROW_NUMBER() OVER (PARTITION BY TEST_ID ORDER BY EXECUTED_AT DESC) AS rn
    FROM CAPSTONE_AI_DLC.ARTIFACTS.TEST_RESULTS
    WHERE DATASET_LABEL = 'CLEAN'
)
SELECT
    t.TEST_CATEGORY,
    t.SEVERITY,
    COUNT(*)                                        AS TESTS,
    COUNT_IF(t.COMPILE_STATUS = 'PASS')             AS COMPILED,
    COUNT_IF(t.STATUS = 'ENV_EXCEPTION')            AS ENV_EXCEPTIONS,
    COUNT_IF(l.OUTCOME = 'PASS')                    AS PASSED_CLEAN,
    COUNT_IF(l.OUTCOME = 'FAIL')                    AS FAILED_CLEAN,
    COUNT_IF(l.OUTCOME = 'ERROR')                   AS ERRORED_CLEAN
FROM CAPSTONE_AI_DLC.ARTIFACTS.TEST_CASES t
LEFT JOIN latest l ON l.TEST_ID = t.TEST_ID AND l.rn = 1
GROUP BY 1, 2;

-- ---------------------------------------------------------------------
-- Injected-defect detection detail. This is the strongest evidence in the
-- build, so it gets its own view rather than being rolled into a number.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW V_MUTATION_DETAIL AS
SELECT
    m.DEFECT_NAME,
    c.DESCRIPTION                     AS DEFECT_DESCRIPTION,
    m.EXPECTED_CATEGORY,
    m.CAUGHT,
    m.CAUGHT_BY_EXPECTED_CATEGORY,
    m.TOTAL_FAILING                   AS TESTS_THAT_FIRED,
    ARRAY_TO_STRING(m.CAUGHT_BY, ', ') AS CAUGHT_BY_TESTS,
    t.TRUE_CATEGORY                   AS TRIAGE_TRUE_CATEGORY,
    e.PREDICTED_CATEGORY              AS TRIAGE_PREDICTED_CATEGORY,
    e.CATEGORY_CORRECT                AS TRIAGE_CATEGORY_CORRECT,
    e.PREDICTED_SEVERITY              AS TRIAGE_PREDICTED_SEVERITY,
    e.SEVERITY_CORRECT                AS TRIAGE_SEVERITY_CORRECT,
    e.CONFIDENCE                      AS TRIAGE_STATED_CONFIDENCE
FROM MUTATION_RESULTS m
LEFT JOIN CAPSTONE_AI_DLC.GOVERNANCE.DEFECT_CATALOGUE c    ON c.DEFECT_NAME = m.DEFECT_NAME
LEFT JOIN CAPSTONE_AI_DLC.GOVERNANCE.TRIAGE_GROUND_TRUTH t ON t.DEFECT_NAME = m.DEFECT_NAME
LEFT JOIN TRIAGE_EVAL e                                    ON e.DEFECT_NAME = m.DEFECT_NAME;

-- ---------------------------------------------------------------------
-- Cost attribution. Estimated from token counts and the configured rates,
-- and labelled as an estimate everywhere it appears.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW V_COST_ATTRIBUTION AS
SELECT
    SDLC_PHASE,
    AGENT_NAME,
    ORCHESTRATOR,
    COUNT(*)                     AS RUNS,
    SUM(PROMPT_TOKENS)           AS PROMPT_TOKENS,
    SUM(COMPLETION_TOKENS)       AS COMPLETION_TOKENS,
    SUM(TOTAL_TOKENS)            AS TOTAL_TOKENS,
    ROUND(SUM(EST_CREDITS), 5)   AS EST_CREDITS,
    ROUND(SUM(EST_USD), 4)       AS EST_USD
FROM AGENT_RUN_LOG
GROUP BY 1, 2, 3;

-- ---------------------------------------------------------------------
-- Full traceability: artifact back to the governing clause that authorised
-- it. This is the "secure by design" property made queryable rather than
-- asserted - pick any generated object and see which chunk it cites.
-- ---------------------------------------------------------------------
-- Note: a LATERAL FLATTEN cannot sit on the left of a join, so the citations are
-- unnested in a CTE first and the chunk lookup is joined afterwards.
CREATE OR REPLACE VIEW V_TRACEABILITY AS
WITH cited AS (
    SELECT 'USER_STORY' AS ARTIFACT_TYPE, s.STORY_ID AS ARTIFACT_ID,
           s.TITLE AS ARTIFACT_NAME, s.STATUS, s.RUN_ID,
           c.VALUE::STRING AS CHUNK_ID
    FROM CAPSTONE_AI_DLC.ARTIFACTS.USER_STORIES s,
         LATERAL FLATTEN(input => s.CITATIONS) c
    UNION ALL
    SELECT 'GENERATED_CODE', g.CODE_ID,
           g.OBJECT_NAME || ' (' || g.ARTIFACT_KIND || ')', g.STATUS, g.RUN_ID,
           c.VALUE::STRING
    FROM CAPSTONE_AI_DLC.ARTIFACTS.GENERATED_CODE g,
         LATERAL FLATTEN(input => g.CITATIONS) c
    UNION ALL
    SELECT 'TEST_CASE', t.TEST_ID, t.TEST_NAME, t.STATUS, t.RUN_ID,
           c.VALUE::STRING
    FROM CAPSTONE_AI_DLC.ARTIFACTS.TEST_CASES t,
         LATERAL FLATTEN(input => t.CITATIONS) c
    UNION ALL
    SELECT 'DEFECT', d.DEFECT_ID, d.CATEGORY || ' / ' || d.SEVERITY, d.STATUS, d.RUN_ID,
           c.VALUE::STRING
    FROM CAPSTONE_AI_DLC.ARTIFACTS.DEFECTS d,
         LATERAL FLATTEN(input => d.CITATIONS) c
)
SELECT
    ci.ARTIFACT_TYPE, ci.ARTIFACT_ID, ci.ARTIFACT_NAME, ci.STATUS,
    ci.CHUNK_ID, k.DOC_ID, k.TITLE AS DOC_TITLE, ci.RUN_ID,
    k.CHUNK_ID IS NOT NULL AS CITATION_RESOLVES
FROM cited ci
LEFT JOIN CAPSTONE_AI_DLC.GOVERNANCE.KNOWLEDGE_CHUNKS k
       ON k.CHUNK_ID = ci.CHUNK_ID;

-- Headline counters for the dashboard.
CREATE OR REPLACE VIEW V_HEADLINE AS
SELECT
    (SELECT COUNT(*) FROM AGENT_RUN_LOG)                                        AS AGENT_RUNS,
    (SELECT COUNT_IF(STATUS='REJECTED') FROM AGENT_RUN_LOG)                     AS GOVERNANCE_REFUSALS,
    (SELECT COUNT(*) FROM CAPSTONE_AI_DLC.ARTIFACTS.USER_STORIES)               AS USER_STORIES,
    (SELECT COUNT(*) FROM CAPSTONE_AI_DLC.ARTIFACTS.GENERATED_CODE)             AS CODE_ARTIFACTS,
    (SELECT COUNT(*) FROM CAPSTONE_AI_DLC.ARTIFACTS.TEST_CASES)                 AS TESTS,
    (SELECT COUNT(*) FROM MUTATION_RESULTS)                                     AS DEFECTS_INJECTED,
    (SELECT COUNT_IF(CAUGHT) FROM MUTATION_RESULTS)                             AS DEFECTS_CAUGHT,
    (SELECT ROUND(SUM(EST_USD),4) FROM AGENT_RUN_LOG)                           AS EST_USD_TOTAL,
    (SELECT SUM(TOTAL_TOKENS) FROM AGENT_RUN_LOG)                               AS TOTAL_TOKENS,
    (SELECT COUNT(*) FROM CAPSTONE_AI_DLC.PIPELINE.SILVER_AP_INVOICES)          AS SILVER_ROWS,
    (SELECT COUNT(*) FROM CAPSTONE_AI_DLC.GOVERNANCE.KNOWLEDGE_CHUNKS)          AS KB_CHUNKS;

SELECT * FROM V_HEADLINE;
