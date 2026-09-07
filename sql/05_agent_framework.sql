-- =====================================================================
-- 05_agent_framework.sql -- shared harness every agent uses
--
-- Design decisions worth stating:
--  * Agents are stored procedures, not notebooks, so n8n can invoke them
--    with a single CALL over the SQL API and so they are grantable and
--    versionable like any other database object.
--  * temperature = 0 everywhere. These agents generate code and tests;
--    reproducibility matters more than variety.
--  * Every run is logged whether it succeeds or fails. A run log with only
--    successes in it is not evidence of anything.
-- =====================================================================

USE DATABASE CAPSTONE_AI_DLC;
USE SCHEMA AGENTS;

-- ---------------------------------------------------------------------
-- Single LLM entry point. Returns text plus token usage so cost can be
-- attributed per run rather than guessed at account level.
--
-- Note: Cortex COMPLETE requires its model argument to be a string
-- literal, which rules out reading the model name from PLATFORM_CONFIG in
-- a plain SQL UDF. Rather than hard-code the model in six places, this is
-- a procedure that interpolates only the model name into the statement and
-- binds the prompt as a parameter, so prompt content cannot alter the SQL.
-- ---------------------------------------------------------------------
-- LLM_COMPLETE was originally a UDF; a procedure cannot replace a function of
-- the same name, so drop the older shape first.
DROP FUNCTION IF EXISTS LLM_COMPLETE(STRING, STRING, NUMBER);

CREATE OR REPLACE PROCEDURE LLM_COMPLETE(P_PROMPT STRING, P_MODEL STRING, P_MAX_TOKENS NUMBER)
RETURNS OBJECT
LANGUAGE SQL
COMMENT = 'Deterministic Cortex COMPLETE call returning text and token usage.'
AS
$$
DECLARE
    v_sql STRING;
    v_out OBJECT;
    res   RESULTSET;
BEGIN
    -- Guard the only interpolated value. Model names are identifiers-ish:
    -- letters, digits, dot, dash, underscore. Anything else is rejected.
    IF (NOT RLIKE(:P_MODEL, '^[A-Za-z0-9._-]+$')) THEN
        RETURN OBJECT_CONSTRUCT('text', NULL, 'error', 'invalid model name');
    END IF;

    v_sql := 'SELECT OBJECT_CONSTRUCT('
          || '''text'',              resp:choices[0]:messages::STRING,'
          || '''prompt_tokens'',     resp:usage:prompt_tokens::NUMBER,'
          || '''completion_tokens'', resp:usage:completion_tokens::NUMBER,'
          || '''total_tokens'',      resp:usage:total_tokens::NUMBER,'
          || '''model'',             resp:model::STRING) AS o'
          || ' FROM (SELECT SNOWFLAKE.CORTEX.COMPLETE('
          || '''' || :P_MODEL || ''','
          || ' [ {''role'':''user'',''content'': ?} ],'
          || ' {''temperature'': 0, ''max_tokens'': ' || :P_MAX_TOKENS::STRING || '}'
          || ') AS resp)';

    res := (EXECUTE IMMEDIATE :v_sql USING (P_PROMPT));
    LET c CURSOR FOR res;
    OPEN c;
    FETCH c INTO v_out;
    CLOSE c;
    RETURN v_out;
END;
$$;

-- ---------------------------------------------------------------------
-- Strips markdown fencing that models add around JSON despite instructions,
-- then parses. Returns NULL on unparseable output so callers can record a
-- FAILED run rather than throwing.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION PARSE_LLM_JSON(P_TEXT STRING)
RETURNS VARIANT
LANGUAGE SQL
AS
$$
    SELECT TRY_PARSE_JSON(
        REGEXP_REPLACE(
            REGEXP_REPLACE(TRIM(P_TEXT), '^```[a-zA-Z]*[\\n\\r]*', ''),
            '```\\s*$', ''
        )
    )
$$;

-- ---------------------------------------------------------------------
-- Central run logger. Takes an OBJECT so agents do not need to be edited
-- when the log gains a column. Cost figures are estimates derived from
-- token counts and the rates in PLATFORM_CONFIG - they are labelled as
-- estimates everywhere they surface.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE LOG_RUN(P_LOG OBJECT)
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
    INSERT INTO CAPSTONE_AI_DLC.METRICS.AGENT_RUN_LOG
        (RUN_ID, AGENT_NAME, SDLC_PHASE, INPUT_REF, INPUT_PAYLOAD, RETRIEVED_CHUNKS,
         PROMPT_TEXT, MODEL_NAME, RESPONSE_RAW, OUTPUT_REF, STATUS, ERROR_MESSAGE,
         PROMPT_TOKENS, COMPLETION_TOKENS, TOTAL_TOKENS, EST_CREDITS, EST_USD,
         LATENCY_MS, ORCHESTRATOR, STARTED_AT, ENDED_AT)
    SELECT
        GET(:P_LOG,'run_id')::STRING,
        GET(:P_LOG,'agent_name')::STRING,
        GET(:P_LOG,'sdlc_phase')::STRING,
        GET(:P_LOG,'input_ref')::STRING,
        GET(:P_LOG,'input_payload'),
        GET(:P_LOG,'retrieved_chunks')::ARRAY,
        GET(:P_LOG,'prompt_text')::STRING,
        GET(:P_LOG,'model_name')::STRING,
        GET(:P_LOG,'response_raw')::STRING,
        GET(:P_LOG,'output_ref')::STRING,
        GET(:P_LOG,'status')::STRING,
        GET(:P_LOG,'error_message')::STRING,
        GET(:P_LOG,'prompt_tokens')::NUMBER,
        GET(:P_LOG,'completion_tokens')::NUMBER,
        GET(:P_LOG,'total_tokens')::NUMBER,
        GET(:P_LOG,'total_tokens')::NUMBER / 1000000.0
            * CAPSTONE_AI_DLC.GOVERNANCE.CFG('CREDITS_PER_M_TOKEN')::FLOAT,
        GET(:P_LOG,'total_tokens')::NUMBER / 1000000.0
            * CAPSTONE_AI_DLC.GOVERNANCE.CFG('CREDITS_PER_M_TOKEN')::FLOAT
            * CAPSTONE_AI_DLC.GOVERNANCE.CFG('CREDIT_USD')::FLOAT,
        GET(:P_LOG,'latency_ms')::NUMBER,
        COALESCE(GET(:P_LOG,'orchestrator')::STRING, 'MANUAL'),
        GET(:P_LOG,'started_at')::TIMESTAMP_NTZ,
        CURRENT_TIMESTAMP();
    RETURN GET(:P_LOG,'run_id')::STRING;
END;
$$;

-- ---------------------------------------------------------------------
-- Requirement intake. This is what arrives from the business: prose, not
-- a spec. The Requirements agent turns these into structured stories.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS CAPSTONE_AI_DLC.GOVERNANCE.REQUIREMENT_INTAKE (
    REQ_ID       STRING NOT NULL PRIMARY KEY,
    RAISED_BY    STRING,
    RAISED_AT    DATE,
    CHANNEL      STRING,
    SUBJECT      STRING,
    BODY         STRING NOT NULL,
    STATUS       STRING DEFAULT 'NEW'
);

DELETE FROM CAPSTONE_AI_DLC.GOVERNANCE.REQUIREMENT_INTAKE;

INSERT INTO CAPSTONE_AI_DLC.GOVERNANCE.REQUIREMENT_INTAKE
    (REQ_ID, RAISED_BY, RAISED_AT, CHANNEL, SUBJECT, BODY)
SELECT v.a, v.b, v.c::DATE, v.d, v.e, v.f
FROM VALUES
(
 'REQ-101','Group Finance Controller','2025-07-08','Email',
 'EMEA invoices missing from the consolidated AP view',
 'The EMEA manufacturing entities we picked up in the acquisition run on Baan and none of their payables show up in the consolidated AP invoice reporting. We are still stitching those in by hand every quarter. Can you get Baan feeding the same consolidated invoice table as SAP and Oracle so vendor spend is complete? The cost centre codes come out of Baan with a region prefix on the front which will not match how we report cost centres elsewhere. Payment terms are coded differently again in Baan. We need this for the Q3 close.'
),
(
 'REQ-102','Shared Services Manager (Americas)','2025-07-11','Service Desk Ticket',
 'Please add Workday AP invoices to consolidated reporting',
 'Now that Baan is being added, please also include the Workday Financials invoices from the Americas shared services tenant in the consolidated AP invoice table. Same treatment as the other sources. This would let us retire the monthly Workday extract we email to Finance.'
),
(
 'REQ-103','Group Finance Controller','2025-07-15','Email',
 'CFO review pack - large invoice visibility',
 'The CFO wants a monthly view of vendor spend that clearly separates out the very large invoices, since those are the ones going through additional review. We report in USD at group level even though invoices are raised in local currency. It needs to be stable - if an invoice was large last month it should still show as large this month, the classification should not move around because exchange rates moved.'
) AS v(a,b,c,d,e,f);

SELECT REQ_ID, SUBJECT, LENGTH(BODY) AS chars FROM CAPSTONE_AI_DLC.GOVERNANCE.REQUIREMENT_INTAKE ORDER BY REQ_ID;
