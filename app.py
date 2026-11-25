"""Question box over the kiosk metric tables.

Reads data/raw_data/dataset.csv.gz through DuckDB, builds the same session and
funnel definitions as the notebook, and asks Deepseek for one SELECT. The key
is DEEPSEEK_API_KEY in the environment or in .streamlit/secrets.toml.
"""

from __future__ import annotations

import json
import os
import re
import threading
from pathlib import Path

import duckdb
import pandas as pd
import streamlit as st
from openai import OpenAI

ROOT = Path(__file__).resolve().parent
LOCK = threading.Lock()

TABLES = (
    "file_inventory",
    "tenant_summary",
    "daily_metrics",
    "funnel_by_tenant",
    "step_loss",
    "store_metrics",
    "basket_by_tenant",
    "conversion_by_tenant",
    "session_segments",
    "metric_notes",
)

REFUSE_TEXT = (
    "This file has no guest id. A session is one visit, and the log covers "
    "about two weeks. Churn, repeat visits, and lifetime value are not in the data."
)

REFUSE_RE = re.compile(
    r"\b("
    r"churn|ltv|lifetime value|life-time value|"
    r"customer retention|user retention|guest retention|"
    r"repeat visits?|returning customers?|come back|"
    r"subscription|subscriber"
    r")\b",
    re.IGNORECASE,
)

EXAMPLES = [
    "What is the purchase rate for each tenant?",
    "Which stores have the lowest purchase rate?",
    "Where do sessions drop in the funnel?",
    "How many sessions did each tenant have each day?",
    "How many items are in a buying session, and what is the median purchase price?",
    "What is the customer churn rate?",
]

KEY_HELP = (
    "Set DEEPSEEK_API_KEY in `.streamlit/secrets.toml` on this machine, "
    "or in the Streamlit Cloud app secrets, then reload."
)


def api_key() -> str:
    key = ""
    try:
        key = str(st.secrets.get("DEEPSEEK_API_KEY", "") or "")
    except Exception:
        key = ""
    if not key:
        key = os.environ.get("DEEPSEEK_API_KEY", "")
    return key.strip()


def model_name() -> str:
    name = ""
    try:
        name = str(st.secrets.get("DEEPSEEK_MODEL", "") or "")
    except Exception:
        name = ""
    return name.strip() or os.environ.get("DEEPSEEK_MODEL", "deepseek-chat")


def run_script(con: duckdb.DuckDBPyConnection, path: Path) -> None:
    raw = path.read_text(encoding="utf-8")
    raw = re.sub(r"/\*.*?\*/", "", raw, flags=re.S)
    for chunk in raw.split(";"):
        kept = [line for line in chunk.splitlines() if not line.strip().startswith("--")]
        statement = "\n".join(kept).strip()
        if statement:
            con.execute(statement)


@st.cache_resource(show_spinner="Reading the event file and building the metric tables.")
def get_db() -> duckdb.DuckDBPyConnection:
    data = ROOT / "data" / "raw_data" / "dataset.csv.gz"
    if not data.is_file():
        raise FileNotFoundError("data/raw_data/dataset.csv.gz is not in the repo.")
    os.chdir(ROOT)
    con = duckdb.connect(database=":memory:")
    run_script(con, ROOT / "data" / "sql" / "init_ddl.sql")
    run_script(con, ROOT / "data" / "sql" / "metric_layer.sql")
    present = {
        row[0]
        for row in con.execute(
            "SELECT table_name FROM information_schema.tables WHERE table_schema = 'main'"
        ).fetchall()
    }
    missing = [name for name in TABLES if name not in present]
    if missing:
        raise RuntimeError(f"Metric tables were not created: {', '.join(missing)}")
    if "events" in present:
        raise RuntimeError("The raw events view is still queryable.")
    return con


def query(sql: str) -> pd.DataFrame:
    with LOCK:
        return get_db().execute(sql).df()


def strip_sql(sql: str) -> str:
    sql = sql.strip()
    sql = re.sub(r"^```(?:sql)?\s*", "", sql, flags=re.I)
    sql = re.sub(r"\s*```$", "", sql)
    sql = re.sub(r"/\*.*?\*/", " ", sql, flags=re.S)
    sql = re.sub(r"--.*?$", " ", sql, flags=re.M)
    return sql.strip().rstrip(";").strip()


def cap_rows(sql: str) -> str:
    match = re.search(r"\blimit\s+(\d+)\s*$", sql, flags=re.I)
    if not match:
        return sql + "\nLIMIT 200"
    capped = min(int(match.group(1)), 200)
    return re.sub(r"\blimit\s+\d+\s*$", f"LIMIT {capped}", sql, flags=re.I)


def bare_table(name: str) -> str:
    name = name.strip().lower()
    if "." not in name:
        return name
    schema, table = name.split(".", 1)
    if schema != "main":
        return name
    return table


def referenced_tables(sql: str) -> set[str]:
    names: set[str] = set()
    pattern = (
        r"\b(?:from|join)\s+"
        r"((?:[a-zA-Z_][\w]*\.)?[a-zA-Z_][\w]*"
        r"(?:\s*,\s*(?:[a-zA-Z_][\w]*\.)?[a-zA-Z_][\w]*)*)"
    )
    for match in re.finditer(pattern, sql, flags=re.I):
        for part in match.group(1).split(","):
            names.add(bare_table(part))
    return names


def cte_names(sql: str) -> set[str]:
    return {name.lower() for name in re.findall(r"\b([a-zA-Z_][\w]*)\s+as\s*\(", sql, flags=re.I)}


def validate(sql: str) -> str:
    body = strip_sql(sql)
    if not body:
        raise ValueError("The model returned an empty query.")
    if ";" in body:
        raise ValueError("Only one SELECT is allowed.")
    if not re.match(r"(?is)^(select|with)\b", body):
        raise ValueError("Only a SELECT is allowed.")
    if re.search(
        r"\b(insert|update|delete|drop|create|alter|copy|attach|detach|pragma|"
        r"install|load|export|call|grant|revoke|set|begin|commit|rollback|"
        r"vacuum|checkpoint|import|replace)\b",
        body,
        flags=re.I,
    ):
        raise ValueError("Only a SELECT against the metric tables is allowed.")
    if re.search(
        r"\b(read_csv|read_csv_auto|read_parquet|read_json|read_json_auto|"
        r"parquet_scan|iceberg_scan|glob)\s*\(",
        body,
        flags=re.I,
    ):
        raise ValueError("The query cannot read files.")
    if re.search(r"\b(events|session_flags|information_schema|duckdb_\w*)\b", body, flags=re.I):
        raise ValueError("The query has to use the metric tables, not the raw events.")
    unknown = referenced_tables(body) - set(TABLES) - cte_names(body)
    if not referenced_tables(body):
        raise ValueError("The query has to read one of the metric tables.")
    if unknown:
        raise ValueError(
            "The query names a table this app does not expose: " + ", ".join(sorted(unknown))
        )
    return cap_rows(
        re.sub(r"(?i)'tenant\s+2'", "'tenant_2'", re.sub(r"(?i)'tenant\s+1'", "'tenant_1'", body))
    )


def client() -> OpenAI:
    return OpenAI(api_key=api_key(), base_url="https://api.deepseek.com", timeout=60)


def complete(messages: list[dict[str, str]]) -> str:
    kwargs = {"model": model_name(), "messages": messages, "temperature": 0}
    try:
        response = client().chat.completions.create(
            **kwargs,
            response_format={"type": "json_object"},
        )
    except Exception as exc:
        text = str(exc).lower()
        if "response_format" not in text and "json" not in text:
            raise
        response = client().chat.completions.create(**kwargs)
    content = response.choices[0].message.content
    return content or ""


def parse_json(text: str) -> dict:
    cleaned = text.strip()
    cleaned = re.sub(r"^```(?:json)?\s*", "", cleaned, flags=re.I)
    cleaned = re.sub(r"\s*```$", "", cleaned)
    return json.loads(cleaned)


def schema_prompt() -> str:
    row = query(
        "SELECT min_date, max_date, row_count, sessions, tenants, stores FROM file_inventory"
    ).iloc[0]
    window = f"{row['min_date']} through {row['max_date']}"
    return f"""You translate one question into one DuckDB SELECT for a kiosk event log.

The log has {int(row['row_count'])} event rows, {int(row['sessions'])} sessions, {int(row['tenants'])} tenants, and {int(row['stores'])} stores. Dates run {window}.

Rules:
- A session is one visit. There is no guest id.
- Return JSON only.
- If the question asks for churn, repeat visits, retention of guests, subscriptions, or lifetime value, return {{"action":"refuse","reason":"{REFUSE_TEXT}"}}
- If the question asks which tenant made more money, or ranks tenants by revenue, return {{"action":"refuse","reason":"Item revenue uses a different price unit in each tenant, so it is not a ranking."}}
- Otherwise return {{"action":"sql","sql":"...","title":"short title"}}
- The SQL is one SELECT or WITH. No semicolon. No DDL. No file reading.
- Read only these tables: {", ".join(TABLES)}
- The tenant column stores tenant_1 and tenant_2. A question that says Tenant 1 means tenant = 'tenant_1'. Tenant 2 means tenant = 'tenant_2'. store_id is text.
- Do not compare item_revenue_all_rows or median_purchase_item_revenue across tenants.
- Prefer the aggregate table that already answers the question. Do not restate a rate that the table already has unless the question asks for the inputs.

Tables:
- file_inventory: one row. row_count, sessions, tenants, stores, kiosks, items, event_names, min_date, max_date, revenue_rows. No revenue total.
- tenant_summary: tenant, sessions, sessions_viewed, sessions_selected, sessions_carted, sessions_purchased, purchase_rate, min_date, max_date, item_revenue_all_rows, revenue_unit. purchase_rate is sessions_purchased / sessions.
- daily_metrics: event_date, tenant, sessions, item_revenue_all_rows, revenue_unit. One row per tenant per date.
- funnel_by_tenant: tenant, step_order, step_name, sessions_reached, share_of_sessions. step_name is all_sessions, view_item_list, select_item, add_to_cart, purchase. share_of_sessions uses all sessions for that tenant as the denominator.
- step_loss: tenant, handoff, sessions_at_prior_step, sessions_at_next_step, retained_rate, lost_rate. handoff is view_to_select, select_to_cart, cart_to_purchase.
- store_metrics: tenant, store_id, kiosk_count, sessions, purchased_sessions, purchase_rate, item_revenue_all_rows, revenue_unit.
- basket_by_tenant: tenant, buying_sessions, items_per_buying_session, median_purchase_item_revenue, revenue_unit.
- metric_notes: topic, definition. Use this when the question asks what a metric means.

Examples:
Question: What is the purchase rate for each tenant?
SQL: SELECT tenant, sessions, sessions_purchased, purchase_rate FROM tenant_summary ORDER BY tenant
Question: Which stores have the lowest purchase rate?
SQL: SELECT tenant, store_id, kiosk_count, sessions, purchased_sessions, purchase_rate FROM store_metrics ORDER BY purchase_rate ASC
"""


def narrate(question: str, sql: str, frame: pd.DataFrame) -> str:
    preview = frame.head(50)
    payload = preview.to_csv(index=False)
    note = ""
    if len(frame) > len(preview):
        note = f"\nThe result has {len(frame)} rows. The CSV is the first {len(preview)}."
    messages = [
        {
            "role": "system",
            "content": (
                "You explain a query result in two sentences. "
                "Use only numbers that appear in the rows. "
                "A session is one visit. "
                "Do not compare item revenue across tenants. The price unit differs. "
                "Do not invent a cause. "
                "If the rows are empty, say the query returned no rows. "
                'Return JSON {"answer":"..."}'
            ),
        },
        {
            "role": "user",
            "content": f"Question: {question}\n\nSQL:\n{sql}\n\nRows:\n{payload}{note}",
        },
    ]
    data = parse_json(complete(messages))
    answer = str(data.get("answer", "")).strip()
    if not answer:
        raise ValueError("empty answer")
    return answer


def tidy(frame: pd.DataFrame) -> pd.DataFrame:
    out = frame.copy()
    for col in out.columns:
        if "date" in col.lower():
            out[col] = pd.to_datetime(out[col])
    return out


def chart(frame: pd.DataFrame) -> None:
    if frame.empty or len(frame) > 60:
        return
    numeric = [col for col in frame.columns if pd.api.types.is_numeric_dtype(frame[col])]
    dates = [col for col in frame.columns if pd.api.types.is_datetime64_any_dtype(frame[col])]
    text = [
        col
        for col in frame.columns
        if col not in dates and not pd.api.types.is_numeric_dtype(frame[col])
    ]
    text = [col for col in text if frame[col].nunique(dropna=True) > 1]
    if dates and "sessions" in frame.columns and len(text) <= 1:
        kwargs: dict = {"x": dates[0], "y": "sessions"}
        if len(text) == 1:
            kwargs["color"] = text[0]
        st.line_chart(frame, **kwargs)
        return
    rates = [col for col in numeric if col.endswith("_rate")]
    if len(text) == 1 and len(rates) == 1 and len(frame) <= 40:
        st.bar_chart(frame, x=text[0], y=rates[0])


def run_question(question: str) -> dict:
    if REFUSE_RE.search(question):
        return {"role": "assistant", "content": REFUSE_TEXT}
    if not api_key():
        return {"role": "assistant", "content": KEY_HELP}
    raw = complete(
        [
            {"role": "system", "content": schema_prompt()},
            {"role": "user", "content": question},
        ]
    )
    try:
        data = parse_json(raw)
    except json.JSONDecodeError:
        return {
            "role": "assistant",
            "content": "The model did not return a query. Ask again in one sentence.",
        }
    if data.get("action") == "refuse":
        reason = str(data.get("reason") or REFUSE_TEXT).strip()
        return {"role": "assistant", "content": reason}
    sql_text = str(data.get("sql") or "").strip()
    if data.get("action") != "sql" or not sql_text:
        return {
            "role": "assistant",
            "content": "The model did not return a query. Ask again in one sentence.",
        }
    try:
        sql = validate(sql_text)
    except ValueError as exc:
        return {
            "role": "assistant",
            "content": str(exc),
            "sql": strip_sql(sql_text),
        }
    try:
        frame = tidy(query(sql))
    except Exception as exc:
        first = str(exc).splitlines()[0]
        return {
            "role": "assistant",
            "content": f"The query failed: {first}",
            "sql": sql,
        }
    try:
        content = narrate(question, sql, frame)
    except Exception:
        content = "The query ran. The table is the result."
    return {"role": "assistant", "content": content, "sql": sql, "frame": frame}


def show_body(message: dict) -> None:
    st.markdown(message["content"])
    frame = message.get("frame")
    if isinstance(frame, pd.DataFrame):
        chart(frame)
        st.dataframe(frame, width="stretch")
    if message.get("sql"):
        st.code(message["sql"], language="sql")


def render(message: dict) -> None:
    with st.chat_message(message["role"]):
        show_body(message)


def safe_error(exc: Exception) -> str:
    text = str(exc).splitlines()[0]
    lowered = text.lower()
    if "api_key" in lowered or "bearer" in lowered or "sk-" in lowered:
        return "The model request was rejected. Check DEEPSEEK_API_KEY."
    return f"The request failed. {exc.__class__.__name__}: {text}"


def main() -> None:
    st.set_page_config(page_title="Kiosk session questions", layout="centered")
    st.title("Kiosk session questions")
    st.caption(
        "Ask about sessions, the funnel, or stores. "
        "A session is one visit. The answer is one query against the metric tables, and the SQL stays on the page."
    )
    try:
        get_db()
    except FileNotFoundError as exc:
        st.error(str(exc))
        st.stop()
    except Exception as exc:
        st.error(f"The metric tables did not build. {exc}")
        st.stop()

    with st.expander("What the tables mean"):
        st.dataframe(query("SELECT topic, definition FROM metric_notes ORDER BY topic"), width="stretch")

    with st.sidebar:
        st.header("Try a question")
        for example in EXAMPLES:
            if st.button(example, width="stretch"):
                st.session_state.pending = example
                st.rerun()
        st.divider()
        st.markdown(
            "Revenue stays inside one tenant. The price unit differs, so a higher sum is not a better tenant."
        )

    if "messages" not in st.session_state:
        st.session_state.messages = []

    prompt = st.chat_input("Ask about sessions, the funnel, or a store")
    if prompt is None and st.session_state.get("pending"):
        prompt = st.session_state.pop("pending")

    if prompt:
        st.session_state.messages.append({"role": "user", "content": prompt})

    for message in st.session_state.messages:
        render(message)

    if prompt and st.session_state.messages[-1]["role"] == "user":
        with st.chat_message("assistant"):
            with st.spinner("Writing the query."):
                try:
                    reply = run_question(prompt)
                except Exception as exc:
                    reply = {"role": "assistant", "content": safe_error(exc)}
            show_body(reply)
        st.session_state.messages.append(reply)


if __name__ == "__main__":
    main()
