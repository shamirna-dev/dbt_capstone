-- =====================================================================
-- 06_agent_req2story.sql -- Agent 1: requirements prose -> user stories
--
-- SDLC phase: REQUIREMENTS
--
-- What makes this more than a prompt wrapper:
--  * It is grounded in the governance corpus, so it produces acceptance
--    criteria that cite the data contract and business rules rather than
--    inventing plausible-sounding ones.
--  * It is required to detect governance conflicts. REQ-102 asks for
--    Workday, which PRD-AP-2025-001 explicitly blocks pending a DPA. An
--    ungrounded model will happily write stories for it. A grounded one
--    should refuse and say why. That difference is the measurable value.
-- =====================================================================

USE DATABASE CAPSTONE_AI_DLC;
USE SCHEMA AGENTS;

CREATE OR REPLACE PROCEDURE AGENT_REQ2STORY(P_REQ_ID STRING, P_ORCHESTRATOR STRING)
RETURNS OBJECT
LANGUAGE SQL
COMMENT = 'Turns a raw business requirement into governed, cited user stories.'
AS
$$
DECLARE
    v_run_id      STRING;
    v_started     TIMESTAMP_NTZ;
    v_subject     STRING;
    v_body        STRING;
    v_query       STRING;
    v_ctx         OBJECT;
    v_context     STRING;
    v_citations   ARRAY;
    v_contract    STRING;
    v_prompt      STRING;
    v_llm         OBJECT;
    v_raw         STRING;
    v_json        VARIANT;
    v_stories     ARRAY;
    v_n           NUMBER DEFAULT 0;
    v_top_k       NUMBER;
BEGIN
    v_run_id  := UUID_STRING();
    v_started := CURRENT_TIMESTAMP();
    v_top_k   := CAPSTONE_AI_DLC.GOVERNANCE.CFG('RAG_TOP_K')::NUMBER;

    SELECT SUBJECT, BODY INTO :v_subject, :v_body
    FROM CAPSTONE_AI_DLC.GOVERNANCE.REQUIREMENT_INTAKE WHERE REQ_ID = :P_REQ_ID;

    IF (v_body IS NULL) THEN
        RETURN OBJECT_CONSTRUCT('status','FAILED','error','unknown REQ_ID: ' || :P_REQ_ID);
    END IF;

    -- Retrieve on the requirement itself plus scope/priority language, so the
    -- retrieval surfaces both the relevant business rules and any statement
    -- that the request is out of scope or blocked.
    v_query := :v_subject || ' ' || :v_body ||
               ' scope priority blocked prerequisites data contract required columns';
    CALL CAPSTONE_AI_DLC.GOVERNANCE.RETRIEVE_CONTEXT(:v_query, :v_top_k) INTO :v_ctx;
    v_context   := GET(:v_ctx,'context_text')::STRING;
    v_citations := GET(:v_ctx,'citations')::ARRAY;

    -- The target contract is passed as data, not prose, so stories reference
    -- real column names and real required/optional flags.
    SELECT LISTAGG(COLUMN_NAME || ' ' || DATA_TYPE ||
                   CASE WHEN IS_REQUIRED THEN ' NOT NULL' ELSE ' NULL' END ||
                   CASE WHEN IS_BUSINESS_KEY THEN ' [business key]' ELSE '' END ||
                   CASE WHEN ALLOWED_VALUES IS NOT NULL
                        THEN ' allowed=' || ARRAY_TO_STRING(ALLOWED_VALUES, '|') ELSE '' END,
                   '\n') WITHIN GROUP (ORDER BY ORDINAL)
      INTO :v_contract
    FROM CAPSTONE_AI_DLC.GOVERNANCE.TARGET_CONTRACT
    WHERE TARGET_TABLE = 'SILVER_AP_INVOICES';

    v_prompt :=
'You are a senior data business analyst on a Snowflake data platform team. You convert raw business requests into implementation-ready user stories for a data engineering backlog.

You must work ONLY from the GOVERNING CONTEXT below. It is the authoritative project documentation. Do not rely on general knowledge about ERP systems.

GOVERNING CONTEXT (each block is prefixed with its citation id in square brackets):
' || :v_context || '

TARGET TABLE CONTRACT for SILVER_AP_INVOICES:
' || :v_contract || '

INCOMING REQUEST
Reference: ' || :P_REQ_ID || '
Subject: ' || :v_subject || '
Body: ' || :v_body || '

YOUR TASK
Produce user stories that implement this request.

HARD RULES
1. Before writing any story, check the governing context for anything that blocks,
   descopes or defers this request. If the request is blocked or out of scope, you
   MUST return zero stories and instead populate "governance_conflict" explaining
   what blocks it and citing the chunk id. Do not write stories for blocked work.
2. Every acceptance criterion must be objectively testable and must reflect a rule
   that appears in the governing context. Do not invent thresholds, codes or
   mappings. If the context gives a specific code or value, use it verbatim.
3. Cite the chunk ids you relied on, per story, in "citations".
4. Use exact column names from the target contract.
5. If the governing context leaves something genuinely undetermined, put it in
   "open_questions" rather than guessing.
6. Story points from the sequence 1,2,3,5,8,13. Priority from HIGH, MEDIUM, LOW,
   taken from the governing context where it states one.
7. Completeness matters as much as correctness. Walk the governing context and
   ensure every distinct transformation rule in scope has a story that covers it -
   including each normalisation mapping, each prefix or format rule, each
   quarantine or permitted-value rule, and each stated non-functional requirement.
   Prefer several precise stories over one broad story that silently drops a rule.
   Do not merge unrelated rules into a single story.
8. Name the exact target object each story acts on. Where the governing context
   states which layer an attribute belongs to, use that layer and do not propose
   adding it elsewhere.

Return ONLY valid JSON, no markdown fence, matching exactly:
{
  "governance_conflict": null,
  "stories": [
    {
      "epic": "string",
      "title": "string",
      "as_a": "string",
      "i_want": "string",
      "so_that": "string",
      "acceptance_criteria": ["string"],
      "source_to_target": [{"source_column":"string","target_column":"string","rule":"string"}],
      "story_points": 3,
      "priority": "HIGH",
      "dependencies": ["string"],
      "open_questions": ["string"],
      "citations": ["chunk-id"]
    }
  ]
}
If blocked, set "governance_conflict" to {"reason":"string","citations":["chunk-id"]} and "stories" to [].';

    CALL CAPSTONE_AI_DLC.AGENTS.LLM_COMPLETE(
             :v_prompt, CAPSTONE_AI_DLC.GOVERNANCE.CFG('DEFAULT_MODEL'), 8192) INTO :v_llm;
    v_raw  := GET(:v_llm,'text')::STRING;
    v_json := CAPSTONE_AI_DLC.AGENTS.PARSE_LLM_JSON(:v_raw);

    IF (v_json IS NULL) THEN
        CALL CAPSTONE_AI_DLC.AGENTS.LOG_RUN(OBJECT_CONSTRUCT(
            'run_id', :v_run_id, 'agent_name','AGENT_REQ2STORY', 'sdlc_phase','REQUIREMENTS',
            'input_ref', :P_REQ_ID, 'input_payload', OBJECT_CONSTRUCT('subject', :v_subject),
            'retrieved_chunks', :v_citations, 'prompt_text', :v_prompt,
            'model_name', GET(:v_llm,'model')::STRING, 'response_raw', :v_raw,
            'status','FAILED', 'error_message','model did not return parseable JSON',
            'prompt_tokens', GET(:v_llm,'prompt_tokens'), 'completion_tokens', GET(:v_llm,'completion_tokens'),
            'total_tokens', GET(:v_llm,'total_tokens'),
            'latency_ms', DATEDIFF('millisecond', :v_started, CURRENT_TIMESTAMP()),
            'orchestrator', :P_ORCHESTRATOR, 'started_at', :v_started));
        RETURN OBJECT_CONSTRUCT('run_id', :v_run_id, 'status','FAILED',
                                'error','unparseable model output');
    END IF;

    -- A declared governance conflict is a successful run with zero stories,
    -- not a failure. This is the outcome we want for blocked requests.
    IF (v_json:governance_conflict IS NOT NULL
        AND v_json:governance_conflict::STRING NOT IN ('null','')) THEN
        CALL CAPSTONE_AI_DLC.AGENTS.LOG_RUN(OBJECT_CONSTRUCT(
            'run_id', :v_run_id, 'agent_name','AGENT_REQ2STORY', 'sdlc_phase','REQUIREMENTS',
            'input_ref', :P_REQ_ID,
            'input_payload', OBJECT_CONSTRUCT('subject', :v_subject,
                                              'governance_conflict', :v_json:governance_conflict),
            'retrieved_chunks', :v_citations, 'prompt_text', :v_prompt,
            'model_name', GET(:v_llm,'model')::STRING, 'response_raw', :v_raw,
            'output_ref','GOVERNANCE_CONFLICT', 'status','REJECTED',
            'error_message', :v_json:governance_conflict:reason::STRING,
            'prompt_tokens', GET(:v_llm,'prompt_tokens'), 'completion_tokens', GET(:v_llm,'completion_tokens'),
            'total_tokens', GET(:v_llm,'total_tokens'),
            'latency_ms', DATEDIFF('millisecond', :v_started, CURRENT_TIMESTAMP()),
            'orchestrator', :P_ORCHESTRATOR, 'started_at', :v_started));

        UPDATE CAPSTONE_AI_DLC.GOVERNANCE.REQUIREMENT_INTAKE
           SET STATUS = 'BLOCKED' WHERE REQ_ID = :P_REQ_ID;

        RETURN OBJECT_CONSTRUCT('run_id', :v_run_id, 'status','GOVERNANCE_CONFLICT',
                                'stories_created', 0,
                                'conflict', :v_json:governance_conflict);
    END IF;

    v_stories := :v_json:stories::ARRAY;

    INSERT INTO CAPSTONE_AI_DLC.ARTIFACTS.USER_STORIES
        (STORY_ID, RUN_ID, SOURCE_DOC_ID, EPIC, TITLE, AS_A, I_WANT, SO_THAT,
         ACCEPTANCE_CRITERIA, SOURCE_TO_TARGET, STORY_POINTS, PRIORITY,
         DEPENDENCIES, OPEN_QUESTIONS, CITATIONS, STATUS)
    SELECT
        :P_REQ_ID || '-S' || LPAD((s.INDEX + 1)::STRING, 2, '0'),
        :v_run_id, :P_REQ_ID,
        s.VALUE:epic::STRING, s.VALUE:title::STRING, s.VALUE:as_a::STRING,
        s.VALUE:i_want::STRING, s.VALUE:so_that::STRING,
        s.VALUE:acceptance_criteria::ARRAY, s.VALUE:source_to_target,
        s.VALUE:story_points::NUMBER, s.VALUE:priority::STRING,
        s.VALUE:dependencies::ARRAY, s.VALUE:open_questions::ARRAY,
        s.VALUE:citations::ARRAY, 'DRAFT'
    FROM TABLE(FLATTEN(input => :v_stories)) s;

    v_n := SQLROWCOUNT;

    CALL CAPSTONE_AI_DLC.AGENTS.LOG_RUN(OBJECT_CONSTRUCT(
        'run_id', :v_run_id, 'agent_name','AGENT_REQ2STORY', 'sdlc_phase','REQUIREMENTS',
        'input_ref', :P_REQ_ID, 'input_payload', OBJECT_CONSTRUCT('subject', :v_subject),
        'retrieved_chunks', :v_citations, 'prompt_text', :v_prompt,
        'model_name', GET(:v_llm,'model')::STRING, 'response_raw', :v_raw,
        'output_ref', :P_REQ_ID || ' stories=' || :v_n::STRING, 'status','SUCCESS',
        'prompt_tokens', GET(:v_llm,'prompt_tokens'), 'completion_tokens', GET(:v_llm,'completion_tokens'),
        'total_tokens', GET(:v_llm,'total_tokens'),
        'latency_ms', DATEDIFF('millisecond', :v_started, CURRENT_TIMESTAMP()),
        'orchestrator', :P_ORCHESTRATOR, 'started_at', :v_started));

    UPDATE CAPSTONE_AI_DLC.GOVERNANCE.REQUIREMENT_INTAKE
       SET STATUS = 'STORIES_DRAFTED' WHERE REQ_ID = :P_REQ_ID;

    RETURN OBJECT_CONSTRUCT('run_id', :v_run_id, 'status','SUCCESS',
                            'stories_created', :v_n, 'citations', :v_citations);
END;
$$;
