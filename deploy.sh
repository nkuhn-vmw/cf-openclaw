#!/bin/bash
# OpenClaw Cloud Foundry Deployment Script
# Supports: GenAI service binding, SSO integration, gateway auth
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

APP_NAME="openclaw"

echo -e "${GREEN}OpenClaw Cloud Foundry Deployment${NC}"
echo "=================================="

# Check prerequisites
check_prerequisites() {
    echo -e "\n${YELLOW}Checking prerequisites...${NC}"

    if ! command -v cf &> /dev/null; then
        echo -e "${RED}Error: Cloud Foundry CLI (cf) is not installed${NC}"
        echo "Install it from: https://docs.cloudfoundry.org/cf-cli/install-go-cli.html"
        exit 1
    fi

    if ! cf target &> /dev/null; then
        echo -e "${RED}Error: Not logged into Cloud Foundry${NC}"
        echo "Run: cf login -a https://api.your-cf-domain.com"
        exit 1
    fi

    echo -e "${GREEN}Prerequisites OK${NC}"
}

# Deploy using buildpack (recommended)
deploy_buildpack() {
    echo -e "\n${YELLOW}Deploying with Node.js buildpack...${NC}"

    # Check if we're in the openclaw directory or need to clone
    if [ ! -f "package.json" ]; then
        echo -e "${YELLOW}OpenClaw source not found. Cloning repository...${NC}"
        git clone https://github.com/openclaw/openclaw.git openclaw-src
        cd openclaw-src

        echo -e "${YELLOW}Copying deployment files...${NC}"
        cp ../manifest-buildpack.yml .
        cp ../.cfignore .
        cp ../.profile .
        cp ../start.sh .
    fi

    echo -e "${CYAN}Pushing to Cloud Foundry...${NC}"
    cf push -f manifest-buildpack.yml
}

# Deploy using Docker (alternative)
deploy_docker() {
    echo -e "\n${YELLOW}Deploying with Docker...${NC}"
    echo -e "${YELLOW}NOTE: No official openclaw/openclaw Docker Hub image exists.${NC}"
    echo -e "${YELLOW}You need to build and push your own, or use a community image.${NC}"
    echo ""

    # Check if diego_docker feature flag is enabled
    if ! cf feature-flags 2>/dev/null | grep -q "diego_docker.*enabled"; then
        echo -e "${YELLOW}Enabling Docker support...${NC}"
        cf enable-feature-flag diego_docker || {
            echo -e "${RED}Warning: Could not enable Docker support. You may need admin privileges.${NC}"
        }
    fi

    read -p "Continue with Docker deployment? (y/N): " confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        cf push -f manifest.yml
    else
        echo "Docker deployment cancelled."
    fi
}

# Setup GenAI service
setup_genai() {
    echo -e "\n${CYAN}=== GenAI Service Setup ===${NC}"

    # Check if genai service is available in marketplace
    if ! cf marketplace 2>/dev/null | grep -q "genai"; then
        echo -e "${RED}Error: GenAI service not found in marketplace${NC}"
        echo "Contact your platform operator to install the GenAI service broker."
        return 1
    fi

    echo -e "${YELLOW}Available GenAI plans:${NC}"
    cf marketplace -e genai 2>/dev/null || echo "(Could not list plans)"
    echo ""

    # Check if service already exists
    if cf service openclaw-genai &>/dev/null; then
        echo -e "${GREEN}Service 'openclaw-genai' already exists.${NC}"
        read -p "Delete and recreate? (y/N): " recreate
        if [ "$recreate" = "y" ] || [ "$recreate" = "Y" ]; then
            cf unbind-service "$APP_NAME" openclaw-genai 2>/dev/null || true
            cf delete-service openclaw-genai -f
            echo "Waiting for service deletion..."
            sleep 5
        else
            echo "Keeping existing service."
            return 0
        fi
    fi

    read -p "Enter GenAI plan name (e.g., tanzu-Qwen3-Coder-30B-A3B-vllm-v1): " genai_plan
    if [ -z "$genai_plan" ]; then
        echo "No plan specified, skipping GenAI setup."
        return 0
    fi

    echo -e "${YELLOW}Creating GenAI service...${NC}"
    cf create-service genai "$genai_plan" openclaw-genai

    echo -e "${YELLOW}Binding to ${APP_NAME}...${NC}"
    cf bind-service "$APP_NAME" openclaw-genai 2>/dev/null || {
        echo -e "${YELLOW}App not yet deployed. Service will be bound on next push.${NC}"
    }

    echo -e "${GREEN}GenAI service configured!${NC}"
    echo "The .profile script will automatically configure OpenClaw to use this model."
}

# Setup SSO with p-identity
setup_sso() {
    echo -e "\n${CYAN}=== SSO Setup (p-identity) ===${NC}"

    # Check if p-identity service is available
    if ! cf marketplace 2>/dev/null | grep -q "p-identity"; then
        echo -e "${RED}Error: SSO service (p-identity) not found in marketplace${NC}"
        echo "Contact your platform operator to install the SSO tile."
        return 1
    fi

    echo -e "${YELLOW}Available SSO plans:${NC}"
    cf marketplace -e p-identity 2>/dev/null || echo "(Could not list plans)"
    echo ""

    # Check if service already exists
    if cf service openclaw-sso &>/dev/null; then
        echo -e "${GREEN}Service 'openclaw-sso' already exists.${NC}"
    else
        read -p "Enter SSO plan name: " sso_plan
        if [ -z "$sso_plan" ]; then
            echo "No plan specified, skipping SSO setup."
            return 0
        fi

        echo -e "${YELLOW}Creating SSO service...${NC}"
        cf create-service p-identity "$sso_plan" openclaw-sso
    fi

    echo -e "${YELLOW}Binding SSO service to ${APP_NAME}...${NC}"
    cf bind-service "$APP_NAME" openclaw-sso 2>/dev/null || {
        echo -e "${YELLOW}App not yet deployed. Add 'openclaw-sso' to services in manifest.${NC}"
    }

    # Generate cookie secret
    COOKIE_SECRET=$(openssl rand -base64 32)
    echo -e "${YELLOW}Setting SSO environment variables...${NC}"
    cf set-env "$APP_NAME" OPENCLAW_SSO_ENABLED "true"
    cf set-env "$APP_NAME" OPENCLAW_COOKIE_SECRET "$COOKIE_SECRET"

    echo -e "${GREEN}SSO configured!${NC}"
    echo "Remember to add 'openclaw-sso' to the services list in your manifest."
    echo "Then restage: cf restage $APP_NAME"
}

# Setup gateway token
setup_gateway_token() {
    echo -e "\n${CYAN}=== Gateway Token Setup ===${NC}"
    echo "OpenClaw requires a gateway authentication token."
    echo "If not set, a random token is auto-generated on each startup."
    echo ""

    read -p "Enter a gateway token (or press Enter to use auto-generated): " token
    if [ -n "$token" ]; then
        cf set-env "$APP_NAME" OPENCLAW_GATEWAY_TOKEN "$token"
        echo -e "${GREEN}Gateway token set. Run 'cf restage $APP_NAME' to apply.${NC}"
    else
        echo "Using auto-generated token. Check 'cf logs $APP_NAME --recent' after startup to find it."
    fi
}

# Set legacy API keys (alternative to GenAI service)
set_api_keys() {
    local app_name="${1:-$APP_NAME}"

    echo -e "\n${CYAN}=== Manual API Keys ===${NC}"
    echo "Use this if NOT using the GenAI service (marketplace model binding)."
    echo ""

    read -p "Enter ANTHROPIC_API_KEY (or press Enter to skip): " anthropic_key
    if [ -n "$anthropic_key" ]; then
        cf set-env "$app_name" ANTHROPIC_API_KEY "$anthropic_key"
    fi

    read -p "Enter OPENAI_API_KEY (or press Enter to skip): " openai_key
    if [ -n "$openai_key" ]; then
        cf set-env "$app_name" OPENAI_API_KEY "$openai_key"
    fi

    if [ -n "$anthropic_key" ] || [ -n "$openai_key" ]; then
        echo -e "${YELLOW}Restaging app to apply environment variables...${NC}"
        cf restage "$app_name"
    fi
}

# Setup CredHub secrets service
setup_secrets() {
    local app_name="${1:-$APP_NAME}"
    local svc_name="openclaw-secrets"

    echo -e "\n${CYAN}=== Secrets Service Setup ===${NC}"
    echo "Creates a user-provided service with gateway token, node seed, and cookie secret."
    echo "These are stored in CF's credential store rather than plain env vars."
    echo ""

    if cf service "$svc_name" &>/dev/null; then
        echo -e "${GREEN}Service '${svc_name}' already exists.${NC}"
        read -p "Delete and recreate? (y/N): " recreate
        if [ "$recreate" = "y" ] || [ "$recreate" = "Y" ]; then
            cf unbind-service "$app_name" "$svc_name" 2>/dev/null || true
            cf delete-service "$svc_name" -f
        else
            echo "Keeping existing service."
            return 0
        fi
    fi

    # Generate or prompt for secrets
    local gw_token node_seed cookie_secret

    read -p "Enter gateway token (or press Enter to auto-generate): " gw_token
    gw_token="${gw_token:-$(openssl rand -hex 32)}"

    read -p "Enter node seed (or press Enter to auto-generate): " node_seed
    node_seed="${node_seed:-$(openssl rand -hex 16)}"

    cookie_secret=$(openssl rand -base64 32)

    echo -e "${YELLOW}Creating secrets service...${NC}"
    cf create-user-provided-service "$svc_name" -p "{\"gateway_token\":\"${gw_token}\",\"node_seed\":\"${node_seed}\",\"cookie_secret\":\"${cookie_secret}\"}"

    echo -e "${YELLOW}Binding to ${app_name}...${NC}"
    cf bind-service "$app_name" "$svc_name" 2>/dev/null || {
        echo -e "${YELLOW}App not yet deployed. Add 'openclaw-secrets' to services in manifest.${NC}"
    }

    echo -e "${GREEN}Secrets service configured!${NC}"
    echo "  Gateway token: ${gw_token:0:8}..."
    echo "  Node seed: ${node_seed:0:8}..."
    echo "  Cookie secret: (auto-generated)"
    echo ""
    echo "Add 'openclaw-secrets' to the services list in your manifest, then restage."
}

# Setup NFS persistent storage
setup_nfs() {
    local app_name="${1:-$APP_NAME}"

    echo -e "\n${CYAN}=== NFS Persistent Storage Setup ===${NC}"
    echo "Bind an NFS volume to persist OpenClaw state (chat history, device pairings,"
    echo "workspace data) across restages and restarts."
    echo ""
    echo -e "${YELLOW}Prerequisites:${NC}"
    echo "  - NFS volume services must be enabled on your CF foundation"
    echo "  - An NFS server share must be available"
    echo ""

    # Check if NFS service type is available
    if ! cf marketplace 2>/dev/null | grep -qE "^nfs\b"; then
        echo -e "${RED}Error: NFS volume service not found in marketplace.${NC}"
        echo "Ask your platform operator to install the NFS Volume Service broker."
        echo "See: https://docs.cloudfoundry.org/devguide/services/using-vol-services.html"
        return 1
    fi

    local SVC_NAME="openclaw-storage"

    if cf service "$SVC_NAME" &>/dev/null; then
        echo -e "${GREEN}Service '${SVC_NAME}' already exists.${NC}"
        read -p "Delete and recreate? (y/N): " recreate
        if [ "$recreate" = "y" ] || [ "$recreate" = "Y" ]; then
            cf unbind-service "$app_name" "$SVC_NAME" 2>/dev/null || true
            cf delete-service "$SVC_NAME" -f
            echo "Waiting for service deletion..."
            sleep 5
        else
            echo "Keeping existing service."
            return 0
        fi
    fi

    echo -e "${YELLOW}Available NFS plans:${NC}"
    cf marketplace -e nfs 2>/dev/null || echo "(Could not list plans)"
    echo ""

    read -p "Enter NFS share path (e.g., nfs-server.example.com/exports/openclaw): " nfs_share
    if [ -z "$nfs_share" ]; then
        echo "No share path provided, skipping NFS setup."
        return 0
    fi

    read -p "Enter NFS plan name (default: Existing): " nfs_plan
    nfs_plan="${nfs_plan:-Existing}"

    echo -e "${YELLOW}Creating NFS service instance...${NC}"
    cf create-service nfs "$nfs_plan" "$SVC_NAME" -c "{\"share\":\"${nfs_share}\"}"

    echo -e "${YELLOW}Binding to ${app_name} with volume mount...${NC}"
    cf bind-service "$app_name" "$SVC_NAME" -c '{"uid":"vcap","gid":"vcap","mount":"/home/vcap/app/data/persistent"}'

    echo -e "\n${GREEN}NFS storage configured!${NC}"
    echo "  Service: ${SVC_NAME}"
    echo "  Share: ${nfs_share}"
    echo "  Mount path: /home/vcap/app/data/persistent"
    echo "  OPENCLAW_STATE_DIR will auto-detect the mount on next restage."
    echo ""
    echo "Restage to apply: cf restage ${app_name}"
}

# Show app info
show_info() {
    echo -e "\n${GREEN}=== Application Status ===${NC}"
    cf app "$APP_NAME" 2>/dev/null || echo "(App not yet deployed)"

    echo -e "\n${YELLOW}Bound Services:${NC}"
    cf services 2>/dev/null | grep "$APP_NAME" || echo "(No services bound)"

    echo -e "\n${YELLOW}Environment Variables:${NC}"
    cf env "$APP_NAME" 2>/dev/null | grep -E "(OPENCLAW_|ANTHROPIC_|OPENAI_)" || echo "(App not yet deployed)"

    echo -e "\n${CYAN}Useful Commands:${NC}"
    echo "  cf logs $APP_NAME --recent       # View recent logs"
    echo "  cf logs $APP_NAME                 # Stream live logs"
    echo "  cf restage $APP_NAME              # Apply config changes"
    echo "  cf ssh $APP_NAME                  # SSH into container"
}

# Full setup (all steps in sequence)
full_setup() {
    echo -e "\n${GREEN}=== Full Setup ===${NC}"
    echo "This will:"
    echo "  1. Create and bind a GenAI service"
    echo "  2. Setup gateway authentication"
    echo "  3. Deploy with buildpack"
    echo "  4. (Optional) Enable SSO"
    echo ""
    read -p "Continue? (y/N): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo "Cancelled."
        return
    fi

    setup_genai
    setup_gateway_token
    deploy_buildpack

    read -p "Enable SSO? (y/N): " enable_sso
    if [ "$enable_sso" = "y" ] || [ "$enable_sso" = "Y" ]; then
        setup_sso
        echo -e "${YELLOW}Restaging to apply SSO...${NC}"
        cf restage "$APP_NAME"
    fi

    show_info
}

# Deploy node (system.run capability)
deploy_node() {
    local NODE_NAME="openclaw-node"

    echo -e "\n${CYAN}=== Deploy OpenClaw Node ===${NC}"
    echo "A node provides system.run/system.which capabilities to the gateway."
    echo ""

    # Check if gateway is running
    if ! cf app "$APP_NAME" &>/dev/null; then
        echo -e "${RED}Error: Gateway app '$APP_NAME' not found.${NC}"
        echo "Deploy the gateway first using option 1 or 2."
        return 1
    fi

    # Get gateway token
    echo -e "${YELLOW}Retrieving gateway token...${NC}"
    local gateway_token
    gateway_token=$(cf env "$APP_NAME" 2>/dev/null | grep "OPENCLAW_GATEWAY_TOKEN" | awk -F: '{print $2}' | tr -d ' ')

    if [ -z "$gateway_token" ]; then
        echo "Gateway token not found in env. Checking recent logs..."
        gateway_token=$(cf logs "$APP_NAME" --recent 2>/dev/null | grep -o "Token: [a-f0-9]*" | tail -1 | awk '{print $2}')
    fi

    if [ -z "$gateway_token" ]; then
        echo -e "${YELLOW}Could not auto-detect gateway token.${NC}"
        read -p "Enter the gateway token: " gateway_token
        if [ -z "$gateway_token" ]; then
            echo -e "${RED}Gateway token is required.${NC}"
            return 1
        fi
    else
        echo -e "${GREEN}Found gateway token: ${gateway_token:0:8}...${NC}"
    fi

    # Check if we're in the openclaw source directory
    if [ ! -f "package.json" ]; then
        echo -e "${RED}Error: Must run from OpenClaw source directory${NC}"
        echo "cd into the openclaw-src directory and try again."
        return 1
    fi

    # Copy node deployment files if not present
    if [ ! -f "manifest-node.yml" ]; then
        echo -e "${YELLOW}Copying node deployment files...${NC}"
        [ -f "../cf-openclaw/manifest-node.yml" ] && cp ../cf-openclaw/manifest-node.yml .
        [ -f "../cf-openclaw/start-node.sh" ] && cp ../cf-openclaw/start-node.sh .
    fi

    # Set the gateway token
    echo -e "${CYAN}Deploying node...${NC}"
    cf push -f manifest-node.yml --no-start
    cf set-env "$NODE_NAME" OPENCLAW_GATEWAY_TOKEN "$gateway_token"

    # Add network policy
    echo -e "${YELLOW}Adding network policy for container-to-container communication...${NC}"
    cf add-network-policy "$NODE_NAME" "$APP_NAME" --port 8081 --protocol tcp || {
        echo -e "${YELLOW}Note: Network policy may already exist or require admin privileges.${NC}"
    }

    # Start the node
    cf start "$NODE_NAME"

    echo -e "\n${GREEN}Node deployed!${NC}"
    echo ""
    echo "The node will connect to the gateway via internal CF networking."
    echo "Check status with: cf logs $NODE_NAME --recent"
    echo ""
    echo "Once connected, the node provides system.run capabilities to agents."
}

# Scale node instances up or down
scale_nodes() {
    local NODE_APP="openclaw-node"

    echo -e "\n${CYAN}=== Scale Node Instances ===${NC}"

    if ! cf app "$NODE_APP" &>/dev/null; then
        echo -e "${RED}Error: Node app '$NODE_APP' not found.${NC}"
        echo "Deploy the node first using option 8."
        return 1
    fi

    echo -e "${YELLOW}Current node status:${NC}"
    cf app "$NODE_APP" | grep -E "(instances|running|crashed)"
    echo ""

    read -p "Enter desired number of instances: " num_instances
    if ! [[ "$num_instances" =~ ^[0-9]+$ ]] || [ "$num_instances" -lt 0 ]; then
        echo -e "${RED}Invalid number. Must be >= 0.${NC}"
        return 1
    fi

    if [ "$num_instances" -eq 0 ]; then
        echo -e "${YELLOW}Stopping all node instances...${NC}"
        cf stop "$NODE_APP"
        echo -e "${GREEN}Node stopped.${NC}"
        return 0
    fi

    # Check if seed is configured (required for multi-instance)
    if [ "$num_instances" -gt 1 ]; then
        local has_seed
        has_seed=$(cf env "$NODE_APP" 2>/dev/null | grep "OPENCLAW_NODE_SEED" || true)
        if [ -z "$has_seed" ]; then
            echo -e "${RED}Error: OPENCLAW_NODE_SEED is required for multi-instance scaling.${NC}"
            echo "Set it on both gateway and node:"
            echo "  cf set-env $APP_NAME OPENCLAW_NODE_SEED \"\$(openssl rand -hex 16)\""
            echo "  cf set-env $NODE_APP OPENCLAW_NODE_SEED \"<same value>\""
            return 1
        fi
    fi

    # Update gateway's max instances if needed
    local max_registered
    max_registered=$(cf env "$APP_NAME" 2>/dev/null | grep "OPENCLAW_NODE_MAX_INSTANCES" | awk -F: '{print $2}' | tr -d ' "' || echo "")

    if [ -z "$max_registered" ] || [ "$max_registered" -lt "$num_instances" ] 2>/dev/null; then
        echo -e "${YELLOW}Gateway needs to register ${num_instances} node keypair(s).${NC}"
        echo "Setting OPENCLAW_NODE_MAX_INSTANCES=${num_instances} on gateway..."
        cf set-env "$APP_NAME" OPENCLAW_NODE_MAX_INSTANCES "$num_instances"
        echo -e "${YELLOW}Restaging gateway to register new device keypairs...${NC}"
        cf restage "$APP_NAME"
    fi

    echo -e "${CYAN}Scaling node to ${num_instances} instance(s)...${NC}"
    cf scale "$NODE_APP" -i "$num_instances"

    echo -e "\n${GREEN}Node scaled to ${num_instances} instance(s)!${NC}"
    echo "Each instance derives a unique identity from the shared seed + CF_INSTANCE_INDEX."
    echo "Check status: cf app $NODE_APP"
}

# Parse --name flag from args
parse_instance_name() {
    local name=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name) name="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    echo "$name"
}

# Create isolated instance for a user/team
create_instance() {
    local instance_name="$1"
    if [ -z "$instance_name" ]; then
        read -p "Enter instance name (e.g., alice, team-alpha): " instance_name
    fi
    if [ -z "$instance_name" ]; then
        echo -e "${RED}Instance name is required.${NC}"
        return 1
    fi

    local GW_APP="openclaw-${instance_name}"
    local NODE_APP="openclaw-node-${instance_name}"
    local GENAI_SVC="openclaw-genai-${instance_name}"

    echo -e "\n${CYAN}=== Creating Instance: ${instance_name} ===${NC}"
    echo "  Gateway app:  ${GW_APP}"
    echo "  Node app:     ${NODE_APP}"
    echo ""

    # Auto-generate secrets
    local SEED=$(openssl rand -hex 16)
    local TOKEN=$(openssl rand -hex 32)

    echo -e "${YELLOW}Generated secrets:${NC}"
    echo "  Node Seed: ${SEED:0:8}..."
    echo "  Gateway Token: ${TOKEN:0:8}..."

    # Check if we're in openclaw source dir
    if [ ! -f "package.json" ]; then
        echo -e "${RED}Error: Must run from OpenClaw source directory${NC}"
        return 1
    fi

    # GenAI service - shared or dedicated
    read -p "Create dedicated GenAI service for ${instance_name}? (y/N, N = use existing shared): " create_genai
    if [ "$create_genai" = "y" ] || [ "$create_genai" = "Y" ]; then
        echo -e "${YELLOW}Available GenAI plans:${NC}"
        cf marketplace -e genai 2>/dev/null || true
        read -p "Enter GenAI plan name: " genai_plan
        if [ -n "$genai_plan" ]; then
            cf create-service genai "$genai_plan" "$GENAI_SVC"
        fi
    else
        read -p "Enter existing GenAI service name to share (default: tanzu-all-models): " shared_svc
        GENAI_SVC="${shared_svc:-tanzu-all-models}"
    fi

    # Deploy gateway (override app name from CLI, use --no-route to avoid hardcoded route)
    echo -e "\n${CYAN}Deploying gateway: ${GW_APP}${NC}"
    cf push "$GW_APP" -f manifest-buildpack.yml --no-start --no-route
    cf map-route "$GW_APP" apps.internal --hostname "$GW_APP"

    # Try to detect the apps domain and create an external route
    local APPS_DOMAIN
    APPS_DOMAIN=$(cf routes 2>/dev/null | awk 'NR>3 && $2 ~ /apps\./ {print $2; exit}' || echo "")
    if [ -n "$APPS_DOMAIN" ]; then
        cf map-route "$GW_APP" "$APPS_DOMAIN" --hostname "$GW_APP"
        echo -e "${GREEN}External route: ${GW_APP}.${APPS_DOMAIN}${NC}"
    fi

    cf set-env "$GW_APP" OPENCLAW_GATEWAY_TOKEN "$TOKEN"
    cf set-env "$GW_APP" OPENCLAW_NODE_SEED "$SEED"
    cf set-env "$GW_APP" OPENCLAW_NODE_MAX_INSTANCES "1"
    cf bind-service "$GW_APP" "$GENAI_SVC" 2>/dev/null || {
        echo -e "${YELLOW}Warning: Could not bind GenAI service '${GENAI_SVC}'.${NC}"
    }
    cf start "$GW_APP"

    # Deploy node
    echo -e "\n${CYAN}Deploying node: ${NODE_APP}${NC}"
    cf push "$NODE_APP" -f manifest-node.yml --no-start --no-route
    cf map-route "$NODE_APP" apps.internal --hostname "$NODE_APP"
    cf set-env "$NODE_APP" OPENCLAW_GATEWAY_TOKEN "$TOKEN"
    cf set-env "$NODE_APP" OPENCLAW_NODE_SEED "$SEED"
    cf set-env "$NODE_APP" OPENCLAW_GATEWAY_HOST "${GW_APP}.apps.internal"
    cf set-env "$NODE_APP" OPENCLAW_NODE_NAME "cf-node-${instance_name}"

    # Network policy
    echo -e "${YELLOW}Adding network policy...${NC}"
    cf add-network-policy "$NODE_APP" "$GW_APP" --port 8081 --protocol tcp || true
    cf start "$NODE_APP"

    echo -e "\n${GREEN}Instance '${instance_name}' deployed!${NC}"
    echo "  Gateway: ${GW_APP}"
    echo "  Node: ${NODE_APP}"
    echo "  Token: ${TOKEN}"
    if [ -n "$APPS_DOMAIN" ]; then
        echo "  URL: https://${GW_APP}.${APPS_DOMAIN}"
    fi
}

# Destroy an instance
destroy_instance() {
    local instance_name="$1"
    if [ -z "$instance_name" ]; then
        read -p "Enter instance name to destroy: " instance_name
    fi
    if [ -z "$instance_name" ]; then
        echo -e "${RED}Instance name is required.${NC}"
        return 1
    fi

    local GW_APP="openclaw-${instance_name}"
    local NODE_APP="openclaw-node-${instance_name}"
    local GENAI_SVC="openclaw-genai-${instance_name}"

    echo -e "\n${RED}=== Destroying Instance: ${instance_name} ===${NC}"
    echo "  This will delete: ${GW_APP}, ${NODE_APP}"
    read -p "Are you sure? (y/N): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo "Cancelled."
        return
    fi

    cf remove-network-policy "$NODE_APP" "$GW_APP" --port 8081 --protocol tcp 2>/dev/null || true
    cf delete "$NODE_APP" -f 2>/dev/null || true
    cf delete "$GW_APP" -f 2>/dev/null || true

    # Optionally delete dedicated GenAI service
    if cf service "$GENAI_SVC" &>/dev/null; then
        read -p "Delete dedicated GenAI service '${GENAI_SVC}'? (y/N): " del_svc
        if [ "$del_svc" = "y" ] || [ "$del_svc" = "Y" ]; then
            cf delete-service "$GENAI_SVC" -f
        fi
    fi

    echo -e "${GREEN}Instance '${instance_name}' destroyed.${NC}"
}

# List all deployed instances
list_instances() {
    echo -e "\n${CYAN}=== OpenClaw Instances ===${NC}"
    echo ""
    echo -e "${YELLOW}Gateway apps:${NC}"
    cf apps 2>/dev/null | grep "^openclaw" | grep -v "node" || echo "  (none found)"
    echo ""
    echo -e "${YELLOW}Node apps:${NC}"
    cf apps 2>/dev/null | grep "^openclaw-node" || echo "  (none found)"
}

# Main menu
main() {
    check_prerequisites

    # Support CLI subcommands: ./deploy.sh create-instance --name alice
    case "${1:-}" in
        create-instance)
            shift
            create_instance "$(parse_instance_name "$@")"
            return
            ;;
        destroy-instance)
            shift
            destroy_instance "$(parse_instance_name "$@")"
            return
            ;;
        list-instances)
            list_instances
            return
            ;;
    esac

    echo -e "\n${YELLOW}Select an option:${NC}"
    echo ""
    echo -e "${CYAN}Single Instance:${NC}"
    echo "  1) Full setup (recommended for first-time deployment)"
    echo "  2) Deploy with buildpack"
    echo "  3) Deploy with Docker"
    echo "  4) Create/bind GenAI service"
    echo "  5) Enable SSO"
    echo "  6) Set gateway token"
    echo "  7) Set manual API keys (alternative to GenAI)"
    echo "  8) Deploy node (system.run capability)"
    echo "  9) Scale nodes"
    echo " 10) Setup secrets service (CredHub)"
    echo " 11) Setup NFS persistent storage"
    echo " 12) Show app info"
    echo ""
    echo -e "${CYAN}Multi-User:${NC}"
    echo " 13) Create user instance"
    echo " 14) Destroy user instance"
    echo " 15) List all instances"
    echo ""
    read -p "Enter choice [1-15]: " choice

    case $choice in
        1) full_setup ;;
        2) deploy_buildpack ;;
        3) deploy_docker ;;
        4) setup_genai ;;
        5) setup_sso ;;
        6) setup_gateway_token ;;
        7) set_api_keys ;;
        8) deploy_node ;;
        9) scale_nodes ;;
        10) setup_secrets ;;
        11) setup_nfs ;;
        12) show_info ;;
        13) create_instance ;;
        14) destroy_instance ;;
        15) list_instances ;;
        *)
            echo -e "${RED}Invalid choice${NC}"
            exit 1
            ;;
    esac
}

# Run main function
main "$@"
