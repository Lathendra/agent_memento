"""
Agent Memento: voice-agent operations, economics and the supervisor Action Inbox.

Reads AGENT_MEMENTO.MART and OPS. The app runs with its owner's role, so the persona selector
applies the persona's view in the app (CSM book of accounts, financials hidden for non-Finance).
Persona copilots in Snowflake Intelligence enforce the same rules natively through row access and masking.
"""

import json

import altair as alt
import pandas as pd
import streamlit as st

st.set_page_config(page_title="Agent Memento", page_icon=":material/smart_toy:", layout="wide")

MART = "AGENT_MEMENTO.MART"
OPS = "AGENT_MEMENTO.OPS"
PERSONAS = {
    "Finance (COGS)": {"role": "AM_FINANCE_R", "financials": True, "csm": None, "agent": "FINANCE_COGS_COPILOT"},
    "Agent Product Manager": {"role": "AM_AGENT_PM_R", "financials": False, "csm": None, "agent": "AGENT_PM_COPILOT"},
    "Customer Success Manager": {"role": "AM_CSM_R", "financials": False, "csm": "AM_CSM_R", "agent": "CSM_COPILOT"},
}
SAMPLES = {
    "Finance (COGS)": ["Which accounts have negative gross margin, and why?", "What is LLM cost by model?"],
    "Agent Product Manager": ["What is the resolution rate by intent?", "Which model routing changes has the supervisor proposed?"],
    "Customer Success Manager": ["Show account health for my accounts", "Which of my accounts had a failure spike last week?"],
}


def conn():
    try:
        return st.connection("snowflake")
    except Exception as e:
        st.error(f"Failed to connect to Snowflake: {e}")
        st.stop()


def run(sql: str, params: list | None = None, ttl: int | None = 600) -> pd.DataFrame:
    df = conn().query(sql, params=params or [], ttl=ttl)
    df.columns = df.columns.str.lower()
    return df


@st.cache_data(ttl=600)
def accounts_for(csm_role: str | None) -> pd.DataFrame:
    if csm_role:
        return run(
            f"""SELECT a.ACCOUNT_ID, a.ACCOUNT_NAME, a.SEGMENT, a.CSM_OWNER
                FROM {MART}.DIM_CUSTOMER_ACCOUNT a
                JOIN AGENT_MEMENTO.GOVERNANCE.ACCOUNT_ACCESS_MAP m ON m.ACCOUNT_ID = a.ACCOUNT_ID
                WHERE m.ROLE_NAME = ? ORDER BY a.ACCOUNT_NAME""",
            [csm_role],
        )
    return run(f"SELECT ACCOUNT_ID, ACCOUNT_NAME, SEGMENT, CSM_OWNER FROM {MART}.DIM_CUSTOMER_ACCOUNT ORDER BY ACCOUNT_NAME")


def load_daily(account_ids: list[str]) -> pd.DataFrame:
    return run(
        f"""SELECT g.CALL_DATE_PT, g.ACCOUNT_ID, a.ACCOUNT_NAME, i.INTENT_NAME, o.OUTCOME_NAME, o.IS_RESOLVED, o.IS_FAILURE,
                   g.CALL_COUNT, g.COST_ANOMALY_COUNT + g.DURATION_ANOMALY_COUNT AS ANOMALY_COUNT,
                   g.BILLABLE_MINUTES, g.COST_AMOUNT, g.TELEPHONY_COST_AMOUNT, g.COGS_AMOUNT, g.REVENUE_AMOUNT,
                   g.GROSS_MARGIN_AMOUNT, g.TOOL_CALL_COUNT, g.TOOL_ERROR_COUNT
            FROM {MART}.AGG_ORG_DAY g
            JOIN {MART}.DIM_CUSTOMER_ACCOUNT a USING (ACCOUNT_ID)
            JOIN {MART}.DIM_INTENT i USING (INTENT_TAG)
            JOIN {MART}.DIM_OUTCOME o USING (OUTCOME_CODE)
            WHERE ARRAY_CONTAINS(g.ACCOUNT_ID::VARIANT, PARSE_JSON(?))""",
        [pd.Series(account_ids).to_json(orient="values")],
    )


def load_actions(persona_name: str) -> pd.DataFrame:
    return run(
        f"""SELECT ACTION_ID, AS_OF_DATE, OWNER_PERSONA, SIGNAL_TYPE, ENTITY_TYPE, ENTITY_NAME, TITLE, DIAGNOSIS_TEXT,
                   RECOMMENDATION_TEXT, PROJECTED_SAVINGS_AMOUNT, DRAFT_STATUS, STATUS, DECIDED_ROLE, DECIDED_PERSONA,
                   DECIDED_TS_PT, DECISION_NOTE
            FROM {OPS}.AGENT_ACTIONS ORDER BY AS_OF_DATE DESC, PROJECTED_SAVINGS_AMOUNT DESC NULLS LAST""",
        ttl=0,
    )


# ----------------------------------------------------------------------------- header
with st.container(horizontal=True, horizontal_alignment="distribute", vertical_alignment="center"):
    st.markdown("# :material/smart_toy: Agent Memento")
    persona = st.segmented_control("Persona", list(PERSONAS), default="Finance (COGS)", label_visibility="collapsed")
persona = persona or "Finance (COGS)"
cfg = PERSONAS[persona]
st.caption(
    f"Viewing as **{persona}** (`{cfg['role']}`). Voice-agent traces Jul 29 to Sep 1 2026 (synthetic). "
    "Model prices and telephony rate are assumed."
)

accts = accounts_for(cfg["csm"])
daily = load_daily(accts["account_id"].tolist())
fin = cfg["financials"]

tab_over, tab_acct, tab_inbox, tab_chat = st.tabs([":material/monitoring: Overview", ":material/business: Accounts",
                                                   ":material/inbox: Action Inbox", ":material/chat: Copilot Chat"])

# ----------------------------------------------------------------------------- overview
with tab_over:
    calls = daily["call_count"].sum()
    resolved = daily.loc[daily["is_resolved"], "call_count"].sum()
    minutes = daily["billable_minutes"].sum()
    cogs = daily["cogs_amount"].sum()
    k = st.columns(6)
    k[0].metric("Calls", f"{calls:,.0f}", border=True)
    k[1].metric("Resolution rate", f"{resolved / max(calls, 1):.1%}", border=True)
    k[2].metric("COGS", f"${cogs:,.0f}", border=True)
    k[3].metric("COGS per minute", f"${cogs / max(minutes, 1):.4f}", border=True)
    if fin:
        rev = daily["revenue_amount"].sum()
        k[4].metric("Revenue", f"${rev:,.0f}", border=True)
        k[5].metric("Gross margin", f"{(rev - cogs) / max(rev, 1):.1%}", border=True)
    else:
        k[4].metric("Revenue", "Finance only", border=True)
        k[5].metric("Tool error rate", f"{daily['tool_error_count'].sum() / max(daily['tool_call_count'].sum(), 1):.2%}", border=True)

    by_day = daily.groupby("call_date_pt").agg(calls=("call_count", "sum"), cogs=("cogs_amount", "sum"),
                                               model=("cost_amount", "sum"), tel=("telephony_cost_amount", "sum")).reset_index()
    row = st.columns(2)
    with row[0], st.container(border=True):
        st.markdown("**Daily calls and COGS**")
        base = alt.Chart(by_day).encode(x=alt.X("call_date_pt:T", title=None))
        st.altair_chart(alt.layer(base.mark_bar(opacity=0.5).encode(y=alt.Y("calls:Q", title="Calls")),
                                  base.mark_line(color="#d62728").encode(y=alt.Y("cogs:Q", title="COGS (USD)")))
                        .resolve_scale(y="independent").properties(height=280), use_container_width=True)
    with row[1], st.container(border=True):
        st.markdown("**Outcome mix by intent**")
        mix = daily.groupby(["intent_name", "outcome_name"])["call_count"].sum().reset_index()
        st.altair_chart(alt.Chart(mix).mark_bar().encode(
            y=alt.Y("intent_name:N", title=None, sort="-x"),
            x=alt.X("call_count:Q", stack="normalize", title=None, axis=alt.Axis(format="%")),
            color=alt.Color("outcome_name:N", title=None, legend=alt.Legend(orient="bottom")),
        ).properties(height=280), use_container_width=True)

# ----------------------------------------------------------------------------- accounts
with tab_acct:
    g = daily.groupby(["account_name"]).agg(
        calls=("call_count", "sum"), minutes=("billable_minutes", "sum"), anomalies=("anomaly_count", "sum"),
        cogs=("cogs_amount", "sum"), model_cost=("cost_amount", "sum"), revenue=("revenue_amount", "sum"),
    ).reset_index()
    res = daily[daily["is_resolved"]].groupby("account_name")["call_count"].sum().rename("resolved")
    fail = daily[daily["is_failure"]].groupby("account_name")["call_count"].sum().rename("failed")
    g = g.merge(res, on="account_name", how="left").merge(fail, on="account_name", how="left").fillna(0)
    g["resolution_rate"] = g["resolved"] / g["calls"]
    g["failure_rate"] = g["failed"] / g["calls"]
    g["anomaly_rate"] = g["anomalies"] / g["calls"]
    g["cogs_per_min"] = g["cogs"] / g["minutes"]
    cols = ["account_name", "calls", "resolution_rate", "failure_rate", "anomaly_rate", "cogs", "cogs_per_min"]
    if fin:
        g["gross_margin"] = g["revenue"] - g["cogs"]
        g["gross_margin_pct"] = g["gross_margin"] / g["revenue"]
        cols += ["revenue", "gross_margin", "gross_margin_pct"]
        g = g.sort_values("gross_margin_pct")
    with st.container(border=True):
        st.markdown("**Account health**" + ("" if fin else " (financials hidden for this persona)"))
        st.dataframe(g[cols], hide_index=True, use_container_width=True, column_config={
            "account_name": "Account",
            "calls": st.column_config.NumberColumn("Calls", format="%d"),
            "resolution_rate": st.column_config.NumberColumn("Resolution", format="percent"),
            "failure_rate": st.column_config.NumberColumn("Failure", format="percent"),
            "anomaly_rate": st.column_config.NumberColumn("Anomaly", format="percent"),
            "cogs": st.column_config.NumberColumn("COGS (USD)", format="$%.0f"),
            "cogs_per_min": st.column_config.NumberColumn("COGS / min", format="$%.4f"),
            "revenue": st.column_config.NumberColumn("Revenue (USD)", format="$%.0f"),
            "gross_margin": st.column_config.NumberColumn("Gross margin (USD)", format="$%.0f"),
            "gross_margin_pct": st.column_config.NumberColumn("Margin %", format="percent"),
        })
    if fin:
        with st.container(border=True):
            st.markdown("**Gross margin by account**")
            st.altair_chart(alt.Chart(g).mark_bar().encode(
                x=alt.X("gross_margin_pct:Q", title=None, axis=alt.Axis(format="%")),
                y=alt.Y("account_name:N", title=None, sort="x"),
                color=alt.condition(alt.datum.gross_margin_pct < 0, alt.value("#d62728"), alt.value("#2ca02c")),
                tooltip=["account_name", alt.Tooltip("gross_margin:Q", format="$,.0f"), alt.Tooltip("gross_margin_pct:Q", format=".1%")],
            ).properties(height=300), use_container_width=True)

# ----------------------------------------------------------------------------- action inbox
with tab_inbox:
    acts = load_actions(persona)
    if cfg["csm"]:
        names = set(accts["account_name"])
        acts = acts[(acts["entity_type"] != "ACCOUNT") | acts["entity_name"].isin(names)]
    if not fin:
        acts = acts[acts["signal_type"] != "NEGATIVE_MARGIN_ACCOUNT"]

    k = st.columns(4)
    open_acts = acts[acts["status"] == "PROPOSED"]
    k[0].metric("Open proposals", f"{len(open_acts):,}", border=True)
    k[1].metric("Approved", f"{(acts['status'] == 'APPROVED').sum():,}", border=True)
    k[2].metric("Rejected", f"{(acts['status'] == 'REJECTED').sum():,}", border=True)
    k[3].metric("Open monthly impact", f"${open_acts['projected_savings_amount'].fillna(0).sum():,.0f}", border=True)

    weeks = sorted(acts["as_of_date"].unique(), reverse=True)
    wk = st.selectbox("Week ending", weeks, index=0) if weeks else None
    show = open_acts[open_acts["as_of_date"] == wk] if wk is not None else open_acts.head(0)
    st.markdown(f"**Open proposals for week ending {wk}**")
    if show.empty:
        st.info("No open proposals for this week.")
    for _, a in show.iterrows():
        with st.container(border=True):
            head = st.columns([6, 2])
            head[0].markdown(f"**#{a['action_id']} {a['title']}**  \n`{a['signal_type']}` · {a['entity_name']} · owner: {a['owner_persona']}")
            if pd.notna(a["projected_savings_amount"]):
                head[1].metric("Monthly impact", f"${a['projected_savings_amount']:,.0f}")
            st.markdown(f"**Diagnosis:** {a['diagnosis_text']}")
            st.markdown(f"**Recommendation:** {a['recommendation_text']}")
            with st.form(key=f"f{a['action_id']}", border=False):
                note = st.text_input("Decision note", key=f"n{a['action_id']}")
                b = st.columns([1, 1, 6])
                approve = b[0].form_submit_button("Approve", type="primary")
                reject = b[1].form_submit_button("Reject")
            if approve or reject:
                decision = "APPROVED" if approve else "REJECTED"
                out = conn().session().sql(
                    f"CALL {OPS}.PROC_DECIDE_ACTION(?, ?, ?, ?)",
                    params=[int(a["action_id"]), decision, persona, note or ""],
                ).collect()[0][0]
                (st.success if out.startswith("OK") else st.error)(out)
                st.rerun()

    with st.expander("Decision audit log"):
        st.dataframe(acts[acts["status"] != "PROPOSED"][["action_id", "as_of_date", "signal_type", "entity_name", "status",
                     "decided_persona", "decided_role", "decided_ts_pt", "decision_note"]], hide_index=True, use_container_width=True)


# ----------------------------------------------------------------------------- copilot chat
def agent_text(raw: str) -> tuple[str, list[str]]:
    """Pull answer text and any generated SQL out of a DATA_AGENT_RUN response."""
    resp = json.loads(raw)
    content = resp.get("content") or resp.get("message", {}).get("content") or []
    texts, sqls = [], []
    for c in content:
        if c.get("type") == "text":
            texts.append(c.get("text", ""))
        elif c.get("type") == "tool_result":
            for r in c.get("tool_result", {}).get("content", []):
                sql = (r.get("json") or {}).get("sql")
                if sql:
                    sqls.append(sql)
    return "\n\n".join(t for t in texts if t).strip() or "_No answer returned._", sqls


def ask_agent(agent: str, history: list[dict]) -> tuple[str, list[str]]:
    body = {"messages": [{"role": m["role"], "content": [{"type": "text", "text": m["text"]}]} for m in history]}
    raw = conn().session().sql(
        "SELECT SNOWFLAKE.CORTEX.DATA_AGENT_RUN(?, ?)", params=[f"AGENT_MEMENTO.SEMANTIC.{agent}", json.dumps(body)]
    ).collect()[0][0]
    return agent_text(raw)


with tab_chat:
    key = f"chat_{cfg['agent']}"
    history = st.session_state.setdefault(key, [])
    with st.container(horizontal=True, vertical_alignment="center"):
        st.markdown(f"Ask **{cfg['agent']}**, the same Cortex Agent exposed through Snowflake Intelligence and the MCP server.")
        if st.button("Clear", icon=":material/delete:"):
            st.session_state[key] = []
            st.rerun()
    st.caption("The app calls the agent with its owner role, so persona row access and masking are not applied here. "
               "Use Snowflake Intelligence under the persona role for enforced views.")
    for m in history:
        with st.chat_message(m["role"]):
            st.markdown(m["text"])
            for s in m.get("sql", []):
                with st.expander("Generated SQL"):
                    st.code(s, language="sql")
    pick = None
    if not history:
        cols = st.columns(len(SAMPLES[persona]))
        for c, q in zip(cols, SAMPLES[persona]):
            if c.button(q, use_container_width=True):
                pick = q
    prompt = st.chat_input(f"Ask the {persona} copilot") or pick
    if prompt:
        history.append({"role": "user", "text": prompt})
        with st.spinner("Copilot is thinking..."):
            try:
                text, sqls = ask_agent(cfg["agent"], history)
            except Exception as e:
                text, sqls = f"Agent call failed: {e}", []
        history.append({"role": "assistant", "text": text, "sql": sqls})
        st.rerun()
