-- =====================================================================
-- 14_agent_defect_triage.sql -- Agent 5: Defect IQ / triage
--
-- SDLC phase: OPERATIONS
--
-- Takes a raw failure signal - a failed assertion, a pipeline error - and
-- classifies it: category, severity from the taxonomy severity model, root
-- cause, remediation, confidence, likely owner.
--
-- This agent is measurable because the injected-defect harness already knows
-- the true category of every failure it caused. TRIAGE_MUTATION_FAILURES
-- replays each corrupted run, triages the resulting failure signal WITHOUT
-- telling the agent which defect was injected, and scores the predicted
-- category against the catalogue. That is a real accuracy number on a real
-- labelled set, not a vibe.
-- =====================================================================

USE DATABASE CAPSTONE_AI_DLC;
USE SCHEMA AGENTS;

CREATE OR REPLACE PROCEDURE AGENT_DEFECT_TRIAGE(
    P_SIGNAL STRING, P_SOURCE_REF STRING, P_RAISED_FROM STRING, P_ORCHESTRATOR STRING)
RETURNS OBJECT
LANGUAGE SQL
COMMENT = 'Classifies a failure signal into a triaged defect with root cause and remediation.'
AS
$$
DECLARE
    v_run_id    STRING;
    v_started   TIMESTAMP_NTZ;
    v_ctx       OBJECT;
    v_context   STRING;
    v_citations ARRAY;
    v_prompt    STRING;
    v_llm       OBJECT;
    v_raw       STRING;
    v_json      VARIANT;
    v_defect_id STRING;
    v_top_k     NUMBER;
BEGIN
    v_run_id  := UUID_STRING();
    v_started := CURRENT_TIMESTAMP();
    v_top_k   := CAPSTONE_AI_DLC.GOVERNANCE.CFG('RAG_TOP_K')::NUMBER;

    CALL CAPSTONE_AI_DLC.GOVERNANCE.RETRIEVE_MULTI(ARRAY_CONSTRUCT(
        'test taxonomy categories and severity model blocking behaviour',
        'reconciliation row loss UNION versus UNION ALL defect',
        'payment terms unmapped code must not be defaulted',
        'cost centre prefix rule and pre-2024-11-01 extracts',
        'permitted currency codes quarantine contract violation',
        'dynamic table incremental refresh downgrade is a defect',
        'invoice key deterministic construction and grain uniqueness'
    ), :v_top_k) INTO :v_ctx;
    v_context   := GET(:v_ctx,'context_text')::STRING;
    v_citations := GET(:v_ctx,'citations')::ARRAY;

    v_prompt :=
'You are a data platform engineer triaging a failure in a Snowflake medallion pipeline.

GOVERNING CONTEXT (authoritative; citation ids in square brackets):
' || :v_context || '

FAILURE SIGNAL
Source: ' || :P_SOURCE_REF || '
Raised from: ' || :P_RAISED_FROM || '
Detail:
' || :P_SIGNAL || '

TASK
Triage this failure.

CATEGORY DEFINITIONS - classify by the NATURE OF THE FAILED CHECK (the symptom),
not by the upstream code fault. The upstream fault belongs in root_cause.
  DATA_QUALITY  - values in the data violate the contract: a required column is
                  NULL, a value is outside its permitted domain, or a numeric or
                  date boundary rule is breached. Use this even when the reason
                  is an incomplete mapping in the transformation.
  LOGIC_ERROR   - the transformation produced structurally wrong output: duplicate
                  grain keys from a fan-out, rows lost between layers, or a
                  surrogate key built the wrong way.
  REFERENTIAL   - rows cannot be traced between layers: a conformed row with no
                  corresponding source row, or a broken key relationship. Prefer
                  this over LOGIC_ERROR whenever the failing check is the
                  referential one.
  SCHEMA_DRIFT  - the shape of a source changed: a column added, removed, renamed
                  or retyped.
  PERFORMANCE   - the pipeline works but costs or takes too much, including a
                  Dynamic Table silently downgrading to full refresh.
  CONFIG        - a warehouse, lag, grant, or environment setting is wrong.
  UNKNOWN       - the signal genuinely does not determine a category.

HARD RULES
1. category must be exactly one of: SCHEMA_DRIFT, DATA_QUALITY, LOGIC_ERROR,
   REFERENTIAL, PERFORMANCE, CONFIG, UNKNOWN, per the definitions above.
2. severity must follow the severity model in the governing context for the kind
   of check that failed. Do not invent a severity scale, and do not escalate
   above what the taxonomy states for that category.
3. root_cause must name the most likely upstream cause in terms of this pipeline -
   a specific transformation, mapping or configuration - not a generic statement
   like "data quality issue".
4. remediation must be a concrete next action a named team could carry out.
5. confidence is a number between 0 and 1. Reserve values above 0.9 for signals
   where the category and severity are both unambiguous. If more than one category
   could defensibly apply, use 0.6 or lower.
6. Cite the chunk ids that informed the classification.
7. Do not speculate beyond the signal and the governing context.

Return ONLY valid JSON, no markdown fence:
{"category":"DATA_QUALITY","severity":"CRITICAL","root_cause":"...","remediation":"...","confidence":0.85,"owner_hint":"...","citations":["chunk-id"]}';

    CALL CAPSTONE_AI_DLC.AGENTS.LLM_COMPLETE(
             :v_prompt, CAPSTONE_AI_DLC.GOVERNANCE.CFG('DEFAULT_MODEL'), 4096) INTO :v_llm;
    v_raw  := GET(:v_llm,'text')::STRING;
    v_json := CAPSTONE_AI_DLC.AGENTS.PARSE_LLM_JSON(:v_raw);

    IF (v_json IS NULL) THEN
        CALL CAPSTONE_AI_DLC.AGENTS.LOG_RUN(OBJECT_CONSTRUCT(
            'run_id', :v_run_id,'agent_name','AGENT_DEFECT_TRIAGE','sdlc_phase','OPERATIONS',
            'input_ref', :P_SOURCE_REF,'retrieved_chunks', :v_citations,
            'prompt_text', :v_prompt,'model_name', GET(:v_llm,'model')::STRING,
            'response_raw', :v_raw,'status','FAILED',
            'error_message','model did not return parseable JSON',
            'prompt_tokens', GET(:v_llm,'prompt_tokens'),
            'completion_tokens', GET(:v_llm,'completion_tokens'),
            'total_tokens', GET(:v_llm,'total_tokens'),
            'latency_ms', DATEDIFF('millisecond', :v_started, CURRENT_TIMESTAMP()),
            'orchestrator', :P_ORCHESTRATOR,'started_at', :v_started));
        RETURN OBJECT_CONSTRUCT('run_id', :v_run_id,'status','FAILED');
    END IF;

    v_defect_id := :v_run_id;

    INSERT INTO CAPSTONE_AI_DLC.ARTIFACTS.DEFECTS
        (DEFECT_ID, RUN_ID, RAISED_FROM, SOURCE_REF, RAW_SIGNAL, CATEGORY, SEVERITY,
         ROOT_CAUSE, REMEDIATION, CONFIDENCE, OWNER_HINT, CITATIONS, STATUS)
    SELECT :v_defect_id, :v_run_id, :P_RAISED_FROM, :P_SOURCE_REF, :P_SIGNAL,
           :v_json:category::STRING, :v_json:severity::STRING,
           :v_json:root_cause::STRING, :v_json:remediation::STRING,
           :v_json:confidence::FLOAT, :v_json:owner_hint::STRING,
           :v_json:citations::ARRAY, 'OPEN';

    CALL CAPSTONE_AI_DLC.AGENTS.LOG_RUN(OBJECT_CONSTRUCT(
        'run_id', :v_run_id,'agent_name','AGENT_DEFECT_TRIAGE','sdlc_phase','OPERATIONS',
        'input_ref', :P_SOURCE_REF,
        'input_payload', OBJECT_CONSTRUCT('raised_from', :P_RAISED_FROM),
        'retrieved_chunks', :v_citations,'prompt_text', :v_prompt,
        'model_name', GET(:v_llm,'model')::STRING,'response_raw', :v_raw,
        'output_ref', :v_defect_id,'status','SUCCESS',
        'prompt_tokens', GET(:v_llm,'prompt_tokens'),
        'completion_tokens', GET(:v_llm,'completion_tokens'),
        'total_tokens', GET(:v_llm,'total_tokens'),
        'latency_ms', DATEDIFF('millisecond', :v_started, CURRENT_TIMESTAMP()),
        'orchestrator', :P_ORCHESTRATOR,'started_at', :v_started));

    RETURN OBJECT_CONSTRUCT('run_id', :v_run_id,'defect_id', :v_defect_id,
                            'category', :v_json:category,'severity', :v_json:severity,
                            'confidence', :v_json:confidence);
END;
$$;

-- ---------------------------------------------------------------------
-- Labelled evaluation of the triage agent.
--
-- The mapping from taxonomy test category to defect category is declared up
-- front, so scoring is not retrofitted to whatever the model happened to say.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE CAPSTONE_AI_DLC.GOVERNANCE.TRIAGE_GROUND_TRUTH (
    DEFECT_NAME       STRING NOT NULL PRIMARY KEY,
    TRUE_CATEGORY     STRING NOT NULL,
    TRUE_SEVERITY     STRING NOT NULL,
    RATIONALE         STRING
);

INSERT INTO CAPSTONE_AI_DLC.GOVERNANCE.TRIAGE_GROUND_TRUTH
    (DEFECT_NAME, TRUE_CATEGORY, TRUE_SEVERITY, RATIONALE)
SELECT v.a, v.b, v.c, v.d FROM VALUES
('NULL_REQUIRED_COLUMN','DATA_QUALITY','CRITICAL',
 'A required contract column is NULL. Taxonomy puts NOT_NULL at CRITICAL.'),
('DUPLICATE_GRAIN_KEY','LOGIC_ERROR','CRITICAL',
 'Duplicate grain key indicates a join fan-out or a non-deterministic key, i.e. a transformation logic fault.'),
('UNPERMITTED_CURRENCY','DATA_QUALITY','HIGH',
 'A value outside the permitted domain reached Silver instead of being quarantined. ACCEPTED_VALUES is HIGH.'),
('NON_POSITIVE_AMOUNT','DATA_QUALITY','HIGH',
 'Boundary rule breach on a numeric contract constraint. BOUNDARY is HIGH.'),
('DUE_DATE_BEFORE_INVOICE_DATE','DATA_QUALITY','HIGH',
 'Boundary rule breach on a date relationship. BOUNDARY is HIGH.'),
('SILENT_ROW_LOSS','LOGIC_ERROR','CRITICAL',
 'Rows lost between Bronze and Silver is the UNION-instead-of-UNION-ALL class, a transformation logic fault. RECONCILIATION is CRITICAL.'),
('ORPHANED_SILVER_ROW','REFERENTIAL','HIGH',
 'A Silver row with no Bronze parent is a referential integrity failure. REFERENTIAL is HIGH.')
AS v(a,b,c,d);

CREATE OR REPLACE TABLE CAPSTONE_AI_DLC.METRICS.TRIAGE_EVAL (
    DEFECT_NAME        STRING,
    TRUE_CATEGORY      STRING,
    PREDICTED_CATEGORY STRING,
    CATEGORY_CORRECT   BOOLEAN,
    TRUE_SEVERITY      STRING,
    PREDICTED_SEVERITY STRING,
    SEVERITY_CORRECT   BOOLEAN,
    CONFIDENCE         FLOAT,
    DEFECT_ID          STRING,
    RUN_AT             TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- For each injected defect, build a realistic failure signal from the tests that
-- actually failed and triage it. The agent is never told the defect name.
CREATE OR REPLACE PROCEDURE TRIAGE_MUTATION_FAILURES()
RETURNS OBJECT
LANGUAGE SQL
AS
$$
DECLARE
    v_name    STRING;
    v_signal  STRING;
    v_res     OBJECT;
    v_n       NUMBER DEFAULT 0;
    v_cat_ok  NUMBER DEFAULT 0;
    v_sev_ok  NUMBER DEFAULT 0;
    c1 CURSOR FOR
        SELECT DEFECT_NAME FROM CAPSTONE_AI_DLC.GOVERNANCE.DEFECT_CATALOGUE ORDER BY ORDINAL;
BEGIN
    DELETE FROM CAPSTONE_AI_DLC.METRICS.TRIAGE_EVAL;

    FOR r IN c1 DO
        v_name := r.DEFECT_NAME;

        -- Compose the signal from failing assertions only. No defect name, no
        -- expected category - only what an on-call engineer would actually see.
        SELECT LISTAGG('Test ' || t.TEST_NAME || ' [' || t.TEST_CATEGORY || '] FAILED on '
                       || t.TARGET_TABLE
                       || COALESCE(' column ' || t.TARGET_COLUMN, '')
                       || ' with ' || res.FAIL_ROW_COUNT::STRING || ' violating row(s).'
                       || ' Test intent: ' || t.DESCRIPTION
                       || ' Assertion: ' || LEFT(t.ASSERTION_SQL, 400), '\n')
                 WITHIN GROUP (ORDER BY t.TEST_NAME)
          INTO :v_signal
        FROM CAPSTONE_AI_DLC.ARTIFACTS.TEST_RESULTS res
        JOIN CAPSTONE_AI_DLC.ARTIFACTS.TEST_CASES t ON t.TEST_ID = res.TEST_ID
        WHERE res.DATASET_LABEL = 'CORRUPTED:' || :v_name AND res.OUTCOME = 'FAIL';

        IF (v_signal IS NOT NULL) THEN
            CALL CAPSTONE_AI_DLC.AGENTS.AGENT_DEFECT_TRIAGE(
                :v_signal, 'CAPSTONE_AI_DLC.PIPELINE.SILVER_AP_INVOICES',
                'TEST_RESULT', 'EVAL_HARNESS') INTO :v_res;

            INSERT INTO CAPSTONE_AI_DLC.METRICS.TRIAGE_EVAL
                (DEFECT_NAME, TRUE_CATEGORY, PREDICTED_CATEGORY, CATEGORY_CORRECT,
                 TRUE_SEVERITY, PREDICTED_SEVERITY, SEVERITY_CORRECT, CONFIDENCE, DEFECT_ID)
            SELECT :v_name, g.TRUE_CATEGORY, GET(:v_res,'category')::STRING,
                   g.TRUE_CATEGORY = GET(:v_res,'category')::STRING,
                   g.TRUE_SEVERITY, GET(:v_res,'severity')::STRING,
                   g.TRUE_SEVERITY = GET(:v_res,'severity')::STRING,
                   GET(:v_res,'confidence')::FLOAT, GET(:v_res,'defect_id')::STRING
            FROM CAPSTONE_AI_DLC.GOVERNANCE.TRIAGE_GROUND_TRUTH g
            WHERE g.DEFECT_NAME = :v_name;

            v_n := :v_n + 1;
        END IF;
    END FOR;

    SELECT COUNT_IF(CATEGORY_CORRECT), COUNT_IF(SEVERITY_CORRECT)
      INTO :v_cat_ok, :v_sev_ok
    FROM CAPSTONE_AI_DLC.METRICS.TRIAGE_EVAL;

    RETURN OBJECT_CONSTRUCT('triaged', :v_n,
                            'category_correct', :v_cat_ok,
                            'severity_correct', :v_sev_ok,
                            'category_accuracy', ROUND(:v_cat_ok / NULLIF(:v_n,0), 4),
                            'severity_accuracy', ROUND(:v_sev_ok / NULLIF(:v_n,0), 4));
END;
$$;
