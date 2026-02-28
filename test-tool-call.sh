#!/usr/bin/env bash
# Test k8s_get_resources tool via curl

set -e

USER="${1:-alice}"
GATEWAY_URL="gateway.kind.cluster:8080"

echo "🔍 Getting token for user: $USER"
TOKEN=$(./get-token.sh "$USER")

if [ -z "$TOKEN" ]; then
  echo "❌ Failed to get token"
  exit 1
fi

echo "✅ Token obtained"
echo ""

# Step 1: Initialize session
echo "📤 Initializing MCP session..."
INIT_RESPONSE=$(curl -si -X POST "http://$GATEWAY_URL/mcp" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H "Authorization: Bearer $TOKEN" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "initialize",
    "params": {
      "protocolVersion": "2024-11-05",
      "capabilities": {},
      "clientInfo": {
        "name": "curl-test",
        "version": "1.0.0"
      }
    }
  }')

SESSION_ID=$(echo "$INIT_RESPONSE" | grep -i '^mcp-session-id:' | sed 's/^[^:]*: *//;s/\r$//')

if [ -z "$SESSION_ID" ]; then
  echo "❌ Failed to get session ID"
  echo "$INIT_RESPONSE"
  exit 1
fi

echo "✅ Session initialized: $SESSION_ID"
echo ""

# Step 2: Call tool
echo "🚀 Calling k8s_get_resources tool..."
echo ""

curl -v -X POST "http://$GATEWAY_URL/mcp" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H "Authorization: Bearer $TOKEN" \
  -H "Mcp-Session-Id: $SESSION_ID" \
  -d '{
    "jsonrpc": "2.0",
    "id": 2,
    "method": "tools/call",
    "params": {
      "name": "k8s_get_resources",
      "arguments": {
        "namespace": "default",
        "resource_type": "pods"
      }
    }
  }'

echo ""
