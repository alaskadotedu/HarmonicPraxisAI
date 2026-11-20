const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const os = require('node:os');
const { createMiddlewareStack } = require('./middleware.js');

const PORT = 8100;
const BASE_DIR = __dirname;
const PHI = (1 + Math.sqrt(5)) / 2;
const runMiddleware = createMiddlewareStack(BASE_DIR);

function readJsonSafe(f, fb = null) { const p = path.join(BASE_DIR, f); return fs.existsSync(p) ? JSON.parse(fs.readFileSync(p, 'utf8')) : fb; }
function recursiveDot(a, offA, b, offB, idx, len, acc = 0) { return idx >= len ? acc : recursiveDot(a, offA, b, offB, idx + 1, len, acc + (a[offA + idx] * b[offB + idx])); }
function sendJson(res, code, data) { const body = JSON.stringify(data); res.writeHead(code, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) }); res.end(body); }

const server = http.createServer((req, res) => {
  runMiddleware(req, res, () => {
    const url = new URL(req.url, `http://localhost:${PORT}`);
    const route = url.pathname.toLowerCase();

    if (req.method === 'GET' && route === '/') {
      const hp = path.join(BASE_DIR, 'index.html');
      if (fs.existsSync(hp)) { const b = fs.readFileSync(hp); res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Content-Length': b.length }); return res.end(b); }
      return sendJson(res, 200, { Status: 'ONLINE' });
    }
    if (req.method === 'GET' && route === '/api/health') {
      return sendJson(res, 200, { Status: 'ONLINE', Runtime: `Node.js ${process.version}`, Port: PORT, AuthEnabled: true });
    }
    if (req.method === 'GET' && route === '/api/audit-logs') {
      const ap = path.join(BASE_DIR, 'middleware_audit.jsonl');
      const lines = fs.existsSync(ap) ? fs.readFileSync(ap, 'utf8').trim().split(/\r?\n/).slice(-25).map(l => JSON.parse(l)) : [];
      return sendJson(res, 200, { Count: lines.length, Logs: lines });
    }
    if (req.method === 'POST' && route === '/api/remediate') {
      const inData = req.body || {};
      const model = readJsonSafe('harmonic_recursive_remediation_v5_1.json');
      if (!model) return sendJson(res, 404, { Error: 'Model artifact missing' });
      const psi = Number(inData.psi ?? 0.5), gain = Number(inData.gain ?? 0.5), purity = Number(inData.purity ?? 0.8), raw = Number(inData.rawScore ?? 0.7), s0 = Number(inData.s0 ?? 1), s1 = Number(inData.s1 ?? -1);
      const cP = Math.cos(psi), sP = Math.sin(psi), c2P = Math.cos(2 * psi), k = (1 + 2.5 * gain) * (1.2 - 0.5 * purity);
      const bendIn = (k * cP * (s0 * s0 + s1 * s1)) + (1.5 * k * psi * psi);
      const xRaw = [1, psi, gain, purity, raw, s0, s1, cP * s0, sP * s1, c2P, bendIn, gain * purity];
      const xNorm = xRaw.map((v, j) => j === 0 ? 1 : (v - model.XMean[j]) / model.XStd[j]);
      const P = 12;
      const g = recursiveDot(xNorm, 0, model.WeightsFlat, 0, 0, P), f = recursiveDot(xNorm, 0, model.WeightsFlat, P, 0, P);
      let w = recursiveDot(xNorm, 0, model.WeightsFlat, 2 * P, 0, P), b = recursiveDot(xNorm, 0, model.WeightsFlat, 3 * P, 0, P);
      const breach = Math.abs(b) > 40 || purity < 0.55;
      if (breach) { b = Math.sign(b) * Math.min(Math.abs(b), 40); w = Math.max(0.68, w + 0.1); }
      return sendJson(res, 200, { CouplingGain: Number(g.toFixed(6)), FrequencyThz: Number(f.toFixed(6)), WatermarkWt: Number(w.toFixed(6)), RegulatedBend: Number(b.toFixed(6)), BreachDetected: breach, Status: 'REGULATED_COMPLIANT' });
    }
    if (req.method === 'POST' && route === '/api/stop') {
      sendJson(res, 200, { Status: 'STOPPING' });
      setTimeout(() => process.exit(0), 100);
      return;
    }
    sendJson(res, 404, { Error: 'Route not found' });
  }).catch(err => sendJson(res, 400, { Error: err.message }));
});
server.listen(PORT, '127.0.0.1');