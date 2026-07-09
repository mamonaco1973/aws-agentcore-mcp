# ================================================================================
# mcp.py
#
# MCP (Model Context Protocol) server over HTTP.
# Implements the streamable-HTTP transport — a plain POST carrying synchronous
# JSON-RPC 2.0. This is what claude.ai / Claude Desktop speak to a remote MCP
# connector; no local proxy or stdio bridge is involved.
#
# Auth: Bearer token in the Authorization header. The token is a Cognito access
# token issued by the claude.ai OAuth flow (see oauth.py) and validated here via
# Cognito's /oauth2/userInfo endpoint, which returns the user's email.
#
# Tools: the six Cost Explorer tools are backed by their own Lambda functions
# (cost-mtd, cost-by-service, …). This module is a thin MCP front door:
#   - tools/list  invokes the cost-tools Lambda to fetch TOOL_REGISTRY (the single
#                 source of truth in costs.py) and strips the internal `route`.
#   - tools/call  maps the tool name → Lambda function name (TOOL_FUNCTIONS env)
#                 and invokes it directly, returning its plain-text body.
# ================================================================================

import json
import logging
import os
import secrets
import urllib.request

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

_lambda      = boto3.client("lambda")
MCP_VERSION  = "2025-03-26"
_SERVER_NAME = "cost-explorer-mcp"
_SERVER_VER  = "1.0.0"

# Function that returns TOOL_REGISTRY (costs.tools_handler). Env-injected so the
# name stays owned by Terraform, not hardcoded here.
_TOOLS_FUNCTION = os.environ.get("TOOLS_FUNCTION", "cost-tools")

# Map of MCP tool name → backing Lambda function name, as a JSON object.
# Example: {"get_month_to_date_cost": "cost-mtd", ...}
_TOOL_FUNCTIONS = json.loads(os.environ.get("TOOL_FUNCTIONS", "{}"))


# ================================================================================
# HTTP + JSON-RPC helpers
# ================================================================================

def _ok(body, extra_headers=None):
    headers = {"Content-Type": "application/json"}
    if extra_headers:
        headers.update(extra_headers)
    return {"statusCode": 200, "headers": headers, "body": json.dumps(body)}


def _accepted():
    # Correct HTTP response for a JSON-RPC notification (no response body).
    return {"statusCode": 202, "headers": {}, "body": ""}


def _http_err(msg, status):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"error": msg}),
    }


def _rpc_error(req_id, code, message, extra_headers=None):
    return _ok(
        {"jsonrpc": "2.0", "id": req_id, "error": {"code": code, "message": message}},
        extra_headers,
    )


def _rpc_ok(req_id, result, extra_headers=None):
    return _ok({"jsonrpc": "2.0", "id": req_id, "result": result}, extra_headers)


# ================================================================================
# Auth — validate the Cognito access token via userInfo
# ================================================================================

_cognito_userinfo_url = None


def _get_cognito_userinfo_url():
    """Build the Cognito userInfo URL once and cache it in module memory."""
    global _cognito_userinfo_url
    if not _cognito_userinfo_url:
        domain = os.environ.get("COGNITO_DOMAIN", "")
        region = boto3.session.Session().region_name
        _cognito_userinfo_url = (
            f"https://{domain}.auth.{region}.amazoncognito.com/oauth2/userInfo"
        )
    return _cognito_userinfo_url


def _resolve_cognito_token(token):
    """Validate a Cognito access token via the userInfo endpoint.

    Calling userInfo is stateless — Cognito verifies the signature and expiry
    server-side, so no crypto library is needed here. Returns the user's email
    on success, or None if the token is invalid or expired.
    """
    req = urllib.request.Request(
        _get_cognito_userinfo_url(),
        headers={"Authorization": f"Bearer {token}"},
    )
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:  # nosec B310 - fixed Cognito userInfo endpoint, not user-controlled
            claims = json.loads(resp.read())
        return claims.get("email", "").lower().strip() or None
    except Exception:
        return None


def _get_auth_user(event):
    """Extract and resolve the Bearer token from the Authorization header."""
    headers = event.get("headers") or {}
    auth    = headers.get("authorization") or headers.get("Authorization") or ""
    if not auth.lower().startswith("bearer "):
        return None
    token = auth[7:].strip()
    return _resolve_cognito_token(token)


# ================================================================================
# Tool registry + invocation
# ================================================================================

def _load_registry():
    """Fetch TOOL_REGISTRY from the cost-tools Lambda (single source of truth).

    Returns the parsed list of tool descriptors (name, description, inputSchema,
    route), or an empty list on failure.
    """
    try:
        resp    = _lambda.invoke(FunctionName=_TOOLS_FUNCTION, Payload=b"{}")
        env     = json.loads(resp["Payload"].read())
        return json.loads(env.get("body", "[]"))
    except Exception:
        logger.exception("Failed to load tool registry from %s", _TOOLS_FUNCTION)
        return []


def _invoke_tool(function_name, user_email):
    """Invoke a backing cost Lambda and return its plain-text body.

    The caller's email is forwarded as the x-mcp-user header so the cost
    handler's audit log records who ran the tool (see costs._audit_log).
    """
    payload = json.dumps({"headers": {"x-mcp-user": user_email}}).encode()
    resp    = _lambda.invoke(FunctionName=function_name, Payload=payload)
    env     = json.loads(resp["Payload"].read())
    return env.get("body", "")


# ================================================================================
# JSON-RPC method handlers
# ================================================================================

def _handle_initialize(req, session_id):
    # Mcp-Session-Id is required by the 2025-03-26 streamable-HTTP transport.
    return _rpc_ok(
        req.get("id"),
        {
            "protocolVersion": MCP_VERSION,
            "capabilities":    {"tools": {}},
            "serverInfo":      {"name": _SERVER_NAME, "version": _SERVER_VER},
        },
        extra_headers={"Mcp-Session-Id": session_id},
    )


def _handle_tools_list(req):
    # Strip the internal `route` field — the AI sees only standard MCP fields.
    tools = [
        {"name": t["name"], "description": t["description"], "inputSchema": t["inputSchema"]}
        for t in _load_registry()
    ]
    return _rpc_ok(req.get("id"), {"tools": tools})


def _handle_tools_call(req, user_email):
    params    = req.get("params", {})
    tool_name = params.get("name", "")

    function_name = _TOOL_FUNCTIONS.get(tool_name)
    if not function_name:
        return _rpc_error(req.get("id"), -32601, f"Unknown tool: {tool_name}")

    logger.info("MCP tools/call: tool=%s fn=%s user=%s", tool_name, function_name, user_email)

    try:
        text = _invoke_tool(function_name, user_email)
    except Exception as exc:
        logger.exception("Tool invocation failed: %s", tool_name)
        return _rpc_error(req.get("id"), -32603, f"Tool invocation failed: {exc}")

    return _rpc_ok(req.get("id"), {"content": [{"type": "text", "text": text}]})


# ================================================================================
# Entry point — POST /mcp
# ================================================================================

def handle_mcp(event):
    """MCP JSON-RPC endpoint — auth via the OAuth Cognito access token."""
    user_id = _get_auth_user(event)
    if not user_id:
        return _http_err("Unauthorized — connect via the claude.ai OAuth flow", 401)

    try:
        req = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return _http_err("Invalid JSON", 400)

    method = req.get("method", "")
    logger.info("MCP request: method=%s user=%s", method, user_id)

    # Session ID is stateless — generated fresh on initialize, echoed back on
    # later requests via the Mcp-Session-Id header (accepted but not validated).
    session_id = (event.get("headers") or {}).get("mcp-session-id") or secrets.token_hex(16)

    if method == "initialize":
        return _handle_initialize(req, session_id)
    if method in ("notifications/initialized", "notifications/cancelled"):
        return _accepted()
    if method == "tools/list":
        return _handle_tools_list(req)
    if method == "tools/call":
        return _handle_tools_call(req, user_id)

    return _rpc_error(req.get("id"), -32601, f"Method not found: {method}")
