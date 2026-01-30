#!/bin/bash
# OpenClaw Cloud Foundry Deployment Script
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

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

# Deploy using Docker
deploy_docker() {
    echo -e "\n${YELLOW}Deploying with Docker...${NC}"

    # Check if Docker feature flag is enabled
    if ! cf feature-flags | grep -q "diego_docker.*enabled"; then
        echo -e "${YELLOW}Enabling Docker support...${NC}"
        cf enable-feature-flag diego_docker || {
            echo -e "${RED}Warning: Could not enable Docker support. You may need admin privileges.${NC}"
        }
    fi

    cf push -f manifest.yml
}

# Deploy using buildpack
deploy_buildpack() {
    echo -e "\n${YELLOW}Deploying with Node.js buildpack...${NC}"

    # Check if we're in the openclaw directory or need to clone
    if [ ! -f "package.json" ]; then
        echo -e "${YELLOW}Cloning OpenClaw repository...${NC}"
        git clone https://github.com/openclaw/openclaw.git openclaw-src
        cd openclaw-src
        cp ../manifest-buildpack.yml manifest.yml
        cp ../.cfignore .
    fi

    cf push -f manifest-buildpack.yml
}

# Set environment variables
set_env_vars() {
    local app_name="${1:-openclaw}"

    echo -e "\n${YELLOW}Setting environment variables...${NC}"

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
    local app_name="${1:-openclaw}"

    echo -e "\n${GREEN}Deployment complete!${NC}"
    echo "===================="
    cf app "$app_name"

    echo -e "\n${YELLOW}Next steps:${NC}"
    echo "1. Set your API keys if not already set:"
    echo "   cf set-env $app_name ANTHROPIC_API_KEY 'your-key'"
    echo "   cf restage $app_name"
    echo ""
    echo "2. View logs:"
    echo "   cf logs $app_name --recent"
    echo ""
    echo "3. Access your app at the route shown above"
}

# Main menu
main() {
    check_prerequisites

    echo -e "\n${YELLOW}Select deployment method:${NC}"
    echo "1) Docker (recommended)"
    echo "2) Node.js buildpack"
    echo "3) Set environment variables only"
    echo "4) Show app info"
    read -p "Enter choice [1-4]: " choice

    case $choice in
        1)
            deploy_docker
            set_env_vars
            show_info
            ;;
        2)
            deploy_buildpack
            set_env_vars
            show_info
            ;;
        3)
            set_env_vars
            ;;
        4)
            show_info
            ;;
        *)
            echo -e "${RED}Invalid choice${NC}"
            exit 1
            ;;
    esac
}

# Run main function
main "$@"
