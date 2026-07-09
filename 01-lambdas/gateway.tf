# ================================================================================
# File: gateway.tf
#
# Purpose:
#   The AgentCore-native front door. A single Amazon Bedrock AgentCore Gateway
#   exposes the six cost Lambdas as MCP tools and enforces inbound auth via a
#   CUSTOM_JWT authorizer wired to the Cognito user pool. This replaces the entire
#   hand-built stack from the V1 project — oauth.py, mcp.py, router.py, the HTTP
#   API, and the OAuth state table are all gone; Gateway does that work.
#
#   Gateway assumes its own IAM role to invoke the target Lambdas, so no per-tool
#   API Gateway routes or lambda permissions are needed.
# ================================================================================

# --------------------------------------------------------------------------------
# Locals — one entry per MCP tool: the name the model sees, its description, and
# the backing Lambda. Drives both the gateway targets and the invoke policy so
# there is a single source of truth.
# --------------------------------------------------------------------------------
locals {
  cost_tools = {
    get_month_to_date_cost = {
      description = "Returns total AWS spend from the first of this month through today."
      lambda_arn  = aws_lambda_function.lambda_mtd.arn
    }
    get_cost_by_service = {
      description = "Returns month-to-date AWS spend broken down by service, sorted descending."
      lambda_arn  = aws_lambda_function.lambda_by_service.arn
    }
    compare_this_month_to_last_month = {
      description = "Compares this month MTD spend against last month full total."
      lambda_arn  = aws_lambda_function.lambda_compare.arn
    }
    get_daily_cost_trend = {
      description = "Returns day-by-day AWS spend for the current month with running totals."
      lambda_arn  = aws_lambda_function.lambda_daily.arn
    }
    find_top_cost_drivers = {
      description = "Returns the top 10 AWS services by spend this month with percentage share."
      lambda_arn  = aws_lambda_function.lambda_top_drivers.arn
    }
    forecast_month_end_cost = {
      description = "Forecasts remaining AWS spend through end of month with an 80% confidence range."
      lambda_arn  = aws_lambda_function.lambda_forecast.arn
    }
  }

  cognito_discovery_url = "https://cognito-idp.${data.aws_region.current.region}.amazonaws.com/${aws_cognito_user_pool.mcp.id}/.well-known/openid-configuration"
}

# ================================================================================
# IAM role assumed by the Gateway to invoke the target Lambdas
# ================================================================================
resource "aws_iam_role" "gateway_role" {
  name = "cost-agentcore-gateway-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "bedrock-agentcore.amazonaws.com" }
    }]
  })
}

# Least-privilege: invoke ONLY the six cost tool Lambdas. Gateway holds no Cost
# Explorer permission itself — each Lambda keeps its own scoped CE role.
resource "aws_iam_role_policy" "gateway_invoke" {
  name = "cost-agentcore-gateway-invoke"
  role = aws_iam_role.gateway_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["lambda:InvokeFunction"]
      Resource = [for t in local.cost_tools : t.lambda_arn]
    }]
  })
}

# ================================================================================
# The AgentCore Gateway — MCP protocol, Cognito JWT authorizer
#
# The CUSTOM_JWT authorizer validates every inbound token against the Cognito
# OIDC discovery document and only accepts tokens issued to the MCP app client.
# This is the managed equivalent of V1's mcp._get_auth_user + /oauth2/userInfo.
# ================================================================================
resource "aws_bedrockagentcore_gateway" "costs" {
  name          = "cost-agentcore-gw-${random_id.suffix.hex}"
  role_arn      = aws_iam_role.gateway_role.arn
  protocol_type = "MCP"

  authorizer_type = "CUSTOM_JWT"
  authorizer_configuration {
    custom_jwt_authorizer {
      discovery_url   = local.cognito_discovery_url
      allowed_clients = [aws_cognito_user_pool_client.mcp.id]
    }
  }
}

# ================================================================================
# Gateway targets — one per cost tool. Each wires a Lambda as an MCP tool and
# declares its schema inline. Tools take no input, so input_schema is an empty
# object. The Gateway invokes the Lambda with its own IAM role (gateway_iam_role).
# ================================================================================
resource "aws_bedrockagentcore_gateway_target" "cost" {
  for_each = local.cost_tools

  name               = replace(each.key, "_", "-")
  gateway_identifier = aws_bedrockagentcore_gateway.costs.gateway_id

  credential_provider_configuration {
    gateway_iam_role {}
  }

  target_configuration {
    mcp {
      lambda {
        lambda_arn = each.value.lambda_arn

        tool_schema {
          inline_payload {
            name        = each.key
            description = each.value.description

            input_schema {
              type = "object"
            }
          }
        }
      }
    }
  }
}

# ================================================================================
# Outputs
# ================================================================================
output "gateway_mcp_url" {
  description = "MCP endpoint URL — the connector target for Claude"
  value       = aws_bedrockagentcore_gateway.costs.gateway_url
}

output "gateway_id" {
  value = aws_bedrockagentcore_gateway.costs.gateway_id
}
