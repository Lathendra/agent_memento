"""Upload local Parquet partitions to @AGENT_MEMENTO.RAW.SPANS_STAGE."""
import os
import snowflake.connector

CONNECTION = os.getenv("SNOWFLAKE_CONNECTION_NAME", "ANTHROPIC-SNOWFLAKE-HACKATHON-ASDZAA")
BASE = os.getenv("PARQUET_DIR", "/Users/lathendra/Downloads/braintrust_synth_jul29_sep01")

con = snowflake.connector.connect(
    connection_name=CONNECTION, role="ATTENDEE_ROLE",
    warehouse="DEFAULT_WH", database="AGENT_MEMENTO", schema="RAW",
)
cur = con.cursor()
for d in sorted(x for x in os.listdir(BASE) if x.startswith("event_dt=")):
    cur.execute(
        f"PUT 'file://{BASE}/{d}/*.parquet' @SPANS_STAGE/{d}/ "
        "AUTO_COMPRESS=FALSE PARALLEL=8 OVERWRITE=FALSE"
    )
    print(d, [(r[0][-12:], r[6]) for r in cur.fetchall()], flush=True)
con.close()
