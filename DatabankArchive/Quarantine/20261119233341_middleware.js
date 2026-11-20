const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

function compose(middlewares) {
  return function run(req, res, finalHandler) {
    let index = -1;
    function dispatch(i) {
      if (i <= index) return Promise.reject(new Error('next() called multiple times'));
      index = i;
      const fn = i === middlewares.length ? finalHandler : middlewares[i];
      if (!fn) return Promise.resolve();
      try {
        return Promise.resolve(fn(req, res, () => dispatch(i + 1)));
      } catch (err) {
        return Promise.reject(err);
      }
    }
    return dispatch(0);
  };
}

function createMiddlewareStack(baseDir, opts = {}) {
  const auditFile = path.join(baseDir, 'middleware_audit.jsonl');
  const maxReqs = opts.maxRequestsPerMinute || 180;
  const apiKey = process.env.HARMONIC_API_KEY || opts.apiKey || '';
  const buckets = new Map();

  const securityHeaders = (req, res, next) => {
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('X-Frame-Options', 'DENY');
    res.setHeader('Referrer-Policy', 'no-referrer');
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type, X-API-Key');
    if (req.method === 'OPTIONS') {
      res.writeHead(204);
      res.end();
      return;
    }
    return next();
  };

  const auditLogger = (req, res, next) => {
    const start = process.hrtime.bigint();
    const reqId = crypto.randomUUID();
    req.requestId = reqId;
    res.setHeader('X-Request-Id', reqId);

    res.on('finish', () => {
      const ms = Number(process.hrtime.bigint() - start) / 1e6;
      const entry = JSON.stringify({
        ts: new Date().toISOString(),
        reqId,
        method: req.method,
        url: req.url,
        status: res.statusCode,
        durationMs: Number(ms.toFixed(3)),
        ip: req.socket.remoteAddress || '127.0.0.1'
      }) + '\n';
      fs.appendFile(auditFile, entry, () => {});
    });
    return next();
  };

  const rateLimiter = (req, res, next) => {
    const urlPath = req.url.split('?')[0].toLowerCase();
    if (urlPath === '/api/stream') return next();
    const ip = req.socket.remoteAddress || '127.0.0.1';
    const now = Date.now();
    let rec = buckets.get(ip);
    if (!rec || now > rec.resetAt) {
      rec = { count: 0, resetAt: now + 60000 };
      buckets.set(ip, rec);
    }
    rec.count++;
    const remaining = Math.max(0, maxReqs - rec.count);
    res.setHeader('X-RateLimit-Limit', String(maxReqs));
    res.setHeader('X-RateLimit-Remaining', String(remaining));
    if (rec.count > maxReqs) {
      const body = JSON.stringify({ Error: 'Rate limit exceeded', RetryAfterSec: Math.ceil((rec.resetAt - now) / 1000) });
      res.writeHead(429, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) });
      res.end(body);
      return;
    }
    return next();
  };

  const authGuard = (req, res, next) => {
    if (!apiKey || req.method === 'GET') return next();
    const provided = req.headers['x-api-key'];
    if (provided !== apiKey) {
      const body = JSON.stringify({ Error: 'Unauthorized: invalid or missing X-API-Key' });
      res.writeHead(401, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) });
      res.end(body);
      return;
    }
    return next();
  };

  const jsonBodyParser = (req, res, next) => {
    if (req.method !== 'POST') return next();
    return new Promise((resolve, reject) => {
      let raw = '';
      let size = 0;
      req.on('data', chunk => {
        size += chunk.length;
        if (size > 65536) {
          reject(Object.assign(new Error('Payload exceeds 64KB limit'), { statusCode: 413 }));
          req.destroy();
          return;
        }
        raw += chunk;
      });
      req.on('end', () => {
        try {
          req.body = raw ? JSON.parse(raw) : {};
          resolve(next());
        } catch {
          reject(Object.assign(new Error('Malformed JSON body'), { statusCode: 400 }));
        }
      });
      req.on('error', reject);
    });
  };

  return compose([securityHeaders, auditLogger, rateLimiter, authGuard, jsonBodyParser]);
}

module.exports = { createMiddlewareStack };