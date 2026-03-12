#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values for skip flags
SKIP_CLUSTER=${SKIP_CLUSTER:-false}
SKIP_METALLB=${SKIP_METALLB:-false}
SKIP_CERT_MANAGER=${SKIP_CERT_MANAGER:-false}
SKIP_KEYCLOAK=${SKIP_KEYCLOAK:-false}
SKIP_RBAC=${SKIP_RBAC:-false}
SKIP_KYVERNO=${SKIP_KYVERNO:-false}
SKIP_GATEWAY=${SKIP_GATEWAY:-false}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-cluster)
            SKIP_CLUSTER=true
            shift
            ;;
        --skip-metallb)
            SKIP_METALLB=true
            shift
            ;;
        --skip-cert-manager)
            SKIP_CERT_MANAGER=true
            shift
            ;;
        --skip-keycloak)
            SKIP_KEYCLOAK=true
            shift
            ;;
        --skip-rbac)
            SKIP_RBAC=true
            shift
            ;;
        --skip-kyverno)
            SKIP_KYVERNO=true
            shift
            ;;
        --skip-gateway)
            SKIP_GATEWAY=true
            shift
            ;;
        --skip-all)
            SKIP_CLUSTER=true
            SKIP_METALLB=true
            SKIP_CERT_MANAGER=true
            SKIP_KEYCLOAK=true
            SKIP_RBAC=true
            SKIP_KYVERNO=true
            SKIP_GATEWAY=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --skip-cluster       Skip Kind cluster creation"
            echo "  --skip-metallb       Skip MetalLB installation"
            echo "  --skip-cert-manager  Skip cert-manager installation"
            echo "  --skip-keycloak      Skip Keycloak installation"
            echo "  --skip-rbac          Skip RBAC configuration"
            echo "  --skip-kyverno       Skip Kyverno installation"
            echo "  --skip-gateway       Skip Gateway API and agentgateway installation"
            echo "  --skip-all           Skip all infrastructure setup (only apply gateway configs and policies)"
            echo "  --help, -h           Show this help message"
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Function to print colored messages
print_info() {
    echo -e "${BLUE}ℹ ${1}${NC}"
}

print_success() {
    echo -e "${GREEN}✓ ${1}${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ ${1}${NC}"
}

print_error() {
    echo -e "${RED}✗ ${1}${NC}"
}

print_header() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  ${1}${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

find_free_local_port() {
    local requested_port=${1:-18080}
    local candidate

    for candidate in "$requested_port" 18081 18082 18083 18084 18085; do
        if ! lsof -nP -iTCP:$candidate -sTCP:LISTEN >/dev/null 2>&1; then
            echo "$candidate"
            return 0
        fi
    done

    return 1
}

start_keycloak_port_forward() {
    local preferred_port=${KEYCLOAK_LOCAL_PORT:-18080}
    local chosen_port

    if [ -n "${KC_PF_PID:-}" ] && kill -0 "$KC_PF_PID" 2>/dev/null; then
        return 0
    fi

    chosen_port=$(find_free_local_port "$preferred_port") || {
        print_error "Could not find a free local port for Keycloak bootstrap access."
        return 1
    }

    KEYCLOAK_LOCAL_PORT="$chosen_port"
    KEYCLOAK_BOOTSTRAP_URL="http://127.0.0.1:${KEYCLOAK_LOCAL_PORT}"

    print_info "Starting port-forward to Keycloak for bootstrap access on ${KEYCLOAK_BOOTSTRAP_URL}..."
    kubectl port-forward svc/keycloak -n keycloak ${KEYCLOAK_LOCAL_PORT}:8080 >/tmp/keycloak-port-forward.log 2>&1 &
    KC_PF_PID=$!

    sleep 2

    if ! kill -0 "$KC_PF_PID" 2>/dev/null; then
        print_error "Failed to start Keycloak port-forward."
        print_warning "Check /tmp/keycloak-port-forward.log for details."
        return 1
    fi

    local max_attempts=15
    local attempt=0
    while [ $attempt -lt $max_attempts ]; do
        if curl -s -f "${KEYCLOAK_BOOTSTRAP_URL}/realms/master/.well-known/openid-configuration" >/dev/null 2>&1; then
            print_success "Keycloak bootstrap endpoint is reachable at ${KEYCLOAK_BOOTSTRAP_URL}"
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 1
    done

    print_error "Keycloak port-forward started but the bootstrap endpoint is not responding."
    print_warning "Check /tmp/keycloak-port-forward.log for details."
    kill "$KC_PF_PID" 2>/dev/null || true
    unset KC_PF_PID
    return 1
}

# Function to wait for deployment to be ready
wait_for_deployment() {
    local namespace=$1
    local deployment=$2
    local timeout=${3:-300}

    print_info "Waiting for deployment $deployment in namespace $namespace to be ready..."
    kubectl wait --for=condition=available --timeout=${timeout}s deployment/$deployment -n $namespace 2>/dev/null || {
        print_warning "Timeout waiting for $deployment, but continuing..."
    }
}

# Function to wait for pods to be ready
wait_for_pods() {
    local namespace=$1
    local label=$2
    local timeout=${3:-300}

    print_info "Waiting for pods with label $label in namespace $namespace..."
    kubectl wait --for=condition=ready --timeout=${timeout}s pods -l $label -n $namespace 2>/dev/null || {
        print_warning "Timeout waiting for pods, but continuing..."
    }
}

# Function to wait for Kyverno webhook to be ready
wait_for_kyverno_webhook() {
    print_info "Checking if Kyverno webhook is ready..."

    # Check if Kyverno is installed
    if ! kubectl get namespace kyverno >/dev/null 2>&1; then
        print_error "Kyverno namespace not found. Please install Kyverno first."
        return 1
    fi

    # Wait for webhook configuration to exist
    print_info "Waiting for Kyverno webhook configuration to be created..."
    max_attempts=60
    attempt=0
    while [ $attempt -lt $max_attempts ]; do
        if kubectl get validatingwebhookconfiguration kyverno-authz-server-validation >/dev/null 2>&1; then
            print_success "Webhook configuration found"
            break
        fi
        attempt=$((attempt + 1))
        if [ $attempt -lt $max_attempts ]; then
            echo -n "."
            sleep 2
        else
            print_error "Webhook configuration was not created in time"
            return 1
        fi
    done

    # Patch webhook configuration to use v1beta1 instead of v1alpha1
    print_info "Updating webhook configuration to use v1beta1 API..."
    kubectl patch validatingwebhookconfiguration kyverno-authz-server-validation --type='json' -p='[
        {"op": "replace", "path": "/webhooks/0/clientConfig/service/path", "value": "/validate-policies-kyverno-io-v1beta1-validatingpolicy"},
        {"op": "replace", "path": "/webhooks/0/rules/0/apiVersions", "value": ["v1beta1"]}
    ]' >/dev/null 2>&1

    # Wait for webhook service endpoints to be ready
    print_info "Waiting for Kyverno webhook service endpoints to be ready..."
    kubectl wait --for=jsonpath='{.subsets[*].addresses[*].ip}' --timeout=120s endpoints/kyverno-authz-server -n kyverno 2>/dev/null || {
        print_warning "Timeout waiting for webhook service endpoints"
    }

    # Wait for webhook pods to be ready
    print_info "Waiting for Kyverno webhook pods to be ready..."
    kubectl wait --for=condition=ready --timeout=120s pods -l app.kubernetes.io/instance=kyverno-authz-server -n kyverno 2>/dev/null || {
        print_warning "Timeout waiting for webhook pods"
    }

    # Test if webhook is actually responding to validation requests
    print_info "Testing webhook readiness..."
    max_attempts=30
    attempt=0
    webhook_ready=false

    # Create a temporary test file
    cat > /tmp/webhook-test.yaml <<'EOF'
apiVersion: policies.kyverno.io/v1beta1
kind: ValidatingPolicy
metadata:
  name: webhook-readiness-test
spec:
  evaluation:
    mode: Envoy
  validations:
    - expression: "envoy.Allowed().Response()"
EOF

    while [ $attempt -lt $max_attempts ]; do
        # Try to create a test ValidatingPolicy with dry-run to test webhook
        if kubectl apply --dry-run=server -f /tmp/webhook-test.yaml >/dev/null 2>&1; then
            webhook_ready=true
            print_success "Webhook is responding to validation requests"
            rm -f /tmp/webhook-test.yaml
            break
        fi
        attempt=$((attempt + 1))
        if [ $attempt -lt $max_attempts ]; then
            echo -n "."
            sleep 2
        fi
    done

    rm -f /tmp/webhook-test.yaml

    if [ "$webhook_ready" = false ]; then
        print_error "Webhook is not responding to validation requests"
        print_info "Check webhook status with: kubectl get pods -n kyverno"
        print_info "Check webhook logs with: kubectl logs -n kyverno -l app.kubernetes.io/instance=kyverno-authz-server"
        return 1
    fi

    return 0
}

# Check prerequisites
print_header "Step 0: Checking Prerequisites"

for cmd in kind kubectl helm openssl curl jq; do
    if ! command -v $cmd &> /dev/null; then
        print_error "$cmd is not installed. Please install it first."
        exit 1
    fi
    print_success "$cmd is installed"
done

# Check for terraform (optional but recommended for Keycloak setup)
if ! command -v terraform &> /dev/null; then
    print_warning "terraform is not installed. Keycloak users and clients will not be configured automatically."
    print_info "Install terraform to enable automatic Keycloak configuration: https://www.terraform.io/downloads"
else
    print_success "terraform is installed"
fi

# Step 1: Generate SSL Certificates
if [ "$SKIP_CLUSTER" = false ]; then
    print_header "Step 1: Generate SSL Certificates"

    print_info "Creating .ssl directory..."
    mkdir -p .ssl

    print_info "Generating root CA private key..."
    openssl genrsa -out .ssl/root-ca-key.pem 4096 2>/dev/null

    print_info "Generating root CA certificate..."
    openssl req -x509 -new -nodes -key .ssl/root-ca-key.pem \
      -sha256 -days 3650 -out .ssl/root-ca.pem \
      -subj "/CN=Kind Root CA" 2>/dev/null

    print_success "SSL certificates generated"
else
    print_warning "Skipping SSL certificate generation (cluster setup skipped)"
fi

# Step 2: Create Kind Cluster
if [ "$SKIP_CLUSTER" = false ]; then
    print_header "Step 2: Create Kind Cluster with OIDC Support"

    if kind get clusters | grep -q "^kind$"; then
        print_warning "Kind cluster 'kind' already exists."
        read -p "Do you want to delete and recreate it? (y/n) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            print_info "Deleting existing cluster..."
            kind delete cluster
            print_info "Creating Kind cluster..."
            kind create cluster --image kindest/node:v1.33.1 --config bootstrap/kind-config.yaml
            print_success "Kind cluster created"
        else
            print_warning "Keeping existing cluster. Make sure it was created with the correct OIDC configuration!"
            print_info "Expected config: bootstrap/kind-config.yaml"
        fi
    else
        print_info "Creating Kind cluster..."
        kind create cluster --image kindest/node:v1.33.1 --config bootstrap/kind-config.yaml
        print_success "Kind cluster created"
    fi
else
    print_warning "Skipping Kind cluster creation"
fi

# Step 2b: Install MetalLB
if [ "$SKIP_METALLB" = false ]; then
    print_header "Step 2b: Install MetalLB"

    print_info "Installing MetalLB..."
    kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.15.3/config/manifests/metallb-native.yaml

    print_info "Waiting for MetalLB to be ready..."
    sleep 10
    wait_for_deployment metallb-system controller 120
    kubectl wait --for=condition=ready --timeout=120s pods -l app=metallb,component=speaker -n metallb-system 2>/dev/null || {
        print_warning "Timeout waiting for speaker pods, but continuing..."
    }

    print_info "Configuring MetalLB IP Pool..."
    kubectl apply -f bootstrap/metallb-config.yaml

    print_success "MetalLB installed and configured"
else
    print_warning "Skipping MetalLB installation"
fi

# Step 3: Install cert-manager (for Kyverno)
if [ "$SKIP_CERT_MANAGER" = false ]; then
    print_header "Step 3: Install cert-manager"

    print_info "Installing/upgrading cert-manager..."
    helm upgrade -i cert-manager oci://quay.io/jetstack/charts/cert-manager \
      --version v1.19.2 \
      --namespace cert-manager \
      --create-namespace \
      --set crds.enabled=true \
      --wait

    print_success "cert-manager is ready"
else
    print_warning "Skipping cert-manager installation"
fi

# Step 4: Generate Keycloak SSL Certificates
if [ "$SKIP_KEYCLOAK" = false ]; then
    print_header "Step 4: Generate Keycloak SSL Certificates"

    print_info "Creating certificate configuration..."
    cat <<EOF > .ssl/req.cnf
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
[req_distinguished_name]
[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName = @alt_names
[alt_names]
DNS.1 = keycloak.kind.cluster
EOF

    print_info "Generating Keycloak private key..."
    openssl genrsa -out .ssl/key.pem 2048 2>/dev/null

    print_info "Creating certificate signing request..."
    openssl req -new -key .ssl/key.pem -out .ssl/csr.pem \
      -subj "/CN=kube-ca" \
      -addext "subjectAltName = DNS:keycloak.kind.cluster" \
      -sha256 -config .ssl/req.cnf 2>/dev/null

    print_info "Creating certificate..."
    openssl x509 -req -in .ssl/csr.pem \
      -CA .ssl/root-ca.pem -CAkey .ssl/root-ca-key.pem \
      -CAcreateserial -sha256 -out .ssl/cert.pem -days 3650 \
      -extensions v3_req -extfile .ssl/req.cnf 2>/dev/null

    print_success "Keycloak SSL certificates generated"
else
    print_warning "Skipping Keycloak SSL certificate generation"
fi

# Step 5: Install Keycloak
if [ "$SKIP_KEYCLOAK" = false ]; then
    print_header "Step 5: Install Keycloak"

    print_info "Creating namespace..."
    kubectl create namespace keycloak --dry-run=client -o yaml | kubectl apply -f -

    print_info "Creating Kubernetes secret for Keycloak TLS..."
    # Delete existing secret if it exists to avoid Helm ownership conflicts
    kubectl delete secret keycloak-tls -n keycloak 2>/dev/null || true

    # Create secret with Helm labels for proper ownership
    kubectl create secret tls -n keycloak keycloak-tls \
      --cert=.ssl/cert.pem \
      --key=.ssl/key.pem

    # Add Helm labels to the secret
    kubectl label secret keycloak-tls -n keycloak \
      app.kubernetes.io/managed-by=Helm \
      --overwrite
    kubectl annotate secret keycloak-tls -n keycloak \
      meta.helm.sh/release-name=keycloak \
      meta.helm.sh/release-namespace=keycloak \
      --overwrite

    print_info "Installing/upgrading Keycloak (this may take a few minutes)..."
    helm upgrade -i keycloak keycloak \
      --repo https://charts.bitnami.com/bitnami \
      --namespace keycloak \
      --wait --timeout 15m \
      -f bootstrap/keycloak-values.yaml

    print_success "Keycloak installed"
    print_info "External access: via LoadBalancer (for kubectl OIDC)"
    print_info "Internal access: AgentgatewayPolicy uses internal ClusterIP service for MCP auth"

    # Get LoadBalancer IP (retry until assigned)
    print_info "Waiting for Keycloak LoadBalancer IP..."
    max_attempts=30
    attempt=0
    KEYCLOAK_LB_IP=""
    while [ $attempt -lt $max_attempts ]; do
        KEYCLOAK_LB_IP=$(kubectl get svc keycloak -n keycloak -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
        if [ -n "$KEYCLOAK_LB_IP" ]; then
            print_success "Keycloak LoadBalancer IP: $KEYCLOAK_LB_IP"
            break
        fi
        attempt=$((attempt + 1))
        echo -n "."
        sleep 2
    done

    if [ -z "$KEYCLOAK_LB_IP" ]; then
        print_warning "Failed to get Keycloak LoadBalancer IP after ${max_attempts} attempts"
    fi

    # On macOS with Docker Desktop, MetalLB LoadBalancer IPs are not routable
    # from the host. Use kubectl port-forward so host-side tools (curl, Terraform,
    # configure-keycloak-client-reg.sh) can reach Keycloak via localhost.
    start_keycloak_port_forward || exit 1

    print_info "Updating /etc/hosts so keycloak.kind.cluster resolves locally..."
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sudo sed -i '' '/keycloak\.kind\.cluster/d' /etc/hosts 2>/dev/null || true
    else
        sudo sed -i '/keycloak\.kind\.cluster/d' /etc/hosts 2>/dev/null || true
    fi
    echo "127.0.0.1 keycloak.kind.cluster" | sudo tee -a /etc/hosts
    print_success "DNS entry added to /etc/hosts (127.0.0.1 via port-forward)"

    # Apply Terraform configuration to create users, groups, and OAuth clients
    if [ -f ./bootstrap/keycloak.tf ]; then
        print_info "Waiting for Keycloak to be fully ready..."
        kubectl wait --for=condition=ready --timeout=300s pod/keycloak-0 -n keycloak 2>/dev/null || {
            print_warning "Timeout waiting for Keycloak pod"
        }

        # Wait for Keycloak to be ready to accept API requests
        print_info "Verifying Keycloak API is responding..."
        max_attempts=30
        attempt=0
        while [ $attempt -lt $max_attempts ]; do
            if curl -s -f -X POST "${KEYCLOAK_BOOTSTRAP_URL}/realms/master/protocol/openid-connect/token" \
                -d grant_type=password \
                -d client_id=admin-cli \
                -d username=admin \
                -d password=admin > /dev/null 2>&1; then
                print_success "Keycloak API is ready!"
                break
            fi
            attempt=$((attempt + 1))
            if [ $attempt -lt $max_attempts ]; then
                echo -n "."
                sleep 2
            else
                print_error "Keycloak API did not become ready in time"
                print_warning "You can manually apply Terraform later with:"
                print_warning "  cd bootstrap && terraform init && terraform apply"
                kill $KC_PF_PID 2>/dev/null
                exit 1
            fi
        done

        print_info "Applying Terraform configuration to Keycloak..."
        print_info "This will create users (alice, user-dev, user-admin), groups (kube-dev, kube-admin), and OAuth clients..."

        terraform -chdir=./bootstrap init -upgrade >/dev/null 2>&1
        if terraform -chdir=./bootstrap apply -auto-approve -var="keycloak_url=${KEYCLOAK_BOOTSTRAP_URL}"; then
            print_success "Keycloak configuration applied via Terraform"
        else
            print_error "Failed to apply Terraform configuration"
            print_warning "You can manually apply it later with:"
            print_warning "  cd bootstrap && terraform init && terraform apply -var=\"keycloak_url=${KEYCLOAK_BOOTSTRAP_URL}\""
        fi

        if [ -f ./bootstrap/configure-keycloak-client-reg.sh ]; then
            print_info "Configuring Keycloak client registration trusted hosts for MCP Inspector..."
            chmod +x ./bootstrap/configure-keycloak-client-reg.sh
            KEYCLOAK_URL="${KEYCLOAK_BOOTSTRAP_URL}" ./bootstrap/configure-keycloak-client-reg.sh || {
                print_warning "Failed to configure Keycloak client registration policy automatically."
                print_warning "Run manually: KEYCLOAK_URL=${KEYCLOAK_BOOTSTRAP_URL} ./bootstrap/configure-keycloak-client-reg.sh"
            }
        else
            print_warning "configure-keycloak-client-reg.sh not found, skipping client registration policy setup"
        fi
    else
        print_warning "Terraform configuration not found at ./bootstrap/keycloak.tf"
    fi

    # Stop the port-forward now that Keycloak setup is complete
    kill $KC_PF_PID 2>/dev/null
    print_info "Stopped Keycloak port-forward"

else
    print_warning "Skipping Keycloak installation"
fi

# Step 6: Configure Kubernetes RBAC
if [ "$SKIP_RBAC" = false ]; then
    print_header "Step 6: Configure Kubernetes RBAC for Users and Groups"

    print_info "Creating namespaces..."
    kubectl create namespace dev-team --dry-run=client -o yaml | kubectl apply -f -
    kubectl create namespace admin-team --dry-run=client -o yaml | kubectl apply -f -
    kubectl create namespace production --dry-run=client -o yaml | kubectl apply -f -

    print_info "Applying RBAC roles..."
    kubectl apply -f bootstrap/roles/dev-team.yaml
    kubectl apply -f bootstrap/roles/admin-team.yaml

    print_success "RBAC configured"

    # Create kubectl configurations
    if [ -f ./bootstrap/create-config.sh ]; then
        print_info "Waiting for Keycloak to be fully ready..."

        # Wait for Keycloak deployment to be ready
        kubectl wait --for=condition=ready --timeout=300s pod/keycloak-0 -n keycloak 2>/dev/null || {
            print_warning "Timeout waiting for Keycloak pod"
        }

        # Start port-forward if not already running (e.g. when --skip-keycloak was used)
        if ! kill -0 $KC_PF_PID 2>/dev/null; then
            start_keycloak_port_forward || exit 1

            # Ensure /etc/hosts points to localhost
            if ! grep -q "127.0.0.1.*keycloak.kind.cluster" /etc/hosts; then
                print_info "Updating /etc/hosts for keycloak.kind.cluster..."
                if [[ "$OSTYPE" == "darwin"* ]]; then
                    sudo sed -i '' '/keycloak\.kind\.cluster/d' /etc/hosts 2>/dev/null || true
                else
                    sudo sed -i '/keycloak\.kind\.cluster/d' /etc/hosts 2>/dev/null || true
                fi
                echo "127.0.0.1 keycloak.kind.cluster" | sudo tee -a /etc/hosts
            fi
        fi

        print_info "Verifying Keycloak API is responding..."
        max_attempts=30
        attempt=0
        while [ $attempt -lt $max_attempts ]; do
            if curl -s -f -X POST "${KEYCLOAK_BOOTSTRAP_URL}/realms/master/protocol/openid-connect/token" \
                -d grant_type=password \
                -d client_id=admin-cli \
                -d username=admin \
                -d password=admin > /dev/null 2>&1; then
                print_success "Keycloak API is ready!"
                break
            fi
            attempt=$((attempt + 1))
            if [ $attempt -lt $max_attempts ]; then
                echo -n "."
                sleep 2
            else
                print_error "Keycloak API did not become ready in time"
                print_warning "You can manually run create-config.sh later"
                kill $KC_PF_PID 2>/dev/null
                exit 1
            fi
        done

        if grep -q "keycloak.kind.cluster" /etc/hosts; then
            print_info "Running create-config.sh..."
            chmod +x ./bootstrap/create-config.sh
            KEYCLOAK_ISSUER="${KEYCLOAK_BOOTSTRAP_URL}/realms/master" ./bootstrap/create-config.sh || {
                print_warning "Failed to create kubectl configurations."
                print_warning "You may need to run this manually after Keycloak is fully ready:"
                print_warning "  KEYCLOAK_ISSUER=${KEYCLOAK_BOOTSTRAP_URL}/realms/master ./bootstrap/create-config.sh"
            }
            print_success "kubectl configurations created"
        else
            print_warning "/etc/hosts does not have keycloak.kind.cluster entry"
            print_warning "Run manually: ./bootstrap/create-config.sh"
        fi

        # Stop port-forward
        kill $KC_PF_PID 2>/dev/null
    else
        print_warning "create-config.sh not found, skipping this step"
    fi
else
    print_warning "Skipping RBAC configuration"
fi

# Step 7: Install Kyverno Authorization Server
if [ "$SKIP_KYVERNO" = false ]; then
    print_header "Step 7: Install Kyverno Authorization Server"

    print_info "Creating ClusterIssuer..."
    kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}
EOF

    print_info "Applying Kyverno CRDs..."
    kubectl apply \
      -f https://raw.githubusercontent.com/kyverno/kyverno/refs/heads/main/config/crds/policies.kyverno.io/policies.kyverno.io_validatingpolicies.yaml

    # Delete the webhook configuration if it exists to avoid field manager conflicts
    # (the kubectl patch in wait_for_kyverno_webhook sets fields that conflict with Helm's server-side apply)
    kubectl delete validatingwebhookconfiguration kyverno-authz-server-validation 2>/dev/null || true

    print_info "Installing/upgrading Kyverno authorization server (this may take a few minutes)..."
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

    print_info "Applying Kyverno RBAC for SubjectAccessReview..."
    kubectl apply -f policies/kyverno-sar-rbac.yaml

    # Wait for Kyverno deployment to be ready
    print_info "Waiting for Kyverno authorization server to be ready..."
    kubectl wait --for=condition=available --timeout=300s deployment/kyverno-authz-server -n kyverno 2>/dev/null || {
        print_warning "Timeout waiting for Kyverno deployment"
    }

    # Wait for webhook to be ready
    wait_for_kyverno_webhook || {
        print_warning "Webhook may not be fully ready, but continuing..."
        print_info "If policy application fails, wait a moment and try: kubectl apply -f policies/"
    }

    print_success "Kyverno authorization server installed with custom image"
else
    print_warning "Skipping Kyverno installation"
fi

# Step 8: Install Gateway API and agentgateway
if [ "$SKIP_GATEWAY" = false ]; then
    print_header "Step 8: Install Gateway API and agentgateway"

    print_info "Installing Gateway API CRDs..."
    kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.1/standard-install.yaml

    print_info "Installing agentgateway CRDs..."
    helm upgrade -i agentgateway-crds oci://ghcr.io/kgateway-dev/charts/agentgateway-crds \
      --create-namespace --namespace agentgateway-system \
      --version v2.2.0-main \
      --set controller.image.pullPolicy=Always

    print_info "Installing agentgateway..."
    helm upgrade -i agentgateway oci://ghcr.io/kgateway-dev/charts/agentgateway \
      --namespace agentgateway-system \
      --version v2.2.0-main \
      --set controller.image.pullPolicy=Always \
      --set controller.extraEnv.KGW_ENABLE_GATEWAY_API_EXPERIMENTAL_FEATURES=true

    print_info "Waiting for agentgateway components to be ready..."
    wait_for_deployment agentgateway-system agentgateway 300
    wait_for_deployment agentgateway-system agentgateway-proxy 300
    kubectl wait --for=jsonpath='{.subsets[*].addresses[*].ip}' --timeout=120s endpoints/agentgateway-proxy -n agentgateway-system 2>/dev/null || {
        print_warning "Timeout waiting for agentgateway proxy endpoints, but continuing..."
    }

    print_success "Gateway API and agentgateway installed"

    print_info "Installing kagent-tools (Kubernetes-aware MCP tools)..."
    helm upgrade -i -n kagent --create-namespace kagent-tools \
      oci://ghcr.io/kagent-dev/tools/helm/kagent-tools \
      --version 0.0.13

    print_success "kagent-tools installed"
else
    print_warning "Skipping Gateway API and agentgateway installation"
fi

# Step 9: Configure Gateway Resources
print_header "Step 9: Configure Gateway Resources with MCP Authentication"

if [ -d ./gateway ]; then
    print_info "Applying gateway configurations..."
    kubectl apply -f gateway/
    print_success "Gateway resources applied"
else
    print_warning "gateway/ directory not found, skipping gateway configuration"
fi

# Step 10: Apply Kyverno Policies
print_header "Step 10: Apply Kyverno Authorization Policies"

if [ -d ./policies ]; then
    # Ensure webhook is ready before applying policies
    if ! wait_for_kyverno_webhook; then
        print_error "Kyverno webhook is not ready. Cannot apply policies."
        print_warning "You can manually apply policies later with:"
        print_warning "  kubectl apply -f policies/"
    else
        print_info "Applying Kyverno policies..."
        kubectl apply -f policies/no-unauthenticated-calls.yaml
        kubectl apply -f policies/restricted-group-deny-tools.yaml
        kubectl apply -f policies/dev-group-tool-guardrails.yaml
        kubectl apply -f policies/create-from-url-authz.yaml
        print_success "Kyverno policies applied"

        print_info "Verifying policies..."
        kubectl get validatingpolicy
    fi
else
    print_warning "policies/ directory not found, skipping policy application"
fi

# Continue with gateway host access configuration
if [ -d ./gateway ]; then

    if [[ "$OSTYPE" == "darwin"* ]]; then
        print_info "Configuring gateway.kind.cluster for host access via port-forward..."

        read -p "Do you want to update /etc/hosts for gateway.kind.cluster? (y/n) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            # On macOS with Docker Desktop, MetalLB LoadBalancer IPs are not routable
            # from the host. Keep the hostname on localhost and forward traffic to
            # the Gateway service so curl/Cursor can reach the MCP endpoint.
            print_info "Waiting for agentgateway proxy to be ready for port-forward..."
            wait_for_deployment agentgateway-system agentgateway-proxy 300
            kubectl wait --for=jsonpath='{.subsets[*].addresses[*].ip}' --timeout=120s endpoints/agentgateway-proxy -n agentgateway-system 2>/dev/null || {
                print_warning "Timeout waiting for agentgateway proxy endpoints, but continuing..."
            }

            print_info "Starting port-forward to agentgateway for host access..."
            nohup kubectl port-forward svc/agentgateway-proxy -n agentgateway-system 8080:8080 \
                >/tmp/agentgateway-port-forward.log 2>&1 &
            GATEWAY_PF_PID=$!
            sleep 2

            if kill -0 $GATEWAY_PF_PID 2>/dev/null; then
                sudo sed -i '' '/gateway\.kind\.cluster/d' /etc/hosts 2>/dev/null || true
                echo "127.0.0.1 gateway.kind.cluster" | sudo tee -a /etc/hosts >/dev/null
                print_success "DNS entry added to /etc/hosts (127.0.0.1 via port-forward)"
                print_info "Gateway port-forward log: /tmp/agentgateway-port-forward.log"
                print_info "You can now access the gateway at: http://gateway.kind.cluster:8080/mcp"
            else
                print_warning "Failed to start gateway port-forward."
                print_warning "Check /tmp/agentgateway-port-forward.log for details."
                print_warning "You can retry manually with: kubectl port-forward svc/agentgateway-proxy -n agentgateway-system 8080:8080"
            fi
        else
            print_warning "Skipping gateway host configuration."
        fi
    else
        # Wait for gateway to get LoadBalancer IP
        print_info "Waiting for gateway LoadBalancer IP..."
        sleep 10
        GATEWAY_LB_IP=$(kubectl get gateway -n agentgateway-system -o jsonpath='{.items[0].status.addresses[0].value}' 2>/dev/null || echo "")

        if [ -n "$GATEWAY_LB_IP" ]; then
            print_success "Gateway LoadBalancer IP: $GATEWAY_LB_IP"

            read -p "Do you want to update /etc/hosts for gateway.kind.cluster? (y/n) " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                sudo sed -i '/gateway\.kind\.cluster/d' /etc/hosts 2>/dev/null || true
                echo "$GATEWAY_LB_IP gateway.kind.cluster" | sudo tee -a /etc/hosts >/dev/null
                print_success "DNS entry added to /etc/hosts"
                print_info "You can now access the gateway at: http://gateway.kind.cluster:8080/mcp"
            else
                print_warning "Skipping DNS configuration. Access gateway at: http://$GATEWAY_LB_IP:8080/mcp"
            fi
        else
            print_warning "Failed to get Gateway LoadBalancer IP"
        fi
    fi
fi

# Final summary
print_header "Installation Complete!"

echo ""
print_success "All components have been installed successfully!"
echo ""
print_info "Next steps:"
echo "  1. Test token acquisition for alice:"
echo "     ./get-token.sh alice"
echo ""
echo "  2. Verify AgentgatewayPolicy and Kyverno policies:"
echo "     kubectl get agentgatewaypolicy -n agentgateway-system"
echo "     kubectl get validatingpolicy"
echo ""
echo "  3. Gateway URL:"
if [[ "$OSTYPE" == "darwin"* ]]; then
    echo "     http://gateway.kind.cluster:8080/mcp"
else
    echo "     GATEWAY_URL=\"\$(kubectl get gateway -n agentgateway-system -o jsonpath='{.items[0].status.addresses[0].value}'):8080\""
    echo "     echo \"Gateway URL: http://\$GATEWAY_URL/mcp\""
fi
echo ""
echo "  4. Run demo test cases from README.md:"
echo "     - Test Case 1.1: Unauthenticated request (should fail with 403)"
echo "     - Test Case 1.2: Authenticated request (should succeed)"
echo "     - Test Case 2.1: Authorized create in dev-team (should succeed)"
echo "     - Test Case 2.2: Unauthorized create in production (should fail with 403)"
echo ""
print_info "Keycloak Users & Credentials (configured via Terraform):"
echo "  - alice / alice        (kube-dev group)"
echo "  - user-dev / user-dev  (kube-dev group)"
echo "  - user-admin / user-admin (kube-admin group)"
echo ""
print_info "If Keycloak is restarted and users are lost, re-run Terraform:"
echo "  cd bootstrap && terraform apply"
echo ""
print_info "For troubleshooting, see the 'Common Issues' section in install.md"
echo ""