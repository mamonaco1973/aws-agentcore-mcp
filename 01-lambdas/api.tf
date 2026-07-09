# ================================================================================
# File: api.tf
# ================================================================================
# Purpose:
#   HTTP API that fronts the MCP connector. Every route targets the single MCP
#   router Lambda and is PUBLIC at the gateway — there is no AWS_IAM authorizer
#   anymore. Authentication is handled inside the Lambda:
#     - the OAuth endpoints broker a Cognito login (they ARE the auth)
#     - POST /mcp validates the Bearer as a Cognito access token (mcp.py)
#
#   Routes:
#     GET  /.well-known/oauth-authorization-server  → OAuth server metadata
#     POST /oauth/register                          → RFC 7591 dynamic registration
#     GET  /authorize                               → start Cognito login
#     GET  /oauth/callback                          → Cognito redirect target
#     POST /oauth/token                             → mac_ code → access token
#     POST /mcp                                      → MCP JSON-RPC
#
#   The six cost tools are NOT exposed here — the router invokes them directly
#   via lambda:InvokeFunction.
# ================================================================================

# --------------------------------------------------------------------------------
# RESOURCE: aws_apigatewayv2_api.costs_api
# --------------------------------------------------------------------------------
# HTTP API for the MCP connector. No CORS block: claude.ai calls /mcp server-to-
# server, and the OAuth endpoints are browser redirects, not fetch() calls.
# --------------------------------------------------------------------------------
resource "aws_apigatewayv2_api" "costs_api" {
  name          = "costs-mcp-api"
  protocol_type = "HTTP"
}

# --------------------------------------------------------------------------------
# RESOURCE: aws_apigatewayv2_integration.router
# --------------------------------------------------------------------------------
# One integration — the router Lambda handles every route.
# --------------------------------------------------------------------------------
resource "aws_apigatewayv2_integration" "router" {
  api_id                 = aws_apigatewayv2_api.costs_api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.mcp_router.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

# --------------------------------------------------------------------------------
# RESOURCE: aws_apigatewayv2_route — public OAuth + MCP routes
# --------------------------------------------------------------------------------
# No authorization_type on any route: the Lambda enforces auth. An API-GW
# authorizer would reject the OAuth handshake and the initial /mcp probe before
# the client ever presents a token.
# --------------------------------------------------------------------------------

resource "aws_apigatewayv2_route" "oauth_metadata" {
  api_id    = aws_apigatewayv2_api.costs_api.id
  route_key = "GET /.well-known/oauth-authorization-server"
  target    = "integrations/${aws_apigatewayv2_integration.router.id}"
}

resource "aws_apigatewayv2_route" "oauth_register" {
  api_id    = aws_apigatewayv2_api.costs_api.id
  route_key = "POST /oauth/register"
  target    = "integrations/${aws_apigatewayv2_integration.router.id}"
}

resource "aws_apigatewayv2_route" "oauth_authorize" {
  api_id    = aws_apigatewayv2_api.costs_api.id
  route_key = "GET /authorize"
  target    = "integrations/${aws_apigatewayv2_integration.router.id}"
}

resource "aws_apigatewayv2_route" "oauth_callback" {
  api_id    = aws_apigatewayv2_api.costs_api.id
  route_key = "GET /oauth/callback"
  target    = "integrations/${aws_apigatewayv2_integration.router.id}"
}

resource "aws_apigatewayv2_route" "oauth_token" {
  api_id    = aws_apigatewayv2_api.costs_api.id
  route_key = "POST /oauth/token"
  target    = "integrations/${aws_apigatewayv2_integration.router.id}"
}

resource "aws_apigatewayv2_route" "mcp" {
  api_id    = aws_apigatewayv2_api.costs_api.id
  route_key = "POST /mcp"
  target    = "integrations/${aws_apigatewayv2_integration.router.id}"
}

# --------------------------------------------------------------------------------
# RESOURCE: aws_apigatewayv2_stage.costs_stage
# --------------------------------------------------------------------------------
resource "aws_apigatewayv2_stage" "costs_stage" {
  api_id      = aws_apigatewayv2_api.costs_api.id
  name        = "$default"
  auto_deploy = true
}

# --------------------------------------------------------------------------------
# RESOURCE: aws_lambda_permission.allow_router_invoke
# --------------------------------------------------------------------------------
# Grant API Gateway permission to invoke the router Lambda.
# --------------------------------------------------------------------------------
resource "aws_lambda_permission" "allow_router_invoke" {
  statement_id  = "AllowAPIGatewayInvokeRouter"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.mcp_router.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.costs_api.execution_arn}/*/*"
}

# --------------------------------------------------------------------------------
# OUTPUT: mcp_endpoint — the URL users paste into their MCP client
# --------------------------------------------------------------------------------
output "mcp_endpoint" {
  description = "MCP connector URL — add this to claude.ai as a custom connector"
  value       = "${aws_apigatewayv2_api.costs_api.api_endpoint}/mcp"
}

output "api_base_url" {
  description = "Base API Gateway URL (OAuth endpoints live under here)"
  value       = aws_apigatewayv2_api.costs_api.api_endpoint
}
