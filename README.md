# OpenClaw Cloud Foundry Deployment

Deploy [OpenClaw](https://github.com/openclaw/openclaw) to Cloud Foundry with automatic Tanzu GenAI service integration and optional SSO authentication.

## Features

- **GenAI Service Integration**: Automatically configures OpenClaw to use CF marketplace LLM models (no cloud API keys needed)
- **SSO Authentication**: Optional oauth2-proxy sidecar using CF's p-identity SSO service
- **Gateway Auth**: Mandatory token-based authentication for the OpenClaw gateway
- **Node Deployment**: Deploy nodes for system.run capabilities with auto-pairing via container-to-container networking
- **Multi-Instance Scaling**: Scale nodes horizontally with `cf scale` using deterministic seed-based keypair derivation
- **Secrets Service**: Optional CredHub/user-provided service for centralized secret management
- **Multi-User Deployment**: Provision isolated gateway+node instances per user or team
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

### Setup (Seed-Based - Recommended)

The seed-based approach uses a single shared secret to derive Ed25519 keypairs deterministically on both gateway and node. No external key generation needed.

#### 1. Generate a shared seed and set on both apps

```bash
# Generate a random seed
SEED=$(openssl rand -hex 16)

# Set on gateway (pre-registers the node's derived public key)
cf set-env openclaw OPENCLAW_NODE_SEED "$SEED"
cf restage openclaw

# Set on node (derives the matching keypair for authentication)
cf set-env openclaw-node OPENCLAW_NODE_SEED "$SEED"
```

#### 2. Deploy the node

```bash
# Copy node deployment files to openclaw source directory
cp manifest-node.yml start-node.sh /path/to/openclaw/

# Deploy and configure
cd /path/to/openclaw
cf push -f manifest-node.yml --no-start
cf set-env openclaw-node OPENCLAW_GATEWAY_TOKEN "<gateway-token>"
cf set-env openclaw-node OPENCLAW_NODE_SEED "$SEED"

# Add network policy for container-to-container communication
cf add-network-policy openclaw-node openclaw --port 8081 --protocol tcp

# Start the node
cf start openclaw-node
```

#### 3. Verify connection

```bash
cf logs openclaw-node --recent
# Should show: "Setting up device identity from seed..." and "Gateway is reachable!"
```

### Setup (Legacy PEM Keys)

<details>
<summary>Alternative approach using explicit Ed25519 PEM keypairs</summary>

```bash
# 1. Generate a keypair
node -e "const c=require('crypto');const k=c.generateKeyPairSync('ed25519');console.log(k.publicKey.export({type:'spki',format:'pem'}));console.log(k.privateKey.export({type:'pkcs8',format:'pem'}))"

# 2. Set public key on gateway
cf set-env openclaw OPENCLAW_NODE_DEVICE_PUBLIC_KEY "-----BEGIN PUBLIC KEY-----..."
cf restage openclaw

# 3. Set both keys on node
cf set-env openclaw-node OPENCLAW_NODE_DEVICE_PUBLIC_KEY "-----BEGIN PUBLIC KEY-----..."
cf set-env openclaw-node OPENCLAW_NODE_DEVICE_PRIVATE_KEY "-----BEGIN PRIVATE KEY-----..."

# 4. Deploy node, add network policy, start
cf push -f manifest-node.yml --no-start
cf set-env openclaw-node OPENCLAW_GATEWAY_TOKEN "<gateway-token>"
cf add-network-policy openclaw-node openclaw --port 8081 --protocol tcp
cf start openclaw-node
```

</details>

### Multi-Instance Node Scaling

Scale nodes horizontally using the seed-based approach. Each CF instance derives a unique keypair from `OPENCLAW_NODE_SEED + ":" + CF_INSTANCE_INDEX`.

```bash
# 1. Set the max instances on the gateway (pre-registers N keypairs)
cf set-env openclaw OPENCLAW_NODE_MAX_INSTANCES 5
cf restage openclaw

# 2. Scale the node app
cf scale openclaw-node -i 5

# Or use deploy.sh:
./deploy.sh
# Select: 9) Scale nodes
```

Each instance appears in the gateway with a unique name (`cf-node-0`, `cf-node-1`, etc.).

### Quick Deploy with deploy.sh

Use option 8 in the interactive menu:

```bash
./deploy.sh
# Select: 8) Deploy node (system.run capability)
```

This automates token retrieval and network policy setup.

## Secrets Service (Optional)

Store gateway token, node seed, and cookie secret in a CF user-provided service instead of plain env vars. Secrets are stored in CF's credential store and injected via `VCAP_SERVICES`.

```bash
# Create the secrets service (auto-generates token and seed)
./deploy.sh
# Select: 10) Setup secrets service (CredHub)

# Or manually:
cf create-user-provided-service openclaw-secrets -p '{"gateway_token":"...","node_seed":"...","cookie_secret":"..."}'
cf bind-service openclaw openclaw-secrets
cf bind-service openclaw-node openclaw-secrets
cf restage openclaw
```

The `.profile` script automatically extracts secrets from the `openclaw-secrets` service binding. These take precedence over env vars.

## Persistent Storage with NFS (Optional)

By default, OpenClaw state (chat history, device pairings, workspace data) is stored in the container's ephemeral filesystem and lost on restage or crash. Bind an NFS volume service to persist this data.

### Prerequisites

- NFS Volume Services broker installed on your CF foundation
- An NFS server share accessible from the CF cells

### Setup

```bash
# 1. Create an NFS service instance
cf create-service nfs Existing openclaw-storage -c '{"share":"nfs-server.example.com/exports/openclaw"}'

# 2. Bind with volume mount
cf bind-service openclaw openclaw-storage -c '{"uid":"vcap","gid":"vcap","mount":"/home/vcap/app/data/persistent"}'

# 3. Restage to mount the volume
cf restage openclaw

# Or use deploy.sh:
./deploy.sh
# Select: 11) Setup NFS persistent storage
```

The `.profile` script auto-detects the NFS mount from `VCAP_SERVICES` and sets `OPENCLAW_STATE_DIR` to point to it. No additional configuration needed.

### Without NFS

If NFS is not available on your foundation, state is ephemeral. This is fine for single-user setups where chat history isn't critical. Templates and configuration are regenerated from env vars on each startup.

## Multi-User Deployment

Provision isolated gateway+node instances per user or team using `deploy.sh`:

```bash
# Create an instance (auto-generates secrets, sets up networking)
./deploy.sh create-instance --name alice

# Or interactively:
./deploy.sh
# Select: 12) Create user instance

# List all instances
./deploy.sh list-instances

# Destroy an instance
./deploy.sh destroy-instance --name alice
```

Each instance gets:
- Gateway app: `openclaw-alice`
- Node app: `openclaw-node-alice`
- Auto-generated gateway token and node seed
- Internal networking and c2c policy

## Interactive Deployment

Use `deploy.sh` for guided setup:

```bash
./deploy.sh
```

**Single Instance:**
1. **Full setup** - Creates GenAI service, sets gateway token, deploys, optional SSO
2. **Deploy with buildpack** - Just deploys the app
3. **Deploy with Docker** - Alternative Docker deployment
4. **Create/bind GenAI service** - Setup marketplace LLM model
5. **Enable SSO** - Setup p-identity SSO
6. **Set gateway token** - Configure persistent auth token
7. **Set manual API keys** - Alternative to GenAI service (uses cloud APIs directly)
8. **Deploy node** - Deploy a node for system.run capabilities
9. **Scale nodes** - Scale node instances up or down
10. **Setup secrets service** - Store secrets in CredHub/user-provided service
11. **Setup NFS persistent storage** - Bind NFS volume for persistent state
12. **Show app info** - Display status, services, and env vars

**Multi-User:**
13. **Create user instance** - Provision isolated gateway+node per user
14. **Destroy user instance** - Tear down a user's instance
15. **List all instances** - Show all deployed OpenClaw apps

CLI subcommands are also supported:

```bash
./deploy.sh create-instance --name alice
./deploy.sh destroy-instance --name alice
./deploy.sh list-instances
```

## Configuration Reference

### Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `OPENCLAW_GATEWAY_TOKEN` | Recommended | Fixed auth token for gateway. Auto-generated if not set. |
| `OPENCLAW_NODE_SEED` | For node | Shared seed for deterministic keypair derivation (recommended) |
| `OPENCLAW_NODE_MAX_INSTANCES` | No | Number of node instance keypairs to pre-register (default: `1`) |
| `OPENCLAW_PINNED_VERSION` | No | Expected OpenClaw version; warns on mismatch to protect against format changes |
| `OPENCLAW_SSO_ENABLED` | No | Set to `true` to enable SSO proxy |
| `OPENCLAW_COOKIE_SECRET` | If SSO | Base64-encoded secret for SSO session cookies |
| `OPENCLAW_STATE_DIR` | No | Data directory (default: `/home/vcap/app/data`) |
| `ANTHROPIC_API_KEY` | No | Manual Anthropic API key (alternative to GenAI service) |
| `OPENAI_API_KEY` | No | Manual OpenAI API key (alternative to GenAI service) |
| `OPENCLAW_NODE_DEVICE_PUBLIC_KEY` | Legacy | Ed25519 public key (PEM) for node auto-pairing |
| `OPENCLAW_NODE_DEVICE_PRIVATE_KEY` | Legacy | Ed25519 private key (PEM) for node identity |
| `OPENCLAW_NODE_DEVICE_NAME` | No | Display name for the node (default: `cf-node`) |
| `OPENCLAW_GATEWAY_HOST` | For node | Gateway hostname (default: `openclaw.apps.internal`) |
| `OPENCLAW_GATEWAY_PORT` | For node | Gateway port (default: `8081`) |

### Services

| Service | Type | Purpose |
|---------|------|---------|
| `openclaw-genai` | `genai` | LLM model from CF marketplace |
| `openclaw-sso` | `p-identity` | SSO authentication |
| `openclaw-secrets` | `user-provided` | Centralized secrets (gateway_token, node_seed, cookie_secret) |
| `openclaw-storage` | `nfs` | Persistent volume for state data (optional) |

## Security Notes

- **Gateway auth is mandatory** in recent OpenClaw versions. The `.profile` script always configures token-based auth.
- **CVE-2026-25253** (CVSS 8.8): Auth token exfiltration leading to RCE. Patched in OpenClaw v2026.1.29. Use a patched version.
- When using SSO, the oauth2-proxy handles authentication before requests reach OpenClaw. The gateway token still applies for direct API/WebSocket connections.
- API keys and tokens set via `cf set-env` are stored in CF's encrypted credential store.

## Requirements

- Cloud Foundry with Node.js buildpack (Node 22+ support)
- GenAI service broker (for LLM integration)
- SSO tile / p-identity service (for SSO, optional)
- NFS Volume Services broker (for persistent storage, optional)
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
