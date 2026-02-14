#!/usr/bin/env node
// S3 Sync Utility for OpenClaw on Cloud Foundry
// Persists state to S3-compatible object storage (AWS S3, SeaweedFS, MinIO, Ceph).
// Zero external dependencies — uses Node.js built-in crypto and https/http.
//
// Usage:
//   node s3-sync.js restore       — Download persisted files from S3 before startup
//   node s3-sync.js backup-loop   — Periodically upload changed files (every 60s)
//   node s3-sync.js flush         — One-time upload of all changed files (shutdown)
//
// Required env vars: S3_ACCESS_KEY_ID, S3_SECRET_ACCESS_KEY, S3_BUCKET
// Optional env vars: S3_ENDPOINT, S3_REGION, S3_PREFIX

'use strict';

const crypto = require('crypto');
const https = require('https');
const http = require('http');
const fs = require('fs');
const path = require('path');
const { URL } = require('url');

// ============================================================
// Configuration
// ============================================================

const ACCESS_KEY = process.env.S3_ACCESS_KEY_ID;
const SECRET_KEY = process.env.S3_SECRET_ACCESS_KEY;
const BUCKET = process.env.S3_BUCKET;
const REGION = process.env.S3_REGION || 'us-east-1';
const PREFIX = process.env.S3_PREFIX || 'openclaw';
const STATE_DIR = process.env.OPENCLAW_STATE_DIR || '/home/vcap/app/data';
const BACKUP_INTERVAL_MS = 60_000;

if (!ACCESS_KEY || !SECRET_KEY || !BUCKET) {
    console.error('s3-sync: Missing required env vars (S3_ACCESS_KEY_ID, S3_SECRET_ACCESS_KEY, S3_BUCKET)');
    process.exit(1);
}

// Parse S3 endpoint — support path-style and virtual-hosted-style
let s3Host, s3Port, s3Protocol, usePathStyle;
if (process.env.S3_ENDPOINT) {
    const url = new URL(process.env.S3_ENDPOINT);
    s3Host = url.hostname;
    s3Port = url.port ? parseInt(url.port, 10) : (url.protocol === 'https:' ? 443 : 80);
    s3Protocol = url.protocol === 'https:' ? 'https' : 'http';
    // Non-AWS endpoints (SeaweedFS, MinIO, Ceph) typically use path-style
    usePathStyle = true;
} else {
    // Default: AWS S3 virtual-hosted-style
    s3Host = `${BUCKET}.s3.${REGION}.amazonaws.com`;
    s3Port = 443;
    s3Protocol = 'https';
    usePathStyle = false;
}

// Files/directories to sync (relative to STATE_DIR)
const SYNC_PATTERNS = [
    'identity/device.json',
    'identity/device-auth.json',
    'credentials/',
    'devices/paired.json',
    'agents/',
];

// Directories within agents/ to skip (regenerated at startup)
const SKIP_PATTERNS = [
    '/qmd/xdg-config/',
];

// In-memory hash cache for change detection
const hashCache = new Map();

// ============================================================
// AWS Signature V4
// ============================================================

function hmacSha256(key, data) {
    return crypto.createHmac('sha256', key).update(data).digest();
}

function sha256Hex(data) {
    return crypto.createHash('sha256').update(data).digest('hex');
}

function signV4(method, urlPath, query, headers, payloadHash, date) {
    const dateStamp = date.toISOString().replace(/[-:]/g, '').slice(0, 8);
    const amzDate = dateStamp + 'T' + date.toISOString().replace(/[-:]/g, '').slice(9, 15) + 'Z';

    headers['x-amz-date'] = amzDate;
    headers['x-amz-content-sha256'] = payloadHash;

    // Canonical request
    const sortedHeaders = Object.keys(headers).sort();
    const signedHeaders = sortedHeaders.join(';');
    const canonicalHeaders = sortedHeaders.map(k => k + ':' + headers[k].trim()).join('\n') + '\n';
    const canonicalQuery = query || '';

    const canonicalRequest = [
        method, urlPath, canonicalQuery, canonicalHeaders, signedHeaders, payloadHash
    ].join('\n');

    // String to sign
    const scope = `${dateStamp}/${REGION}/s3/aws4_request`;
    const stringToSign = `AWS4-HMAC-SHA256\n${amzDate}\n${scope}\n${sha256Hex(canonicalRequest)}`;

    // Signing key
    let signingKey = hmacSha256('AWS4' + SECRET_KEY, dateStamp);
    signingKey = hmacSha256(signingKey, REGION);
    signingKey = hmacSha256(signingKey, 's3');
    signingKey = hmacSha256(signingKey, 'aws4_request');

    const signature = hmacSha256(signingKey, stringToSign).toString('hex');

    headers['authorization'] = `AWS4-HMAC-SHA256 Credential=${ACCESS_KEY}/${scope}, SignedHeaders=${signedHeaders}, Signature=${signature}`;

    return headers;
}

// ============================================================
// S3 Operations
// ============================================================

function s3Request(method, objectKey, { body, query } = {}) {
    return new Promise((resolve, reject) => {
        const urlPath = usePathStyle
            ? `/${BUCKET}/${objectKey}`
            : `/${objectKey}`;
        const host = usePathStyle ? s3Host : `${BUCKET}.${s3Host}`;

        const payloadHash = sha256Hex(body || '');
        const date = new Date();

        const headers = { host };
        if (body) headers['content-length'] = String(Buffer.byteLength(body));

        signV4(method, urlPath, query || '', headers, payloadHash, date);

        const fullPath = query ? `${urlPath}?${query}` : urlPath;
        const transport = s3Protocol === 'https' ? https : http;

        const req = transport.request({
            hostname: usePathStyle ? s3Host : host,
            port: s3Port,
            path: fullPath,
            method,
            headers,
            rejectUnauthorized: false, // allow self-signed certs (common in CF)
        }, (res) => {
            const chunks = [];
            res.on('data', c => chunks.push(c));
            res.on('end', () => {
                const responseBody = Buffer.concat(chunks).toString();
                if (res.statusCode >= 200 && res.statusCode < 300) {
                    resolve({ statusCode: res.statusCode, body: responseBody, headers: res.headers });
                } else {
                    reject(new Error(`S3 ${method} ${objectKey}: HTTP ${res.statusCode} — ${responseBody.slice(0, 200)}`));
                }
            });
        });

        req.on('error', reject);
        if (body) req.write(body);
        req.end();
    });
}

async function listObjects(prefix) {
    const query = `list-type=2&prefix=${encodeURIComponent(prefix)}`;
    const result = await s3Request('GET', '', { query });
    // Parse XML response for <Key> elements
    const keys = [];
    const keyRegex = /<Key>([^<]+)<\/Key>/g;
    let match;
    while ((match = keyRegex.exec(result.body)) !== null) {
        keys.push(match[1]);
    }
    // Handle truncation
    if (result.body.includes('<IsTruncated>true</IsTruncated>')) {
        const tokenMatch = result.body.match(/<NextContinuationToken>([^<]+)<\/NextContinuationToken>/);
        if (tokenMatch) {
            const moreQuery = `${query}&continuation-token=${encodeURIComponent(tokenMatch[1])}`;
            const moreResult = await s3Request('GET', '', { query: moreQuery });
            let m;
            while ((m = keyRegex.exec(moreResult.body)) !== null) {
                keys.push(m[1]);
            }
        }
    }
    return keys;
}

async function getObject(key) {
    const result = await s3Request('GET', key);
    return result.body;
}

async function putObject(key, data) {
    await s3Request('PUT', key, { body: data });
}

// ============================================================
// File Discovery
// ============================================================

function shouldSync(relativePath) {
    // Check skip patterns
    for (const skip of SKIP_PATTERNS) {
        if (relativePath.includes(skip)) return false;
    }
    // Skip logs directory
    if (relativePath.startsWith('logs/')) return false;
    // Skip openclaw.json (regenerated by .profile)
    if (relativePath === 'openclaw.json') return false;

    // Check against sync patterns
    for (const pattern of SYNC_PATTERNS) {
        if (pattern.endsWith('/')) {
            if (relativePath.startsWith(pattern)) return true;
        } else {
            if (relativePath === pattern) return true;
        }
    }
    return false;
}

function discoverLocalFiles() {
    const files = [];
    function walk(dir, relBase) {
        if (!fs.existsSync(dir)) return;
        for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
            const rel = relBase ? `${relBase}/${entry.name}` : entry.name;
            if (entry.isDirectory()) {
                walk(path.join(dir, entry.name), rel);
            } else if (entry.isFile() && shouldSync(rel)) {
                files.push(rel);
            }
        }
    }
    walk(STATE_DIR, '');
    return files;
}

function fileHash(filePath) {
    const data = fs.readFileSync(filePath);
    return sha256Hex(data);
}

// ============================================================
// Sync Modes
// ============================================================

async function restore() {
    console.log(`s3-sync: Restoring state from s3://${BUCKET}/${PREFIX}/`);
    try {
        const keys = await listObjects(`${PREFIX}/`);
        if (keys.length === 0) {
            console.log('s3-sync: No existing state found in S3 (first run)');
            return;
        }

        let restored = 0;
        for (const key of keys) {
            const relativePath = key.slice(`${PREFIX}/`.length);
            if (!relativePath || !shouldSync(relativePath)) continue;

            const localPath = path.join(STATE_DIR, relativePath);
            fs.mkdirSync(path.dirname(localPath), { recursive: true });

            const data = await getObject(key);
            fs.writeFileSync(localPath, data);
            hashCache.set(relativePath, sha256Hex(data));
            restored++;
        }
        console.log(`s3-sync: Restored ${restored} file(s)`);
    } catch (err) {
        console.error('s3-sync: Restore failed:', err.message);
        // Non-fatal — app can still start with empty state
    }
}

async function uploadChanged() {
    const files = discoverLocalFiles();
    let uploaded = 0;

    for (const rel of files) {
        const localPath = path.join(STATE_DIR, rel);
        try {
            const hash = fileHash(localPath);
            if (hashCache.get(rel) === hash) continue;

            const data = fs.readFileSync(localPath, 'utf8');
            const s3Key = `${PREFIX}/${rel}`;
            await putObject(s3Key, data);
            hashCache.set(rel, hash);
            uploaded++;
        } catch (err) {
            console.error(`s3-sync: Failed to upload ${rel}:`, err.message);
        }
    }

    return uploaded;
}

async function flush() {
    console.log('s3-sync: Flushing state to S3...');
    try {
        const uploaded = await uploadChanged();
        console.log(`s3-sync: Flushed ${uploaded} changed file(s)`);
    } catch (err) {
        console.error('s3-sync: Flush failed:', err.message);
    }
}

async function backupLoop() {
    console.log(`s3-sync: Starting backup loop (every ${BACKUP_INTERVAL_MS / 1000}s)`);
    const tick = async () => {
        try {
            const uploaded = await uploadChanged();
            if (uploaded > 0) {
                console.log(`s3-sync: Backed up ${uploaded} changed file(s)`);
            }
        } catch (err) {
            console.error('s3-sync: Backup cycle error:', err.message);
        }
    };
    setInterval(tick, BACKUP_INTERVAL_MS);
    // Keep process alive
    process.on('SIGTERM', () => process.exit(0));
    process.on('SIGINT', () => process.exit(0));
}

// ============================================================
// CLI Entry Point
// ============================================================

const mode = process.argv[2];
switch (mode) {
    case 'restore':
        restore().catch(err => { console.error('s3-sync:', err); process.exit(1); });
        break;
    case 'backup-loop':
        backupLoop().catch(err => { console.error('s3-sync:', err); process.exit(1); });
        break;
    case 'flush':
        flush().catch(err => { console.error('s3-sync:', err); process.exit(1); });
        break;
    default:
        console.error('Usage: node s3-sync.js <restore|backup-loop|flush>');
        process.exit(1);
}
