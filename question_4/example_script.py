"""
nl_to_structured_query_ae.py
=============================
Natural Language -> Structured JSON -> Pandas, for a CDISC SDTM AE
(Adverse Events) dataset.

Architecture
------------
This version does NOT let the LLM write or execute arbitrary Pandas code.
Instead:

    1. The LLM is given the AE dataframe's schema + SDTM domain knowledge.
    2. It parses the user's question into a constrained JSON object
       (a `QuerySpec`) naming the target column(s) and filter value(s) —
       using LangChain's structured output (a Pydantic schema), so the
       model literally cannot return anything outside that shape.
    3. A deterministic Python translator turns that JSON into a Pandas
       operation, with every column/operator validated against an
       allow-list before anything touches the dataframe.

This is safer than agent-based code generation for real clinical data:
no eval(), no dynamic code execution, and every query is inspectable
and testable before it runs.

Setup
-----
    pip install langchain langchain-openai pandas
    pip install pyreadstat   # only needed for .xpt / .sas7bdat files

    export OPENAI_API_KEY="sk-..."   # or ANTHROPIC_API_KEY, see build_llm()

Run
---
    python nl_to_structured_query_ae.py path/to/ae.xpt
    python nl_to_structured_query_ae.py path/to/ae.sas7bdat
    python nl_to_structured_query_ae.py path/to/ae.csv

Then ask things like:
    - "How many subjects had a serious adverse event?"
    - "Show all events with severity SEVERE"
    - "What adverse events were reported as related to study drug?"
    - "Count of AEs by system organ class"
    - "Which subjects had an event with fatal outcome?"

Important disclaimer
---------------------
This is a coding pattern demo, not a validated clinical analysis tool.
Always have a qualified statistician/programmer review any output used
for regulatory submissions, safety signal decisions, or clinical
reporting.
"""

import sys
from typing import List, Literal, Optional, Union

import pandas as pd
from pydantic import BaseModel, Field

# ---------------------------------------------------------------------------
# 1. Load the real SDTM AE dataset (no synthetic data in this version)
# ---------------------------------------------------------------------------
#
# SDTM AE is the raw (non-derived) Adverse Events domain. Unlike ADaM ADAE,
# it has no TRTA/TRTEMFL — those are analysis-derived. Typical AE variables:
#   STUDYID   - Study identifier
#   DOMAIN    - Always "AE" for this domain
#   USUBJID   - Unique subject identifier
#   AESEQ     - Sequence number of the AE record within the subject
#   AETERM    - Verbatim (as-reported) adverse event term
#   AEDECOD   - MedDRA-coded preferred term
#   AELLT     - MedDRA lowest-level term (if coded to that granularity)
#   AEBODSYS  - MedDRA System Organ Class (SDTM often labels this AESOC too)
#   AESEV     - Severity: MILD / MODERATE / SEVERE
#   AESER     - Serious event flag: Y / N
#   AEACN     - Action taken with study treatment
#   AEREL     - Investigator-assessed relatedness/causality
#   AEOUT     - Outcome of the event
#   AESTDTC   - Start date/time of the event, ISO 8601 string (raw SDTM
#               dates are character, not proper datetimes, until derived)
#   AEENDTC   - End date/time of the event, ISO 8601 string

def load_ae(path: str) -> pd.DataFrame:
    """
    Load a real SDTM AE dataset from a SAS transport file (.xpt), a SAS
    dataset (.sas7bdat), or a CSV export. Requires `pyreadstat` for the
    SAS formats: pip install pyreadstat
    """
    lower = path.lower()
    if lower.endswith(".xpt"):
        import pyreadstat
        df, _meta = pyreadstat.read_xport(path)
    elif lower.endswith(".sas7bdat"):
        import pyreadstat
        df, _meta = pyreadstat.read_sas7bdat(path)
    elif lower.endswith(".csv"):
        df = pd.read_csv(path)
    else:
        raise ValueError(f"Unsupported file type: {path}")

    # Normalize to uppercase to match SDTM naming convention, in case the
    # source export lowercased them.
    df.columns = [c.upper() for c in df.columns]
    return df


def describe_schema(df: pd.DataFrame, sample_rows: int = 5) -> str:
    lines = []
    for col in df.columns:
        sample_vals = df[col].dropna().unique()[:sample_rows].tolist()
        lines.append(f"- {col} ({df[col].dtype}): sample values = {sample_vals}")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# 2. Structured JSON output schema (the "QuerySpec")
# ---------------------------------------------------------------------------
# This is the contract the LLM must fill in. It cannot return free text or
# arbitrary code — LangChain's structured output forces the response into
# this shape (or the call fails validation and we retry).

Operator = Literal["==", "!=", ">", "<", ">=", "<=", "contains", "in"]
Aggregation = Literal["count", "count_distinct_subjects", "sum", "mean"]


class FilterCondition(BaseModel):
    column: str = Field(description="The AE dataframe column to filter on, e.g. 'AESER'")
    operator: Operator = Field(description="Comparison operator to apply")
    value: Union[str, int, float, List[str]] = Field(
        description="Value to filter for, e.g. 'Y', 'SEVERE', or a list for 'in'"
    )


class QuerySpec(BaseModel):
    """Structured representation of a natural-language question about AE data."""

    target_column: Optional[str] = Field(
        default=None,
        description=(
            "The primary column the user is asking about or wants returned, "
            "e.g. 'AEDECOD' for 'what adverse events...', 'USUBJID' for "
            "'which subjects...'. Null if the question is a simple count."
        ),
    )
    filters: List[FilterCondition] = Field(
        default_factory=list,
        description="Filter conditions to apply, e.g. AESER == 'Y' for serious events",
    )
    groupby: Optional[List[str]] = Field(
        default=None,
        description="Columns to group by, e.g. ['AEBODSYS'] for 'count by system organ class'",
    )
    aggregation: Optional[Aggregation] = Field(
        default=None,
        description=(
            "Aggregation to compute. Use 'count_distinct_subjects' for "
            "subject-level counts (the common clinical question), 'count' "
            "for row counts."
        ),
    )
    assumption: Optional[str] = Field(
        default=None,
        description="Any assumption made to resolve ambiguity in the question, stated in plain English",
    )


# ---------------------------------------------------------------------------
# 3. LLM setup with structured output
# ---------------------------------------------------------------------------

def build_llm():
    """
    Returns a LangChain chat model configured to always return a QuerySpec.
    """
    # --- OpenAI (default) ---
    try:
        from langchain_openai import ChatOpenAI
        llm = ChatOpenAI(model="gpt-4o-mini", temperature=0)
    except ImportError:
        raise ImportError(
            "Install an LLM provider package, e.g.:\n"
            "  pip install langchain-openai    (for OpenAI models)\n"
            "  pip install langchain-anthropic (for Claude models)\n"
        )

    # To use Claude instead, comment out the block above and use:
    #
    # from langchain_anthropic import ChatAnthropic
    # llm = ChatAnthropic(model="claude-sonnet-4-5-20250929", temperature=0)

    return llm.with_structured_output(QuerySpec)


SYSTEM_PROMPT_TEMPLATE = """You convert natural language questions about a
CDISC SDTM AE (Adverse Events) dataset into a structured query.

The dataframe `df` has this schema:

{schema}

SDTM AE domain knowledge:
- One row = one adverse event record for one subject (USUBJID). A subject
  can have multiple AE rows.
- "Serious adverse event" / "SAE" means AESER == "Y".
- "Related to study drug" / "drug-related" means AEREL == "RELATED"
  (exact controlled-terminology value may vary — check sample values above).
- Severity (AESEV) is ordinal: MILD < MODERATE < SEVERE.
- AEDECOD is the MedDRA-coded preferred term (specific event). AEBODSYS
  (or AESOC) is the broader System Organ Class. Do not conflate them.
  AETERM is the raw, as-reported verbatim text — prefer AEDECOD for
  "what adverse events" questions unless the user asks for verbatim terms.
- This is raw SDTM, not derived ADaM: there is no treatment-arm or
  treatment-emergent flag unless one appears in the schema above. If the
  user asks about treatment arms and no such column exists, still return
  your best-effort QuerySpec, but note that in `assumption`.
- Questions like "how many subjects..." require aggregation
  "count_distinct_subjects", not a row count, since a subject may have
  multiple AE rows.
- Only ever reference columns that appear in the schema above. Never
  invent a column name.

Only use the given columns and produce a QuerySpec. If the question is
ambiguous, make the most reasonable assumption and record it in the
`assumption` field.
"""


# ---------------------------------------------------------------------------
# 4. Deterministic translator: QuerySpec -> Pandas (no eval, no exec)
# ---------------------------------------------------------------------------

_OPS = {
    "==": lambda s, v: s == v,
    "!=": lambda s, v: s != v,
    ">": lambda s, v: s > v,
    "<": lambda s, v: s < v,
    ">=": lambda s, v: s >= v,
    "<=": lambda s, v: s <= v,
    "contains": lambda s, v: s.astype(str).str.contains(str(v), case=False, na=False),
    "in": lambda s, v: s.isin(v if isinstance(v, list) else [v]),
}


class QueryValidationError(Exception):
    pass


def validate_spec(spec: QuerySpec, df: pd.DataFrame) -> None:
    valid_cols = set(df.columns)

    if spec.target_column and spec.target_column not in valid_cols:
        raise QueryValidationError(f"Unknown target_column: {spec.target_column!r}")

    for f in spec.filters:
        if f.column not in valid_cols:
            raise QueryValidationError(f"Unknown filter column: {f.column!r}")
        if f.operator not in _OPS:
            raise QueryValidationError(f"Unsupported operator: {f.operator!r}")

    if spec.groupby:
        for col in spec.groupby:
            if col not in valid_cols:
                raise QueryValidationError(f"Unknown groupby column: {col!r}")

    if spec.aggregation and spec.aggregation not in (
        "count", "count_distinct_subjects", "sum", "mean"
    ):
        raise QueryValidationError(f"Unsupported aggregation: {spec.aggregation!r}")


def run_query(spec: QuerySpec, df: pd.DataFrame) -> pd.DataFrame:
    """Executes a validated QuerySpec against df using only pandas ops
    resolved through the _OPS allow-list — no eval()/exec() anywhere."""
    result = df

    for f in spec.filters:
        mask = _OPS[f.operator](result[f.column], f.value)
        result = result[mask]

    if spec.groupby:
        if spec.aggregation == "count_distinct_subjects":
            result = (
                result.groupby(spec.groupby)["USUBJID"]
                .nunique()
                .reset_index(name="n_subjects")
            )
        elif spec.aggregation == "count":
            result = result.groupby(spec.groupby).size().reset_index(name="n_records")
        elif spec.aggregation in ("sum", "mean") and spec.target_column:
            result = (
                result.groupby(spec.groupby)[spec.target_column]
                .agg(spec.aggregation)
                .reset_index()
            )
        else:
            result = result.groupby(spec.groupby).size().reset_index(name="n_records")
    else:
        if spec.aggregation == "count_distinct_subjects":
            n = result["USUBJID"].nunique()
            result = pd.DataFrame({"n_subjects": [n]})
        elif spec.aggregation == "count":
            result = pd.DataFrame({"n_records": [len(result)]})
        elif spec.target_column:
            result = result[[spec.target_column]].drop_duplicates()

    return result


# ---------------------------------------------------------------------------
# 5. Question -> QuerySpec -> result, with validation retry
# ---------------------------------------------------------------------------

def ask(structured_llm, question: str, df: pd.DataFrame, max_retries: int = 2):
    schema = describe_schema(df)
    system_prompt = SYSTEM_PROMPT_TEMPLATE.format(schema=schema)

    messages = [
        {"role": "system", "content": system_prompt},
        {"role": "user", "content": question},
    ]

    last_error = None
    for attempt in range(max_retries + 1):
        spec: QuerySpec = structured_llm.invoke(messages)
        try:
            validate_spec(spec, df)
            result = run_query(spec, df)
            return spec, result
        except QueryValidationError as e:
            last_error = e
            messages.append({"role": "assistant", "content": spec.model_dump_json()})
            messages.append(
                {
                    "role": "user",
                    "content": (
                        f"That spec was invalid: {e}. Only use columns from "
                        f"the schema. Please correct and return a new QuerySpec."
                    ),
                }
            )

    raise QueryValidationError(f"Failed after {max_retries + 1} attempts: {last_error}")


# ---------------------------------------------------------------------------
# 6. CLI entrypoint
# ---------------------------------------------------------------------------

def main():
    if len(sys.argv) < 2:
        print("Usage: python nl_to_structured_query_ae.py path/to/ae.[xpt|sas7bdat|csv]")
        sys.exit(1)

    path = sys.argv[1]
    print(f"Loading SDTM AE dataset from: {path}")
    df = load_ae(path)
    print(f"\n{len(df)} rows, "
          f"{df['USUBJID'].nunique() if 'USUBJID' in df.columns else '?'} unique subjects\n")
    print(df.head())
    print("\nSchema:")
    print(describe_schema(df))
    print("\nType a question about the AE data, or 'quit' to exit.\n")

    structured_llm = build_llm()

    while True:
        try:
            question = input("Q> ").strip()
        except (EOFError, KeyboardInterrupt):
            print("\nExiting.")
            break

        if not question:
            continue
        if question.lower() in {"quit", "exit"}:
            break

        try:
            spec, result = ask(structured_llm, question, df)
        except QueryValidationError as e:
            print(f"\nCould not resolve a valid query: {e}\n")
            continue
        except Exception as e:  # noqa: BLE001
            print(f"\nError: {e}\n")
            continue

        print(f"\nParsed query: {spec.model_dump_json(indent=2, exclude_none=True)}")
        if spec.assumption:
            print(f"\nAssumption made: {spec.assumption}")
        print(f"\nResult:\n{result}\n")


if __name__ == "__main__":
    main()
