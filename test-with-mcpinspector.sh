#!/usr/bin/env bash
# Test MCP gateway with MCP Inspector
# MCP Inspector should auto-discover OAuth and prompt for login

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATEWAY_URL="${GATEWAY_URL:-http://gateway.kind.cluster:8080/mcp}"

echo "🔍 Testing with MCP Inspector"
echo "=============================="
echo ""
echo "Gateway URL: $GATEWAY_URL"
echo ""
echo "MCP Inspector will:"
echo "  1. Fetch resource metadata from the gateway"
echo "  2. Auto-discover OAuth endpoints"
echo "  3. Prompt you to sign in"
echo "  4. Connect to the MCP server"
echo ""
echo "Expected behavior:"
echo "  ✅ Alice (kube-dev group) → Should see tools and can make calls"
echo "  ❌ unauthorized-user (restricted group) → Should be denied tool access"
echo ""
echo "Press Enter to launch MCP Inspector..."
read

# Trust the local root CA so the Inspector can reach Keycloak over HTTPS
export NODE_EXTRA_CA_CERTS="${SCRIPT_DIR}/.ssl/root-ca.pem"

# Launch MCP Inspector with the gateway URL
npx @modelcontextprotocol/inspector "$GATEWAY_URL"
