# ================================================================================
# File: lambda-mcp.tf
#
# Purpose:
#   Deploys the MCP router Lambda — the connector's single front door. It serves
#   the public OAuth endpoints (oauth.py) and the MCP JSON-RPC endpoint (mcp.py).
#   On tools/call it invokes the appropriate backing cost Lambda directly; those
#   six functions are no longer exposed through API Gateway.
#
# Handler:
#   router.lambda_handler  (code/router.py → oauth.py + mcp.py)
# ================================================================================

# --------------------------------------------------------------------------------
# Locals — tool-name → backing Lambda function name, injected as a JSON env var.
# Single source of truth for the mapping mcp.py uses on tools/call.
# --------------------------------------------------------------------------------
locals {
  mcp_tool_functions = {
    get_month_to_date_cost           = aws_lambda_function.lambda_mtd.function_name
    get_cost_by_service              = aws_lambda_function.lambda_by_service.function_name
    compare_this_month_to_last_month = aws_lambda_function.lambda_compare.function_name
    get_daily_cost_trend             = aws_lambda_function.lambda_daily.function_name
    find_top_cost_drivers            = aws_lambda_function.lambda_top_drivers.function_name
    forecast_month_end_cost          = aws_lambda_function.lambda_forecast.function_name
  }

  # All Lambdas the router may invoke: the six cost tools + the tool registry.
  mcp_invokable_arns = [
    aws_lambda_function.lambda_mtd.arn,
    aws_lambda_function.lambda_by_service.arn,
    aws_lambda_function.lambda_compare.arn,
    aws_lambda_function.lambda_daily.arn,
    aws_lambda_function.lambda_top_drivers.arn,
    aws_lambda_function.lambda_forecast.arn,
    aws_lambda_function.lambda_tools.arn,
  ]
}

# --------------------------------------------------------------------------------
# RESOURCE: aws_iam_role.mcp_router_role
# --------------------------------------------------------------------------------
resource "aws_iam_role" "mcp_router_role" {
  name = "cost-mcp-router-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
      Effect    = "Allow"
    }]
  })
}

# CloudWatch Logs for the router itself.
resource "aws_iam_role_policy_attachment" "mcp_router_basic" {
  role       = aws_iam_role.mcp_router_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# --------------------------------------------------------------------------------
# RESOURCE: aws_iam_role_policy.mcp_router_invoke
# --------------------------------------------------------------------------------
# Least-privilege: invoke ONLY the seven cost/registry Lambdas — the router holds
# no Cost Explorer permission itself; each backing Lambda keeps its scoped role.
# --------------------------------------------------------------------------------
resource "aws_iam_role_policy" "mcp_router_invoke" {
  name = "cost-mcp-router-invoke"
  role = aws_iam_role.mcp_router_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["lambda:InvokeFunction"]
      Resource = local.mcp_invokable_arns
    }]
  })
}

# --------------------------------------------------------------------------------
# RESOURCE: aws_iam_role_policy.mcp_router_dynamo
# --------------------------------------------------------------------------------
# Read/write the transient OAuth state table (PENDINGAUTH / AUTHCODE records).
# --------------------------------------------------------------------------------
resource "aws_iam_role_policy" "mcp_router_dynamo" {
  name = "cost-mcp-router-dynamo"
  role = aws_iam_role.mcp_router_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "dynamodb:GetItem",
        "dynamodb:PutItem",
        "dynamodb:DeleteItem",
      ]
      Resource = aws_dynamodb_table.oauth_state.arn
    }]
  })
}

# --------------------------------------------------------------------------------
# RESOURCE: aws_lambda_function.mcp_router
# --------------------------------------------------------------------------------
resource "aws_lambda_function" "mcp_router" {
  function_name    = "cost-mcp-router"
  role             = aws_iam_role.mcp_router_role.arn
  runtime          = "python3.14"
  handler          = "router.lambda_handler"
  filename         = data.archive_file.lambdas_zip.output_path
  source_code_hash = data.archive_file.lambdas_zip.output_base64sha256
  timeout          = 30

  environment {
    variables = {
      TABLE_NAME        = aws_dynamodb_table.oauth_state.name
      COGNITO_DOMAIN    = aws_cognito_user_pool_domain.mcp.domain
      MCP_CLIENT_ID     = aws_cognito_user_pool_client.mcp.id
      MCP_CLIENT_SECRET = aws_cognito_user_pool_client.mcp.client_secret
      TOOLS_FUNCTION    = aws_lambda_function.lambda_tools.function_name
      TOOL_FUNCTIONS    = jsonencode(local.mcp_tool_functions)
    }
  }
}
