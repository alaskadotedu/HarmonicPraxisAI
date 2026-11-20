const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

function createMiddlewareStack(baseDir, opts = {}) {
  const auditFile = path.join(baseDir, 'middleware_audit.jsonl');
  const maxReqs = opts.maxRequestsPerMinute || 360;
  const buckets = new Map();

  return async function runMiddleware(req, res, nextHandler) {
    const start = process.hrtime.bigint();
    const reqId = crypto.randomUUID();
    req.requestId = reqId;
    res.setHeader('X-Request-Id', reqId);
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('X-Frame-Options', 'DENY');
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type, X-API-Key');

    res.on('finish', () => {
      const ms = Number(process.hrtime.bigint() - start) / 1e6;
      const line = JSON.stringify({ ts: new Date().toISOString(), reqId, method: req.method, url: req.url, status: res.statusCode, ms: Number(ms.toFixed(3)) }) + '\n';
      try { fs.appendFileSync(auditFile, line, 'utf8'); } catch {}
    });

    if (req.method === 'OPTIONS') { res.writeHead(204); return res.end(); }
    const urlPath = req.url.split('?').at(0).toLowerCase();
    if (urlPath !== '/api/stream') {
      const ip = req.socket.remoteAddress || '127.0.0.1';
      const now = Date.now();
      let b = buckets.get(ip);
      if (!b || now > b.resetAt) { b = { count: 0, resetAt: now + 60000 }; buckets.set(ip, b); }
      b.count++;
      res.setHeader('X-RateLimit-Remaining', String(Math.max(0, maxReqs - b.count)));
      if (b.count > maxReqs) {
        const body = JSON.stringify({ Error: 'Rate limit exceeded' });
        res.writeHead(429, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) });
        return res.end(body);
      }
    }

    const keyFile = path.join(baseDir, 'harmonic_api_key.txt');
    const apiKey = process.env.HARMONIC_API_KEY || (fs.existsSync(keyFile) ? fs.readFileSync(keyFile, 'utf8').trim() : '');
    if (apiKey && req.method !== 'GET' && req.headers['x-api-key'] !== apiKey) {
      const body = JSON.stringify({ Error: 'Unauthorized: invalid or missing X-API-Key' });
      res.writeHead(401, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) });
      return res.end(body);
    }

    if (req.method === 'POST') {
      req.body = await new Promise((resolve, reject) => {
        let raw = '';
        req.on('data', c => { raw += c; if (raw.length > 65536) reject(new Error('Payload > 64KB')); });
        req.on('end', () => { try { resolve(raw ? JSON.parse(raw) : {}); } catch { reject(new Error('Invalid JSON')); } });
        req.on('error', reject);
      });
    }
    return nextHandler();
  };
}
module.exports = { createMiddlewareStack };