#AWS #MCP #AgentCore #Bedrock #ClaudeAI

*Build a Remote MCP Server with Amazon Bedrock AgentCore Gateway*

What if AWS wrote the entire MCP front door for you — the protocol, the auth, the routing — and all you had to do was point it at your Lambda functions?

That is what Amazon Bedrock AgentCore Gateway does. In this project we connect Claude directly to our live AWS costs through a managed MCP gateway, secured with Amazon Cognito. Six Lambda functions become six MCP tools. There is no API Gateway, no router function, and no OAuth code — the Gateway speaks the protocol and validates the token for us.

Build that front door by hand and it is roughly seven hundred lines of code. Here, it is a single Terraform resource.

But there is a catch, and it shows up the moment you try to connect. AgentCore Gateway does not serve the two OAuth routes an MCP client needs in order to connect on its own — discovery (RFC 8414) and dynamic client registration (RFC 7591). So Claude cannot find the login, and it cannot register itself. You paste in an OAuth client ID and a client secret by hand. That is not a bug. It is AWS's documented flow.

We use AWS Cost Explorer as the example tool set, but the pattern works for any Lambda-backed MCP server. And we finish with an honest comparison, because managed is not automatically better. It is different.

WHAT YOU'LL LEARN
• Exposing Lambda functions as MCP tools with Bedrock AgentCore Gateway — no protocol code at all
• Securing the Gateway with a CUSTOM_JWT authorizer backed by an Amazon Cognito user pool
• Why AgentCore does not serve OAuth discovery or dynamic client registration, and exactly what that costs you
• Connecting claude.ai with a manually supplied OAuth client ID and secret — AWS's documented flow
• Managed versus hand-built — an honest look at what you actually trade away

INFRASTRUCTURE DEPLOYED
• Amazon Bedrock AgentCore Gateway (MCP protocol) with a CUSTOM_JWT authorizer
• 6 Gateway targets — one per Lambda, each with an inline tool schema the model sees
• 6 Cost Explorer Lambdas (Python 3.14), each with its own scoped execution role
• Gateway IAM role scoped to lambda:InvokeFunction on exactly those six functions
• Amazon Cognito user pool + Hosted UI + confidential OAuth client
• All provisioned with Terraform in a single apply, torn down with a single command

GitHub
https://github.com/mamonaco1973/aws-agentcore-mcp

README
https://github.com/mamonaco1973/aws-agentcore-mcp/blob/main/README.md

TIMESTAMPS
00:00 Introduction
00:38 Architecture
01:45 Securing MCP
02:39 Deploy It Yourself
