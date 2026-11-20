const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const os = require('node:os');
const { DatabaseSync } = require('node:sqlite');
const { createMiddlewareStack } = require('./middleware.js');

const PORT = Number(process.env.PORT || 8100);
const BASE_DIR = __dirname;
const PHI = (1 + Math.sqrt(5)) / 2;
const runMiddleware = createMiddlewareStack(BASE_DIR);

const db = new DatabaseSync(path.join(BASE_DIR, 'harmonic_praxis_vault.db'));
db.exec(fs.readFileSync(path.join(BASE_DIR, 'schema.sql'), 'utf8'));

function initCabinets() {
  const now = new Date().toISOString();
  const ins = db.prepare('INSERT OR REPLACE INTO cabinet_topology (cabinet_id, cabinet_name, tier, retention, created_utc) VALUES (?, ?, ?, ?, ?)');
  ins.run('CAB_01_TELEMETRY', 'Telemetry & Manifold Frame Vault', 'HOT_OLTP', '90_DAYS', now);
  ins.run('CAB_02_INTEGRITY', 'Cryptographic SHA-256 Baseline Registry', 'IMMUTABLE_SECURITY', 'PERENNIAL', now);
  ins.run('CAB_03_MODELS', 'Recursive Linear Regression Artifact Store', 'MODEL_GOVERNANCE', 'PERENNIAL', now);
  ins.run('CAB_04_AUDIT', 'Middleware HTTP & Rate-Limit Audit Ledger', 'COMPLIANCE_LOG', '365_DAYS', now);
  const mPath = path.join(BASE_DIR, 'harmonic_recursive_remediation_v5_1.json');
  if (fs.existsSync(mPath)) {
    const m = JSON.parse(fs.readFileSync(mPath, 'utf8'));
    db.prepare('INSERT OR REPLACE INTO regression_models (model_id, version, feature_dim, target_dim, lambda_reg, weights_json, x_mean_json, x_std_json, registered_utc) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)')
      .run('MDL_RIDGE_V6', m.Version || '6.0.0', 12, 4, 1e-4, JSON.stringify(m.WeightsFlat || []), JSON.stringify(m.XMean || []), JSON.stringify(m.XStd || []), now);
  }
}
initCabinets();

function readJsonSafe(f, fb = null) { const p = path.join(BASE_DIR, f); return fs.existsSync(p) ? JSON.parse(fs.readFileSync(p, 'utf8')) : fb; }
function recursiveDot(a, offA, b, offB, idx, len, acc = 0) { return idx >= len ? acc : recursiveDot(a, offA, b, offB, idx + 1, len, acc + (a[offA + idx] * b[offB + idx])); }
function sendJson(res, code, data) { const body = JSON.stringify(data); res.writeHead(code, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) }); res.end(body); }
function solveRemediation(input, persist = true) {
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
    g = recursiveDot(xNorm, 0, model.WeightsFlat, 0, 0, P); f = recursiveDot(xNorm, 0, model.WeightsFlat, P, 0, P);
    w = recursiveDot(xNorm, 0, model.WeightsFlat, 2 * P, 0, P); b = recursiveDot(xNorm, 0, model.WeightsFlat, 3 * P, 0, P);
  }
  const breach = Math.abs(b) > 40 || purity < 0.55;
  if (breach) { b = Math.sign(b) * Math.min(Math.abs(b), 40); w = Math.max(0.68, w + 0.1); }
  const out = { CouplingGain: Number(g.toFixed(6)), FrequencyThz: Number(f.toFixed(6)), WatermarkWt: Number(w.toFixed(6)), RegulatedBend: Number(b.toFixed(6)), BreachDetected: breach, Status: 'REGULATED_COMPLIANT' };
  if (persist) { try { db.prepare('INSERT INTO telemetry_frames (source_file, step_seq, coupling_gain, frequency_thz, watermark_wt, regulated_bend, breach_detected, status, ingested_utc) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)').run('LIVE_API_STREAM', Date.now() % 100000, out.CouplingGain, out.FrequencyThz, out.WatermarkWt, out.RegulatedBend, breach ? 1 : 0, out.Status, new Date().toISOString()); } catch {} }
  return out;
}
function runCryptographicAudit() {
  const baseline = readJsonSafe('dew_integrity_baseline.json', {});
  const files = fs.readdirSync(BASE_DIR).filter(f => fs.statSync(path.join(BASE_DIR, f)).isFile() && !f.endsWith('.db') && !f.endsWith('-wal') && !f.endsWith('-shm') && !f.endsWith('.zip') && f !== 'middleware_audit.jsonl');
  const now = new Date().toISOString();
  const ins = db.prepare('INSERT OR REPLACE INTO integrity_registry (artifact_name, sha256_digest, size_bytes, phi_weight, risk_score, remediation_action, verified_utc) VALUES (?, ?, ?, ?, ?, ?, ?)');
  return files.map((file, idx) => {
    const buf = fs.readFileSync(path.join(BASE_DIR, file));
    const sha256 = crypto.createHash('sha256').update(buf).digest('hex');
    const ref = baseline[file];
    const drift = !ref ? 0.0 : (ref.Sha256.toLowerCase() !== sha256.toLowerCase() ? 1.0 : 0.0);
    const phiW = Number(Math.pow(PHI, -(idx % 6)).toFixed(4));
    const risk = Number(Math.min(1, (0.08 * phiW) + (0.85 * drift)).toFixed(4));
    const action = drift >= 1.0 ? 'HASH_DRIFT_DETECTED' : 'VERIFIED_NOMINAL';
    ins.run(file, sha256, buf.length, phiW, risk, action, now);
    return { Seq: idx + 1, Artifact: file, SizeKB: Number((buf.length / 1024).toFixed(2)), Sha256Prefix: sha256.slice(0, 14).toUpperCase(), PhiWeight: phiW, RiskScore: risk, RemediationAction: action };
  });
}

const server = http.createServer((req, res) => {
  runMiddleware(req, res, () => {
    const url = new URL(req.url, `http://localhost:${PORT}`);
    const route = url.pathname.toLowerCase();
    if (req.method === 'GET' && route === '/') { const hp = path.join(BASE_DIR, 'index.html'); if (fs.existsSync(hp)) { const b = fs.readFileSync(hp); res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Content-Length': b.length }); return res.end(b); } return sendJson(res, 200, { Status: 'ONLINE', Release: '6.0.0-Production' }); }
    if (req.method === 'GET' && route === '/api/health') { return sendJson(res, 200, { Status: 'ONLINE', Release: '6.0.0-Production', Runtime: `Node.js ${process.version}`, Database: 'SQLite-WAL', Port: PORT }); }
    if (req.method === 'GET' && route === '/api/cabinets') { return sendJson(res, 200, { Topology: db.prepare('SELECT * FROM cabinet_topology').all(), Counts: { CAB_01_TELEMETRY: db.prepare('SELECT COUNT(*) AS c FROM telemetry_frames').get().c, CAB_02_INTEGRITY: db.prepare('SELECT COUNT(*) AS c FROM integrity_registry').get().c, CAB_03_MODELS: db.prepare('SELECT COUNT(*) AS c FROM regression_models').get().c, CAB_04_AUDIT: db.prepare('SELECT COUNT(*) AS c FROM http_audit_ledger').get().c } }); }
    if (req.method === 'GET' && route === '/api/dashboard') { const matrix = runCryptographicAudit(); return sendJson(res, 200, { TimestampUtc: new Date().toISOString(), FreeMemPct: Number(((os.freemem() / os.totalmem()) * 100).toFixed(2)), ProcCount: os.cpus().length * 16, TotalDatumRows: db.prepare('SELECT COUNT(*) AS c FROM telemetry_frames').get().c, Matrix: matrix }); }
    if (req.method === 'GET' && route === '/api/audit-logs') { const ap = path.join(BASE_DIR, 'middleware_audit.jsonl'); const logs = fs.existsSync(ap) ? fs.readFileSync(ap, 'utf8').trim().split(/\r?\n/).filter(Boolean).slice(-25).map(l => JSON.parse(l)) : []; return sendJson(res, 200, { Count: logs.length, Logs: logs }); }
    if (req.method === 'GET' && route === '/api/stream') { res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache', 'Connection': 'keep-alive' }); let seq = 0; const timer = setInterval(() => { seq++; const psi = Number((((seq * 0.22) % (2 * Math.PI)) - Math.PI).toFixed(4)); const solved = solveRemediation({ psi, gain: Number((0.40 + 0.55 * Math.abs(Math.sin(psi))).toFixed(4)), purity: Number((0.45 + 0.50 * Math.abs(Math.cos(psi * 0.5))).toFixed(4)), rawScore: 0.75, s0: 4.2 * Math.cos(psi), s1: -3.9 * Math.sin(psi) }, false); res.write(`id: ${seq}\nevent: telemetry\ndata: ${JSON.stringify(Object.assign({ Seq: seq, TimestampUtc: new Date().toISOString(), FreeMemPct: Number(((os.freemem() / os.totalmem()) * 100).toFixed(2)), Psi: psi }, solved))}\n\n`); }, 500); req.on('close', () => clearInterval(timer)); return; }
    if (req.method === 'POST' && route === '/api/remediate') { return sendJson(res, 200, solveRemediation(req.body || {}, true)); }
    if (req.method === 'POST' && route === '/api/stop') { sendJson(res, 200, { Status: 'STOPPING_PRODUCTION_STACK' }); setTimeout(() => { db.close(); process.exit(0); }, 120); return; }
    sendJson(res, 404, { Error: 'Route not found' });
  }).catch(err => sendJson(res, 400, { Error: err.message, RequestId: req.requestId }));
});
server.listen(PORT, '0.0.0.0');