"""
costs.py — Lambda handlers for the AWS Cost Explorer MCP API.

This module consolidates all six cost query tools into a single Python file.
Each tool is a top-level handler wired to its own Lambda function and IAM role
via Terraform, while sharing the boto3 Cost Explorer client and date helpers.

Handler → Lambda function → MCP tool mapping:
    mtd_handler          →  cost-mtd          →  get_month_to_date_cost
    by_service_handler   →  cost-by-service   →  get_cost_by_service
    compare_handler      →  cost-compare      →  compare_this_month_to_last_month
    daily_handler        →  cost-daily        →  get_daily_cost_trend
    top_drivers_handler  →  cost-top-drivers  →  find_top_cost_drivers
    forecast_handler     →  cost-forecast     →  forecast_month_end_cost

Each Lambda is registered as an AgentCore Gateway target (see gateway.tf). The
tool name, description, and inputSchema are declared in the target's tool_schema
block, so there is no in-code tool registry in this version.

Response format:
    Handlers return a plain-text summary string, which AgentCore Gateway relays
    verbatim as the MCP tool result. This lets the AI narrate results without
    parsing nested ResultsByTime arrays. (In the API-Gateway version these were
    wrapped in an HTTP proxy envelope; Gateway Lambda targets use the raw return
    value instead.)

Cost Explorer notes:
    - CE is a global AWS service — the boto3 client always targets us-east-1.
    - CE date ranges are [start, end) — end is exclusive.
    - CE data has a 24–48 hour lag; today's spend may not yet be visible.
    - GetCostForecast requires at least one day of historical data and will
      raise DataUnavailableException on brand-new accounts.

Authentication:
    These handlers are not exposed directly. AgentCore Gateway validates the
    caller's Cognito JWT (its CUSTOM_JWT authorizer) and then invokes the target
    Lambda with the Gateway's IAM role. Each function keeps its own least-privilege
    execution role scoped to ce:GetCostAndUsage and/or ce:GetCostForecast.
"""

from datetime import datetime, timezone, timedelta
from calendar import monthrange

import boto3
from botocore.exceptions import ClientError

# ---------------------------------------------------------------------------
# Module-level singletons
# ---------------------------------------------------------------------------

# CE is a global service — endpoint must be us-east-1 regardless of the
# Lambda deployment region.
ce = boto3.client("ce", region_name="us-east-1")


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

def _audit_log(event: dict, tool: str) -> None:
    """Log the tool invocation for audit purposes.

    Caller identity is enforced upstream by the Gateway's CUSTOM_JWT authorizer
    (a validated Cognito token), so it is not re-derived here. The event holds
    only the tool's input arguments. `event` is kept in the signature for call-
    site symmetry across handlers.

    Args:
        event (dict): Tool input arguments passed by AgentCore Gateway (unused).
        tool (str): Name of the MCP tool being invoked.
    """
    print(f"AUDIT tool={tool}")


def _response(status_code: int, text: str) -> str:
    """Return the plain-text tool result for AgentCore Gateway.

    Gateway relays a Lambda target's return value straight to the client as the
    MCP tool result, so we return the summary string directly. `status_code` is
    accepted for call-site symmetry (some handlers pass 500 on error) but is not
    encoded in the response — an error simply comes back as its text.

    Args:
        status_code (int): Legacy status hint from call sites (unused).
        text (str): Plain-text summary for AI narration.

    Returns:
        str: The summary text, used verbatim as the tool result.
    """
    return text


def _mtd_window():
    """Return (start, end) strings for a month-to-date CE query.

    CE end dates are exclusive. End is set to tomorrow so any partial
    data ingested for today is included in the result.

    Returns:
        tuple[str, str]: (first of current month, tomorrow) as YYYY-MM-DD.
    """
    now = datetime.now(timezone.utc)
    start = f"{now.year}-{now.month:02d}-01"
    tomorrow = (now + timedelta(days=1)).strftime("%Y-%m-%d")
    return start, tomorrow


def _full_month_window(year: int, month: int):
    """Return (start, end) strings covering a complete calendar month.

    CE end dates are exclusive — end is set to the first day of the
    following month.

    Args:
        year (int): 4-digit year.
        month (int): Month number (1–12).

    Returns:
        tuple[str, str]: (first of month, first of next month) as YYYY-MM-DD.
    """
    start = f"{year}-{month:02d}-01"
    if month == 12:
        end = f"{year + 1}-01-01"
    else:
        end = f"{year}-{month + 1:02d}-01"
    return start, end


def _prev_month():
    """Return (year, month) for the previous calendar month.

    Returns:
        tuple[int, int]: (year, month) of last month.
    """
    now = datetime.now(timezone.utc)
    if now.month == 1:
        return now.year - 1, 12
    return now.year, now.month - 1


def _sum_cost(response: dict) -> float:
    """Sum BlendedCost across all ResultsByTime entries in a CE response.

    Args:
        response (dict): Raw GetCostAndUsage response from Cost Explorer.

    Returns:
        float: Total blended cost in USD.
    """
    total = 0.0
    for result in response.get("ResultsByTime", []):
        total += float(
            result.get("Total", {})
            .get("BlendedCost", {})
            .get("Amount", 0)
        )
    return total


# ---------------------------------------------------------------------------
# Tool metadata
# ---------------------------------------------------------------------------
# Unlike the API-Gateway version, tool name / description / inputSchema are NOT
# defined here. AgentCore Gateway owns that metadata: each Lambda is registered
# as a gateway target whose tool_schema block (gateway.tf) declares the tool the
# model sees. The mapping of handler → tool name is in the module docstring.


# ---------------------------------------------------------------------------
# MCP tool handlers
# ---------------------------------------------------------------------------

def mtd_handler(event, context):
    """Return total AWS spend from the first of this month to today.

    Args:
        event (dict): Tool input arguments from AgentCore Gateway (unused).
        context (obj): Lambda context object (unused).

    Returns:
        str: Plain-text MTD cost summary, or an error message on CE failure.
    """
    _audit_log(event, "get_month_to_date_cost")
    start, end = _mtd_window()

    try:
        resp = ce.get_cost_and_usage(
            TimePeriod={"Start": start, "End": end},
            Granularity="MONTHLY",
            Metrics=["BlendedCost"],
        )
    except ClientError as exc:
        msg = exc.response["Error"]["Message"]
        return _response(500, f"Cost Explorer error: {msg}")

    total = _sum_cost(resp)
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    return _response(
        200,
        f"Month-to-date AWS cost ({start} through {today}): ${total:,.2f} USD",
    )


def by_service_handler(event, context):
    """Return MTD cost broken down by AWS service, sorted descending.

    Args:
        event (dict): Tool input arguments from AgentCore Gateway (unused).
        context (obj): Lambda context object (unused).

    Returns:
        str: Per-service cost breakdown, or an error message on CE failure.
    """
    _audit_log(event, "get_cost_by_service")
    start, end = _mtd_window()

    try:
        resp = ce.get_cost_and_usage(
            TimePeriod={"Start": start, "End": end},
            Granularity="MONTHLY",
            Metrics=["BlendedCost"],
            GroupBy=[{"Type": "DIMENSION", "Key": "SERVICE"}],
        )
    except ClientError as exc:
        msg = exc.response["Error"]["Message"]
        return _response(500, f"Cost Explorer error: {msg}")

    services = {}
    for result in resp.get("ResultsByTime", []):
        for group in result.get("Groups", []):
            name = group["Keys"][0]
            amount = float(group["Metrics"]["BlendedCost"]["Amount"])
            services[name] = services.get(name, 0.0) + amount

    if not services:
        return _response(200, "No service cost data found for the current month.")

    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    lines = [f"AWS cost by service ({start} through {today}):"]
    for svc, cost in sorted(services.items(), key=lambda x: x[1], reverse=True):
        if cost >= 0.001:
            lines.append(f"  {svc}: ${cost:,.2f}")
    return _response(200, "\n".join(lines))


def compare_handler(event, context):
    """Compare total cost between this month (MTD) and last month (full).

    Args:
        event (dict): Tool input arguments from AgentCore Gateway (unused).
        context (obj): Lambda context object (unused).

    Returns:
        str: Month-over-month comparison, or an error message on CE failure.
    """
    _audit_log(event, "compare_this_month_to_last_month")
    this_start, this_end = _mtd_window()
    prev_year, prev_month = _prev_month()
    last_start, last_end = _full_month_window(prev_year, prev_month)

    try:
        this_resp = ce.get_cost_and_usage(
            TimePeriod={"Start": this_start, "End": this_end},
            Granularity="MONTHLY",
            Metrics=["BlendedCost"],
        )
        last_resp = ce.get_cost_and_usage(
            TimePeriod={"Start": last_start, "End": last_end},
            Granularity="MONTHLY",
            Metrics=["BlendedCost"],
        )
    except ClientError as exc:
        msg = exc.response["Error"]["Message"]
        return _response(500, f"Cost Explorer error: {msg}")

    this_cost = _sum_cost(this_resp)
    last_cost = _sum_cost(last_resp)
    delta = this_cost - last_cost
    pct = (delta / last_cost * 100) if last_cost > 0 else 0.0
    direction = "higher" if delta >= 0 else "lower"

    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    lines = [
        "Month-over-month cost comparison:",
        f"  Last month  ({last_start[:7]}, full):    ${last_cost:,.2f}",
        f"  This month  ({this_start[:7]}, MTD):     ${this_cost:,.2f}",
        f"  Difference: ${abs(delta):,.2f} {direction} ({abs(pct):.1f}%)",
        f"  Note: this month is MTD through {today}; not a full-month comparison.",
    ]
    return _response(200, "\n".join(lines))


def daily_handler(event, context):
    """Return the daily cost trend for the current month.

    Args:
        event (dict): Tool input arguments from AgentCore Gateway (unused).
        context (obj): Lambda context object (unused).

    Returns:
        str: One line per day of spend, or an error message on CE failure.
    """
    _audit_log(event, "get_daily_cost_trend")
    start, end = _mtd_window()

    try:
        resp = ce.get_cost_and_usage(
            TimePeriod={"Start": start, "End": end},
            Granularity="DAILY",
            Metrics=["BlendedCost"],
        )
    except ClientError as exc:
        msg = exc.response["Error"]["Message"]
        return _response(500, f"Cost Explorer error: {msg}")

    results = resp.get("ResultsByTime", [])
    if not results:
        return _response(200, "No daily cost data available yet for this month.")

    lines = ["Daily AWS cost trend (current month):"]
    running = 0.0
    for result in results:
        date = result["TimePeriod"]["Start"]
        amount = float(
            result.get("Total", {}).get("BlendedCost", {}).get("Amount", 0)
        )
        running += amount
        lines.append(f"  {date}: ${amount:,.2f}  (running total: ${running:,.2f})")
    return _response(200, "\n".join(lines))


def top_drivers_handler(event, context):
    """Return the top 10 AWS cost drivers for the current month.

    Args:
        event (dict): Tool input arguments from AgentCore Gateway (unused).
        context (obj): Lambda context object (unused).

    Returns:
        str: Ranked list of services by spend, or an error message on CE failure.
    """
    _audit_log(event, "find_top_cost_drivers")
    start, end = _mtd_window()

    try:
        resp = ce.get_cost_and_usage(
            TimePeriod={"Start": start, "End": end},
            Granularity="MONTHLY",
            Metrics=["BlendedCost"],
            GroupBy=[{"Type": "DIMENSION", "Key": "SERVICE"}],
        )
    except ClientError as exc:
        msg = exc.response["Error"]["Message"]
        return _response(500, f"Cost Explorer error: {msg}")

    services = {}
    for result in resp.get("ResultsByTime", []):
        for group in result.get("Groups", []):
            name = group["Keys"][0]
            amount = float(group["Metrics"]["BlendedCost"]["Amount"])
            services[name] = services.get(name, 0.0) + amount

    if not services:
        return _response(200, "No cost data found for the current month.")

    ranked = sorted(services.items(), key=lambda x: x[1], reverse=True)[:10]
    total = sum(services.values())
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")

    lines = [f"Top AWS cost drivers ({start} through {today}):"]
    for i, (svc, cost) in enumerate(ranked, start=1):
        pct = (cost / total * 100) if total > 0 else 0.0
        lines.append(f"  {i:2d}. {svc}: ${cost:,.2f} ({pct:.1f}% of total)")
    lines.append(f"\n  Total across all services: ${total:,.2f}")
    return _response(200, "\n".join(lines))


def forecast_handler(event, context):
    """Forecast remaining AWS spend through end of this month.

    Uses GetCostForecast to project cost from today through the last
    day of the current month, including a confidence interval.

    Args:
        event (dict): Tool input arguments from AgentCore Gateway (unused).
        context (obj): Lambda context object (unused).

    Returns:
        str: Forecast amount and confidence range, an explanatory note when no
             forecast is needed, or an error message on failure.
    """
    _audit_log(event, "forecast_month_end_cost")
    now = datetime.now(timezone.utc)
    today = now.strftime("%Y-%m-%d")

    # CE forecast end date is exclusive — use first day of next month.
    if now.month == 12:
        end_exclusive = f"{now.year + 1}-01-01"
    else:
        end_exclusive = f"{now.year}-{now.month + 1:02d}-01"

    last_day = monthrange(now.year, now.month)[1]
    last_day_str = f"{now.year}-{now.month:02d}-{last_day:02d}"

    if today >= last_day_str:
        return _response(
            200,
            f"Today is the last day of {now.strftime('%B %Y')} — no forecast needed.",
        )

    try:
        resp = ce.get_cost_forecast(
            TimePeriod={"Start": today, "End": end_exclusive},
            Metric="BLENDED_COST",
            Granularity="MONTHLY",
            PredictionIntervalLevel=80,
        )
    except ClientError as exc:
        code = exc.response["Error"]["Code"]
        msg = exc.response["Error"]["Message"]
        # DataUnavailableException means insufficient history for a forecast.
        if code == "DataUnavailableException":
            return _response(
                200,
                "Forecast unavailable — not enough cost history yet (typically needs 1+ month).",
            )
        return _response(500, f"Cost Explorer error: {msg}")

    mean = float(resp.get("Total", {}).get("Amount", 0))
    intervals = resp.get("ForecastResultsByTime", [])
    low = high = mean
    if intervals:
        low = float(intervals[0].get("PredictionIntervalLowerBound", mean))
        high = float(intervals[0].get("PredictionIntervalUpperBound", mean))

    lines = [
        f"AWS cost forecast — remaining {now.strftime('%B %Y')} ({today} through {last_day_str}):",
        f"  Estimated remaining spend: ${mean:,.2f}",
        f"  80% confidence range:      ${low:,.2f} – ${high:,.2f}",
    ]
    return _response(200, "\n".join(lines))
