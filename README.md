# OpenClaw Cloud Foundry Deployment

Deploy [OpenClaw](https://github.com/openclaw/openclaw) to Cloud Foundry with automatic Tanzu GenAI service integration.

## Files

| File | Description |
|------|-------------|
| `manifest.yml` | CF manifest for Docker-based deployment |
| `manifest-buildpack.yml` | CF manifest for Node.js buildpack deployment |
| `.cfignore` | Files to exclude from `cf push` |
| `.profile` | Startup script that auto-configures Tanzu GenAI service |
| `deploy.sh` | Interactive deployment helper script |

## Quick Start

1. **Clone OpenClaw and add these files:**
   ```bash
   git clone https://github.com/openclaw/openclaw.git
   cd openclaw

   # Copy deployment files
   curl -sL https://raw.githubusercontent.com/nkuhn-vmw/cf-openclaw/main/manifest-buildpack.yml -o manifest-buildpack.yml
   curl -sL https://raw.githubusercontent.com/nkuhn-vmw/cf-openclaw/main/.cfignore -o .cfignore
   curl -sL https://raw.githubusercontent.com/nkuhn-vmw/cf-openclaw/main/.profile -o .profile
   ```

2. **Build the application:**
   ```bash
   pnpm install
   pnpm build
   pnpm ui:build
   ```

3. **Create and bind a GenAI service:**
   ```bash
   cf create-service genai tanzu-Qwen3-Coder-30B-A3B-vllm-v1 openclaw-genai
   ```

4. **Update the manifest** with your CF domain:
   ```bash
   # Edit manifest-buildpack.yml and change the route
   sed -i '' 's/apps.tas-tdc.kuhn-labs.com/YOUR_APPS_DOMAIN/' manifest-buildpack.yml
   ```

5. **Deploy:**
   ```bash
   cf push -f manifest-buildpack.yml
   cf bind-service openclaw openclaw-genai
   cf restage openclaw
   ```

## GenAI Service Integration

The `.profile` script automatically:
- Reads GenAI service credentials from `VCAP_SERVICES`
- Creates OpenClaw config at `~/.openclaw/openclaw.json`
- Registers a custom `tanzu-genai` provider with the service endpoint
- Sets the bound model as the primary AI model

### Supported GenAI Plans

Any OpenAI-compatible GenAI service plan works:
- `tanzu-Qwen3-Coder-30B-A3B-vllm-v1`
- `anthropic-claude-sonnet4`
- `openai-gpt-4o`
- `google-gemini-2.5`

### Switch Models

```bash
cf unbind-service openclaw openclaw-genai
cf delete-service openclaw-genai -f
cf create-service genai anthropic-claude-sonnet4 openclaw-genai
cf bind-service openclaw openclaw-genai
cf restage openclaw
```

## Requirements

- Cloud Foundry with Node.js buildpack (Node 22+ support)
- GenAI service broker (optional, for LLM integration)
- 2GB+ memory allocation

## Manual API Key Configuration

If not using GenAI service, set API keys manually:
```bash
cf set-env openclaw ANTHROPIC_API_KEY "your-key"
# or
cf set-env openclaw OPENAI_API_KEY "your-key"
cf set-env openclaw OPENCLAW_GATEWAY_TOKEN "your-gateway-token"
cf restage openclaw
```
