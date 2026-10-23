# Agent Memento: Project Plan

Goal: give the voice-agent business one governed answer to "where do we lose money and quality, and what should we change?". Personas ask; an autonomous supervisor proposes; humans decide; everything is audited.

## Quick Navigation

- [Judging Fit](#judging-fit)
- [Phases](#phases)
- [Decisions](#decisions)
- [Next](#next)

---

## Judging Fit

| Theme (event slides) | Delivered |
|---|---|
| Autonomy unlocks value: agents own the job end to end | `TSK_AGENT_SUPERVISOR` detects, Claude drafts, actions are proposed, humans approve, every run is logged |
| Model drafts → agent decides; teams hand off whole jobs | Claude writes the wording; numbers come from SQL; approval goes through `PROC_DECIDE_ACTION` |
| Context × Claude | Semantic view with 15 VQRs → 3 persona copilots → Claude Desktop over MCP |
| Governed by default (row-level security, data boundaries) | `RAP_ACCOUNT`, `MP_FINANCIAL`, PHI/PII masking and tags |
| Security flows through (agents act with the person's rights) | The same question returns 8 accounts to Finance and 3 masked accounts to the CSM |
| Observable and auditable | `AGENT_RUN_LOG`, `AGENT_ACTIONS` decision trail, 28 checks, persona evals |
| Frontier AI on regulated data | Claude on aggregates only; PHI stays masked in RAW and STAGING |

[Back to top](#quick-navigation)

---

## Phases

```mermaid
flowchart LR
    P0["P0 Raw"] --> P1["P1 Staging"] --> P2["P2 Mart"] --> P3["P3 Governance"] --> P4["P4 SV, agent, app"]
    P4 --> P5["P5 Accounts and COGS"] --> P6["P6 Persona trust"] --> P7["P7 Supervisor"] --> P8["P8 Copilots and MCP"] --> P9["P9 Action Inbox"]
    style P0 fill:#d4edda,stroke:#28a745,color:#155724
    style P1 fill:#d4edda,stroke:#28a745,color:#155724
    style P2 fill:#d4edda,stroke:#28a745,color:#155724
    style P3 fill:#d4edda,stroke:#28a745,color:#155724
    style P4 fill:#d4edda,stroke:#28a745,color:#155724
    style P5 fill:#d4edda,stroke:#28a745,color:#155724
    style P6 fill:#d4edda,stroke:#28a745,color:#155724
    style P7 fill:#d4edda,stroke:#28a745,color:#155724
    style P8 fill:#d4edda,stroke:#28a745,color:#155724
    style P9 fill:#d4edda,stroke:#28a745,color:#155724
```

| Phase | Exit criterion | Status |
|---|---|---|
| P0–P4 | Mart, semantic view, agent, MCP and dashboard built; DQ01–DQ12 pass | Done |
| P5 Accounts and COGS | 8 accounts; revenue, COGS and margin reconcile; ≥ 2 negative-margin accounts | Done (DQ13–DQ19) |
| P6 Persona trust | PM / CSM / Finance see 8 / 3 / 8 accounts; revenue visible to Finance only | Done (RL01–RL03) |
| P7 Supervisor | 36 Claude-drafted actions; rerun adds 0; decisions audited | Done (DQ20–DQ24) |
| P8 Copilots and MCP | 3 copilots, 15 VQRs, MCP exposes all; persona evals pass | Done (6/6 evals) |
| P9 Action Inbox | Approve and reject from Streamlit through `PROC_DECIDE_ACTION` | Deployed; not yet opened in Snowsight |

[Back to top](#quick-navigation)

---

## Decisions

| # | Decision | Why |
|---|---|---|
| D1 | Call key is `ROOT_SPAN_ID` | `session_id` is unique per span |
| D2 | No version dedup | RAW has no duplicate IDs |
| D3 | No tool dimension | Tool names are random and unique |
| D4 | Rule-based outcome and intent | Payload text is random |
| D5 | Models mapped to Claude Sonnet/Haiku/Opus 4.5 at list prices | Data has no cost |
| D6 | PHI/PII controls despite synthetic data | Production-grade trust |
| D7 | Streamlit deployed by SQL on container runtime | No `snow` CLI; no extra packages |
| D8 | Reference brokerage dataset excluded | Used only as a pattern |
| D9 | Real org + 8 synthetic accounts, assigned by hash | Single org in data; row-level security needs a boundary |
| D10 | Revenue per billable minute | Matches voice billing |
| D11 | COGS = model + telephony | Full unit cost per minute |
| D12 | One copilot per persona | Shows per-role trust |
| D13 | SQL computes numbers; Claude drafts text | No hallucinated figures |
| D14 | Streamlit runs as its owner role | Row access in the app is emulated by the persona selector |

[Back to top](#quick-navigation)

---

## Next

| Priority | Item |
|---|---|
| P1 | Open `AGENT_OPS_DASHBOARD` and rehearse the [Demo Runbook](Demo-Runbook.md) |
| P1 | Connect `AGENT_MEMENTO_MCP` to Claude Desktop (OAuth or PAT) |
| P2 | Extend the evals to 5 questions per persona |
| P2 | Replace assumed prices with contracted rates |
| P3 | Incremental load (stream + task) for live Braintrust feeds |

[Back to top](#quick-navigation)
