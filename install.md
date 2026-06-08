# MCP Least Privilege Demo - Complete Tutorial

This tutorial walks you through setting up a complete demonstration of the MCP (Model Context Protocol) Gateway with least privilege access controls for Kubernetes. You'll learn how to integrate Keycloak for authentication and enforce fine-grained authorization policies using Kyverno.

## Overview

By the end of this tutorial, you will have:
- A Kind cluster (`kyverno-authz`) with port mapping for Keycloak
- Keycloak as an OIDC identity provider with user groups and OAuth 2.0 support
- AgentgatewayPolicy with MCP authentication for seamless OAuth flows
- Role-based access control (RBAC) for different user personas
- Kyverno authorization policies enforcing MCP tool access
- agentgateway routing MCP requests with authentication and authorization checks

**Key Feature**: This demo showcases **MCP authentication** via AgentgatewayPolicy, which enables MCP clients (like MCP Inspector, VS Code, or Claude Code) to automatically discover OAuth endpoints, dynamically register with Keycloak, and complete the OAuth 2.0 flow without manual token management.

## Prerequisites

- `kind`
- `kubectl`
- `helm` (v3)
- `curl`
- `jq`

No `openssl`, no `terraform`, no `/etc/hosts` edits required. macOS resolves `*.localhost` to `127.0.0.1` natively (RFC 6761).

## Quick Start

```bash
./install.sh
```

That's it. The script handles everything. For a step-by-step breakdown, read on.

---

## Architecture

```
MCP Client → gateway.localhost:8080/mcp
    → agentgateway (port-forward 8080)
        → JWT validation (mcp-authn policy → Keycloak JWKS)
        → Kyverno ext-authz (gRPC → kyverno-authz-server)
            → SubjectAccessReview → Kubernetes RBAC
        → kagent-tools MCP backend
```

- **Keycloak**: `http://keycloak.localhost:18080` — NodePort 30080 bound to host port 18080 via `extraPortMappings`
- **MCP Gateway**: `http://gateway.localhost:8080/mcp` — `kubectl port-forward svc/agentgateway-proxy`
- **JWKS** (internal): `keycloak-http.keycloak.svc.cluster.local:8080/realms/master/protocol/openid-connect/certs`

---

## Step 1: Create Kind Cluster

```bash
kind create cluster --image kindest/node:v1.33.1 --config bootstrap/kind-config.yaml
```

The cluster config (`bootstrap/kind-config.yaml`) binds host port `18080` to container port `30080` so Keycloak's NodePort is directly accessible at `keycloak.localhost:18080` without any `/etc/hosts` changes.

## Step 2: Install cert-manager

cert-manager is required by Kyverno for webhook TLS certificates:

```bash
helm upgrade -i cert-manager oci://quay.io/jetstack/charts/cert-manager \
  --version v1.19.2 \
  --namespace cert-manager \
  --create-namespace \
  --set crds.enabled=true \
  --wait
```

## Step 3: Install Keycloak

```bash
kubectl create namespace keycloak --dry-run=client -o yaml | kubectl apply -f -

helm upgrade -i keycloak keycloakx \
  --repo https://codecentric.github.io/helm-charts \
  --namespace keycloak \
  --wait --timeout 15m \
  -f bootstrap/keycloak-values.yaml
```

Keycloak is deployed as a NodePort service on port 30080, accessible at `http://keycloak.localhost:18080`. Admin credentials: `admin/admin`.

### Configure Keycloak

The setup script creates users, groups, and OAuth clients via the Keycloak Admin REST API:

```bash
KEYCLOAK_URL=http://keycloak.localhost:18080 ./bootstrap/setup-keycloak.sh
```

This creates:
- **Groups**: `kube-dev`, `kube-admin`, `restricted`
- **Users**: `alice` (kube-dev), `user-dev` (kube-dev), `user-admin` (kube-admin), `unauthorized-user` (restricted)
- **Clients**: `kube` (confidential, direct grant), `mcp-inspector` (public, auth code flow), plus dynamic registration support
- **Audience mapper**: adds `http://gateway.localhost:8080/mcp` to JWT `aud` claim
- **Groups scope**: `groups` claim included in all tokens

## Step 4: Configure Kubernetes RBAC

```bash
kubectl create namespace dev-team
kubectl create namespace admin-team
kubectl create namespace production

kubectl apply -f bootstrap/roles/dev-team.yaml
kubectl apply -f bootstrap/roles/admin-team.yaml
```

- `kube-dev` group: create/read/update/delete on pods, deployments, services etc. in `dev-team`
- `kube-admin` group: cluster-admin

## Step 5: Install Kyverno Authorization Server

```bash
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}
EOF

kubectl apply \
  -f https://raw.githubusercontent.com/kyverno/kyverno/refs/heads/main/config/crds/policies.kyverno.io/policies.kyverno.io_validatingpolicies.yaml

helm upgrade -i kyverno-authz-server kyverno-authz-server \
  --repo https://kyverno.github.io/kyverno-authz \
  --namespace kyverno --create-namespace \
  --wait \
  --values - <<EOF
config:
  type: envoy
authzServer:
  container:
    image:
      repository: lucchmielowski/kyverno-authz
      tag: latest
      pullPolicy: Always
validatingWebhookConfiguration:
  container:
    image:
      repository: lucchmielowski/kyverno-authz
      tag: latest
      pullPolicy: Always
  certificates:
    certManager:
      issuerRef:
        group: cert-manager.io
        kind: ClusterIssuer
        name: selfsigned-issuer
EOF
```

Apply RBAC for SubjectAccessReview:

```bash
kubectl apply -f policies/kyverno-sar-rbac.yaml
```

Patch webhook to use `v1beta1`:

```bash
kubectl wait --for=jsonpath='{.metadata.name}'=kyverno-authz-server-validation \
  validatingwebhookconfiguration/kyverno-authz-server-validation --timeout=120s

kubectl patch validatingwebhookconfiguration kyverno-authz-server-validation --type='json' -p='[
  {"op": "replace", "path": "/webhooks/0/clientConfig/service/path", "value": "/validate-policies-kyverno-io-v1beta1-validatingpolicy"},
  {"op": "replace", "path": "/webhooks/0/rules/0/apiVersions", "value": ["v1beta1"]}
]'
```

## Step 6: Install agentgateway and kagent-tools

```bash
# Gateway API CRDs
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.1/standard-install.yaml

# agentgateway
helm upgrade -i agentgateway-crds oci://ghcr.io/kgateway-dev/charts/agentgateway-crds \
  --create-namespace --namespace agentgateway-system --version v2.2.0-main
helm upgrade -i agentgateway oci://ghcr.io/kgateway-dev/charts/agentgateway \
  --namespace agentgateway-system --version v2.2.0-main \
  --set controller.image.pullPolicy=Always \
  --set controller.extraEnv.KGW_ENABLE_GATEWAY_API_EXPERIMENTAL_FEATURES=true

# Kubernetes-aware MCP tools
helm upgrade -i -n kagent --create-namespace kagent-tools \
  oci://ghcr.io/kagent-dev/tools/helm/kagent-tools --version 0.0.13
```

## Step 7: Apply Gateway Resources

```bash
kubectl apply -f gateway/
```

Key resources:
- **gateway-policy.yaml**: AgentgatewayPolicy with MCP auth (JWT validation against Keycloak) and Kyverno ext-authz
- **http-route.yaml**: Routes for `/mcp`, `/.well-known/oauth-*`, and Keycloak proxy paths
- **mcp-backend.yaml**: Backend pointing to kagent-tools

### AgentgatewayPolicy highlights

```yaml
# JWT validation — issuer/audience must match what Keycloak issues
authentication:
  issuer: "http://keycloak.localhost:18080/realms/master"
  audiences:
    - "http://gateway.localhost:8080/mcp"
  jwks:
    backendRef:
      name: keycloak-http   # internal ClusterIP — agentgateway pods use this
      namespace: keycloak
      port: 8080

# Kyverno ext-authz over gRPC
extAuth:
  backendRef:
    name: kyverno-authz-server
    namespace: kyverno
    port: 9081
```

## Step 8: Apply Kyverno Policies

```bash
kubectl apply -f policies/
```

Policies applied:
- **no-unauthenticated-calls**: Rejects requests without a valid JWT; checks group membership (`kube-dev` or `kube-admin`)
- **restricted-group-deny-tools**: Blocks all tool calls for the `restricted` group
- **dev-group-tool-guardrails**: Blocks direct write tools (`k8s_apply_manifest`, `k8s_create_resource`, etc.) for `kube-dev`
- **create-from-url-authz**: For `k8s_create_resource_from_url`, fetches the manifest from the URL, extracts the resource kind and API group, and performs a SubjectAccessReview to verify the user can create that resource type in the requested namespace

## Step 9: Start Gateway Port-Forward

```bash
nohup kubectl port-forward svc/agentgateway-proxy -n agentgateway-system 8080:8080 > /tmp/agentgateway-port-forward.log 2>&1 &
```

The gateway is now accessible at `http://gateway.localhost:8080/mcp`.

---

## Testing

### Get tokens

```bash
# alice — kube-dev group
TOKEN=$(curl -s -X POST http://keycloak.localhost:18080/realms/master/protocol/openid-connect/token \
  -d grant_type=password -d client_id=kube -d client_secret=kube-client-secret \
  -d username=alice -d password=alice -d scope=openid | jq -r .access_token)

# unauthorized-user — restricted group
UNAUTH=$(curl -s -X POST http://keycloak.localhost:18080/realms/master/protocol/openid-connect/token \
  -d grant_type=password -d client_id=kube -d client_secret=kube-client-secret \
  -d username=unauthorized-user -d password=unauthorized-user -d scope=openid | jq -r .access_token)
```

Or use the helper:
```bash
TOKEN=$(./get-token.sh alice)
```

See README.md for full test cases.

### Test with MCP Inspector

```bash
npx @modelcontextprotocol/inspector@0.18.0
```

1. Transport: **Streamable HTTP**, URL: `http://gateway.localhost:8080/mcp`
2. Click **Connect** — it will fail (auth required, expected)
3. Click **Open Auth Settings** → **Quick OAuth Flow**
4. Log in as `user-dev` / `user-dev` or `user-admin` / `user-admin`
5. After the OAuth flow completes, reconnect — you now have an authenticated session

### Test with Cursor

Create `.cursor/mcp.json`:

```json
{
  "mcpServers": {
    "agentgateway": {
      "url": "http://gateway.localhost:8080/mcp"
    }
  }
}
```

Connect in Cursor Settings → Tools & MCP. When prompted, run `mcp_auth` to complete the OAuth flow.

---

## Troubleshooting

**Keycloak not accessible**
```bash
curl http://keycloak.localhost:18080/realms/master/.well-known/openid-configuration | jq .issuer
# Should return: "http://keycloak.localhost:18080/realms/master"
```

**JWT audience error (`InvalidAudience`)**
- Token must have `aud: ["http://gateway.localhost:8080/mcp", ...]`
- Re-run `setup-keycloak.sh` to recreate the audience mapper

**403 on tool calls**
```bash
# Check Kyverno logs
kubectl logs -n kyverno -l app.kubernetes.io/name=kyverno-authz-server

# Verify RBAC (test as kube-dev group)
kubectl auth can-i create deployments -n dev-team \
  --as=alice@domain.com --as-group=kube-dev
```

**Gateway port-forward died**
```bash
nohup kubectl port-forward svc/agentgateway-proxy -n agentgateway-system 8080:8080 > /tmp/agentgateway-port-forward.log 2>&1 &
```

**Keycloak lost data (pod restarted)**
```bash
KEYCLOAK_URL=http://keycloak.localhost:18080 ./bootstrap/setup-keycloak.sh
```

---

## Cleanup

```bash
kind delete cluster --name kyverno-authz
```

No `/etc/hosts` cleanup needed.
