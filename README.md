# Demo KubeconEU 2026

This demo showcases how [Kyverno](https://kyverno.io/) policies enforce authentication and authorization for MCP tool calls through [agentgateway](https://agentgateway.dev/).

## Prerequisites

- Kind cluster running with Kyverno Envoy Plugin
- Keycloak configured with users and groups
- Agentgateway deployed
- Policies applied: `no-unauthenticated-calls`, `restricted-group-deny-tools`, `dev-group-tool-guardrails`, and `create-from-url-authz`

## Setup

1. Ensure all components are running:
   ```bash
   kubectl get pods -n kyverno
   kubectl get pods -n keycloak
   ```

2. Get authentication tokens for different users:
   ```bash
   # Get token for a user in kube-dev group
   ./get-token.sh alice
   
   # Get token for a user in kube-admin group
   ./get-token.sh admin
   ```

## Agent Integrations

### Cursor 

Create a `.cursor/mcp.json` file in the project.

```
{
  "mcpServers": {
    "agentgateway": {
      "url": "http://gateway.kind.cluster:8080/mcp"
    }
  }
}
```

Go into the Cursor Settings under Tools & MCP, and connect to the agentgateway MCP server. When prompted, run `mcp_auth` from the Cursor session. That will run the DCR flow with Keycloak and give you access to the gateway-exposed tools for your identity.

For `kube-dev` users, the demo is intentionally locked down to read-only Kubernetes tools plus `k8s_create_resource_from_url`. Direct write paths such as `k8s_apply_manifest`, `k8s_create_resource`, `k8s_patch_resource`, `k8s_delete_resource`, and `shell` are blocked so they cannot bypass the SAR-protected flow.

---

## Example 1: Restrict all non-authorized calls

This example demonstrates the `no-unauthenticated-calls` policy that enforces authentication and group membership for all MCP Gateway requests.

### Policy Overview

The `no-unauthenticated-calls` policy:
- Validates JWT tokens from the Authorization header
- Verifies token signature using Keycloak JWKS endpoint
- Checks that the user belongs to allowed groups (`kube-dev` or `kube-admin`)
- Returns 401 Unauthorized for invalid/missing tokens or users not in an allowed group

### Test Case 1.1: Unauthenticated Request (Should Fail)

```bash
# Make a request without authentication token
curl -v -X POST http://gateway.kind.cluster:8080/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "tools/call",
    "params": {
      "name": "k8s_get_resources",
      "arguments": {
        "namespace": "default",
        "resource_type": "pods"
      }
    }
  }'
```

**Expected Result:**
- Status: `401 Unauthorized`
- Response: `{"error":"unauthorized","error_description":"JWT token required"}`
- Policy denies the request because no JWT token is present

### Test Case 1.2: Valid Token with Authorized Group (Should Succeed)

```bash
# Get token for alice (member of kube-dev group)
TOKEN=$(./get-token.sh alice)

# Initialize MCP session
SESSION_ID=$(curl -sS --http1.1 -i http://gateway.kind.cluster:8080/mcp \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl","version":"1.0"}}}' \
  | grep -i "^Mcp-Session-Id:" | cut -d' ' -f2 | tr -d '\r')

# Make authenticated request
curl -X POST http://gateway.kind.cluster:8080/mcp -v \
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
```

**Expected Result:**
- Status: `200 OK`
- Policy allows the request because:
  - Valid JWT token is present
  - Token is properly signed and validated
  - User belongs to `kube-dev` group (allowed group)

### \[OPTIONAL\] Test Case 1.3: Invalid Token (Should Fail)

```bash
# Make a request with an invalid token
curl -X POST http://gateway.kind.cluster:8080/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H 'Authorization: Bearer invalid-token-here' \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "tools/call",
    "params": {
      "name": "k8s_get_resources",
      "arguments": {
        "namespace": "default",
        "resource_type": "pods"
      }
    }
  }'
```

**Expected Result:**
- Status: `401 Unauthorized`
- Policy denies the request because the JWT token is invalid or cannot be decoded

### \[OPTIONAL\] Test Case 1.4: Valid Token with Unauthorized Group (Should Fail)

```bash
# Get token for a user in the "restricted" group (not in kube-dev or kube-admin)
UNAUTHORIZED_TOKEN=$(./get-token.sh unauthorized-user)

# Attempt any request - should be denied at the authentication layer
curl -v -X POST http://gateway.kind.cluster:8080/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H "Authorization: Bearer $UNAUTHORIZED_TOKEN" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "initialize",
    "params": {
      "protocolVersion": "2025-06-18",
      "capabilities": {},
      "clientInfo": {"name": "curl", "version": "1.0"}
    }
  }'
```

**Expected Result:**
- Status: `401 Unauthorized`
- Policy denies the request because user group (`restricted`) is not in the allowed list (`kube-dev`, `kube-admin`)

---

## Example 2: Restrict create from URL via SAR

This example demonstrates the `create-from-url-authz` policy that uses Kubernetes Subject Access Review (SAR) to verify if a user has permission to create resources from a URL.

### Policy Overview

The `create-from-url-authz` policy:
- Intercepts MCP tool calls for `k8s_create_resource_from_url`
- Extracts namespace and URL from the MCP request arguments
- Fetches and parses the Kubernetes manifest from the URL
- Extracts the resource kind from the manifest
- Creates a Subject Access Review (SAR) to check if the user can create that resource type in the specified namespace
- Returns 403 Forbidden if SAR denies the operation

### RBAC Setup

For the policy to perform SAR checks, the Kyverno authz server needs permission to create `SubjectAccessReview` resources against the Kubernetes API. Apply the RBAC resources before running this example:

```bash
kubectl apply -f policies/kyverno-sar-rbac.yaml
```

This creates a `ClusterRole` and `ClusterRoleBinding` that grant the `kyverno-authz-server` service account in the `kyverno` namespace permission to create `subjectaccessreviews`. Without this, the policy would be unable to query Kubernetes RBAC to determine whether a user is authorized to create a given resource.

### Test Case 2.1: Authorized Create Operation (Should Succeed)

```bash
# Get token for alice (has create permissions in dev-team namespace)
TOKEN=$(./get-token.sh alice)

# Initialize MCP session (REQUIRED!)
SESSION_ID=$(curl -sS --http1.1 -i "http://gateway.kind.cluster:8080/mcp" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl","version":"1.0"}}}' \
  | grep -i "^Mcp-Session-Id:" | cut -d' ' -f2 | tr -d '\r')

echo "Session ID: $SESSION_ID"

# Deployment manifest URL
MANIFEST_URL="https://raw.githubusercontent.com/kubernetes/website/main/content/en/examples/controllers/nginx-deployment.yaml"

# Create resource in dev-team namespace (alice has permissions here)
curl -s "http://gateway.kind.cluster:8080/mcp" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Mcp-Session-Id: $SESSION_ID" \
  -d "{
    \"jsonrpc\": \"2.0\",
    \"id\": 2,
    \"method\": \"tools/call\",
    \"params\": {
      \"name\": \"k8s_create_resource_from_url\",
      \"arguments\": {
        \"namespace\": \"dev-team\",
        \"url\": \"$MANIFEST_URL\"
      }
    }
  }"
```

**Expected Result:**
```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "deployment.apps/nginx-deployment created"
      }
    ]
  }
}
```

**Why it succeeds:**
- ✅ User is authenticated with valid JWT token
- ✅ SAR check confirms alice (kube-dev group) has `create` permission for deployments in `dev-team` namespace
- ✅ Resource is created successfully

**Verify the deployment was created:**
```bash
kubectl get deployments -n dev-team
```

### Test Case 2.2: Unauthorized Create Operation (Should Fail)

```bash
# Get token for alice (does NOT have create permissions in production namespace)
TOKEN=$(./get-token.sh alice)

# Gateway URL
GATEWAY_URL="gateway.kind.cluster:8080"

# Initialize MCP session
SESSION_ID=$(curl -sS --http1.1 -i "http://gateway.kind.cluster:8080/mcp" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl","version":"1.0"}}}' \
  | grep -i "^Mcp-Session-Id:" | cut -d' ' -f2 | tr -d '\r')

echo "Session ID: $SESSION_ID"

# Attempt to create resource in production namespace
MANIFEST_URL="https://raw.githubusercontent.com/kubernetes/website/main/content/en/examples/controllers/nginx-deployment.yaml"

curl -s "http://gateway.kind.cluster:8080/mcp" -v \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Mcp-Session-Id: $SESSION_ID" \
  -d "{
    \"jsonrpc\": \"2.0\",
    \"id\": 2,
    \"method\": \"tools/call\",
    \"params\": {
      \"name\": \"k8s_create_resource_from_url\",
      \"arguments\": {
        \"namespace\": \"production\",
        \"url\": \"$MANIFEST_URL\"
      }
    }
  }"
```

**Expected Result:**
- Status: `403 Forbidden`
- Empty response body (request is denied at the authorization layer)

**Why it fails:**
- ✅ User is authenticated with valid JWT token
- ❌ SAR check fails - alice (kube-dev group) does NOT have `create` permission for deployments in `production` namespace
- ❌ Resource creation is blocked by the `create-from-url-authz` policy

---

## Summary

These examples demonstrate:

1. **Authentication Enforcement**: All requests must include valid JWT tokens from Keycloak, and users must belong to authorized groups.

2. **Authorization Enforcement**: Even with valid authentication, users can only perform operations they're authorized for, verified through Kubernetes Subject Access Review.

3. **Least Privilege**: Users are restricted to their assigned namespaces and resource types based on Kubernetes RBAC.

4. **Per-User Accountability**: Each request is tied to the actual user identity from the JWT token, enabling proper audit trails.

5. **Policy-Based Guardrails**: Kyverno policies provide additional validation beyond basic RBAC, allowing for complex business rules.