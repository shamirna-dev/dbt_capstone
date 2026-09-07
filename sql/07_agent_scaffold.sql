-- =====================================================================
-- 07_agent_scaffold.sql -- Agent 2: ETL / dbt code scaffolding
--
-- SDLC phase: BUILD
--
-- Two decisions that make the generated code trustworthy rather than
-- merely plausible:
--
--  1. The agent generates plain Snowflake SQL against real physical table
--     names, which is then COMPILE-CHECKED against the live account with
--     EXPLAIN. The dbt model file is derived from that verified SQL by
--     deterministic substitution (physical name -> ref()/source()), so the
--     dbt artifact inherits a real compile guarantee. Generating jinja
--     directly would have produced code nothing could verify.
--
--  2. The agent is given the actual source column list and sample values
--     from INFORMATION_SCHEMA and the table itself, not a description of
--     them. It writes transformations against the data that exists.
-- =====================================================================

USE DATABASE CAPSTONE_AI_DLC;
USE SCHEMA AGENTS;

-- ---------------------------------------------------------------------
-- Compile verification. EXPLAIN forces full parse, name resolution and
-- type checking without materialising anything or scanning data.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE COMPILE_CHECK(P_SQL STRING)
RETURNS OBJECT
LANGUAGE SQL
COMMENT = 'Validates a SELECT statement against the live account via EXPLAIN.'
AS
$$
DECLARE
    res RESULTSET;
BEGIN
    res := (EXECUTE IMMEDIATE 'EXPLAIN USING TEXT ' || :P_SQL);
    RETURN OBJECT_CONSTRUCT('status','PASS','error',NULL);
EXCEPTION
    WHEN OTHER THEN
        RETURN OBJECT_CONSTRUCT('status','FAIL','error', SQLERRM);
END;
$$;

-- ---------------------------------------------------------------------
-- Renders verified physical SQL into a dbt model. Deterministic string
-- substitution only - no model involved, so this step cannot hallucinate.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION TO_DBT_MODEL(P_SQL STRING, P_MATERIALIZATION STRING, P_TARGET_LAG STRING)
RETURNS STRING
LANGUAGE SQL
COMMENT = 'Converts compile-verified physical SQL into a dbt model file body.'
AS
$$
    SELECT
        '{{' || CHAR(10) ||
        '    config(' || CHAR(10) ||
        '        materialized = ''' || P_MATERIALIZATION || '''' ||
        CASE WHEN P_TARGET_LAG IS NULL THEN ''
             ELSE ',' || CHAR(10) || '        target_lag = ''' || P_TARGET_LAG || '''' ||
                  ',' || CHAR(10) || '        snowflake_warehouse = ''COMPUTE_WH''' ||
                  ',' || CHAR(10) || '        refresh_mode = ''INCREMENTAL'''
        END || CHAR(10) ||
        '    )' || CHAR(10) ||
        '}}' || CHAR(10) || CHAR(10) ||
        REGEXP_REPLACE(
            REGEXP_REPLACE(
                P_SQL,
                'CAPSTONE_AI_DLC\\.PIPELINE\\.(BRONZE_[A-Z_]+)',
                '{{ source(''ap_bronze'', ''\\1'') }}'
            ),
            'CAPSTONE_AI_DLC\\.PIPELINE\\.(STG_[A-Z_]+|SILVER_[A-Z_]+|GOLD_[A-Z_]+)',
            '{{ ref(''\\1'') }}'
        )
$$;

-- ---------------------------------------------------------------------
-- Agent 2. Scaffolds one staging model conforming one source system to
-- the Silver contract.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE AGENT_SCAFFOLD(P_SOURCE_SYSTEM STRING, P_STORY_ID STRING, P_ORCHESTRATOR STRING)
RETURNS OBJECT
LANGUAGE SQL
COMMENT = 'Generates and compile-verifies a staging model conforming one source to the Silver contract.'
AS
$$
DECLARE
    v_run_id     STRING;
    v_started    TIMESTAMP_NTZ;
    v_bronze     STRING;
    v_target     STRING;
    v_ctx        OBJECT;
    v_context    STRING;
    v_citations  ARRAY;
    v_contract   STRING;
    v_srccols    STRING;
    v_sample     STRING;
    v_prompt     STRING;
    v_llm        OBJECT;
    v_raw        STRING;
    v_json       VARIANT;
    v_code       STRING;
    v_chk        OBJECT;
    v_code_id    STRING;
    v_dbt        STRING;
    v_top_k      NUMBER;
    v_sample_sql STRING;
    res          RESULTSET;
BEGIN
    v_run_id  := UUID_STRING();
    v_started := CURRENT_TIMESTAMP();
    v_top_k   := CAPSTONE_AI_DLC.GOVERNANCE.CFG('RAG_TOP_K')::NUMBER;
    v_bronze  := 'BRONZE_' || UPPER(:P_SOURCE_SYSTEM) || '_AP_INVOICES';
    v_target  := 'STG_' || UPPER(:P_SOURCE_SYSTEM) || '_AP_INVOICES';

    -- Real source metadata, not a description of it.
    SELECT LISTAGG(COLUMN_NAME || ' ' || DATA_TYPE, ', ') WITHIN GROUP (ORDER BY ORDINAL_POSITION)
      INTO :v_srccols
    FROM CAPSTONE_AI_DLC.INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = 'PIPELINE' AND TABLE_NAME = :v_bronze;

    IF (v_srccols IS NULL) THEN
        RETURN OBJECT_CONSTRUCT('status','FAILED','error','no such bronze table: ' || :v_bronze);
    END IF;

    -- Three real rows so the model can see the actual encodings it must handle
    -- (prefixed vs unprefixed cost centres, source-specific term codes).
    v_sample_sql := 'SELECT ARRAY_AGG(OBJECT_CONSTRUCT(*))::STRING AS s FROM (SELECT * FROM CAPSTONE_AI_DLC.PIPELINE.'
                 || :v_bronze || ' LIMIT 3)';
    res := (EXECUTE IMMEDIATE :v_sample_sql);
    LET c1 CURSOR FOR res; OPEN c1; FETCH c1 INTO v_sample; CLOSE c1;

    -- One targeted query per fact this agent needs. A single broad query does
    -- not reliably retrieve the mapping tables, and a missing mapping causes
    -- the model to invent one.
    CALL CAPSTONE_AI_DLC.GOVERNANCE.RETRIEVE_MULTI(ARRAY_CONSTRUCT(
        UPPER(:P_SOURCE_SYSTEM) || ' payment terms source code mapping to canonical NETnn',
        UPPER(:P_SOURCE_SYSTEM) || ' approval status source value mapping to canonical APPROVED PENDING',
        'cost centre prefix strip first hyphen ' || UPPER(:P_SOURCE_SYSTEM),
        'invoice key construction deterministic surrogate key rule',
        'SQL coding standards CTE structure UNION ALL explicit casts prohibited practices',
        'is ' || UPPER(:P_SOURCE_SYSTEM) || ' in scope, blocked, deferred or excluded from this release',
        'permitted currency codes and quarantine rule'
    ), :v_top_k) INTO :v_ctx;
    v_context   := GET(:v_ctx,'context_text')::STRING;
    v_citations := GET(:v_ctx,'citations')::ARRAY;

    SELECT LISTAGG(COLUMN_NAME || ' ' || DATA_TYPE ||
                   CASE WHEN IS_REQUIRED THEN ' NOT NULL' ELSE ' NULL' END ||
                   CASE WHEN ALLOWED_VALUES IS NOT NULL
                        THEN ' allowed=' || ARRAY_TO_STRING(ALLOWED_VALUES,'|') ELSE '' END,
                   '\n') WITHIN GROUP (ORDER BY ORDINAL)
      INTO :v_contract
    FROM CAPSTONE_AI_DLC.GOVERNANCE.TARGET_CONTRACT
    WHERE TARGET_TABLE = 'SILVER_AP_INVOICES';

    v_prompt :=
'You are a senior analytics engineer writing production Snowflake SQL for a medallion pipeline.

GOVERNING CONTEXT (authoritative; citation ids in square brackets):
' || :v_context || '

TARGET CONTRACT - SILVER_AP_INVOICES columns in order:
' || :v_contract || '

SOURCE TABLE: CAPSTONE_AI_DLC.PIPELINE.' || :v_bronze || '
SOURCE COLUMNS: ' || :v_srccols || '

THREE REAL SOURCE ROWS (JSON):
' || COALESCE(:v_sample, '[]') || '

TASK
Write ONE Snowflake SELECT statement that conforms this source to the target
contract. It will become the staging model ' || :v_target || '.

HARD RULES
1. First check the governing context for whether this source system is in scope.
   If it is blocked, deferred or excluded from the current release, return
   governance_conflict and no code.
2. Output the target columns in exactly the contract order, aliased to the exact
   contract column names. Do not add extra columns. Do not use SELECT *.
3. Follow the coding standards in the governing context: CTE named source, then
   renamed, then logic; UNION ALL never UNION; explicit casts; TRY_ parsing for
   values that may not parse; no ROW_NUMBER or sequence for the key.
4. Use the mapping tables in the governing context verbatim for payment terms and
   approval status. Include EVERY row of those tables that applies to this source
   system - do not omit a mapping because it does not appear in the three sample
   rows, and do not invent a mapping that is absent from the tables. A source code
   that is genuinely not in the mapping table must yield NULL, never a default and
   never a guess based on how the code looks.
5. Apply the cost centre rule exactly as the context states it, including the case
   where no prefix is present.
6. Reference the source table by its full name CAPSTONE_AI_DLC.PIPELINE.' || :v_bronze || '.
7. The statement must be a single SELECT, no CREATE, no semicolon, no comments
   outside the SQL, and must compile against Snowflake as written.
8. SOURCE_SYSTEM must be the literal ''' || UPPER(:P_SOURCE_SYSTEM) || '''.

Return ONLY valid JSON, no markdown fence:
{"governance_conflict": null, "sql": "the SELECT statement", "notes": ["assumption or caveat"], "citations": ["chunk-id"]}
If blocked: {"governance_conflict": {"reason":"string","citations":["chunk-id"]}, "sql": null, "notes": [], "citations": []}';

    CALL CAPSTONE_AI_DLC.AGENTS.LLM_COMPLETE(
             :v_prompt, CAPSTONE_AI_DLC.GOVERNANCE.CFG('DEFAULT_MODEL'), 8192) INTO :v_llm;
    v_raw  := GET(:v_llm,'text')::STRING;
    v_json := CAPSTONE_AI_DLC.AGENTS.PARSE_LLM_JSON(:v_raw);

    IF (v_json IS NULL) THEN
        CALL CAPSTONE_AI_DLC.AGENTS.LOG_RUN(OBJECT_CONSTRUCT(
            'run_id', :v_run_id,'agent_name','AGENT_SCAFFOLD','sdlc_phase','BUILD',
            'input_ref', :P_SOURCE_SYSTEM,'retrieved_chunks', :v_citations,
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

    IF (v_json:governance_conflict IS NOT NULL
        AND v_json:governance_conflict::STRING NOT IN ('null','')) THEN
        CALL CAPSTONE_AI_DLC.AGENTS.LOG_RUN(OBJECT_CONSTRUCT(
            'run_id', :v_run_id,'agent_name','AGENT_SCAFFOLD','sdlc_phase','BUILD',
            'input_ref', :P_SOURCE_SYSTEM,
            'input_payload', OBJECT_CONSTRUCT('governance_conflict', :v_json:governance_conflict),
            'retrieved_chunks', :v_citations,'prompt_text', :v_prompt,
            'model_name', GET(:v_llm,'model')::STRING,'response_raw', :v_raw,
            'output_ref','GOVERNANCE_CONFLICT','status','REJECTED',
            'error_message', :v_json:governance_conflict:reason::STRING,
            'prompt_tokens', GET(:v_llm,'prompt_tokens'),
            'completion_tokens', GET(:v_llm,'completion_tokens'),
            'total_tokens', GET(:v_llm,'total_tokens'),
            'latency_ms', DATEDIFF('millisecond', :v_started, CURRENT_TIMESTAMP()),
            'orchestrator', :P_ORCHESTRATOR,'started_at', :v_started));
        RETURN OBJECT_CONSTRUCT('run_id', :v_run_id,'status','GOVERNANCE_CONFLICT',
                                'conflict', :v_json:governance_conflict);
    END IF;

    v_code := :v_json:sql::STRING;
    CALL CAPSTONE_AI_DLC.AGENTS.COMPILE_CHECK(:v_code) INTO :v_chk;

    v_code_id := :v_run_id || ':' || :v_target;
    v_dbt := CAPSTONE_AI_DLC.AGENTS.TO_DBT_MODEL(:v_code, 'view', NULL);

    INSERT INTO CAPSTONE_AI_DLC.ARTIFACTS.GENERATED_CODE
        (CODE_ID, RUN_ID, STORY_ID, ARTIFACT_KIND, LAYER, OBJECT_NAME, SOURCE_SYSTEM,
         CODE_TEXT, COMPILE_STATUS, COMPILE_ERROR, STATUS, CITATIONS)
    SELECT :v_code_id, :v_run_id, :P_STORY_ID, 'STAGING_SELECT', 'SILVER', :v_target,
           UPPER(:P_SOURCE_SYSTEM), :v_code,
           GET(:v_chk,'status')::STRING, GET(:v_chk,'error')::STRING,
           'DRAFT', :v_json:citations::ARRAY;

    INSERT INTO CAPSTONE_AI_DLC.ARTIFACTS.GENERATED_CODE
        (CODE_ID, RUN_ID, STORY_ID, ARTIFACT_KIND, LAYER, OBJECT_NAME, SOURCE_SYSTEM,
         CODE_TEXT, COMPILE_STATUS, COMPILE_ERROR, STATUS, CITATIONS)
    SELECT :v_code_id || ':dbt', :v_run_id, :P_STORY_ID, 'DBT_MODEL', 'SILVER',
           :v_target, UPPER(:P_SOURCE_SYSTEM), :v_dbt,
           GET(:v_chk,'status')::STRING,
           'derived from compile-' || LOWER(GET(:v_chk,'status')::STRING) || ' physical SQL',
           'DRAFT', :v_json:citations::ARRAY;

    CALL CAPSTONE_AI_DLC.AGENTS.LOG_RUN(OBJECT_CONSTRUCT(
        'run_id', :v_run_id,'agent_name','AGENT_SCAFFOLD','sdlc_phase','BUILD',
        'input_ref', :P_SOURCE_SYSTEM,
        'input_payload', OBJECT_CONSTRUCT('target', :v_target,'notes', :v_json:notes),
        'retrieved_chunks', :v_citations,'prompt_text', :v_prompt,
        'model_name', GET(:v_llm,'model')::STRING,'response_raw', :v_raw,
        'output_ref', :v_code_id,
        'status', CASE WHEN GET(:v_chk,'status')::STRING = 'PASS' THEN 'SUCCESS' ELSE 'FAILED' END,
        'error_message', GET(:v_chk,'error')::STRING,
        'prompt_tokens', GET(:v_llm,'prompt_tokens'),
        'completion_tokens', GET(:v_llm,'completion_tokens'),
        'total_tokens', GET(:v_llm,'total_tokens'),
        'latency_ms', DATEDIFF('millisecond', :v_started, CURRENT_TIMESTAMP()),
        'orchestrator', :P_ORCHESTRATOR,'started_at', :v_started));

    RETURN OBJECT_CONSTRUCT('run_id', :v_run_id,'status','SUCCESS','code_id', :v_code_id,
                            'object_name', :v_target,
                            'compile_status', GET(:v_chk,'status'),
                            'compile_error', GET(:v_chk,'error'));
END;
$$;
