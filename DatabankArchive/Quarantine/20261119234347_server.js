const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const os = require('node:os');
const { createMiddlewareStack } = require('./middleware.js');

const PORT = Number(process.env.PORT || 8100);
const BASE_DIR = __dirname;
const PHI = (1 + Math.sqrt(5)) / 2;
const runMiddleware = createMiddlewareStack(BASE_DIR);

function readJsonSafe(f, fb = null) { const p = path.join(BASE_DIR, f); return fs.existsSync(p) ? JSON.parse(fs.readFileSync(p, 'utf8')) : fb; }
function parseCsvSafe(f) {
  const p = path.join(BASE_DIR, f);
  if (!fs.existsSync(p)) return [];
  const lines = fs.readFileSync(p, 'utf8').split(/\r?\n/).filter(Boolean);
  if (lines.length < 2) return [];
  const headers = lines[0].split(',').map(h => h.replace(/^"|"$/g, ''));
  return lines.slice(1).map(l => { const v = l.split(',').map(x => x.replace(/^"|"$/g, '')); const o = {}; headers.forEach((h, i) => { o[h] = v[i] ?? ''; }); return o; });
}
function recursiveDot(a, offA, b, offB, idx, len, acc = 0) { return idx >= len ? acc : recursiveDot(a, offA, b, offB, idx + 1, len, acc + (a[offA + idx] * b[offB + idx])); }
function sendJson(res, code, data) { const body = JSON.stringify(data); res.writeHead(code, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) }); res.end(body); }

function solveRemediation(input) {
  const model = readJsonSafe('harmonic_recursive_remediation_v5_1.json');
  const psi = Number(input.psi ?? 0.5), gain = Number(input.gain ?? 0.5), purity = Number(input.purity ?? 0.8);
  const raw = Number(input.rawScore ?? 0.7), s0 = Number(input.s0 ?? 1.0), s1 = Number(input.s1 ?? -1.0);
  const cP = Math.cos(psi), sP = Math.sin(psi), c2P = Math.cos(2 * psi);
  const k = (1 + 2.5 * gain) * (1.2 - 0.5 * purity);
  const bendIn = (k * cP * (s0 * s0 + s1 * s1)) + (1.5 * k * psi * psi);
  let g = gain, f = (299792458 / ((532 - 4 * gain) * 1e-9)) / 1e12, w = 0.72, b = bendIn;
  if (model && Array.isArray(model.WeightsFlat) && Array.isArray(model.XMean)) {
    const xRaw = [1, psi, gain, purity, raw, s0, s1, cP * s0, sP * s1, c2P, bendIn, gain * purity];
    const xNorm = xRaw.map((v, j) => j === 0 ? 1 : (v - model.XMean[j]) / model.XStd[j]);
    const P = 12;
    g = recursiveDot(xNorm, 0, model.WeightsFlat, 0, 0, P);
    f = recursiveDot(xNorm, 0, model.WeightsFlat, P, 0, P);
    w = recursiveDot(xNorm, 0, model.WeightsFlat, 2 * P, 0, P);
    b = recursiveDot(xNorm, 0, model.WeightsFlat, 3 * P, 0, P);
  }
  const breach = Math.abs(b) > 40 || purity < 0.55;
  if (breach) { b = Math.sign(b) * Math.min(Math.abs(b), 40); w = Math.max(0.68, w + 0.1); }
  return { CouplingGain: Number(g.toFixed(6)), FrequencyThz: Number(f.toFixed(6)), WatermarkWt: Number(w.toFixed(6)), RegulatedBend: Number(b.toFixed(6)), BreachDetected: breach, Status: 'REGULATED_COMPLIANT' };
}

function runCryptographicAudit() {
  const baseline = readJsonSafe('dew_integrity_baseline.json', {});
  const files = fs.readdirSync(BASE_DIR).filter(f => fs.statSync(path.join(BASE_DIR, f)).isFile() && !f.startsWith('dew_') && !f.startsWith('amalgamated_') && f !== 'middleware_audit.jsonl');
  return files.map((file, idx) => {
    const buf = fs.readFileSync(path.join(BASE_DIR, file));
    const sha256 = crypto.createHash('sha256').update(buf).digest('hex');
    const ref = baseline[file];
    const drift = !ref ? 0.65 : (ref.Sha256.toLowerCase() !== sha256.toLowerCase() ? 1.0 : 0.0);
    const phiW = Math.pow(PHI, -(idx % 6));
    const risk = Math.min(1, (0.08 * phiW) + (0.85 * drift));
    return { Seq: idx + 1, Artifact: file, SizeKB: Number((buf.length / 1024).toFixed(2)), Sha256Prefix: sha256.slice(0, 14).toUpperCase(), PhiWeight: Number(phiW.toFixed(4)), RiskScore: Number(risk.toFixed(4)), RemediationAction: drift >= 1.0 ? 'HASH_DRIFT_DETECTED' : (drift > 0 ? 'UNTRACKED_ARTIFACT' : 'VERIFIED_NOMINAL') };
  });
}

const server = http.createServer((req, res) => {
  runMiddleware(req, res, () => {
    const url = new URL(req.url, `http://localhost:${PORT}`);
    const route = url.pathname.toLowerCase();

    if (req.method === 'GET' && route === '/') {
      const hp = path.join(BASE_DIR, 'index.html');
      if (fs.existsSync(hp)) { const b = fs.readFileSync(hp); res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Content-Length': b.length }); return res.end(b); }
      return sendJson(res, 200, { Status: 'ONLINE', Port: PORT });
    }
    if (req.method === 'GET' && route === '/api/health') {
      const model = readJsonSafe('harmonic_recursive_remediation_v5_1.json');
      return sendJson(res, 200, { Status: 'ONLINE', Version: '5.4.0', Runtime: `Node.js ${process.version}`, Port: PORT, AuthEnabled: true, ModelLoaded: Boolean(model) });
    }
    if (req.method === 'GET' && route === '/api/dashboard') {
      const freeMemPct = Number(((os.freemem() / os.totalmem()) * 100).toFixed(2));
      const telemetry = parseCsvSafe('amalgamated_telemetry_index.csv');
      return sendJson(res, 200, { TimestampUtc: new Date().toISOString(), FreeMemPct: freeMemPct, ProcCount: os.cpus().length * 16, TotalDatumRows: telemetry.length, Matrix: runCryptographicAudit() });
    }
    if (req.method === 'GET' && route === '/api/telemetry') {
      const rows = parseCsvSafe('amalgamated_telemetry_index.csv');
      const limit = Number(url.searchParams.get('limit') || 15), offset = Number(url.searchParams.get('offset') || 0);
      return sendJson(res, 200, { TotalRows: rows.length, Offset: offset, Limit: limit, Records: rows.slice(offset, offset + limit) });
    }
    if (req.method === 'GET' && route === '/api/audit-logs') {
      const ap = path.join(BASE_DIR, 'middleware_audit.jsonl');
      const logs = fs.existsSync(ap) ? fs.readFileSync(ap, 'utf8').trim().split(/\r?\n/).filter(Boolean).slice(-25).map(l => JSON.parse(l)) : [];
      return sendJson(res, 200, { Count: logs.length, Logs: logs });
    }
    if (req.method === 'GET' && route === '/api/stream') {
      res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache', 'Connection': 'keep-alive' });
      let seq = 0;
      const timer = setInterval(() => {
        seq++;
        const psi = Number((((seq * 0.22) % (2 * Math.PI)) - Math.PI).toFixed(4));
        const gain = Number((0.40 + 0.55 * Math.abs(Math.sin(psi))).toFixed(4));
        const purity = Number((0.45 + 0.50 * Math.abs(Math.cos(psi * 0.5))).toFixed(4));
        const solved = solveRemediation({ psi, gain, purity, rawScore: 0.75, s0: 4.2 * Math.cos(psi), s1: -3.9 * Math.sin(psi) });
        const pkt = Object.assign({ Seq: seq, TimestampUtc: new Date().toISOString(), FreeMemPct: Number(((os.freemem() / os.totalmem()) * 100).toFixed(2)), Psi: psi }, solved);
        res.write(`id: ${seq}\nevent: telemetry\ndata: ${JSON.stringify(pkt)}\n\n`);
      }, 500);
      req.on('close', () => clearInterval(timer));
      return;
    }
    if (req.method === 'POST' && route === '/api/remediate') { return sendJson(res, 200, solveRemediation(req.body || {})); }
    if (req.method === 'POST' && route === '/api/stop') { sendJson(res, 200, { Status: 'STOPPING_NODE_BACKEND' }); setTimeout(() => process.exit(0), 120); return; }
    sendJson(res, 404, { Error: 'Route not found' });
  }).catch(err => sendJson(res, 400, { Error: err.message, RequestId: req.requestId }));
});

server.listen(PORT, '127.0.0.1');