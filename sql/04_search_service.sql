-- =====================================================================
-- 04_search_service.sql -- the Cortex Search index over the corpus
--
-- Run order: 02_knowledge_layer.sql -> 03_knowledge_seed.sql ->
--            CALL GOVERNANCE.REBUILD_KNOWLEDGE_CHUNKS() -> this file.
--
-- Cortex Search is used rather than a hand-rolled cosine-similarity search
-- over EMBED_TEXT vectors: it gives hybrid lexical + semantic matching with
-- reranking, and keeps itself in sync with the base table on TARGET_LAG.
-- Lexical matching matters here because the queries contain exact tokens
-- that must hit -- column names, rule ids like BR-004, codes like T90.
-- =====================================================================

USE DATABASE CAPSTONE_AI_DLC;
USE SCHEMA GOVERNANCE;

CALL REBUILD_KNOWLEDGE_CHUNKS();

CREATE OR REPLACE CORTEX SEARCH SERVICE KB_SEARCH
  ON CHUNK_TEXT
  ATTRIBUTES DOC_ID, DOC_TYPE, TITLE
  WAREHOUSE = COMPUTE_WH
  TARGET_LAG = '1 hour'
  COMMENT = 'RAG index over governing docs: PRD, data contract, standards, patterns, test taxonomy, business rules.'
  AS SELECT CHUNK_ID, DOC_ID, DOC_TYPE, TITLE, CHUNK_TEXT
     FROM KNOWLEDGE_CHUNKS;

-- Retrieval smoke test. The expected result is that BR-004 from the PRD and
-- the cost-centre section of BR-NORM-001 are returned - i.e. retrieval finds
-- the governing clause, not merely topically similar text.
CALL RETRIEVE_CONTEXT(
    'How should Baan IV cost centre prefixes be handled when loading COST_CENTER_OR_DEPT?', 3);
