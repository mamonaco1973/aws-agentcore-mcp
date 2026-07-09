#!/bin/bash
# ================================================================================
# File: validate.sh
#
# Purpose:
#   Smoke-tests the six Cost Explorer Lambdas by invoking them directly via the
#   AWS CLI — confirming Cost Explorer connectivity independent of the Gateway.
#
# Notes:
#   - The live path for MCP clients is the AgentCore Gateway, gated by a Cognito
#     JWT. Direct Lambda invocation bypasses that so validation needs no OAuth.
#   - Handlers now return a plain-text string (Gateway relays it verbatim), not
#     an HTTP proxy envelope — so we read the payload directly with `jq -r .`.
#   - A Lambda that raises sets FunctionError; we treat that as a failure.
# ================================================================================

export AWS_DEFAULT_REGION="us-east-1"
set -euo pipefail

RESPONSE_FILE="/tmp/lambda_response.json"

# ------------------------------------------------------------------------------
# Helper: invoke a cost Lambda, print its text result, fail on FunctionError.
# ------------------------------------------------------------------------------
invoke_tool() {
  local fn_name="$1"
  local label="$2"

  echo ""
  echo "NOTE: Invoking ${label} (${fn_name})..."

  local meta
  meta=$(aws lambda invoke \
    --function-name "${fn_name}" \
    --payload '{}' \
    --cli-binary-format raw-in-base64-out \
    "${RESPONSE_FILE}")

  # FunctionError present → the handler raised; surface the raw payload.
  if echo "${meta}" | jq -e '.FunctionError' > /dev/null 2>&1; then
    echo "ERROR: ${label} raised an error:"
    cat "${RESPONSE_FILE}"
    exit 1
  fi

  # Handler returns a plain string; jq -r '.' unwraps the JSON string encoding.
  jq -r '.' "${RESPONSE_FILE}"
}

# ------------------------------------------------------------------------------
# Invoke each of the six cost tools
# ------------------------------------------------------------------------------

invoke_tool "cost-mtd"          "get_month_to_date_cost"
invoke_tool "cost-by-service"   "get_cost_by_service"
invoke_tool "cost-compare"      "compare_this_month_to_last_month"
invoke_tool "cost-daily"        "get_daily_cost_trend"
invoke_tool "cost-top-drivers"  "find_top_cost_drivers"
invoke_tool "cost-forecast"     "forecast_month_end_cost"

# ------------------------------------------------------------------------------
# Summary — print the live MCP endpoint from Terraform state, if available.
# ------------------------------------------------------------------------------

GATEWAY_URL=""
if [[ -d 01-lambdas ]]; then
  GATEWAY_URL=$( (cd 01-lambdas && terraform output -raw gateway_mcp_url) 2>/dev/null || true )
fi

echo ""
echo "========================================================================"
echo "  Validation complete — all six cost tools returned successfully."
echo "========================================================================"
if [[ -n "${GATEWAY_URL}" ]]; then
  echo "  MCP endpoint: ${GATEWAY_URL}"
  echo "  Auth: Cognito JWT via the AgentCore Gateway CUSTOM_JWT authorizer"
fi
echo "========================================================================"

# ================================================================================
# End of script
# ================================================================================
