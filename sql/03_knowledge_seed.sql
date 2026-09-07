-- =====================================================================
-- 03_knowledge_seed.sql -- the governing corpus the agents are grounded in
--
-- These are the documents a real data engagement would hold in Confluence:
-- a PRD, a data contract, coding standards, DT patterns, a test taxonomy
-- and normalisation business rules. They are deliberately specific and
-- contain decisions an LLM could not guess, which is what makes RAG
-- grounding measurable rather than decorative.
-- =====================================================================

USE DATABASE CAPSTONE_AI_DLC;
USE SCHEMA GOVERNANCE;

DELETE FROM KNOWLEDGE_DOCS;

-- ------------------------------------------------------------------ PRD
INSERT INTO KNOWLEDGE_DOCS (DOC_ID, DOC_TYPE, TITLE, OWNER, VERSION, EFFECTIVE_DATE, BODY)
SELECT 'PRD-AP-2025-001', 'PRD',
       'PRD: Onboard Baan IV (EMEA) into the Consolidated AP Invoice Pipeline',
       'Finance Data Product Owner', 'v1.3', '2025-07-01', $$
# PRD-AP-2025-001 -- Onboard Baan IV (EMEA) into the Consolidated AP Invoice Pipeline

## Background
The consolidated accounts-payable reporting layer (SILVER_AP_INVOICES) currently
ingests SAP (global) and Oracle EBS (Americas). Following the 2024 acquisition of
the EMEA manufacturing division, a third ERP -- Infor Baan IV -- must be onboarded.
A fourth source, Workday Financials (Americas shared services), is planned but is
NOT in scope for this release.

## Business objective
Give Group Finance a single vendor-spend view covering 100% of legal entities so
that the quarterly supplier consolidation exercise stops relying on four manual
spreadsheet extracts. Current manual effort is approximately 6 analyst-days per
quarter.

## Priority and sequencing
- Baan IV onboarding: HIGH priority, committed for Q3 2025.
- Workday onboarding: MEDIUM priority, explicitly blocked pending a signed Data
  Processing Agreement with the Workday tenant owner. Do not build Workday
  transformations in this release. Scaffolding may be prepared but must not be
  scheduled or materialised.

## Functional requirements

### BR-001 Source ingestion
All Baan IV AP invoice records must land in the Bronze layer unmodified, retaining
original column names, so that the raw extract remains auditable against the
source system. No filtering, deduplication or type coercion at Bronze.

### BR-002 Silver conformance
Baan records must be conformed to the SILVER_AP_INVOICES contract and unioned with
the existing SAP and Oracle streams. SOURCE_SYSTEM must be set to the literal
'BAAN'. The union must be UNION ALL -- distinct-based unions previously caused a
silent 4% row loss when two sources legitimately shared an invoice number.

### BR-003 Invoice key construction
INVOICE_KEY must be deterministic and stable across reloads. Construct it as
SOURCE_SYSTEM || '-' || the source natural key. It must never be built from a
sequence, a ROW_NUMBER() or a hash of the full row, because downstream
reconciliation joins on INVOICE_KEY across refreshes.

### BR-004 Cost centre format change
Every source records cost centres with a system-specific prefix followed by a
hyphen: SAP 'CC-ENG-01', Oracle 'D-ENG', Baan 'BC-MFG', Workday 'WCC-TECH'. The
consolidated layer expects the cost centre with that leading system prefix
removed, i.e. everything up to and including the FIRST hyphen is stripped:
'CC-ENG-01' becomes 'ENG-01' and 'BC-MFG' becomes 'MFG'. Note this must strip on
the first hyphen, not the last -- stripping on the last hyphen would reduce the
SAP value 'CC-ENG-01' to '01' and lose the cost centre entirely.
Baan release 4.7c introduced the prefix; extracts taken before 2024-11-01 have no
prefix at all, so the transformation must tolerate a value with no hyphen and pass
it through unchanged rather than blindly splitting.

### BR-005 Payment terms normalisation
Each source encodes payment terms differently. A shared normalisation layer must
map all source encodings to the canonical NETnn form. See BR-NORM-001 for the
authoritative mapping table. Unmapped codes must pass through as NULL and be
reported, never silently defaulted to NET30 -- an earlier defaulting bug
understated the average days-payable-outstanding metric by 11 days.

### BR-006 High-value invoice flag
Invoices with a USD-equivalent gross amount at or above 75,000 must be flagged
for the CFO review report.

The flag is a reporting concern and belongs in the GOLD layer, as a column named
HIGH_VALUE_FLAG on GOLD_AP_INVOICE_REVIEW. It must NOT be added to
SILVER_AP_INVOICES: the Silver contract DC-SILVER-AP-001 is a conformance contract
and is not extended with derived reporting attributes. Any request to add
HIGH_VALUE_FLAG to Silver should be redirected to Gold.

USD equivalence must be computed using the frozen reference rates published in
BR-NORM-001 for the invoice's CURRENCY_CODE. Those rates are fixed for the whole
2025 reporting year - there is deliberately no per-date rate table - so an invoice
classified as high value stays classified that way regardless of subsequent
currency movement. Do not use a live or current-date FX rate, and do not look for
a date-varying rate: it does not exist.

### BR-007 Approval status normalisation
Source approval states must be mapped to the canonical set APPROVED, PENDING,
REJECTED, PAID. The authoritative per-source mapping is in BR-NORM-001. Note that
the Baan 4.7c extracts now being received use word values such as POSTED,
APPROVED and PENDING; the single-character codes described in older internal notes
belong to Baan 4.6 and must not be coded against.

## Non-functional requirements
- Silver layer freshness target: 60 minutes.
- The pipeline must be incremental. Full refreshes of the Silver layer are not
  acceptable beyond the initial backfill.
- No production PII may be used in any non-production environment. All lower
  environments must be populated with synthetic data.

## Explicitly out of scope
- Cross-source duplicate invoice detection. Group Finance has confirmed the same
  physical invoice is never entered into two ERPs, so no dedup logic is required.
  This assumption should be monitored with a data quality check but not enforced.
- Currency revaluation and FX gain/loss reporting.
- Vendor master data harmonisation. Vendor identifiers remain source-scoped in
  this release.

## Open questions
- Q1: Does the EMEA division use Baan company codes that overlap with SAP company
  codes? If so SOURCE_ORG_CODE may not be unique across sources.
- Q2: Confirm whether Baan 'held' status invoices should map to PENDING or be
  excluded entirely.
$$;

-- -------------------------------------------------------- DATA CONTRACT
INSERT INTO KNOWLEDGE_DOCS (DOC_ID, DOC_TYPE, TITLE, OWNER, VERSION, EFFECTIVE_DATE, BODY)
SELECT 'DC-SILVER-AP-001', 'DATA_CONTRACT',
       'Data Contract: SILVER_AP_INVOICES', 'Data Platform Team', 'v2.1', '2025-06-15', $$
# Data Contract: SILVER_AP_INVOICES

## Purpose
The conformed, source-agnostic accounts-payable invoice fact. One row per invoice
per source system. This is the only sanctioned input for AP spend reporting.

## Grain
One row per (SOURCE_SYSTEM, SOURCE_INVOICE_ID). INVOICE_KEY is unique and not null.

## Column specification

| Column | Type | Required | Notes |
|---|---|---|---|
| INVOICE_KEY | STRING | yes | Unique. SOURCE_SYSTEM || '-' || SOURCE_INVOICE_ID |
| SOURCE_SYSTEM | STRING | yes | One of SAP, ORACLE, BAAN, WORKDAY |
| SOURCE_INVOICE_ID | STRING | yes | Natural key in the source |
| INVOICE_NUMBER | STRING | yes | Human-readable; NOT unique across sources |
| VENDOR_ID | STRING | yes | Source-scoped, not harmonised |
| VENDOR_NAME | STRING | yes | Trimmed, no case normalisation |
| INVOICE_DATE | DATE | yes | Must not be in the future |
| DUE_DATE | DATE | no | When present must be >= INVOICE_DATE |
| INVOICE_AMOUNT | NUMBER(18,2) | yes | Gross, in CURRENCY_CODE. Must be > 0 |
| CURRENCY_CODE | STRING | yes | ISO 4217. Permitted: USD, EUR, GBP |
| PAYMENT_TERMS | STRING | no | Canonical NETnn or NULL. Never defaulted |
| PO_NUMBER | STRING | no | NULL where not PO-matched |
| LINE_DESCRIPTION | STRING | no | Free text |
| GL_ACCOUNT | STRING | no | Source GL code, not harmonised |
| COST_CENTER_OR_DEPT | STRING | no | System prefix stripped at first hyphen |
| APPROVAL_STATUS | STRING | yes | One of APPROVED, PENDING, REJECTED, PAID |
| CREATED_AT | TIMESTAMP_NTZ | yes | Source record creation time |
| SOURCE_ORG_CODE | STRING | no | Company code / org id / tenant id |
| SOURCE_DOCUMENT_TYPE | STRING | no | Where the source supplies one |
| SOURCE_ENTRY_METHOD | STRING | no | Where the source supplies one |

## Guarantees to consumers
- INVOICE_KEY is stable across refreshes. A given source invoice keeps its key forever.
- No row is ever hard-deleted. Reversals appear as new rows.
- Required columns are never NULL. A source row that cannot satisfy the required
  set is quarantined, not silently loaded with NULLs.

## Breaking-change policy
Adding a nullable column is non-breaking. Removing a column, tightening a type,
or changing INVOICE_KEY construction is breaking and requires consumer sign-off
plus a two-release deprecation window.
$$;

-- ------------------------------------------------------ CODING STANDARD
INSERT INTO KNOWLEDGE_DOCS (DOC_ID, DOC_TYPE, TITLE, OWNER, VERSION, EFFECTIVE_DATE, BODY)
SELECT 'STD-SQL-001', 'CODING_STANDARD',
       'Snowflake SQL and dbt Coding Standards', 'Data Platform Team', 'v3.0', '2025-01-10', $$
# Snowflake SQL and dbt Coding Standards

## Naming
- Layers are prefixed: BRONZE_, SILVER_, GOLD_.
- Source-specific Bronze models: BRONZE_<SOURCE>_<ENTITY>, e.g. BRONZE_BAAN_AP_INVOICES.
- Staging models that conform a single source to the target contract:
  STG_<SOURCE>_<ENTITY>, e.g. STG_BAAN_AP_INVOICES. One staging model per source.
- All identifiers UPPER_SNAKE_CASE. No quoted lower-case identifiers.

## Structure
- Every model begins with a CTE named `source` selecting from exactly one ref()
  or source(). No SELECT * in a final projection -- always enumerate columns in
  target-contract order.
- Conformance logic lives in one CTE named `renamed`, business logic in `logic`,
  and the model ends with `SELECT ... FROM logic`.
- One transformation concern per CTE. Do not combine renaming and business rules.

## Required practices
- Always use UNION ALL, never UNION, when combining source streams. UNION's
  implicit distinct has silently dropped legitimate rows in this codebase before.
- Always cast explicitly at the staging boundary: `col::NUMBER(18,2)`. Never rely
  on implicit coercion.
- Use TRY_TO_DATE / TRY_TO_NUMBER when parsing source text fields so a single bad
  value quarantines one row rather than failing the whole model.
- NULL handling must be explicit. Use COALESCE only where the contract permits a
  default; otherwise let NULL propagate.
- Divisions must be guarded: use NULLIF(denominator, 0).
- Never use SELECT DISTINCT to fix a fan-out. Fix the join grain instead.

## Prohibited
- ROW_NUMBER() or sequences for surrogate keys on conformed facts. Keys must be
  deterministic from natural keys.
- CURRENT_DATE() or CURRENT_TIMESTAMP() inside incremental model logic -- it makes
  refreshes non-reproducible. Pass an as-of parameter instead.
- Hard-coded environment names, database names or warehouse names inside models.

## dbt conventions
- Materialisation for Bronze: view. Silver: dynamic_table. Gold: dynamic_table.
- Every model has a schema.yml entry with a description and at least one test on
  the grain column.
- Tests on required contract columns are not_null; on the grain column,
  unique + not_null; on enumerated columns, accepted_values.
$$;

-- ------------------------------------------------------------- PATTERNS
INSERT INTO KNOWLEDGE_DOCS (DOC_ID, DOC_TYPE, TITLE, OWNER, VERSION, EFFECTIVE_DATE, BODY)
SELECT 'STD-DT-002', 'PATTERN',
       'Dynamic Table Patterns for Incremental Conformance', 'Data Platform Team', 'v1.4', '2025-03-20', $$
# Dynamic Table Patterns for Incremental Conformance

## When to use a Dynamic Table
Use a Dynamic Table for any conformed layer that must stay fresh without bespoke
orchestration. Prefer it over a task-plus-merge pattern unless you need
row-level upsert semantics that DTs cannot express.

## Standard Silver conformance DT
```sql
CREATE OR REPLACE DYNAMIC TABLE SILVER_<ENTITY>
    TARGET_LAG = '60 minutes'
    WAREHOUSE  = COMPUTE_WH
    REFRESH_MODE = INCREMENTAL
    INITIALIZE = ON_CREATE
AS
SELECT ... FROM STG_<SOURCE_A>
UNION ALL
SELECT ... FROM STG_<SOURCE_B>;
```

## Rules that keep a DT incremental
Snowflake silently downgrades a Dynamic Table to full refresh when the query
contains constructs it cannot incrementalise. The following are the ones that
have bitten this codebase:
- Non-deterministic functions: CURRENT_TIMESTAMP(), RANDOM(), UUID_STRING().
- Window functions with ORDER BY over the full partition where the ordering key
  is not persisted.
- LATERAL FLATTEN over a column that changes shape.
- Aggregations at the top level of the DT query -- push them into a downstream DT.

Always confirm the refresh mode actually achieved after creation:
```sql
SELECT NAME, REFRESH_MODE, REFRESH_MODE_REASON
FROM   INFORMATION_SCHEMA.DYNAMIC_TABLES
WHERE  NAME = '<name>';
```
If REFRESH_MODE came back FULL when INCREMENTAL was requested, treat it as a
defect, not a warning.

## Target lag guidance
- Set the Silver lag to the business freshness requirement, not lower. Every
  reduction multiplies warehouse cost.
- Downstream Gold DTs should use TARGET_LAG = DOWNSTREAM so the chain is pulled
  by demand rather than each layer polling independently.
$$;

-- -------------------------------------------------------- TEST TAXONOMY
INSERT INTO KNOWLEDGE_DOCS (DOC_ID, DOC_TYPE, TITLE, OWNER, VERSION, EFFECTIVE_DATE, BODY)
SELECT 'QA-TAX-001', 'TEST_TAXONOMY',
       'Data Quality Test Taxonomy and Severity Model', 'QA Lead - Data', 'v2.0', '2025-05-05', $$
# Data Quality Test Taxonomy and Severity Model

Every conformed table must carry at least one test from each applicable category.
A test is written as an assertion query that returns ZERO rows when the data is
correct; any returned row is a violation.

## Categories

### NOT_NULL -- severity CRITICAL
Every column marked required in the data contract. Violation blocks release.

### UNIQUENESS -- severity CRITICAL
The declared grain. For SILVER_AP_INVOICES this is INVOICE_KEY. Test for
duplicate keys, not just count-vs-distinct-count, so the failing keys are visible.

### ACCEPTED_VALUES -- severity HIGH
Any column with an enumerated domain in the contract: SOURCE_SYSTEM,
CURRENCY_CODE, APPROVAL_STATUS. Must assert the value is IN the permitted set,
and must treat an unexpected new value as a failure rather than ignoring it.

### BOUNDARY -- severity HIGH
Numeric and date range rules stated in the contract:
- INVOICE_AMOUNT must be strictly greater than zero.
- INVOICE_DATE must not be in the future.
- DUE_DATE, when not null, must be on or after INVOICE_DATE.

### REFERENTIAL -- severity HIGH
Conformed rows must trace back to a Bronze row. For every Silver row of a given
SOURCE_SYSTEM there must exist a matching Bronze record on the natural key.
Orphaned Silver rows indicate a join or filter defect.

### TYPE_VIOLATION -- severity MEDIUM
Source text fields that are parsed into typed columns must not produce silent
NULLs. Compare the count of non-null source values against the count of
successfully parsed target values; a gap is a violation.

### RECONCILIATION -- severity CRITICAL
Row counts and summed amounts must agree between Bronze and Silver per source
system, allowing only documented quarantine exclusions. This is the test that
catches the UNION-instead-of-UNION-ALL class of defect.

### VOLUME -- severity MEDIUM
Row count per source per load must fall within an expected band. A source
delivering zero rows is a failure, not an empty success.

### FRESHNESS -- severity HIGH
MAX(CREATED_AT) must be within the stated freshness target of the contract.

## Severity model
- CRITICAL -- blocks promotion. Pipeline halts.
- HIGH -- blocks promotion to production, warns in lower environments.
- MEDIUM -- raises a defect, does not block.
- LOW -- informational trend only.

## Test authoring rules
- Assertion SQL must be fully qualified and must not depend on session context.
- Every test must state which defect class it is designed to catch, so the test
  suite can itself be validated by injecting that defect and confirming the test
  fails.
- A test that cannot be made to fail by any injected defect is a tautology and
  must be removed.
$$;

-- -------------------------------------------------------- BUSINESS RULES
INSERT INTO KNOWLEDGE_DOCS (DOC_ID, DOC_TYPE, TITLE, OWNER, VERSION, EFFECTIVE_DATE, BODY)
SELECT 'BR-NORM-001', 'BUSINESS_RULE',
       'Normalisation Mappings: Payment Terms, Approval Status, Cost Centre', 'Finance Data Steward', 'v1.6', '2025-06-30', $$
# Normalisation Mappings

These mappings were reconciled against the actual source extracts on 2025-06-30.
An earlier revision of this document listed Baan 'T'-series term codes and
single-character status codes; those belong to Baan 4.6 and are not present in the
4.7c extracts now being received. The tables below are authoritative.

## Payment terms -- canonical form NETnn
The canonical representation is the string 'NET' followed by the net days with no
separator, e.g. NET30, NET60. Immediate payment is NET00.

| Source | Source code | Canonical |
|---|---|---|
| SAP | NET30 | NET30 |
| SAP | NET60 | NET60 |
| ORACLE | N30 | NET30 |
| ORACLE | N60 | NET60 |
| BAAN | N30 | NET30 |
| BAAN | N60 | NET60 |
| WORKDAY | Net 30 | NET30 |
| WORKDAY | Net 60 | NET60 |

Any code not in this table maps to NULL and must be surfaced by a data quality
check. It must NOT be defaulted to NET30. Defaulting previously understated
days-payable-outstanding by 11 days across the EMEA portfolio. In particular do
not infer a mapping from an unseen code by pattern similarity -- an unrecognised
code is a data quality signal, not something to guess at.

## Approval status -- canonical set APPROVED, PENDING, REJECTED, PAID

| Source | Source value | Canonical |
|---|---|---|
| SAP | APPROVED | APPROVED |
| SAP | PENDING | PENDING |
| ORACLE | VALIDATED | APPROVED |
| ORACLE | APPROVED | APPROVED |
| ORACLE | PENDING | PENDING |
| BAAN | POSTED | APPROVED |
| BAAN | APPROVED | APPROVED |
| BAAN | PENDING | PENDING |
| WORKDAY | Approved | APPROVED |
| WORKDAY | In Review | PENDING |

APPROVAL_STATUS is a required column, so an unmapped status value cannot be
loaded as NULL. A row whose status does not map must be quarantined and reported.

## Cost centre
Target form strips the leading system prefix: remove everything up to and
including the FIRST hyphen. Where no hyphen is present, pass the value through
unchanged.

| Source | Column | Example in | Example out |
|---|---|---|---|
| SAP | COST_CENTER | CC-ENG-01 | ENG-01 |
| ORACLE | DEPT_CODE | D-ENG | ENG |
| BAAN | BAN_COST_CTR | BC-MFG | MFG |
| WORKDAY | WD_COST_CENTER | WCC-TECH | TECH |

Do not strip on the last hyphen. 'CC-ENG-01' must become 'ENG-01', not '01'.

## Currency
No conversion is performed at Silver except for the high-value flag in BR-006.
Permitted ISO codes are USD, EUR and GBP. Any other code is a contract violation
and the row must be quarantined.

## Reference USD spot rates for the high-value threshold (BR-006)
Use these fixed rates for the whole 2025 reporting year. They are deliberately
frozen so the high-value flag is reproducible. There is no per-date rate table and
none should be sought: the rate depends only on the currency.

| Currency | Rate to USD |
|---|---|
| USD | 1.00 |
| EUR | 1.09 |
| GBP | 1.27 |
$$;

SELECT DOC_ID, DOC_TYPE, LENGTH(BODY) AS body_chars FROM KNOWLEDGE_DOCS ORDER BY DOC_ID;
