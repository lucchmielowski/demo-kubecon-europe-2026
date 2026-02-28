#!/usr/bin/env bash
# Test MCP gateway with curl using OAuth token

set -e

GATEWAY_URL="${GATEWAY_URL:-http://gateway.kind.cluster:8080}"

echo "🧪 Testing MCP Gateway with OAuth"
echo "=================================="
echo ""

# Step 1: Get token interactively
echo "📝 Step 1: Sign in to get token..."
TOKEN=$(./login-interactive.sh)

if [ -z "$TOKEN" ]; then
  echo "❌ Failed to get token" >&2
  exit 1
fi

echo ""
echo "✅ Got token!"
echo ""

# Decode and show user info
# JWT tokens use base64url encoding
decode_jwt_payload() {
  local payload=$(echo "$1" | cut -d. -f2)
  # Convert base64url to base64: replace - with + and _ with /
  payload=$(echo "$payload" | tr -- '-_' '+/')
  # Add padding if needed
  local padding=$((4 - ${#payload} % 4))
  if [ $padding -ne 4 ]; then
    payload="${payload}$(printf '=%.0s' $(seq 1 $padding))"
  fi
  echo "$payload" | base64 -d 2>/dev/null || true
}

# Decode with error handling - temporarily disable set -e
set +e
DECODED=$(decode_jwt_payload "$TOKEN")
USERNAME=$(echo "$DECODED" | jq -r '.preferred_username // .email' 2>/dev/null || echo "unknown")
USER_GROUPS=$(echo "$DECODED" | jq -r '.groups // [] | join(", ")' 2>/dev/null || echo "")
set -e

echo "👤 Signed in as: $USERNAME"
echo "👥 Groups: $USER_GROUPS"
echo ""

# Step 2: Initialize MCP session
echo "📤 Step 2: Initializing MCP session..."
echo ""

INIT_REQUEST='{
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
}'

# Temporarily disable set -e for curl commands (they may fail to connect)
set +e
INIT_RESPONSE=$(curl -s --connect-timeout 5 --max-time 10 -X POST "$GATEWAY_URL/mcp" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Authorization: Bearer $TOKEN" \
  -d "$INIT_REQUEST" 2>&1)

HTTP_CODE=$(curl -s --connect-timeout 5 --max-time 10 -o /dev/null -w "%{http_code}" -X POST "$GATEWAY_URL/mcp" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Authorization: Bearer $TOKEN" \
  -d "$INIT_REQUEST")
set -e

echo "HTTP Status: $HTTP_CODE"
echo ""

if [ -z "$HTTP_CODE" ] || [ "$HTTP_CODE" = "000" ]; then
  echo "❌ Failed to connect to gateway at $GATEWAY_URL"
  echo ""
  echo "Make sure the MCP gateway is running:"
  echo "  kubectl port-forward -n mcp-system svc/mcp-gateway 8080:80"
  exit 1
elif [ "$HTTP_CODE" != "200" ]; then
  if [ "$HTTP_CODE" = "401" ]; then
    echo "❌ Request DENIED - 401 Unauthorized"
    echo ""
    echo "This means the user '$USERNAME' is not in an authorized group (kube-dev or kube-admin)"
    echo "User groups: $USER_GROUPS"
  elif [ "$HTTP_CODE" = "403" ]; then
    echo "❌ Request DENIED - 403 Forbidden"
    echo ""
    echo "Authorization policy denied the request"
  else
    echo "⚠️  Unexpected status code: $HTTP_CODE"
    echo ""
    echo "Response:"
    echo "$INIT_RESPONSE"
  fi
  exit 1
fi

echo "✅ Session initialized!"
echo ""

# Extract session ID from response headers
SESSION_ID=$(curl -s --connect-timeout 5 --max-time 10 -i -X POST "$GATEWAY_URL/mcp" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Authorization: Bearer $TOKEN" \
  -d "$INIT_REQUEST" 2>/dev/null | grep -i '^mcp-session-id:' | sed 's/^[^:]*: *//;s/\r$//')

if [ -z "$SESSION_ID" ]; then
  echo "⚠️  No session ID returned, trying to proceed anyway..."
  echo ""
fi

# Step 3: Test MCP request
echo "📤 Step 3: Making MCP request (tools/list)..."
echo ""

MCP_REQUEST='{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "tools/list"
}'

# Temporarily disable set -e for curl commands
set +e
if [ -n "$SESSION_ID" ]; then
  RESPONSE=$(curl -s --connect-timeout 5 --max-time 10 -X POST "$GATEWAY_URL/mcp" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -H "Authorization: Bearer $TOKEN" \
    -H "MCP-Session-ID: $SESSION_ID" \
    -d "$MCP_REQUEST" 2>&1)

  HTTP_CODE=$(curl -s --connect-timeout 5 --max-time 10 -o /dev/null -w "%{http_code}" -X POST "$GATEWAY_URL/mcp" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -H "Authorization: Bearer $TOKEN" \
    -H "MCP-Session-ID: $SESSION_ID" \
    -d "$MCP_REQUEST")
else
  RESPONSE=$(curl -s --connect-timeout 5 --max-time 10 -X POST "$GATEWAY_URL/mcp" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -H "Authorization: Bearer $TOKEN" \
    -d "$MCP_REQUEST" 2>&1)

  HTTP_CODE=$(curl -s --connect-timeout 5 --max-time 10 -o /dev/null -w "%{http_code}" -X POST "$GATEWAY_URL/mcp" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -H "Authorization: Bearer $TOKEN" \
    -d "$MCP_REQUEST")
fi
set -e

echo "HTTP Status: $HTTP_CODE"
echo ""

if [ "$HTTP_CODE" = "200" ]; then
  echo "✅ Request ALLOWED!"
  echo ""
  echo "Response:"
  echo "$RESPONSE" | jq '.' 2>/dev/null || echo "$RESPONSE"
elif [ "$HTTP_CODE" = "401" ]; then
  echo "❌ Request DENIED - 401 Unauthorized"
  echo ""
  echo "This means the user '$USERNAME' is not in an authorized group (kube-dev or kube-admin)"
  echo "User groups: $USER_GROUPS"
elif [ "$HTTP_CODE" = "403" ]; then
  echo "❌ Request DENIED - 403 Forbidden"
  echo ""
  echo "Authorization policy denied the request"
else
  echo "⚠️  Unexpected status code: $HTTP_CODE"
  echo ""
  echo "Response:"
  echo "$RESPONSE"
fi