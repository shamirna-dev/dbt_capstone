"""
Fill the L2 capstone template from the measured results of this build.

Shape names come from tools/inspect_pptx.py. Text is written run-by-run so the
template's fonts, colours and theme survive; only the characters change.

Every figure written here is either measured (from METRICS.AGENT_RUN_LOG and
METRICS.EVAL_RESULTS) or explicitly marked "est.". Nothing is invented.
"""

import copy
import sys
from pptx import Presentation
from pptx.util import Pt

SRC = sys.argv[1]
DST = sys.argv[2]

prs = Presentation(SRC)


def shapes_by_name(slide):
    return {sh.name: sh for sh in slide.shapes}


def set_text(shape, paragraphs, size=None):
    """Replace a shape's text, keeping the first run's character formatting."""
    if isinstance(paragraphs, str):
        paragraphs = [paragraphs]

    tf = shape.text_frame
    tf.word_wrap = True

    # Template run to clone formatting from.
    src_p = tf.paragraphs[0]
    src_r = src_p.runs[0] if src_p.runs else None

    # Drop every paragraph after the first, and every run in the first.
    for p in list(tf.paragraphs[1:]):
        p._p.getparent().remove(p._p)
    for r in list(tf.paragraphs[0].runs[1:]):
        r._r.getparent().remove(r._r)

    def write(par, text, template_run):
        if par.runs:
            run = par.runs[0]
        else:
            run = par.add_run()
            if template_run is not None:
                run._r.insert(0, copy.deepcopy(template_run._r.find(
                    '{http://schemas.openxmlformats.org/drawingml/2006/main}rPr')))
        run.text = text
        if size is not None:
            run.font.size = Pt(size)

    write(tf.paragraphs[0], paragraphs[0], src_r)

    for extra in paragraphs[1:]:
        new_p = copy.deepcopy(src_p._p)
        src_p._p.getparent().append(new_p)
        par = tf.paragraphs[-1]
        for r in list(par.runs[1:]):
            r._r.getparent().remove(r._r)
        write(par, extra, src_r)


def set_cell(cell, text, size=None):
    tf = cell.text_frame
    src_p = tf.paragraphs[0]
    src_r = src_p.runs[0] if src_p.runs else None
    for p in list(tf.paragraphs[1:]):
        p._p.getparent().remove(p._p)
    for r in list(src_p.runs[1:]):
        r._r.getparent().remove(r._r)
    if src_p.runs:
        run = src_p.runs[0]
    else:
        run = src_p.add_run()
    run.text = text
    if size is not None:
        run.font.size = Pt(size)


# ===================================================================== SLIDE 1
s = shapes_by_name(prs.slides[0])
set_text(s["Text 2"], "Submission Template \u00b7 Option 4")
set_text(s["Text 4"], "Option 4 \u00b7 AI Case Study")
set_text(s["Text 7"],
         "Open Choice \u2014 self-defined problem: AI-accelerated data engineering SDLC / STLC",
         size=11)
set_text(s["Text 8"],
         "Name: Shamirna Antony                    Date: ____________________")

# ===================================================================== SLIDE 3
s = shapes_by_name(prs.slides[2])
set_text(s["Text 2"], "OPTION 4 \u2014 AI Case Study")
set_text(s["Text 3"], "Case study & domain")
set_text(s["Text 5"],
         "Open Choice. Multi-ERP accounts-payable consolidation on Snowflake \u2014 "
         "onboarding a 4th ERP (Infor Baan IV) into a governed medallion pipeline.",
         size=9)
set_text(s["Text 8"],
         "Delivery rules live across 6 documents. Five RAG-grounded agents turn a prose "
         "request into cited user stories, compile-verified SQL, 28 executable tests and "
         "triaged defects \u2014 behind a human approval gate.",
         size=9)
set_text(s["Text 9"], "Measured outcomes")
set_text(s["Text 11"],
         "7/7 injected defects caught \u00b7 5/5 governance controls upheld \u00b7 163/163 "
         "citations resolve \u00b7 28/28 tests compile \u00b7 9.1 min agent time, $0.63 est.",
         size=9)

set_text(s["Text 13"], "EVIDENCE \u2014 measured on-account")
set_text(s["Text 14"], "Tests proven capable of failing")
set_text(s["Text 16"],
         "7 defect classes injected into a sandbox copy of the conformed layer. "
         "7/7 caught, every one by the expected taxonomy category.",
         size=9)
set_text(s["Text 17"], "Governance enforced, not assumed")
set_text(s["Text 19"],
         "A source the PRD blocks pending a DPA was refused by both the requirements and "
         "build agents. Zero stories, zero code, zero rows.",
         size=9)
set_text(s["Text 20"], "Traceability")
set_text(s["Text 22"],
         "Every artifact records the governing chunks it relied on. 163/163 cited ids "
         "resolve \u2014 a deterministic check, not an opinion.",
         size=9)
set_text(s["Text 23"],
         "Left column is the Option 4 submission; right column summarises the evidence behind it.",
         size=10)

# ===================================================================== SLIDE 4
s = shapes_by_name(prs.slides[3])
set_text(s["Text 3"],
         "Turn a prose data requirement into a governed, tested, incrementally-refreshing "
         "Snowflake pipeline in one session \u2014 every artifact traceable to the clause "
         "that authorised it.",
         size=10)

steps = [
    ("Text 7",  "1 \u00b7 Ground",
     "Text 8",  "6 governing docs \u2192 chunked \u2192 Cortex Search index. Built with Cortex Code + snow CLI."),
    ("Text 12", "2 \u00b7 Specify",
     "Text 13", "Requirements agent \u2192 cited user stories. Refuses work the docs prohibit."),
    ("Text 17", "3 \u00b7 Build",
     "Text 18", "Scaffold agent \u2192 conformance SQL, EXPLAIN-verified. Human approval gate."),
    ("Text 22", "4 \u00b7 Verify",
     "Text 23", "Test agent \u2192 28 assertions. 7 defects injected to prove they fail."),
    ("Text 27", "5 \u00b7 Operate",
     "Text 28", "Triage agent, run log, dashboard. n8n gate + Snowflake Task DAG."),
]
for t_name, title, b_name, body in steps:
    set_text(s[t_name], title, size=11)
    set_text(s[b_name], body, size=8)

set_text(s["Text 29"],
         "All five steps are Snowflake stored procedures, so either orchestrator calls the same code.",
         size=10)

# ===================================================================== SLIDE 5
s = shapes_by_name(prs.slides[4])
set_text(s["Text 3"], [
    "Read 6 governing documents, then hand-write per-source mappings, tests and test data",
    "PRD records ~6 analyst-days per quarter of manual consolidation (est. baseline \u2014 not measured in this build)",
    "Silent failures: a UNION instead of UNION ALL dropped 4% of rows; defaulting unmapped payment terms understated DPO by 11 days",
    "Missed rules surface in production, not in review",
], size=10)
set_text(s["Text 6"], [
    "20 agent runs \u2192 17 cited stories, 3 staging models, 28 tests, 1 synthetic batch, 7 triaged defects",
    "2 refinement rounds: retrieval recall 5 \u2192 17 chunks; corpus defects fixed after the judge flagged them",
    "First pass: 3/3 models and 28/28 tests compiled with no manual edits",
    "9.1 min total agent time, $0.63 est. \u2014 measured from METRICS.AGENT_RUN_LOG",
], size=10)
set_text(s["Text 7"],
         "Screenshot to paste: Streamlit dashboard \u2192 Evidence tab (METRICS.V_EVAL_SUMMARY).",
         size=10)

# ===================================================================== SLIDE 6
s = shapes_by_name(prs.slides[5])
tbl = s["Table 0"].table
rows = [
    ["Conformance SQL per source", "~2\u20133 hrs each (est.)", "25 s each (measured)",
     "3/3 compiled first pass"],
    ["Data quality suite authoring", "~1 day (est.)", "54 s (measured)",
     "28/28 compiled, 27/27 pass"],
    ["Suite proven able to fail", "Rarely done at all", "7 defect classes injected",
     "7/7 caught by expected category"],
    ["Requirement \u2192 governed backlog", "Days, document-dependent", "34 s per requirement",
     "17 stories, 163/163 citations valid"],
    ["Out-of-scope work prevented", "Caught late, if at all", "Refused before any code",
     "5/5 governance controls upheld"],
]
for r_i, row in enumerate(rows, start=1):
    for c_i, val in enumerate(row):
        set_cell(tbl.cell(r_i, c_i), val, size=10)

set_text(s["Text 2"],
         "AI-side figures are measured from the run log (20 runs, 9.1 min, $0.63 est.). "
         "Baselines marked (est.) are consultant estimates \u2014 this build had no human "
         "control arm, so no % time-saved is claimed. The defensible gain is verifiability: "
         "7/7 injected defects caught and every artifact traceable to its governing clause.",
         size=9)

# ===================================================================== SLIDE 7
s = shapes_by_name(prs.slides[6])
set_text(s["Text 5"],
         "The whole accelerator: 18 ordered deploy scripts, 5 agent procedures, the RAG "
         "layer, the mutation + labelled-triage eval harness, 2 n8n workflows, a dbt project.",
         size=9)
set_text(s["Text 10"],
         "Any Snowflake + dbt team. Swap the 6 governing documents and repoint the bronze "
         "tables \u2014 agents read the target contract from metadata, not from prompts.",
         size=9)
set_text(s["Text 15"],
         "README with ordered deploy steps, docs/CAPSTONE.md write-up, a deployed Streamlit "
         "dashboard, and an n8n README stating the SQL API prerequisites.",
         size=9)
set_text(s["Text 20"],
         "A repeatable pattern for every source-onboarding engagement, and an injected-defect "
         "harness that gives a QA lead objective evidence a generated suite actually works.",
         size=9)

# ===================================================================== SLIDE 8
s = shapes_by_name(prs.slides[7])
set_text(s["Text 4"], [
    "Grounded generation was genuinely accurate: 3/3 staging models and 28/28 tests compiled first pass, honouring the first-hyphen cost-centre rule and the ban on defaulting unmapped payment terms",
    "Refused prohibited work: quoted the PRD clause blocking a source pending a DPA and wrote zero stories for it",
], size=9)
set_text(s["Text 8"], [
    "Invented an approval-status mapping when retrieval missed the mapping table \u2014 would have written NULL into a NOT NULL contract column. Cause: one broad retrieval query, not the model",
    "Overconfident triage: 0.93 stated confidence against 0.86 category and 0.71 severity accuracy; escalated HIGH to CRITICAL twice",
], size=9)
set_text(s["Text 12"], [
    "Rewrote retrieval as one targeted query per fact (5 \u2192 17 chunks) and defined the triage categories explicitly (71% \u2192 86%)",
    "The judge's flagged 'hallucinations' were mostly defects in the documents I wrote \u2014 BR-006 demanded a column no contract had. I fixed the corpus, not the agent",
], size=9)

# ===================================================================== SLIDE 9
s = shapes_by_name(prs.slides[8])
set_text(s["Text 4"],  "capstone-ai-dlc/ \u2014 18 SQL scripts", size=9)
set_text(s["Text 7"],  "docs/CAPSTONE.md", size=9)
set_text(s["Text 10"], "METRICS.AGENT_RUN_LOG", size=9)
set_text(s["Text 13"], "APP.CAPSTONE_DASHBOARD", size=9)
set_text(s["Text 16"],
         "Option 4 \u2192 Practice / Capability Lead   \u00b7   full prompt, citations and cost "
         "per run are queryable in METRICS.AGENT_RUN_LOG",
         size=10)

# ==================================================================== SLIDE 11
s = shapes_by_name(prs.slides[10])
set_text(s["Text 5"],  "26 / 30")
set_text(s["Text 9"],  "24 / 30")
set_text(s["Text 13"], "28 / 30")
set_text(s["Text 17"], "25 / 30")
set_text(s["Text 21"], "not demo'd", size=10)
set_text(s["Text 23"],
         "My total:  103 / 150      Clear = 70+     (I demonstrated 4 of 5 topics)")

# ==================================================================== SLIDE 12
s = shapes_by_name(prs.slides[11])
set_text(s["Text 3"],
         "\"Before this program, I thought AI was a faster way to write code \u2014 useful for "
         "boilerplate, risky for anything a client depends on.\"",
         size=10)
set_text(s["Text 5"],
         "\"Now I know it is only as correct as the documentation you ground it in \u2014 and "
         "that the real engineering is building the checks that prove it.\"",
         size=10)
set_text(s["Text 8"],
         "The judge flagged 5 invented values in my backlog. Four were contradictions in the "
         "governing documents I had written myself. Evaluate the corpus, not just the model.",
         size=10)
set_text(s["Text 13"],
         "Make the AI prove its tests can fail. A generated test that only ever passes tells "
         "you nothing.",
         size=9)

prs.save(DST)
print(f"WROTE: {DST}")
