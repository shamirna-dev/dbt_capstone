-# Capstone deck — what's filled, what's yours

Output: `C:\Users\i.shamirna\Downloads\AI_Capstone_L2_Shamirna_Antony.pptx`
Regenerate any time with:

```powershell
python tools\fill_capstone_pptx.py `
  "C:\Users\i.shamirna\Downloads\AI_Capstone_Template_L2.pptx" `
  "C:\Users\i.shamirna\Downloads\AI_Capstone_L2_Shamirna_Antony.pptx"
```

## Filled

| Slide | Status |
|---|---|
| 1 Title | Option 4, your name. **Date left blank.** |
| 2 How to use | Untouched — this is the instruction slide, delete it before submitting |
| 3 Project Overview | Left column = Option 4 submission. Right column repurposed to "EVIDENCE" (the template only ships Option 1 / Option 2 columns) |
| 4 My AI Approach | Goal + 5 steps: Ground, Specify, Build, Verify, Operate |
| 5 Before → After | Both columns. **Needs a screenshot pasted** |
| 6 Impact Scorecard | 5 metric rows + summary. **Contains estimates — read below** |
| 7 Reusability & Scale | All four quadrants |
| 8 Right / Wrong / Corrected | All three bands |
| 9 Evidence & Artifacts | Artifact names. **Links and validator details needed** |
| 10 Rubric | Untouched — reference slide |
| 11 Self-Rating | 26 / 24 / 28 / 25 / blank = **103 / 150**, 4 of 5 topics |
| 12 Reflection | Drafted in your voice. **Confidence scores left blank** |
| 13 Rubric Validation | Untouched — validator only |

## Five things only you can do

1. **Date** on slide 1.
2. **Delete slide 2** (instruction slide — the template says to remove instruction notes).
3. **Paste a screenshot** on slide 5. Best one: the Streamlit dashboard's Evidence
   tab, which shows every metric next to its method and caveat. Second choice: the
   Pipeline & QA tab showing test coverage by taxonomy category.
4. **Slide 9 links.** If you push to Git, replace `capstone-ai-dlc/ — 18 SQL
   scripts` with the repo URL. Also add your validator's name, role and email.
5. **Slide 12 confidence scores** (`Before: __/10  After: __/10`). I deliberately
   left these blank — they are a claim about you, not about the build.

## Two judgement calls you should agree with before submitting

### The estimates on slide 6

The rubric asks you to quantify before/after. This build has no human control arm,
so there is no measured baseline. I handled it by labelling every figure:

- **After AI** column — all measured from `METRICS.AGENT_RUN_LOG`.
- **Before AI** column — marked `(est.)` where it is a consultant estimate.
- The summary box states plainly that no % time-saved is claimed and explains why.

The `~6 analyst-days per quarter` figure on slide 5 comes from the PRD's own
business-context section, so it is at least sourced rather than invented.

If you would rather drop the estimates entirely, delete the `Before AI` cells and
lead on the verifiability metrics. You will score less well on "quantify
before/after" but you cannot be challenged on a number. My recommendation is to
keep them as labelled — a reviewer who sees `(est.)` alongside `(measured)` will
trust the whole deck more, not less.

### The self-rating: 103 / 150

| Topic | Score | Reasoning |
|---|---|---|
| Spec-Driven Development | 26 | Rubric's top-marks wording is "spec discipline governs agent behaviour and hand-offs, not just a single file." That is literally the design — `TARGET_CONTRACT` and the governing corpus drive agent behaviour, and `DRAFT → APPROVED → MATERIALIZED` governs hand-offs |
| AI-Powered Development | 24 | Agent mode + CLI delivering working software. Held back from higher because no skills or hooks were used |
| LLM Evaluation & Interpretability | 28 | Strongest area: 4 eval families, labelled ground truth, mutation testing, before/after iterations, confidence-vs-accuracy calibration, and decisions changed by the data |
| Agent Design, Orchestration & Ops | 25 | 5 agents, 5-stage orchestration, two paths, failure handling, sandbox recovery, full observability. Held back because the n8n leg was not executed end to end |
| AI Tool Integration & Extensibility | blank | No MCP servers, hooks, or custom skills were built. Not demonstrated |

Leaving topic 5 blank is the honest move and the template explicitly allows it
(minimum 3 topics; you have 4). Scoring it low-but-nonzero would invite a
validator to ask what you built, and the answer is nothing.

If you want that fifth topic, the contained piece of work is wrapping the five
agent procedures as an MCP server or a Cortex skill. That is the only change that
would move the score.
