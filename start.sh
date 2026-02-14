#!/bin/bash
# OpenClaw Cloud Foundry Startup Script
# Handles S3-backed persistent storage when ~/s3.env is present,
# otherwise runs OpenClaw directly.
set -e

OPENCLAW_PORT="${PORT:-8080}"

if [ -f ~/s3.env ]; then
    source ~/s3.env
    echo "=== S3 Persistent Storage Enabled ==="
    node s3-sync.cjs restore

    node dist/index.js gateway --allow-unconfigured --port "$OPENCLAW_PORT" --bind lan &
    OPENCLAW_PID=$!

    node s3-sync.cjs backup-loop &
    BACKUP_PID=$!

    cleanup() {
        echo "Shutting down — flushing state to S3..."
        node s3-sync.cjs flush
        kill "$OPENCLAW_PID" "$BACKUP_PID" 2>/dev/null || true
    }
    trap cleanup SIGTERM SIGINT

    wait "$OPENCLAW_PID"
else
    echo "=== Direct Mode ==="
    exec node dist/index.js gateway --allow-unconfigured --port "$OPENCLAW_PORT" --bind lan
fi
