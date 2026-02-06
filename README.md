# OpenClaw Cloud Foundry Deployment

Deploy [OpenClaw](https://github.com/openclaw/openclaw) to Cloud Foundry with automatic Tanzu GenAI service integration and optional SSO authentication.

## Features

- **GenAI Service Integration**: Automatically configures OpenClaw to use CF marketplace LLM models (no cloud API keys needed)
- **SSO Authentication**: Optional oauth2-proxy sidecar using CF's p-identity SSO service
- **Gateway Auth**: Mandatory token-based authentication for the OpenClaw gateway
- **Node Deployment**: Deploy nodes for system.run capabilities with auto-pairing via container-to-container networking
- **Dual Format Support**: Works with both deprecated single-model and new multi-model GenAI credential formats

## Files

| File | Description |
|------|-------------|
| `manifest-buildpack.yml` | CF manifest for Node.js buildpack deployment (recommended) |
| `manifest-node.yml` | CF manifest for deploying an OpenClaw node |
| `manifest.yml` | CF manifest for Docker-based deployment (reference) |
| `.cfignore` | Files to exclude from `cf push` |
| `.profile` | Startup script that auto-configures GenAI, gateway auth, SSO, and node pairing |
| `start.sh` | Process wrapper handling SSO proxy or direct startup |
| `start-node.sh` | Startup script for node deployment |
| `deploy.sh` | Interactive deployment helper script |

## Quick Start

### 1. Clone OpenClaw and add deployment files

```bash
git clone https://github.com/openclaw/openclaw.git
cd openclaw

# Copy deployment files
curl -sL https://raw.githubusercontent.com/nkuhn-vmw/cf-openclaw/main/manifest-buildpack.yml -o manifest-buildpack.yml
curl -sL https://raw.githubusercontent.com/nkuhn-vmw/cf-openclaw/main/.cfignore -o .cfignore
curl -sL https://raw.githubusercontent.com/nkuhn-vmw/cf-openclaw/main/.profile -o .profile
curl -sL https://raw.githubusercontent.com/nkuhn-vmw/cf-openclaw/main/start.sh -o start.sh
chmod +x start.sh
```

### 2. Build the application

```bash
pnpm install
pnpm build
pnpm ui:build
```

### 3. Create a GenAI service

```bash
# List available plans
cf marketplace -e genai

# Create service with your preferred model
cf create-service genai tanzu-Qwen3-Coder-30B-A3B-vllm-v1 openclaw-genai
```

### 4. Update the manifest with your CF domain

```bash
sed -i '' 's/apps.tas-tdc.kuhn-labs.com/YOUR_APPS_DOMAIN/' manifest-buildpack.yml
```

### 5. Deploy

```bash
cf push -f manifest-buildpack.yml
```

### 6. Set a gateway token (recommended)

```bash
# Set a fixed token so it persists across restarts
cf set-env openclaw OPENCLAW_GATEWAY_TOKEN "your-secret-token"
cf restage openclaw
```

If you skip this step, a random token is auto-generated on each startup. Check `cf logs openclaw --recent` to find it.

## GenAI Service Integration

The `.profile` script automatically configures OpenClaw to use your bound GenAI service. It supports both credential formats from the GenAI service broker.

### How It Works

1. On app startup, `.profile` parses `VCAP_SERVICES` for GenAI credentials
2. For the new multi-model format (v10.2+), it discovers available models via the `/openai/v1/models` endpoint
3. Creates an OpenClaw config at `~/.openclaw/openclaw.json` with a `tanzu-genai` provider
4. Sets the discovered model as the primary AI model

### Supported GenAI Plans

Any OpenAI-compatible GenAI service plan works. Common examples:
- `tanzu-Qwen3-Coder-30B-A3B-vllm-v1` (on-premise vLLM)
- `anthropic-claude-sonnet4` (Anthropic via proxy)
- `openai-gpt-4o` (OpenAI via proxy)
- `google-gemini-2.5` (Google via proxy)
- Multi-model plans (e.g., `all-models`)

### Switch Models

```bash
cf unbind-service openclaw openclaw-genai
cf delete-service openclaw-genai -f
cf create-service genai <new-plan> openclaw-genai
cf bind-service openclaw openclaw-genai
cf restage openclaw
```

## SSO Authentication (Optional)

Protect your OpenClaw instance with Cloud Foundry's SSO service using oauth2-proxy as a reverse proxy.

### Architecture

```
Without SSO:  Client → CF Router → OpenClaw (:$PORT)
With SSO:     Client → CF Router → oauth2-proxy (:$PORT) → OpenClaw (:8081)
                                        ↕
                                  CF UAA / p-identity
```

### Setup

```bash
# 1. Create SSO service
cf create-service p-identity <plan-name> openclaw-sso

# 2. Bind to app
cf bind-service openclaw openclaw-sso

# 3. Enable SSO and set cookie secret
cf set-env openclaw OPENCLAW_SSO_ENABLED true
cf set-env openclaw OPENCLAW_COOKIE_SECRET "$(openssl rand -base64 32)"

# 4. Add openclaw-sso to services in manifest-buildpack.yml (uncomment the line)

# 5. Restage
cf restage openclaw
```

Users will be redirected to your organization's SSO login page before accessing OpenClaw.

### Disable SSO

```bash
cf set-env openclaw OPENCLAW_SSO_ENABLED false
cf restage openclaw
```

## Node Deployment (Optional)

Deploy an OpenClaw node to provide `system.run` and `system.which` capabilities to the gateway. This allows agents to execute shell commands in a controlled CF environment.

### Architecture

```
Gateway (openclaw) ←── internal networking ──→ Node (openclaw-node)
     :8081                                         connects outbound
```

The node connects to the gateway via CF container-to-container networking using an internal route.

### Setup

#### 1. Generate a device keypair

```bash
node -e "const c=require('crypto');const k=c.generateKeyPairSync('ed25519');console.log(k.publicKey.export({type:'spki',format:'pem'}));console.log(k.privateKey.export({type:'pkcs8',format:'pem'}))"
```

Save both keys - they're needed for auto-pairing.

#### 2. Configure the gateway with the node's public key

```bash
cf set-env openclaw OPENCLAW_NODE_DEVICE_PUBLIC_KEY "-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEA...
-----END PUBLIC KEY-----"
cf restage openclaw
```

#### 3. Deploy the node

```bash
# Copy node deployment files to openclaw source directory
cp manifest-node.yml start-node.sh /path/to/openclaw/

# Get the gateway token
cf logs openclaw --recent | grep "Token:"

# Deploy and configure
cd /path/to/openclaw
cf push -f manifest-node.yml --no-start
cf set-env openclaw-node OPENCLAW_GATEWAY_TOKEN "<gateway-token>"
cf set-env openclaw-node OPENCLAW_NODE_DEVICE_PUBLIC_KEY "-----BEGIN PUBLIC KEY-----..."
cf set-env openclaw-node OPENCLAW_NODE_DEVICE_PRIVATE_KEY "-----BEGIN PRIVATE KEY-----..."

# Add network policy for container-to-container communication
cf add-network-policy openclaw-node openclaw --port 8081 --protocol tcp

# Start the node
cf start openclaw-node
```

#### 4. Verify connection

```bash
cf logs openclaw-node --recent
# Should show: "Gateway is reachable!" and stable connection
```

### Quick Deploy with deploy.sh

Use option 8 in the interactive menu:

```bash
./deploy.sh
# Select: 8) Deploy node (system.run capability)
```

This automates token retrieval and network policy setup.

## Interactive Deployment

Use `deploy.sh` for guided setup:

```bash
./deploy.sh
```

Options:
1. **Full setup** - Creates GenAI service, sets gateway token, deploys, optional SSO
2. **Deploy with buildpack** - Just deploys the app
3. **Deploy with Docker** - Alternative Docker deployment
4. **Create/bind GenAI service** - Setup marketplace LLM model
5. **Enable SSO** - Setup p-identity SSO
6. **Set gateway token** - Configure persistent auth token
7. **Set manual API keys** - Alternative to GenAI service (uses cloud APIs directly)
8. **Deploy node** - Deploy a node for system.run capabilities
9. **Show app info** - Display status, services, and env vars

## Configuration Reference

### Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `OPENCLAW_GATEWAY_TOKEN` | Recommended | Fixed auth token for gateway. Auto-generated if not set. |
| `OPENCLAW_SSO_ENABLED` | No | Set to `true` to enable SSO proxy |
| `OPENCLAW_COOKIE_SECRET` | If SSO | Base64-encoded secret for SSO session cookies |
| `OPENCLAW_STATE_DIR` | No | Data directory (default: `/home/vcap/app/data`) |
| `ANTHROPIC_API_KEY` | No | Manual Anthropic API key (alternative to GenAI service) |
| `OPENAI_API_KEY` | No | Manual OpenAI API key (alternative to GenAI service) |
| `OPENCLAW_NODE_DEVICE_PUBLIC_KEY` | For node | Ed25519 public key (PEM) for node auto-pairing |
| `OPENCLAW_NODE_DEVICE_PRIVATE_KEY` | For node | Ed25519 private key (PEM) for node identity |
| `OPENCLAW_NODE_DEVICE_NAME` | No | Display name for the node (default: `cf-node`) |
| `OPENCLAW_GATEWAY_HOST` | For node | Gateway hostname (default: `openclaw.apps.internal`) |
| `OPENCLAW_GATEWAY_PORT` | For node | Gateway port (default: `8081`) |

### Services

| Service | Type | Purpose |
|---------|------|---------|
| `openclaw-genai` | `genai` | LLM model from CF marketplace |
| `openclaw-sso` | `p-identity` | SSO authentication |

## Security Notes

- **Gateway auth is mandatory** in recent OpenClaw versions. The `.profile` script always configures token-based auth.
- **CVE-2026-25253** (CVSS 8.8): Auth token exfiltration leading to RCE. Patched in OpenClaw v2026.1.29. Use a patched version.
- When using SSO, the oauth2-proxy handles authentication before requests reach OpenClaw. The gateway token still applies for direct API/WebSocket connections.
- API keys and tokens set via `cf set-env` are stored in CF's encrypted credential store.

## Requirements

- Cloud Foundry with Node.js buildpack (Node 22+ support)
- GenAI service broker (for LLM integration)
- SSO tile / p-identity service (for SSO, optional)
- 2GB+ memory allocation
- 4GB+ disk quota (for buildpack deployment)

## Troubleshooting

### App crashes on startup
Check logs: `cf logs openclaw --recent`
- If "GenAI service credentials incomplete" → verify the service is bound: `cf services`
- If "Model discovery failed" → the GenAI proxy may not be reachable during startup; try restaging

### Can't find gateway token
```bash
cf logs openclaw --recent | grep "Token:"
```

### SSO redirect loop
- Verify the cookie secret is set: `cf env openclaw | grep COOKIE_SECRET`
- Check that the p-identity service plan's redirect URIs allow your app URL
- View oauth2-proxy logs: `cf logs openclaw --recent | grep oauth2`

### GenAI model not working
```bash
# Check what model was configured
cf ssh openclaw -c "cat ~/.openclaw/openclaw.json"

# Test the GenAI endpoint directly
cf ssh openclaw -c 'curl -sf -H "Authorization: Bearer $API_KEY" "$API_BASE/openai/v1/models"'
```
