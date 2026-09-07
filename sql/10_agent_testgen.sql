-- =====================================================================
-- 10_agent_testgen.sql -- Agent 3: data quality test generation
--
-- SDLC phase: QA
--
-- The taxonomy document requires that every test declares which defect
-- class it is designed to catch, and states that a test which cannot be
-- made to fail by any injected defect is a tautology that must be removed.
-- That rule is what makes this agent verifiable: the generated suite is
-- validated by deliberately corrupting the data and confirming the right
-- tests fail. See 12_defect_injection.sql.
-- =====================================================================

USE DATABASE CAPSTONE_AI_DLC;
USE SCHEMA AGENTS;

CREATE OR REPLACE PROCEDURE AGENT_TESTGEN(P_TARGET_TABLE STRING, P_STORY_ID STRING, P_ORCHESTRATOR STRING)
RETURNS OBJECT
LANGUAGE SQL
COMMENT = 'Generates a compile-verified data quality suite from the contract and taxonomy.'
AS
$$
DECLARE
    v_run_id    STRING;
    v_started   TIMESTAMP_NTZ;
    v_ctx       OBJECT;
    v_context   STRING;
    v_citations ARRAY;
    v_contract  STRING;
    v_prompt    STRING;
    v_llm       OBJECT;
    v_raw       STRING;
    v_json      VARIANT;
    v_tests     ARRAY;
    v_n         NUMBER DEFAULT 0;
    v_pass      NUMBER DEFAULT 0;
    v_top_k     NUMBER;
    v_fqn       STRING;
BEGIN
    v_run_id  := UUID_STRING();
    v_started := CURRENT_TIMESTAMP();
    v_top_k   := CAPSTONE_AI_DLC.GOVERNANCE.CFG('RAG_TOP_K')::NUMBER;
    v_fqn     := 'CAPSTONE_AI_DLC.PIPELINE.' || UPPER(:P_TARGET_TABLE);

    CALL CAPSTONE_AI_DLC.GOVERNANCE.RETRIEVE_MULTI(ARRAY_CONSTRUCT(
        'data quality test taxonomy categories and severity model',
        'test authoring rules assertion returns zero rows tautology injected defect',
        'reconciliation test bronze to silver row counts union all',
        'boundary rules invoice amount positive due date not before invoice date future dates',
        'permitted currency codes approval status accepted values',
        'grain uniqueness invoice key required columns not null',
        'freshness target and volume expectations'
    ), :v_top_k) INTO :v_ctx;
    v_context   := GET(:v_ctx,'context_text')::STRING;
    v_citations := GET(:v_ctx,'citations')::ARRAY;

    SELECT LISTAGG(COLUMN_NAME || ' ' || DATA_TYPE ||
                   CASE WHEN IS_REQUIRED THEN ' NOT NULL' ELSE ' NULL' END ||
                   CASE WHEN IS_BUSINESS_KEY THEN ' [grain]' ELSE '' END ||
                   CASE WHEN ALLOWED_VALUES IS NOT NULL
                        THEN ' allowed=' || ARRAY_TO_STRING(ALLOWED_VALUES,'|') ELSE '' END,
                   '\n') WITHIN GROUP (ORDER BY ORDINAL)
      INTO :v_contract
    FROM CAPSTONE_AI_DLC.GOVERNANCE.TARGET_CONTRACT
    WHERE TARGET_TABLE = UPPER(:P_TARGET_TABLE);

    v_prompt :=
'You are a data QA engineer designing an executable data quality suite for a Snowflake table.

GOVERNING CONTEXT (authoritative; citation ids in square brackets):
' || :v_context || '

TARGET TABLE: ' || :v_fqn || '
CONTRACT COLUMNS:
' || :v_contract || '

BRONZE SOURCE TABLES available for reconciliation and referential tests:
CAPSTONE_AI_DLC.PIPELINE.BRONZE_SAP_AP_INVOICES     (natural key INVOICE_ID,     SOURCE_SYSTEM = SAP)
CAPSTONE_AI_DLC.PIPELINE.BRONZE_ORACLE_AP_INVOICES  (natural key INV_ID,         SOURCE_SYSTEM = ORACLE)
CAPSTONE_AI_DLC.PIPELINE.BRONZE_BAAN_AP_INVOICES    (natural key BAN_INVOICE_ID, SOURCE_SYSTEM = BAAN)
Workday is not loaded and must not be referenced in any test.

TASK
Produce one test per applicable category in the taxonomy. Cover every category the
taxonomy defines that is applicable to this table, and cover every required column
for NOT_NULL and every enumerated column for ACCEPTED_VALUES.

HARD RULES
1. ASSERTION_SQL must be a single SELECT that returns ZERO rows when the data is
   correct, and one row per violation when it is not. It must select enough columns
   to identify the offending rows, never just a count.
2. Fully qualify every table. Do not rely on session database or schema.
3. Do not use CURRENT_DATE or CURRENT_TIMESTAMP except in the FRESHNESS test.
4. severity must come from the taxonomy severity model for that category.
5. expect_fail_on must name the specific defect that would make this test fail,
   phrased concretely, e.g. "a NULL introduced into APPROVAL_STATUS" or
   "UNION replaced with UNION ALL causing row loss". A test you cannot describe a
   failure mode for is a tautology - do not emit it.
6. Use only the thresholds and permitted values stated in the governing context.
7. test_category must be exactly one of: NOT_NULL, UNIQUENESS, ACCEPTED_VALUES,
   BOUNDARY, REFERENTIAL, TYPE_VIOLATION, VOLUME, FRESHNESS, RECONCILIATION.

Return ONLY valid JSON, no markdown fence:
{"tests":[{"test_name":"snake_case_name","test_category":"NOT_NULL","target_column":"COL or null","severity":"CRITICAL","description":"what it proves","assertion_sql":"SELECT ...","expect_fail_on":"concrete defect","citations":["chunk-id"]}]}';

    CALL CAPSTONE_AI_DLC.AGENTS.LLM_COMPLETE(
             :v_prompt, CAPSTONE_AI_DLC.GOVERNANCE.CFG('DEFAULT_MODEL'), 8192) INTO :v_llm;
    v_raw  := GET(:v_llm,'text')::STRING;
    v_json := CAPSTONE_AI_DLC.AGENTS.PARSE_LLM_JSON(:v_raw);

    IF (v_json IS NULL) THEN
        CALL CAPSTONE_AI_DLC.AGENTS.LOG_RUN(OBJECT_CONSTRUCT(
            'run_id', :v_run_id,'agent_name','AGENT_TESTGEN','sdlc_phase','QA',
            'input_ref', :P_TARGET_TABLE,'retrieved_chunks', :v_citations,
            'prompt_text', :v_prompt,'model_name', GET(:v_llm,'model')::STRING,
            'response_raw', :v_raw,'status','FAILED',
            'error_message','model did not return parseable JSON',
            'prompt_tokens', GET(:v_llm,'prompt_tokens'),
            'completion_tokens', GET(:v_llm,'completion_tokens'),
            'total_tokens', GET(:v_llm,'total_tokens'),
            'latency_ms', DATEDIFF('millisecond', :v_started, CURRENT_TIMESTAMP()),
            'orchestrator', :P_ORCHESTRATOR,'started_at', :v_started));
        RETURN OBJECT_CONSTRUCT('run_id', :v_run_id,'status','FAILED','error','unparseable model output');
    END IF;

    v_tests := :v_json:tests::ARRAY;

    INSERT INTO CAPSTONE_AI_DLC.ARTIFACTS.TEST_CASES
        (TEST_ID, RUN_ID, STORY_ID, TARGET_TABLE, TARGET_COLUMN, TEST_CATEGORY,
         TEST_NAME, DESCRIPTION, SEVERITY, ASSERTION_SQL, EXPECT_FAIL_ON,
         COMPILE_STATUS, STATUS, CITATIONS)
    SELECT
        :v_run_id || ':' || t.VALUE:test_name::STRING,
        :v_run_id, :P_STORY_ID, UPPER(:P_TARGET_TABLE),
        NULLIF(t.VALUE:target_column::STRING,'null'),
        t.VALUE:test_category::STRING, t.VALUE:test_name::STRING,
        t.VALUE:description::STRING, t.VALUE:severity::STRING,
        t.VALUE:assertion_sql::STRING, t.VALUE:expect_fail_on::STRING,
        'NOT_CHECKED', 'DRAFT', t.VALUE:citations::ARRAY
    FROM TABLE(FLATTEN(input => :v_tests)) t;

    v_n := SQLROWCOUNT;

    CALL CAPSTONE_AI_DLC.AGENTS.LOG_RUN(OBJECT_CONSTRUCT(
        'run_id', :v_run_id,'agent_name','AGENT_TESTGEN','sdlc_phase','QA',
        'input_ref', :P_TARGET_TABLE,
        'input_payload', OBJECT_CONSTRUCT('tests_generated', :v_n),
        'retrieved_chunks', :v_citations,'prompt_text', :v_prompt,
        'model_name', GET(:v_llm,'model')::STRING,'response_raw', :v_raw,
        'output_ref','tests=' || :v_n::STRING,'status','SUCCESS',
        'prompt_tokens', GET(:v_llm,'prompt_tokens'),
        'completion_tokens', GET(:v_llm,'completion_tokens'),
        'total_tokens', GET(:v_llm,'total_tokens'),
        'latency_ms', DATEDIFF('millisecond', :v_started, CURRENT_TIMESTAMP()),
        'orchestrator', :P_ORCHESTRATOR,'started_at', :v_started));

    RETURN OBJECT_CONSTRUCT('run_id', :v_run_id,'status','SUCCESS','tests_generated', :v_n);
END;
$$;

-- ---------------------------------------------------------------------
-- Compile-check every DRAFT test. A test that does not compile is worse
-- than no test, because it looks like coverage.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE COMPILE_TEST_SUITE()
RETURNS OBJECT
LANGUAGE SQL
AS
$$
DECLARE
    v_id    STRING;
    v_sql   STRING;
    v_chk   OBJECT;
    v_pass  NUMBER DEFAULT 0;
    v_fail  NUMBER DEFAULT 0;
    c1 CURSOR FOR
        SELECT TEST_ID, ASSERTION_SQL FROM CAPSTONE_AI_DLC.ARTIFACTS.TEST_CASES
        WHERE COMPILE_STATUS IS NULL OR COMPILE_STATUS = 'NOT_CHECKED';
BEGIN
    FOR r IN c1 DO
        v_id  := r.TEST_ID;
        v_sql := r.ASSERTION_SQL;
        CALL CAPSTONE_AI_DLC.AGENTS.COMPILE_CHECK(:v_sql) INTO :v_chk;
        UPDATE CAPSTONE_AI_DLC.ARTIFACTS.TEST_CASES
           SET COMPILE_STATUS = GET(:v_chk,'status')::STRING,
               COMPILE_ERROR  = GET(:v_chk,'error')::STRING
         WHERE TEST_ID = :v_id;
        IF (GET(:v_chk,'status')::STRING = 'PASS') THEN
            v_pass := :v_pass + 1;
        ELSE
            v_fail := :v_fail + 1;
        END IF;
    END FOR;
    RETURN OBJECT_CONSTRUCT('compiled_pass', :v_pass, 'compiled_fail', :v_fail);
END;
$$;

-- ---------------------------------------------------------------------
-- Execute the suite. DATASET_LABEL records what the suite was run against
-- so clean-run and corrupted-run results are comparable.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE RUN_TEST_SUITE(P_DATASET_LABEL STRING)
RETURNS OBJECT
LANGUAGE SQL
AS
$$
DECLARE
    v_id     STRING;
    v_sql    STRING;
    v_cnt    NUMBER;
    v_pass   NUMBER DEFAULT 0;
    v_fail   NUMBER DEFAULT 0;
    v_err    NUMBER DEFAULT 0;
    res      RESULTSET;
    c1 CURSOR FOR
        SELECT TEST_ID, ASSERTION_SQL FROM CAPSTONE_AI_DLC.ARTIFACTS.TEST_CASES
        WHERE COMPILE_STATUS = 'PASS';
BEGIN
    FOR r IN c1 DO
        v_id  := r.TEST_ID;
        v_sql := r.ASSERTION_SQL;
        BEGIN
            res := (EXECUTE IMMEDIATE
                    'SELECT COUNT(*) AS n FROM (' || :v_sql || ')');
            LET c2 CURSOR FOR res;
            OPEN c2;
            FETCH c2 INTO v_cnt;
            CLOSE c2;

            INSERT INTO CAPSTONE_AI_DLC.ARTIFACTS.TEST_RESULTS
                (RESULT_ID, TEST_ID, DATASET_LABEL, OUTCOME, FAIL_ROW_COUNT)
            SELECT UUID_STRING(), :v_id, :P_DATASET_LABEL,
                   CASE WHEN :v_cnt = 0 THEN 'PASS' ELSE 'FAIL' END, :v_cnt;

            IF (v_cnt = 0) THEN
                v_pass := :v_pass + 1;
            ELSE
                v_fail := :v_fail + 1;
            END IF;
        EXCEPTION
            WHEN OTHER THEN
                INSERT INTO CAPSTONE_AI_DLC.ARTIFACTS.TEST_RESULTS
                    (RESULT_ID, TEST_ID, DATASET_LABEL, OUTCOME, ERROR_MESSAGE)
                SELECT UUID_STRING(), :v_id, :P_DATASET_LABEL, 'ERROR', SQLERRM;
                v_err := :v_err + 1;
        END;
    END FOR;
    RETURN OBJECT_CONSTRUCT('dataset', :P_DATASET_LABEL,
                            'passed', :v_pass, 'failed', :v_fail, 'errored', :v_err);
END;
$$;
