"""
Capstone dashboard: AI-accelerated data SDLC/STLC on Snowflake.

Reporting principle for this page: every number shown was measured on this
account, and each one is displayed with the method that produced it and the
reason it might mislead. There is deliberately no productivity-uplift figure,
because this build had no human-baseline control arm to compare against. A
percentage without a denominator is a marketing claim, not evidence.
"""

import altair as alt
import pandas as pd
import streamlit as st
from snowflake.snowpark.context import get_active_session

st.set_page_config(page_title="AI Data SDLC Capstone", layout="wide")
session = get_active_session()

DB = "CAPSTONE_AI_DLC"


@st.cache_data(ttl=120)
def q(sql: str) -> pd.DataFrame:
    return session.sql(sql).to_pandas()


st.title("AI-Accelerated Data SDLC / STLC")
st.caption(
    "Requirements to a tested, governed Snowflake pipeline. Built entirely on "
    "Snowflake — Cortex for generation, Cortex Search for retrieval, stored "
    "procedures as agents, Dynamic Tables as the pipeline — with n8n providing "
    "the human approval gate."
)

tab_overview, tab_evidence, tab_pipeline, tab_trace, tab_cost = st.tabs(
    ["Overview", "Evidence", "Pipeline & QA", "Traceability", "Cost"]
)

# ---------------------------------------------------------------- Overview
with tab_overview:
    h = q(f"SELECT * FROM {DB}.METRICS.V_HEADLINE").iloc[0]

    c1, c2, c3, c4 = st.columns(4)
    c1.metric("Agent runs", int(h.AGENT_RUNS))
    c2.metric("Artifacts produced",
              int(h.USER_STORIES) + int(h.CODE_ARTIFACTS) + int(h.TESTS))
    c3.metric("Injected defects caught",
              f"{int(h.DEFECTS_CAUGHT)}/{int(h.DEFECTS_INJECTED)}")
    c4.metric("Est. LLM cost", f"${float(h.EST_USD_TOTAL):.2f}")

    c1, c2, c3, c4 = st.columns(4)
    c1.metric("Governance refusals", int(h.GOVERNANCE_REFUSALS),
              help="Requests the agents declined because the governing documents "
                   "prohibited them. A correct outcome, not an error.")
    c2.metric("Knowledge chunks", int(h.KB_CHUNKS))
    c3.metric("Tokens consumed", f"{int(h.TOTAL_TOKENS):,}")
    c4.metric("Conformed rows", int(h.SILVER_ROWS))

    st.divider()
    st.subheader("Throughput by SDLC phase")
    st.caption(
        "Counts of artifacts that exist and their review state. This is "
        "throughput, not saved effort — nothing here claims a time reduction."
    )
    thr = q(f"SELECT * FROM {DB}.METRICS.V_SDLC_THROUGHPUT")
    st.dataframe(thr, use_container_width=True, hide_index=True)

    st.subheader("Agent execution profile")
    perf = q(
        f"""SELECT AGENT_NAME, SDLC_PHASE, RUNS, SUCCEEDED,
                   REFUSED_ON_GOVERNANCE, FAILED, TOTAL_TOKENS,
                   EST_USD_TOTAL, AVG_SECONDS
            FROM {DB}.METRICS.V_AGENT_PERFORMANCE
            ORDER BY SDLC_PHASE"""
    )
    st.dataframe(perf, use_container_width=True, hide_index=True)
    st.caption(
        "Governance refusals are counted separately from failures. Conflating "
        "them would make the platform look unreliable when it is behaving "
        "exactly as intended."
    )

# ---------------------------------------------------------------- Evidence
with tab_evidence:
    st.subheader("What was actually measured")
    st.caption(
        "Ordered strongest evidence first. Hover or expand a row to see the "
        "method and the caveat that travels with it."
    )

    ev = q(
        f"""SELECT EVIDENCE_STRENGTH, EVAL_FAMILY, METRIC_NAME, METRIC_VALUE,
                   NUMERATOR, DENOMINATOR, METHOD, CAVEAT
            FROM {DB}.METRICS.V_EVAL_SUMMARY
            ORDER BY CASE EVAL_FAMILY
                       WHEN 'MUTATION' THEN 1 WHEN 'GOVERNANCE' THEN 2
                       WHEN 'CITATION' THEN 3 WHEN 'TESTGEN' THEN 4
                       WHEN 'TRIAGE' THEN 5 ELSE 6 END, METRIC_NAME"""
    )

    for family in ev.EVAL_FAMILY.unique():
        block = ev[ev.EVAL_FAMILY == family]
        strength = block.iloc[0].EVIDENCE_STRENGTH
        with st.expander(f"{family} — {strength}", expanded=(family == "MUTATION")):
            for _, r in block.iterrows():
                val = r.METRIC_VALUE
                denom = (
                    f"  ({int(r.NUMERATOR)}/{int(r.DENOMINATOR)})"
                    if pd.notna(r.NUMERATOR) and pd.notna(r.DENOMINATOR)
                    and r.DENOMINATOR
                    else ""
                )
                st.markdown(f"**{r.METRIC_NAME}: {val:g}**{denom}")
                st.caption(f"Method: {r.METHOD}")
                st.caption(f":orange[Caveat:] {r.CAVEAT}")

    st.divider()
    st.subheader("Injected-defect detection")
    st.caption(
        "The test taxonomy states that a test which cannot be made to fail by "
        "any injected defect is a tautology. Each defect below was deliberately "
        "introduced into a sandbox copy of the conformed layer to confirm the "
        "generated suite catches it — and that the right category catches it."
    )
    mut = q(
        f"""SELECT DEFECT_NAME, EXPECTED_CATEGORY, CAUGHT,
                   CAUGHT_BY_EXPECTED_CATEGORY, TESTS_THAT_FIRED,
                   CAUGHT_BY_TESTS, TRIAGE_TRUE_CATEGORY,
                   TRIAGE_PREDICTED_CATEGORY, TRIAGE_CATEGORY_CORRECT,
                   TRIAGE_STATED_CONFIDENCE
            FROM {DB}.METRICS.V_MUTATION_DETAIL
            ORDER BY DEFECT_NAME"""
    )
    st.dataframe(mut, use_container_width=True, hide_index=True)

    st.divider()
    st.subheader("Evaluation-driven change")
    hist = q(
        f"""SELECT METRIC_NAME,
                   MAX(IFF(ITERATION='v1_before_doc_fix', METRIC_VALUE, NULL)) AS BEFORE,
                   MAX(IFF(ITERATION='v2_after_doc_fix',  METRIC_VALUE, NULL)) AS AFTER
            FROM {DB}.METRICS.EVAL_HISTORY
            GROUP BY 1
            HAVING BEFORE IS DISTINCT FROM AFTER
            ORDER BY 1"""
    )
    if hist.empty:
        st.info("No before/after iterations recorded.")
    else:
        st.dataframe(hist, use_container_width=True, hide_index=True)
        st.caption(
            "The judge flagged invented values in the first backlog. The cause "
            "was a contradiction in the governing corpus, not the model: the PRD "
            "demanded a high-value flag that the Silver data contract had no "
            "column for, and described a per-date FX rate that the rules "
            "document does not publish. Correcting the documents removed the "
            "invented values. Grounded generation faithfully propagates "
            "documentation defects — which is an argument for evaluating the "
            "corpus, not only the model."
        )

# --------------------------------------------------------- Pipeline & QA
with tab_pipeline:
    st.subheader("Test suite coverage")
    cov = q(
        f"""SELECT TEST_CATEGORY, SEVERITY, TESTS, COMPILED, ENV_EXCEPTIONS,
                   PASSED_CLEAN, FAILED_CLEAN, ERRORED_CLEAN
            FROM {DB}.METRICS.V_TEST_COVERAGE
            ORDER BY TEST_CATEGORY"""
    )
    st.dataframe(cov, use_container_width=True, hide_index=True)

    chart = (
        alt.Chart(cov)
        .mark_bar()
        .encode(
            x=alt.X("TEST_CATEGORY:N", title="Taxonomy category", sort="-y"),
            y=alt.Y("TESTS:Q", title="Tests generated"),
            color=alt.Color("SEVERITY:N", title="Severity"),
            tooltip=["TEST_CATEGORY", "SEVERITY", "TESTS", "PASSED_CLEAN"],
        )
        .properties(height=280)
    )
    st.altair_chart(chart, use_container_width=True)
    st.caption(
        "TYPE_VIOLATION has no tests because it does not apply here: the source "
        "amount and date columns are already typed NUMBER and DATE in Bronze, so "
        "there is no text-to-typed parse that could silently NULL. An absent "
        "category is worth explaining rather than padding."
    )

    st.divider()
    st.subheader("Conformed layer")
    silver = q(
        f"""SELECT SOURCE_SYSTEM,
                   COUNT(*) AS ROWS_OUT,
                   COUNT(*) - COUNT(PAYMENT_TERMS) AS NULL_PAYMENT_TERMS,
                   COUNT(*) - COUNT(APPROVAL_STATUS) AS NULL_APPROVAL_STATUS,
                   COUNT(*) - COUNT(DISTINCT INVOICE_KEY) AS DUPLICATE_KEYS
            FROM {DB}.PIPELINE.SILVER_AP_INVOICES
            GROUP BY 1 ORDER BY 1"""
    )
    st.dataframe(silver, use_container_width=True, hide_index=True)
    st.caption(
        "Workday is absent by design. Its onboarding is blocked pending a Data "
        "Processing Agreement, and both the requirements agent and the build "
        "agent refused to produce anything for it."
    )

    st.subheader("Gold review layer")
    gold = q(
        f"""SELECT SOURCE_SYSTEM, COUNT(*) AS INVOICES,
                   COUNT_IF(HIGH_VALUE_FLAG) AS HIGH_VALUE,
                   MAX(INVOICE_AMOUNT_USD) AS MAX_USD
            FROM {DB}.PIPELINE.GOLD_AP_INVOICE_REVIEW
            GROUP BY 1 ORDER BY 1"""
    )
    st.dataframe(gold, use_container_width=True, hide_index=True)
    st.caption(
        "HIGH_VALUE_FLAG uses the frozen reference rates published in the "
        "business rules, not a live FX feed, so a classification does not change "
        "when exchange rates move."
    )

    st.divider()
    st.subheader("Synthetic test data validation")
    synth = q(
        f"""SELECT BATCH_ID, TARGET_TABLE, ROW_COUNT, STATUS,
                   PII_SCAN_RESULT, RI_CHECK_RESULT
            FROM {DB}.ARTIFACTS.SYNTH_BATCHES ORDER BY CREATED_AT DESC"""
    )
    st.dataframe(synth, use_container_width=True, hide_index=True)
    st.caption(
        "Real vendor names were never placed in the generation prompt, and the "
        "output is scanned for collision with production identifiers rather than "
        "assumed clean. The batch also has to prove it reached the rules the "
        "production extract cannot exercise — an unmapped payment-terms code and "
        "a cost centre with no prefix."
    )

# ----------------------------------------------------------- Traceability
with tab_trace:
    st.subheader("Artifact to governing clause")
    st.caption(
        "Every agent records the knowledge-base chunks it relied on. Any "
        "generated artifact can therefore be traced to the clause that "
        "authorised it. CITATION_RESOLVES is a deterministic check that the "
        "cited chunk actually exists."
    )

    types = q(
        f"SELECT DISTINCT ARTIFACT_TYPE FROM {DB}.METRICS.V_TRACEABILITY ORDER BY 1"
    ).ARTIFACT_TYPE.tolist()
    chosen = st.multiselect("Artifact type", types, default=types)

    if chosen:
        in_list = ", ".join(f"'{c}'" for c in chosen)
        tr = q(
            f"""SELECT ARTIFACT_TYPE, ARTIFACT_ID, ARTIFACT_NAME, STATUS,
                       CHUNK_ID, DOC_ID, DOC_TITLE, CITATION_RESOLVES
                FROM {DB}.METRICS.V_TRACEABILITY
                WHERE ARTIFACT_TYPE IN ({in_list})
                ORDER BY ARTIFACT_TYPE, ARTIFACT_ID, CHUNK_ID"""
        )
        unresolved = int((~tr.CITATION_RESOLVES).sum())
        if unresolved:
            st.error(f"{unresolved} citation(s) do not resolve to a knowledge chunk.")
        else:
            st.success(
                f"All {len(tr)} citations resolve to a real knowledge chunk."
            )
        st.dataframe(tr, use_container_width=True, hide_index=True)

        st.subheader("Most-cited governing documents")
        by_doc = (
            tr.dropna(subset=["DOC_ID"])
            .groupby(["DOC_ID", "DOC_TITLE"])
            .size()
            .reset_index(name="CITATIONS")
            .sort_values("CITATIONS", ascending=False)
        )
        st.dataframe(by_doc, use_container_width=True, hide_index=True)

# ------------------------------------------------------------------- Cost
with tab_cost:
    st.subheader("Estimated cost attribution")
    st.warning(
        "These are estimates derived from token counts and the rates in "
        "GOVERNANCE.PLATFORM_CONFIG. They are not billed figures. Reconcile "
        "against ACCOUNT_USAGE before quoting them to anyone.",
        icon=":material/info:",
    )
    cost = q(
        f"""SELECT SDLC_PHASE, AGENT_NAME, ORCHESTRATOR, RUNS,
                   PROMPT_TOKENS, COMPLETION_TOKENS, TOTAL_TOKENS,
                   EST_CREDITS, EST_USD
            FROM {DB}.METRICS.V_COST_ATTRIBUTION
            ORDER BY EST_USD DESC"""
    )
    st.dataframe(cost, use_container_width=True, hide_index=True)

    if not cost.empty:
        pie = (
            alt.Chart(cost)
            .mark_arc(innerRadius=60)
            .encode(
                theta=alt.Theta("EST_USD:Q"),
                color=alt.Color("AGENT_NAME:N", title="Agent"),
                tooltip=["AGENT_NAME", "TOTAL_TOKENS", "EST_USD"],
            )
            .properties(height=300)
        )
        st.altair_chart(pie, use_container_width=True)

    st.divider()
    st.subheader("Run log")
    runs = q(
        f"""SELECT STARTED_AT, AGENT_NAME, SDLC_PHASE, INPUT_REF, STATUS,
                   ORCHESTRATOR, TOTAL_TOKENS, ROUND(EST_USD, 5) AS EST_USD,
                   LATENCY_MS, LEFT(COALESCE(ERROR_MESSAGE, ''), 160) AS NOTE
            FROM {DB}.METRICS.AGENT_RUN_LOG
            ORDER BY STARTED_AT DESC"""
    )
    st.dataframe(runs, use_container_width=True, hide_index=True)
    st.caption(
        "Failed and refused runs are retained. A run log containing only "
        "successes is not evidence of anything."
    )
