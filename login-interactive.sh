#!/usr/bin/env bash
# Interactive OAuth Device Code flow for MCP authentication
# User will be prompted to sign in via browser as alice or unauthorized-user.

set -e

CLIENT_ID="${1:-mcp-inspector}"
KEYCLOAK_URL="http://keycloak.kind.cluster:8080/realms/master"

echo "🔐 Starting OAuth Device Code flow..." >&2
echo "" >&2

# Step 1: Request device code
DEVICE_RESPONSE=$(curl -s -X POST "$KEYCLOAK_URL/protocol/openid-connect/auth/device" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d "client_id=$CLIENT_ID")

DEVICE_CODE=$(echo "$DEVICE_RESPONSE" | jq -r '.device_code')
USER_CODE=$(echo "$DEVICE_RESPONSE" | jq -r '.user_code')
VERIFICATION_URI=$(echo "$DEVICE_RESPONSE" | jq -r '.verification_uri_complete // .verification_uri')
INTERVAL=$(echo "$DEVICE_RESPONSE" | jq -r '.interval // 5')

if [ "$DEVICE_CODE" = "null" ] || [ -z "$DEVICE_CODE" ]; then
  echo "❌ Failed to get device code" >&2
  echo "$DEVICE_RESPONSE" | jq >&2
  exit 1
fi

# Step 2: Show user where to authenticate
echo "📱 Please sign in:" >&2
echo "" >&2
echo "   URL: $VERIFICATION_URI" >&2
echo "   Code: $USER_CODE" >&2
echo "" >&2

# Open browser automatically if possible
if command -v open >/dev/null 2>&1; then
  open "$VERIFICATION_URI" 2>/dev/null || true
fi

echo "⏳ Waiting for you to complete sign-in..." >&2

# Step 3: Poll for token
MAX_ATTEMPTS=60
ATTEMPT=0

while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
  sleep "$INTERVAL"
  ATTEMPT=$((ATTEMPT + 1))

  TOKEN_RESPONSE=$(curl -s -X POST "$KEYCLOAK_URL/protocol/openid-connect/token" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -d "client_id=$CLIENT_ID" \
    -d "grant_type=urn:ietf:params:oauth:grant-type:device_code" \
    -d "device_code=$DEVICE_CODE" 2>/dev/null)

  ERROR=$(echo "$TOKEN_RESPONSE" | jq -r '.error // ""')

  if [ "$ERROR" = "authorization_pending" ]; then
    # Still waiting for user
    echo -n "." >&2
    continue
  elif [ "$ERROR" = "slow_down" ]; then
    # Increase polling interval
    INTERVAL=$((INTERVAL + 5))
    echo -n "." >&2
    continue
  elif [ -n "$ERROR" ] && [ "$ERROR" != "null" ] && [ "$ERROR" != "" ]; then
    # Error occurred
    echo "" >&2
    echo "❌ Authentication failed: $ERROR" >&2
    echo "$TOKEN_RESPONSE" | jq >&2
    exit 1
  fi

  # Check if we got a token
  ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.access_token // ""')
  if [ -n "$ACCESS_TOKEN" ] && [ "$ACCESS_TOKEN" != "null" ]; then
    echo "" >&2
    echo "✅ Authentication successful!" >&2

    # Decode token to show who signed in (JWT uses base64url encoding)
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
    DECODED=$(decode_jwt_payload "$ACCESS_TOKEN")
    USERNAME=$(echo "$DECODED" | jq -r '.preferred_username // .email // .sub' 2>/dev/null || echo "unknown")
    USER_GROUPS=$(echo "$DECODED" | jq -r '.groups // [] | join(", ")' 2>/dev/null || echo "")
    set -e

    echo "👤 Signed in as: $USERNAME" >&2
    if [ -n "$USER_GROUPS" ] && [ "$USER_GROUPS" != "null" ] && [ "$USER_GROUPS" != "" ]; then
      echo "👥 Groups: $USER_GROUPS" >&2
    fi
    echo "" >&2

    # Output token to stdout
    echo "$ACCESS_TOKEN"

    # Copy to clipboard on mac
    if command -v pbcopy >/dev/null 2>&1; then
      echo "$ACCESS_TOKEN" | pbcopy
      echo "📋 Token copied to clipboard" >&2
    fi

    exit 0
  fi
done

echo "" >&2
echo "❌ Timeout waiting for authentication" >&2
exit 1