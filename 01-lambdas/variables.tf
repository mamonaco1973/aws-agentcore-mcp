# ================================================================================
# File: variables.tf
#
# Purpose:
#   Input variables for the Cost Explorer MCP stack. Only the optional test-user
#   knobs live here — everything else is derived at apply time.
# ================================================================================

# --------------------------------------------------------------------------------
# Optional seed user — set both to get a ready-to-log-in account after apply.
# Leave empty (the default) to manage users through the Cognito console instead.
# Pass via environment: TF_VAR_test_user_email / TF_VAR_test_user_password.
# --------------------------------------------------------------------------------
variable "test_user_email" {
  description = "Email for an optional seeded Cognito test user (empty = skip)."
  type        = string
  default     = ""
}

variable "test_user_password" {
  description = "Permanent password for the seeded test user (min 12 chars, upper/lower/number)."
  type        = string
  default     = ""
  sensitive   = true
}

# --------------------------------------------------------------------------------
# MCP client OAuth redirect URLs — Cognito requires an EXACT match, so these must
# be the precise callback(s) the connector uses. Defaults cover claude.ai /
# claude.com custom connectors. If your client uses a different (e.g. org-scoped)
# redirect, add it here — or front the Gateway with the DCR shim (see README).
# --------------------------------------------------------------------------------
variable "mcp_callback_urls" {
  description = "Exact OAuth callback URLs allowed for the MCP Cognito client."
  type        = list(string)
  default = [
    "https://claude.ai/api/mcp/auth_callback",
    "https://claude.com/api/mcp/auth_callback",
  ]
}
