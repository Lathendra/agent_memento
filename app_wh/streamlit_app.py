"""
Agent Memento: voice-agent operations, economics and the supervisor Action Inbox.

Reads AGENT_MEMENTO.MART and OPS. The app runs with its owner's role, so the persona selector
applies the persona's view in the app (CSM book of accounts, financials hidden for non-Finance).
Persona copilots in Snowflake Intelligence enforce the same rules natively through row access and masking.
"""

import json
import re

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


# ----------------------------------------------------------------------------- display helpers
LABELS = {"Finance (COGS)": "Finance", "Agent Product Manager": "Product Manager", "Customer Success Manager": "Customer Success"}
SIGNALS = {
    "NEGATIVE_MARGIN_ACCOUNT": ("Margin", "red", ":material/trending_down:"),
    "MODEL_COST_SHIFT": ("Model routing", "blue", ":material/alt_route:"),
    "ANOMALY_SPIKE": ("Quality", "orange", ":material/warning:"),
}


def md_safe(text: str) -> str:
    """Escape $ so Streamlit does not render dollar amounts as LaTeX math."""
    return str(text or "").replace("$", "\\$")


def as_bullets(text: str) -> str:
    """Turn '1) ... 2) ...' or '1. ... 2. ...' into a Markdown bullet list; leave other text as is."""
    parts = [x.strip(" ;") for x in re.split(r"\s*(?:^|\s)\d+[).]\s+", str(text or "")) if x.strip(" ;")]
    return "\n".join(f"- {md_safe(x)}" for x in parts) if len(parts) > 1 else md_safe(text)


def money(v: float) -> str:
    return f"${v / 1000:,.1f}K" if abs(v) >= 10_000 else f"${v:,.0f}"


# ----------------------------------------------------------------------------- header
with st.container(horizontal=True, horizontal_alignment="distribute", vertical_alignment="center"):
    st.markdown("# :material/smart_toy: Agent Memento")
    persona = st.segmented_control("Persona", list(PERSONAS), default="Finance (COGS)", format_func=LABELS.get,
                                   label_visibility="collapsed")
persona = persona or "Finance (COGS)"
cfg = PERSONAS[persona]

accts = accounts_for(cfg["csm"])
daily = load_daily(accts["account_id"].tolist())
fin = cfg["financials"]

scope = (f"{len(accts)} accounts in your book" if cfg["csm"] else f"all {len(accts)} accounts")
access = "full financials" if fin else "financials hidden"
st.caption(f":material/badge: Viewing as **{LABELS[persona]}** · {scope} · {access} · "
           "Synthetic voice-agent calls, Jul 29 to Sep 1 2026")

# shared numbers
calls = daily["call_count"].sum()
resolved = daily.loc[daily["is_resolved"], "call_count"].sum()
minutes = daily["billable_minutes"].sum()
cogs = daily["cogs_amount"].sum()
rev = daily["revenue_amount"].sum()
tool_err = daily["tool_error_count"].sum() / max(daily["tool_call_count"].sum(), 1)

g = daily.groupby("account_name").agg(
    calls=("call_count", "sum"), minutes=("billable_minutes", "sum"), anomalies=("anomaly_count", "sum"),
    cogs=("cogs_amount", "sum"), revenue=("revenue_amount", "sum"),
).reset_index()
res = daily[daily["is_resolved"]].groupby("account_name")["call_count"].sum().rename("resolved")
fail = daily[daily["is_failure"]].groupby("account_name")["call_count"].sum().rename("failed")
g = g.merge(res, on="account_name", how="left").merge(fail, on="account_name", how="left").fillna(0)
g["resolution_rate"] = g["resolved"] / g["calls"]
g["failure_rate"] = g["failed"] / g["calls"]
g["cogs_per_min"] = g["cogs"] / g["minutes"]
g["gross_margin"] = g["revenue"] - g["cogs"]
g["gross_margin_pct"] = g["gross_margin"] / g["revenue"].where(g["revenue"] > 0)
losers = g[g["gross_margin"] < 0].sort_values("gross_margin_pct")

st.markdown("""
<style>
div[data-baseweb="tab-list"] {
    gap: 0.5rem; padding: 0.4rem; background: #f3f5f9; border-radius: 14px; margin-bottom: 0.75rem;
}
div[data-baseweb="tab-list"] button[role="tab"] {
    flex: 1 1 0; justify-content: center; height: 3.1rem; padding: 0 1rem;
    border-radius: 10px; background: transparent; border: 1px solid transparent;
    transition: background 0.15s ease, box-shadow 0.15s ease;
}
div[data-baseweb="tab-list"] button[role="tab"] p { font-size: 1.05rem; font-weight: 600; color: #475467; }
div[data-baseweb="tab-list"] button[role="tab"]:hover { background: #e7ecf5; }
div[data-baseweb="tab-list"] button[role="tab"][aria-selected="true"] {
    background: #ffffff; border-color: #d0d8e8; box-shadow: 0 2px 6px rgba(16, 24, 40, 0.10);
}
div[data-baseweb="tab-list"] button[role="tab"][aria-selected="true"] p { color: #1a5fd0; }
div[data-baseweb="tab-highlight"], div[data-baseweb="tab-border"] { display: none; }
</style>
""", unsafe_allow_html=True)

tab_chat, tab_inbox, tab_over, tab_acct = st.tabs([":material/chat: Ask the Copilot", ":material/inbox: Action Inbox",
                                                   ":material/monitoring: Overview", ":material/business: Accounts"])

# ----------------------------------------------------------------------------- overview
with tab_over:
    st.subheader("How is the voice agent doing?")
    headline = f"**{resolved / max(calls, 1):.0%}** of **{calls:,.0f}** calls were resolved by the agent, at **${cogs / max(minutes, 1):.3f}** per minute."
    if fin and len(losers):
        st.error(f"{headline} But **{len(losers)} accounts lose money** on every call. See the Accounts tab.",
                 icon=":material/priority_high:")
    else:
        st.success(headline, icon=":material/check_circle:")

    k = st.columns(4)
    k[0].metric("Calls handled", f"{calls:,.0f}", border=True, help="Voice-agent calls in the period.")
    k[1].metric("Resolved by agent", f"{resolved / max(calls, 1):.1%}", border=True,
                help="Share of calls the agent closed without a human or a failure.")
    k[2].metric("Cost per minute", f"${cogs / max(minutes, 1):.4f}", border=True,
                help="COGS = LLM model cost + telephony, divided by billable minutes.")
    if fin:
        k[3].metric("Gross margin", f"{(rev - cogs) / max(rev, 1):.1%}", f"{money(rev - cogs)} profit", border=True,
                    help="(Revenue - COGS) / Revenue. Visible to Finance only.")
    else:
        k[3].metric("Tool error rate", f"{tool_err:.2%}", border=True,
                    help="Share of agent tool calls (calendar, CRM, payments) that errored.")

    by_day = daily.groupby("call_date_pt").agg(calls=("call_count", "sum"), cogs=("cogs_amount", "sum")).reset_index()
    row = st.columns(2)
    with row[0], st.container(border=True):
        st.markdown("**Cost moves with call volume**")
        st.caption("Bars: calls per day. Line: daily COGS in USD.")
        base = alt.Chart(by_day).encode(x=alt.X("call_date_pt:T", title=None))
        st.altair_chart(alt.layer(base.mark_bar(opacity=0.45).encode(y=alt.Y("calls:Q", title="Calls")),
                                  base.mark_line(color="#d62728", strokeWidth=2.5).encode(y=alt.Y("cogs:Q", title="COGS (USD)")))
                        .resolve_scale(y="independent").properties(height=260), width="stretch")
    with row[1], st.container(border=True):
        by_int = daily.groupby("intent_name").agg(calls=("call_count", "sum")).join(
            daily[daily["is_resolved"]].groupby("intent_name")["call_count"].sum().rename("res")).fillna(0).reset_index()
        by_int["rate"] = by_int["res"] / by_int["calls"]
        worst = by_int.sort_values("rate").iloc[0] if len(by_int) else None
        st.markdown("**Resolution rate by caller intent**")
        st.caption(f"Weakest intent: **{worst['intent_name']}** at {worst['rate']:.1%}." if worst is not None else "")
        st.altair_chart(alt.Chart(by_int).mark_bar().encode(
            y=alt.Y("intent_name:N", title=None, sort="x"),
            x=alt.X("rate:Q", title=None, axis=alt.Axis(format="%"), scale=alt.Scale(domain=[0.8, 1])),
            color=alt.when(alt.datum.rate < 0.95).then(alt.value("#f28e2b")).otherwise(alt.value("#59a14f")),
            tooltip=["intent_name", alt.Tooltip("rate:Q", format=".1%"), alt.Tooltip("calls:Q", format=",")],
        ).properties(height=260), width="stretch")

# ----------------------------------------------------------------------------- accounts
with tab_acct:
    st.subheader("Who makes us money, and who costs us?" if fin else "How healthy are the accounts?")
    if cfg["csm"]:
        st.info(f"Your book: **{', '.join(accts['account_name'])}**. Other accounts and all financials are hidden for this role.",
                icon=":material/lock:")
    if fin:
        if len(losers):
            cols = st.columns(len(losers) + 1)
            for c, (_, r) in zip(cols, losers.iterrows()):
                with c, st.container(border=True):
                    st.markdown(f":red[:material/trending_down: **{r['account_name']}**]")
                    st.metric("Gross margin", f"{r['gross_margin_pct']:.1%}", f"{money(r['gross_margin'])} lost",
                              delta_color="normal")
            with cols[-1], st.container(border=True):
                healthy = len(g) - len(losers)
                st.markdown(f":green[:material/check_circle: **{healthy} healthy accounts**]")
                st.metric("Their margin", f"{g.loc[g['gross_margin'] >= 0, 'gross_margin'].sum() / max(g.loc[g['gross_margin'] >= 0, 'revenue'].sum(), 1):.1%}")
        g = g.sort_values("gross_margin_pct")
    else:
        g = g.sort_values("resolution_rate")

    cols = ["account_name", "calls", "resolution_rate", "failure_rate", "cogs_per_min"]
    if fin:
        cols += ["revenue", "gross_margin", "gross_margin_pct"]
    with st.container(border=True):
        st.markdown("**Account scorecard** · " + ("worst margin first" if fin else "lowest resolution first"))
        st.dataframe(g[cols], hide_index=True, width="stretch", column_config={
            "account_name": "Account",
            "calls": st.column_config.NumberColumn("Calls", format="localized"),
            "resolution_rate": st.column_config.ProgressColumn("Resolved", format="percent", min_value=0, max_value=1),
            "failure_rate": st.column_config.NumberColumn("Failed", format="percent"),
            "cogs_per_min": st.column_config.NumberColumn("Cost / min", format="$%.4f"),
            "revenue": st.column_config.NumberColumn("Revenue", format="dollar"),
            "gross_margin": st.column_config.NumberColumn("Profit", format="dollar"),
            "gross_margin_pct": st.column_config.NumberColumn("Margin", format="percent"),
        })
    if fin:
        with st.container(border=True):
            st.markdown("**Gross margin by account** · red bars lose money")
            st.altair_chart(alt.Chart(g).mark_bar().encode(
                x=alt.X("gross_margin_pct:Q", title=None, axis=alt.Axis(format="%")),
                y=alt.Y("account_name:N", title=None, sort="x"),
                color=alt.when(alt.datum.gross_margin_pct < 0).then(alt.value("#d62728")).otherwise(alt.value("#2ca02c")),
                tooltip=["account_name", alt.Tooltip("gross_margin:Q", format="$,.0f"), alt.Tooltip("gross_margin_pct:Q", format=".1%")],
            ).properties(height=280), width="stretch")

# ----------------------------------------------------------------------------- action inbox
with tab_inbox:
    acts = load_actions(persona)
    if cfg["csm"]:
        names = set(accts["account_name"])
        acts = acts[(acts["entity_type"] != "ACCOUNT") | acts["entity_name"].isin(names)]
    if not fin:
        acts = acts[acts["signal_type"] != "NEGATIVE_MARGIN_ACCOUNT"]
    open_acts = acts[acts["status"] == "PROPOSED"]
    weeks = sorted(acts["as_of_date"].unique(), reverse=True)

    st.subheader("What should we do about it?")
    with st.container(horizontal=True, vertical_alignment="bottom"):
        wk = st.selectbox("Week ending", weeks, index=0) if weeks else None
    show = open_acts[open_acts["as_of_date"] == wk] if wk is not None else open_acts.head(0)
    st.info(f"Every morning the **supervisor agent** scans the data, Claude writes the diagnosis, and you decide. "
            f"**{len(show)} open actions** this week worth **{money(show['projected_savings_amount'].fillna(0).sum())}/month**.",
            icon=":material/smart_toy:")

    k = st.columns(4)
    k[0].metric("Open this week", f"{len(show):,}", border=True)
    k[1].metric("Approved (all time)", f"{(acts['status'] == 'APPROVED').sum():,}", border=True)
    k[2].metric("Rejected (all time)", f"{(acts['status'] == 'REJECTED').sum():,}", border=True)
    k[3].metric("Open impact (all weeks)", money(open_acts["projected_savings_amount"].fillna(0).sum()) + "/mo", border=True,
                help="Projected monthly savings or margin recovered if every open action is approved.")

    if show.empty:
        st.success("Nothing waiting for you this week.", icon=":material/done_all:")
    for _, a in show.iterrows():
        label, color, icon = SIGNALS.get(a["signal_type"], (a["signal_type"], "gray", ":material/info:"))
        with st.container(border=True):
            head = st.columns([5, 2], vertical_alignment="center")
            with head[0]:
                st.badge(label, icon=icon, color=color)
                st.markdown(f"#### {md_safe(a['title'])}")
                st.caption(f"{a['entity_name']} · owner: {a['owner_persona']} · action #{a['action_id']}")
            if pd.notna(a["projected_savings_amount"]):
                head[1].metric("Monthly impact", money(a["projected_savings_amount"]))
            st.markdown(f":material/search: **Why:** {md_safe(a['diagnosis_text'])}")
            st.markdown(":material/lightbulb: **Suggested fix:**\n\n" + as_bullets(a["recommendation_text"]))
            with st.form(key=f"f{a['action_id']}", border=False):
                note = st.text_input("Decision note", key=f"n{a['action_id']}", placeholder="e.g. Reprice at renewal")
                b = st.columns([1, 1, 5])
                approve = b[0].form_submit_button("Approve", type="primary", icon=":material/check:")
                reject = b[1].form_submit_button("Reject", icon=":material/close:")
            if approve or reject:
                decision = "APPROVED" if approve else "REJECTED"
                out = conn().session().sql(
                    f"CALL {OPS}.PROC_DECIDE_ACTION(?, ?, ?, ?)",
                    params=[int(a["action_id"]), decision, persona, note or ""],
                ).collect()[0][0]
                if out.startswith("OK"):
                    st.toast(f"Action #{a['action_id']} {decision.lower()} and logged to the audit trail.", icon=":material/verified:")
                else:
                    st.error(out)
                st.rerun()

    with st.expander(":material/history: Decision audit trail (who decided what, and when)"):
        st.dataframe(acts[acts["status"] != "PROPOSED"][["action_id", "as_of_date", "signal_type", "entity_name", "status",
                     "decided_persona", "decided_role", "decided_ts_pt", "decision_note"]], hide_index=True, width="stretch",
                     column_config={"action_id": "#", "as_of_date": "Week", "signal_type": "Signal", "entity_name": "Entity",
                                    "status": "Decision", "decided_persona": "Persona", "decided_role": "Snowflake role",
                                    "decided_ts_pt": "When (PT)", "decision_note": "Note"})


# ----------------------------------------------------------------------------- copilot chat

AGENTS = {
    "FINANCE_COGS_COPILOT": "Finance COGS Copilot",
    "AGENT_PM_COPILOT": "Agent PM Copilot",
    "CSM_COPILOT": "Customer Success Copilot",
    "AGENT_OPS_ANALYST": "Agent Ops Analyst",
}


@st.cache_data(ttl=3600)
def agent_config(agent: str) -> dict:
    """Configured model and skills (tools) for an agent, read from DESCRIBE AGENT."""
    try:
        df = run(f"DESCRIBE AGENT AGENT_MEMENTO.SEMANTIC.{agent}")
        spec = json.loads(df["agent_spec"].iloc[0]) if len(df) else {}
    except Exception:
        spec = {}
    tools = []
    for t in spec.get("tools", []):
        ts = t.get("tool_spec", {})
        res = spec.get("tool_resources", {}).get(ts.get("name"), {})
        kind = {"cortex_analyst_text_to_sql": "Cortex Analyst", "cortex_search": "Cortex Search"}.get(ts.get("type"), ts.get("type"))
        src = res.get("semantic_view") or res.get("name") or ""
        tools.append({"name": ts.get("name"), "kind": kind, "source": src.split(".")[-1]})
    return {"model": spec.get("models", {}).get("orchestration", "auto"), "tools": tools}


def agent_text(raw: str) -> dict:
    """Pull answer text, generated SQL, tools used and model metadata out of a DATA_AGENT_RUN response."""
    resp = json.loads(raw)
    content = resp.get("content") or resp.get("message", {}).get("content") or []
    texts, sqls, used = [], [], []
    for c in content:
        if c.get("type") == "text":
            texts.append(c.get("text", ""))
        elif c.get("type") == "tool_use":
            name = (c.get("tool_use") or {}).get("name")
            if name and name not in used:
                used.append(name)
        elif c.get("type") == "tool_result":
            for r in c.get("tool_result", {}).get("content", []):
                sql = (r.get("json") or {}).get("sql")
                if sql:
                    sqls.append(sql)
    md = resp.get("metadata") or {}
    tokens = sum((u.get("input_tokens", {}).get("total", 0) or 0) + (u.get("output_tokens", {}).get("total", 0) or 0)
                 for u in (md.get("usage") or {}).get("tokens_consumed", []))
    return {"text": "\n\n".join(t for t in texts if t).strip() or "_No answer returned._", "sql": sqls,
            "tools": used, "model": md.get("orchestration_model"), "tokens": tokens}


def ask_agent(agent: str, history: list[dict]) -> dict:
    body = {"messages": [{"role": m["role"], "content": [{"type": "text", "text": m["text"]}]} for m in history]}
    raw = conn().session().sql(
        "SELECT SNOWFLAKE.CORTEX.DATA_AGENT_RUN(?, ?)", params=[f"AGENT_MEMENTO.SEMANTIC.{agent}", json.dumps(body)]
    ).collect()[0][0]
    return agent_text(raw)


def run_caption(m: dict) -> str:
    bits = [f":material/smart_toy: {AGENTS.get(m.get('agent'), m.get('agent'))}"]
    if m.get("tools"):
        bits.append(":material/build: " + ", ".join(m["tools"]))
    if m.get("model"):
        bits.append(f":material/memory: {m['model']}")
    if m.get("tokens"):
        bits.append(f"{m['tokens']:,} tokens")
    return " · ".join(bits)


with tab_chat:
    agent_key = f"agent_for_{persona}"
    st.session_state.setdefault(agent_key, cfg["agent"])
    agent = st.session_state[agent_key]
    key = f"chat_{persona}_{agent}"
    history = st.session_state.setdefault(key, [])

    st.subheader(f"Ask the {LABELS[persona]} copilot")
    with st.container(horizontal=True, vertical_alignment="center"):
        st.markdown("Plain-English questions, answered by a Cortex Agent from governed data. Each answer shows the SQL it ran.")
        if st.button("Clear", icon=":material/delete:"):
            st.session_state[key] = []
            st.session_state.pop(f"pill_{key}", None)
            st.rerun()
    st.caption(":material/info: In this demo app the agent runs with the app owner's role. In Snowflake Intelligence, "
               "CoCo or MCP it runs with your own role, so row access and masking apply automatically.")

    def show(m: dict) -> None:
        with st.chat_message(m["role"]):
            st.markdown(md_safe(m["text"]))
            for s in m.get("sql", []):
                with st.expander("Generated SQL"):
                    st.code(s, language="sql")
            if m["role"] == "assistant":
                st.caption(run_caption(m))

    pills = st.empty()
    pick = None
    if not history:
        pick = pills.pills("Try asking", SAMPLES[persona], key=f"pill_{key}")
    thread = st.container()
    with thread:
        for m in history:
            show(m)

    # Run settings bar, directly above the input box.
    conf = agent_config(agent)
    with st.container(border=True):
        bar = st.columns([3, 4, 2], vertical_alignment="center")
        bar[0].selectbox("Agent", list(AGENTS), key=agent_key, format_func=AGENTS.get,
                         help="Which Cortex Agent answers. Defaults to this persona's copilot; switching keeps a separate thread per agent.")
        with bar[1]:
            st.markdown("**Skill**")
            for t in conf["tools"] or [{"name": "none", "kind": "", "source": ""}]:
                st.badge(f"{t['name']} · {t['kind']} on {t['source']}", icon=":material/build:", color="violet")
        with bar[2]:
            st.markdown("**Model**", help="Set on the agent object. 'auto' lets Snowflake choose; each answer shows the model actually used.")
            last = next((m.get("model") for m in reversed(history) if m.get("model")), None)
            st.badge(f"{conf['model']}" + (f" → {last}" if last and conf["model"] == "auto" else ""),
                     icon=":material/memory:", color="gray")

    prompt = st.chat_input(f"Ask {AGENTS[agent]} anything about calls, cost or accounts") or pick
    if prompt:
        # Render the turn in place (no st.rerun) so the page is not redrawn and greyed out while the agent works.
        pills.empty()
        user = {"role": "user", "text": prompt}
        history.append(user)
        with thread:
            show(user)
            with st.chat_message("assistant"):
                with st.spinner(f"{AGENTS[agent]} is thinking..."):
                    try:
                        out = ask_agent(agent, history)
                    except Exception as e:
                        out = {"text": f"Agent call failed: {e}", "sql": [], "tools": [], "model": None, "tokens": 0}
                out.update(role="assistant", agent=agent)
                st.markdown(md_safe(out["text"]))
                for s in out["sql"]:
                    with st.expander("Generated SQL"):
                        st.code(s, language="sql")
                st.caption(run_caption(out))
        history.append(out)
