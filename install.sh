#!/usr/bin/env bash
#
# APM Stack Installer for the `apm` namespace.
#
# Applies the RPA templates in order, substituting all placeholder variables
# before calling `kubectl apply`.
#
# Steps
# -----
# 1. RBAC            – step1-coroot-cluster-agent-rbac.yaml
# 2. Cluster Agent   – step2-coroot-cluster-agent.yaml
# 3. Node Agent DS   – step3-coroot-node-agent-ds.yaml
# 4. Fluent Bit      – step5-fluent-bit-*.yaml  (optional, --install-fluentbit)
# 5. Prometheus      – step4-prometheus-configmap.yaml
#                     step4-prometheus-deployment.yaml
#                     step4-prometheus-service.yaml
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

IMAGE_REPO=""
K8S_CLUSTER_NAME=""
CONTAINER_ALLOWLIST=""
TECHNOLOGY_CATEGORY_ID=""
CLOUDXP_CUSTOMER_ID=""
APPLICATION_ID=""
APPLICATION_NAME=""
FLUENTBIT_ENDPOINT=""
JWT_TOKEN=""
INSTALL_FLUENTBIT=false
HCMP_METRICS_HOST="sitazure.hcmp.jio.com"
HCMP_METRICS_PORT="443"
HCMP_METRICS_URI="/metrics"
PULL_SECRET_NAME=""
NEXUS_USERNAME=""
NEXUS_PASSWORD=""
NEXUS_AUTH=""
DRY_RUN=false
KUBECONFIG_PATH=""
KUBECTL_CONTEXT=""

usage() {
    cat <<'EOF'
Usage: install.sh [OPTIONS]

Install the APM observability stack into the `apm` namespace.

Required:
  --image-repo IMAGE_REPO
                        Container image registry prefix, e.g. registry.example.com/apm
  --k8s-cluster-name K8S_CLUSTER_NAME
                        Kubernetes cluster name (INSTANCE_TYPE / external_labels.cluster)
  --container-allowlist CONTAINER_ALLOWLIST
                        Regex allowlist for node agent, e.g. '/k8s/(deeptrace|coroot)/.*'
  --technology-category-id TECHNOLOGY_CATEGORY_ID
                        technologyCategoryId label forwarded to Fluent Bit
  --cloudxp-customer-id CLOUDXP_CUSTOMER_ID
                        CloudXP_CustomerID label forwarded to Fluent Bit
  --application-id APPLICATION_ID
                        Application ID label
  --application-name APPLICATION_NAME
                        Application name label
  --fluentbit-endpoint FLUENTBIT_ENDPOINT
                        Fluent Bit remote-write URL for Prometheus remote_write.
                        Required unless --install-fluentbit is set (defaults to
                        http://fluent-bit.apm.svc.cluster.local:9882/api/v1/metrics)
  --jwt-token JWT_TOKEN
                        JWT Bearer token for Fluent Bit HCMP remote_write authentication

Optional:
  --install-fluentbit   Deploy in-cluster Fluent Bit (receives from Prometheus,
                        forwards to HCMP). When set, --fluentbit-endpoint defaults
                        to the in-cluster service URL if omitted.
  --hcmp-metrics-host HOST
                        HCMP metrics host for Fluent Bit output
                        (default: sitazure.hcmp.jio.com)
  --hcmp-metrics-port PORT
                        HCMP metrics port for Fluent Bit output (default: 443)
  --hcmp-metrics-uri URI
                        HCMP metrics path for Fluent Bit output
                        (default: /metrics)
  --pull-secret-name PULL_SECRET_NAME
                        Nexus image pull secret name; when omitted, no Secret or
                        imagePullSecrets are applied (use cluster default pull creds)
  --nexus-username NEXUS_USERNAME
                        Nexus registry username (required with --pull-secret-name)
  --nexus-password NEXUS_PASSWORD
                        Nexus registry password (required with --pull-secret-name)
  --dry-run             Print rendered YAML without calling kubectl
  --kubeconfig PATH     Path to kubeconfig (overrides KUBECONFIG env var)
  --context CONTEXT     kubectl context to use
  --help                Show this help message
EOF
}

die() {
    echo "[ERROR] $*" >&2
    exit 1
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --image-repo)
                IMAGE_REPO="$2"
                shift 2
                ;;
            --k8s-cluster-name)
                K8S_CLUSTER_NAME="$2"
                shift 2
                ;;
            --container-allowlist)
                CONTAINER_ALLOWLIST="$2"
                shift 2
                ;;
            --technology-category-id)
                TECHNOLOGY_CATEGORY_ID="$2"
                shift 2
                ;;
            --cloudxp-customer-id)
                CLOUDXP_CUSTOMER_ID="$2"
                shift 2
                ;;
            --application-id)
                APPLICATION_ID="$2"
                shift 2
                ;;
            --application-name)
                APPLICATION_NAME="$2"
                shift 2
                ;;
            --fluentbit-endpoint)
                FLUENTBIT_ENDPOINT="$2"
                shift 2
                ;;
            --jwt-token)
                JWT_TOKEN="$2"
                shift 2
                ;;
            --install-fluentbit)
                INSTALL_FLUENTBIT=true
                shift
                ;;
            --hcmp-metrics-host)
                HCMP_METRICS_HOST="$2"
                shift 2
                ;;
            --hcmp-metrics-port)
                HCMP_METRICS_PORT="$2"
                shift 2
                ;;
            --hcmp-metrics-uri)
                HCMP_METRICS_URI="$2"
                shift 2
                ;;
            --pull-secret-name)
                PULL_SECRET_NAME="$2"
                shift 2
                ;;
            --nexus-username)
                NEXUS_USERNAME="$2"
                shift 2
                ;;
            --nexus-password)
                NEXUS_PASSWORD="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --kubeconfig)
                KUBECONFIG_PATH="$2"
                shift 2
                ;;
            --context)
                KUBECTL_CONTEXT="$2"
                shift 2
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                die "Unknown option: $1 (use --help)"
                ;;
        esac
    done

    local missing=()
    [[ -z "$IMAGE_REPO" ]] && missing+=("--image-repo")
    [[ -z "$K8S_CLUSTER_NAME" ]] && missing+=("--k8s-cluster-name")
    [[ -z "$CONTAINER_ALLOWLIST" ]] && missing+=("--container-allowlist")
    [[ -z "$TECHNOLOGY_CATEGORY_ID" ]] && missing+=("--technology-category-id")
    [[ -z "$CLOUDXP_CUSTOMER_ID" ]] && missing+=("--cloudxp-customer-id")
    [[ -z "$JWT_TOKEN" ]] && missing+=("--jwt-token")
    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Missing required option(s): ${missing[*]}"
    fi

    if [[ "$INSTALL_FLUENTBIT" == true && -z "$FLUENTBIT_ENDPOINT" ]]; then
        FLUENTBIT_ENDPOINT="http://fluent-bit.apm.svc.cluster.local:9882/api/v1/metrics"
    fi

    if [[ -z "$FLUENTBIT_ENDPOINT" ]]; then
        die "Missing required option: --fluentbit-endpoint (or pass --install-fluentbit to use the in-cluster default)"
    fi

    if [[ -n "$PULL_SECRET_NAME" ]]; then
        local secret_missing=()
        [[ -z "$NEXUS_USERNAME" ]] && secret_missing+=("--nexus-username")
        [[ -z "$NEXUS_PASSWORD" ]] && secret_missing+=("--nexus-password")
        if [[ ${#secret_missing[@]} -gt 0 ]]; then
            die "When --pull-secret-name is set, also pass: ${secret_missing[*]}"
        fi
        NEXUS_AUTH=$(printf '%s:%s' "$NEXUS_USERNAME" "$NEXUS_PASSWORD" | base64)
    fi
}

build_kubectl_args() {
    KUBECTL_ARGS=()
    if [[ -n "$KUBECONFIG_PATH" ]]; then
        KUBECTL_ARGS+=(--kubeconfig "$KUBECONFIG_PATH")
    fi
    if [[ -n "$KUBECTL_CONTEXT" ]]; then
        KUBECTL_ARGS+=(--context "$KUBECTL_CONTEXT")
    fi
}

render_template() {
    local file="$1"
    local content
    content=$(<"$file")
    content="${content//__IMAGE_REPO__/$IMAGE_REPO}"
    content="${content//__K8S_CLUSTER_NAME__/$K8S_CLUSTER_NAME}"
    content="${content//__CONTAINER_ALLOWLIST__/$CONTAINER_ALLOWLIST}"
    content="${content//__technologyCategoryId__/$TECHNOLOGY_CATEGORY_ID}"
    content="${content//__CloudXP_CustomerID__/$CLOUDXP_CUSTOMER_ID}"
    content="${content//__APPLICATION_ID__/$APPLICATION_ID}"
    content="${content//__APPLICATION_NAME__/$APPLICATION_NAME}"
    content="${content//__FLUENTBIT_ENDPOINT__/$FLUENTBIT_ENDPOINT}"
    content="${content//__JWT_TOKEN__/$JWT_TOKEN}"
    content="${content//__HCMP_METRICS_HOST__/$HCMP_METRICS_HOST}"
    content="${content//__HCMP_METRICS_PORT__/$HCMP_METRICS_PORT}"
    content="${content//__HCMP_METRICS_URI__/$HCMP_METRICS_URI}"
    if [[ -n "$PULL_SECRET_NAME" ]]; then
        content="${content//__PULL_SECRET_NAME__/$PULL_SECRET_NAME}"
        content="${content//__NEXUS_USERNAME__/$NEXUS_USERNAME}"
        content="${content//__NEXUS_PASSWORD__/$NEXUS_PASSWORD}"
        content="${content//__NEXUS_AUTH__/$NEXUS_AUTH}"
    else
        content=$(remove_pull_secret_config "$content")
    fi
    printf '%s' "$content"
}

# Drop docker-registry Secret docs and imagePullSecrets when no pull secret is configured.
remove_pull_secret_config() {
    local content="$1"
    printf '%s' "$content" | awk '
        function flush() {
            if (nbuf == 0) return
            if (!skip_doc) {
                if (printed++) printf "---\n"
                printf "%s", buf
            }
            buf = ""
            nbuf = 0
            skip_doc = 0
        }
        /^---$/ {
            flush()
            next
        }
        {
            if ($0 ~ /^kind:[[:space:]]*Secret[[:space:]]*$/) skip_doc = 1
            buf = buf $0 "\n"
            nbuf++
        }
        END { flush() }
    ' | awk '
        /^[[:space:]]*imagePullSecrets:/ { skip = 2; next }
        skip > 0 { skip--; next }
        { print }
    '
}

kubectl_apply() {
    local rendered_yaml="$1"

    if [[ "$DRY_RUN" == true ]]; then
        printf '%s\n' "$rendered_yaml"
        return 0
    fi

    local tmp
    tmp=$(mktemp "${TMPDIR:-/tmp}/apm-rpa.XXXXXX.yaml")
    trap 'rm -f "$tmp"' RETURN
    printf '%s' "$rendered_yaml" >"$tmp"
    kubectl apply -f "$tmp" "${KUBECTL_ARGS[@]}"
    rm -f "$tmp"
    trap - RETURN
}

ensure_namespace() {
    if [[ "$DRY_RUN" == true ]]; then
        echo "# [dry-run] kubectl create namespace apm --dry-run=client"
        return 0
    fi

    kubectl create namespace apm \
        --dry-run=client -o yaml \
        "${KUBECTL_ARGS[@]}" \
        | kubectl apply -f - "${KUBECTL_ARGS[@]}"
    echo "Namespace \`apm\` ensured."
}

apply_step() {
    local step_name="$1"
    shift
    local -a files=("$@")
    local combined_yaml=""
    local rendered file_path

    echo ""
    echo ">>> ${step_name}"

    for filename in "${files[@]}"; do
        file_path="${SCRIPT_DIR}/${filename}"
        if [[ ! -f "$file_path" ]]; then
            die "Template not found: ${file_path}"
        fi
        rendered=$(render_template "$file_path")
        if [[ -n "$combined_yaml" ]]; then
            combined_yaml+=$'\n---\n'
        fi
        combined_yaml+="$rendered"
    done

    kubectl_apply "$combined_yaml"
    echo "    done."
}

main() {
    parse_args "$@"
    build_kubectl_args

    echo "============================================================"
    echo "APM Stack Installer"
    echo "============================================================"
    echo "  Cluster : ${K8S_CLUSTER_NAME}"
    echo "  Image   : ${IMAGE_REPO}"
    echo "  Secret  : ${PULL_SECRET_NAME:-<none — cluster default pull creds>}"
    echo "  FluentBit: ${FLUENTBIT_ENDPOINT}"
    echo "  Install FB: ${INSTALL_FLUENTBIT}"
    if [[ "$INSTALL_FLUENTBIT" == true ]]; then
        echo "  HCMP out : https://${HCMP_METRICS_HOST}:${HCMP_METRICS_PORT}${HCMP_METRICS_URI} (tls.verify=off)"
    fi
    echo "  Dry-run : ${DRY_RUN}"
    echo "============================================================"

    ensure_namespace

    apply_step "Step 1 – RBAC (ServiceAccount + ClusterRole + ClusterRoleBinding)" \
        step1-coroot-cluster-agent-rbac.yaml

    apply_step "Step 2 – Coroot Cluster Agent Deployment" \
        step2-coroot-cluster-agent.yaml

    apply_step "Step 3 – Coroot Node Agent DaemonSet" \
        step3-coroot-node-agent-ds.yaml

    if [[ "$INSTALL_FLUENTBIT" == true ]]; then
        apply_step "Step 4 – Fluent Bit ConfigMap, Deployment & Service" \
            step5-fluent-bit-configmap.yaml \
            step5-fluent-bit-deployment.yaml \
            step5-fluent-bit-service.yaml
    else
        echo ""
        echo ">>> Step 4 – Fluent Bit (skipped; pass --install-fluentbit to deploy)"
    fi

    apply_step "Step 5 – Prometheus ConfigMap, Deployment & Service" \
        step4-prometheus-configmap.yaml \
        step4-prometheus-deployment.yaml \
        step4-prometheus-service.yaml

    echo ""
    echo "APM stack installed successfully."
}

main "$@"

