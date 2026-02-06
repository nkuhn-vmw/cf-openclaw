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

# Main menu
main() {
    check_prerequisites

    echo -e "\n${YELLOW}Select an option:${NC}"
    echo "1) Full setup (recommended for first-time deployment)"
    echo "2) Deploy with buildpack"
    echo "3) Deploy with Docker"
    echo "4) Create/bind GenAI service"
    echo "5) Enable SSO"
    echo "6) Set gateway token"
    echo "7) Set manual API keys (alternative to GenAI)"
    echo "8) Deploy node (system.run capability)"
    echo "9) Show app info"
    read -p "Enter choice [1-9]: " choice

    case $choice in
        1) full_setup ;;
        2) deploy_buildpack ;;
        3) deploy_docker ;;
        4) setup_genai ;;
        5) setup_sso ;;
        6) setup_gateway_token ;;
        7) set_api_keys ;;
        8) deploy_node ;;
        9) show_info ;;
        *)
            echo -e "${RED}Invalid choice${NC}"
            exit 1
            ;;
    esac
}

# Run main function
main "$@"
