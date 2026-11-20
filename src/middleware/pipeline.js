const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

function createPipeline(rootDir, repo) {
  const buckets = new Map();
  return async function handle(req, res, next) {
    const start = process.hrtime.bigint();
    const reqId = crypto.randomUUID();
    res.setHeader('X-Request-Id', reqId);
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('X-Frame-Options', 'DENY');
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type, X-API-Key');

    res.on('finish', () => {
      const ms = Number((Number(process.hrtime.bigint() - start) / 1e6).toFixed(3));
      repo.recordAudit({ ts: new Date().toISOString(), reqId, method: req.method, route: req.url.split('?').at(0), status: res.statusCode, latencyMs: ms });
    });

    if (req.method === 'OPTIONS') { res.writeHead(204); return res.end(); }

    const ip = req.socket.remoteAddress || '127.0.0.1';
    const now = Date.now();
    let b = buckets.get(ip);
    if (!b || now > b.reset) { b = { count: 0, reset: now + 60000 }; buckets.set(ip, b); }
    if (++b.count > 600) {
      const msg = JSON.stringify({ error: 'Rate limit exceeded' });
      res.writeHead(429, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(msg) });
      return res.end(msg);
    }

    const keyFile = path.join(rootDir, 'harmonic_api_key.txt');
    const apiKey = process.env.HARMONIC_API_KEY || (fs.existsSync(keyFile) ? fs.readFileSync(keyFile, 'utf8').trim() : '');
    if (apiKey && req.method === 'POST' && req.headers['x-api-key'] !== apiKey) {
      const msg = JSON.stringify({ error: 'Unauthorized: invalid X-API-Key' });
      res.writeHead(401, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(msg) });
      return res.end(msg);
    }

    if (req.method === 'POST') {
      req.body = await new Promise((resolve, reject) => {
        let raw = '';
        req.on('data', c => { raw += c; if (raw.length > 65536) reject(new Error('Payload > 64KB')); });
        req.on('end', () => { try { resolve(raw ? JSON.parse(raw) : {}); } catch { reject(new Error('Invalid JSON')); } });
      });
    }
    return next();
  };
}
module.exports = { createPipeline };