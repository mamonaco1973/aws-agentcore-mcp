#AWS #MCP #ModelContextProtocol #AWSLambda #APIGateway #Terraform #Python #ClaudeDesktop #Serverless #IAM

*Build a Serverless MCP Backend on AWS (Lambda + API Gateway + SigV4)*

How do you expose serverless AWS tools to any AI client — securely, without managing servers, and without hardcoding anything in the proxy?

In this project we build a reusable MCP backend pattern on AWS: Lambda functions behind API Gateway with full IAM authorization, bridged to any MCP client by a lightweight stdio proxy that signs every request with SigV4.

The proxy makes the remote AWS backend look like a local tool server. The AI never knows the difference. We use AWS Cost Explorer as the example backend — but the pattern works for any Lambda-backed tool set.

The proxy itself contains zero tool-specific logic. It self-configures at startup by calling a /tools discovery endpoint, so you can add or remove tools without touching the proxy at all. Point it at a different endpoint and you have a completely different tool set.

This pattern works with Claude Desktop, OpenAI Codex, Cursor, and any other MCP client that supports stdio transport.

WHAT YOU'LL LEARN
• The serverless MCP backend pattern — how to make remote Lambda tools appear local to any AI client
• Writing a stdio MCP proxy in Bash (and PowerShell) that signs requests with AWS SigV4
• Securing API Gateway routes with AWS_IAM authorization — no API keys to manage or rotate
• Applying least-privilege IAM — one scoped execution role per Lambda, one proxy user with invoke-only rights
• Building a self-configuring /tools discovery endpoint so the proxy never needs hardcoded tool definitions
• Storing and retrieving proxy credentials from Secrets Manager

INFRASTRUCTURE DEPLOYED
• API Gateway HTTP API v2 — 7 routes, all AWS_IAM authorized (unsigned requests rejected before Lambda runs)
• 7 Lambda functions (Python 3.14) — 6 example tools + 1 self-configuring tool registry endpoint
• 7 IAM execution roles — one per Lambda, each scoped to only the permissions that function needs
• IAM user scoped to execute-api:Invoke on this API only — cannot call any AWS service directly
• Secrets Manager secret storing proxy credentials (key ID, secret, endpoint, region)
• MCP proxy (proxy.sh / proxy.ps1) — generic stdio bridge with SigV4 signing, zero tool-specific logic

GitHub
https://github.com/mamonaco1973/aws-serverless-mcp

README
https://github.com/mamonaco1973/aws-serverless-mcp/blob/main/README.md

TIMESTAMPS
00:00 Introduction
00:17 Architecture
01:09 Build the Code
01:25 Build Results
02:10 Demo
