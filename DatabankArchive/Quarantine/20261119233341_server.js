const { createMiddlewareStack } = require('./middleware.js');
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const os = require('node:os');

const PORT = Number(process.env.PORT || 8100);
const BASE_DIR = __dirname;
const PHI = (1 + Math.sqrt(5)) / 2;

function readJsonSafe(fileName, fallback = null) {
  const p = path.join(BASE_DIR, fileName);
  if (!fs.existsSync(p)) return fallback;
  return JSON.parse(fs.readFileSync(p, 'utf8'));
}

function parseCsvSafe(fileName) {
  const p = path.join(BASE_DIR, fileName);
  if (!fs.existsSync(p)) return [];
  const lines = fs.readFileSync(p, 'utf8').split(/\r?\n/).filter(Boolean);
  if (lines.length < 2) return [];
  const headers = lines[0].split(',').map(h => h.replace(/^"|"$/g, ''));
  return lines.slice(1).map(line => {
    const vals = line.split(',').map(v => v.replace(/^"|"$/g, ''));
    const obj = {};
    headers.forEach((h, i) => { obj[h] = vals[i] ?? ''; });
    return obj;
  });
}

function recursiveDot(a, offA, b, offB, idx, len, acc = 0) {
  if (idx >= len) return acc;
  return recursiveDot(a, offA, b, offB, idx + 1, len, acc + (a[offA + idx] * b[offB + idx]));
}

function runCryptographicAudit() {
  const baseline = readJsonSafe('dew_integrity_baseline.json', {});
  const files = fs.readdirSync(BASE_DIR).filter(f => {
    const full = path.join(BASE_DIR, f);
    return fs.statSync(full).isFile() && !f.startsWith('dew_') && !f.startsWith('amalgamated_');
  });
  return files.map((file, idx) => {
    const full = path.join(BASE_DIR, file);
    const buf = fs.readFileSync(full);
    const sha256 = crypto.createHash('sha256').update(buf).digest('hex');
    const ref = baseline[file];
    const drift = !ref ? 0.65 : (ref.Sha256.toLowerCase() !== sha256.toLowerCase() ? 1.0 : 0.0);
    const phiW = Math.pow(PHI, -(idx % 6));
    const risk = Math.min(1, (0.08 * phiW) + (0.85 * drift));
    return {
      Seq: idx + 1,
      Artifact: file,
      SizeKB: Number((buf.length / 1024).toFixed(2)),
      Sha256Prefix: sha256.slice(0, 14).toUpperCase(),
      PhiWeight: Number(phiW.toFixed(4)),
      RiskScore: Number(risk.toFixed(4)),
      RemediationAction: drift >= 1.0 ? 'HASH_DRIFT_DETECTED' : (drift > 0 ? 'UNTRACKED_ARTIFACT' : 'VERIFIED_NOMINAL')
    };
  });
}
function sendJson(res, code, data) {
  const body = JSON.stringify(data);
  res.writeHead(code, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) });
  res.end(body);
}

const runMiddleware = createMiddlewareStack(BASE_DIR, { maxRequestsPerMinute: 240 });
const server = http.createServer((req, res) => {
  runMiddleware(req, res, () => {
  const url = new URL(req.url, `http://localhost:${PORT}`);
  const route = url.pathname.toLowerCase();

  if (req.method === 'GET' && route === '/') {
    const htmlPath = path.join(BASE_DIR, 'index.html');
    if (fs.existsSync(htmlPath)) {
      const html = fs.readFileSync(htmlPath);
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Content-Length': html.length });
      return res.end(html);
    }
    return sendJson(res, 200, { Status: 'ONLINE', Message: 'Node Backend Active (index.html not yet generated)' });
  }

    if (req.method === 'GET' && route === '/api/stream') {
    res.writeHead(200, {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache',
      'Connection': 'keep-alive',
      'Access-Control-Allow-Origin': '*'
    });
    let seq = 0;
    const timer = setInterval(() => {
      seq++;
      const model = readJsonSafe('harmonic_recursive_remediation_v5_1.json');
      const psi = Number((((seq * 0.22) % (2 * Math.PI)) - Math.PI).toFixed(4));
      const gain = Number((0.40 + 0.55 * Math.abs(Math.sin(psi))).toFixed(4));
      const purity = Number((0.45 + 0.50 * Math.abs(Math.cos(psi * 0.5))).toFixed(4));
      const s0 = Number((4.2 * Math.cos(psi)).toFixed(4));
      const s1 = Number((-3.9 * Math.sin(psi)).toFixed(4));
      let freq = 566.0, bend = 0, wt = 0.72, breach = false;
      if (model) {
        const cP = Math.cos(psi), sP = Math.sin(psi), c2P = Math.cos(2 * psi);
        const k = (1 + 2.5 * gain) * (1.2 - 0.5 * purity);
        const bendIn = (k * cP * (s0 * s0 + s1 * s1)) + (1.5 * k * psi * psi);
        const xRaw = [1, psi, gain, purity, 0.75, s0, s1, cP * s0, sP * s1, c2P, bendIn, gain * purity];
        const xNorm = xRaw.map((v, j) => j === 0 ? 1 : (v - model.XMean[j]) / model.XStd[j]);
        const P = 12;
        freq = recursiveDot(xNorm, 0, model.WeightsFlat, 1 * P, 0, P);
        wt = recursiveDot(xNorm, 0, model.WeightsFlat, 2 * P, 0, P);
        bend = recursiveDot(xNorm, 0, model.WeightsFlat, 3 * P, 0, P);
        breach = Math.abs(bend) > 40 || purity < 0.55;
        if (breach) { bend = Math.sign(bend) * Math.min(Math.abs(bend), 40); wt = Math.max(0.68, wt + 0.1); }
      }
      const pkt = {
        Seq: seq,
        TimestampUtc: new Date().toISOString(),
        FreeMemPct: Number(((os.freemem() / os.totalmem()) * 100).toFixed(2)),
        Psi: psi,
        FrequencyThz: Number(freq.toFixed(4)),
        RegulatedBend: Number(bend.toFixed(4)),
        WatermarkWt: Number(wt.toFixed(4)),
        BreachDetected: breach
      };
      res.write(`id: ${seq}\nevent: telemetry\ndata: ${JSON.stringify(pkt)}\n\n`);
    }, 500);
    req.on('close', () => clearInterval(timer));
    return;
  }
  if (req.method === 'GET' && route === '/api/health') {
    const model = readJsonSafe('harmonic_recursive_remediation_v5_1.json');
    return sendJson(res, 200, {
      Status: 'ONLINE',
      Runtime: `Node.js ${process.version}`,
      Port: PORT,
      UptimeSec: Number(process.uptime().toFixed(2)),
      ModelLoaded: Boolean(model),
      ModelVersion: model ? model.Version : 'NONE'
    });
  }

  if (req.method === 'GET' && route === '/api/dashboard') {
    const freeMemPct = Number(((os.freemem() / os.totalmem()) * 100).toFixed(2));
    const telemetry = parseCsvSafe('amalgamated_telemetry_index.csv');
    return sendJson(res, 200, {
      TimestampUtc: new Date().toISOString(),
      FreeMemPct: freeMemPct,
      ProcCount: os.cpus().length * 16,
      TotalDatumRows: telemetry.length,
      Matrix: runCryptographicAudit()
    });
  }

  if (req.method === 'GET' && route === '/api/telemetry') {
    const rows = parseCsvSafe('amalgamated_telemetry_index.csv');
    const limit = Number(url.searchParams.get('limit') || 15);
    const offset = Number(url.searchParams.get('offset') || 0);
    return sendJson(res, 200, { TotalRows: rows.length, Offset: offset, Limit: limit, Records: rows.slice(offset, offset + limit) });
  }

  if (req.method === 'POST' && route === '/api/remediate') {
    let rawBody = '';
    req.on('data', chunk => { rawBody += chunk; });
    req.on('end', () => {
      try {
        const input = req.body || {};
        const model = readJsonSafe('harmonic_recursive_remediation_v5_1.json');
        if (!model) return sendJson(res, 404, { Error: 'Model artifact harmonic_recursive_remediation_v5_1.json not found' });
        const psi = Number(input.psi ?? 0.5), gain = Number(input.gain ?? 0.5), purity = Number(input.purity ?? 0.8);
        const rawScore = Number(input.rawScore ?? 0.7), s0 = Number(input.s0 ?? 1.0), s1 = Number(input.s1 ?? -1.0);
        const cP = Math.cos(psi), sP = Math.sin(psi), c2P = Math.cos(2 * psi);
        const k = (1 + 2.5 * gain) * (1.2 - 0.5 * purity);
        const bendIn = (k * cP * (s0 * s0 + s1 * s1)) + (1.5 * k * psi * psi);
        const xRaw = [1, psi, gain, purity, rawScore, s0, s1, cP * s0, sP * s1, c2P, bendIn, gain * purity];
        const xNorm = xRaw.map((v, j) => j === 0 ? 1 : (v - model.XMean[j]) / model.XStd[j]);
        const P = 12;
        const g = recursiveDot(xNorm, 0, model.WeightsFlat, 0 * P, 0, P);
        const f = recursiveDot(xNorm, 0, model.WeightsFlat, 1 * P, 0, P);
        let w = recursiveDot(xNorm, 0, model.WeightsFlat, 2 * P, 0, P);
        let b = recursiveDot(xNorm, 0, model.WeightsFlat, 3 * P, 0, P);
        const breach = Math.abs(b) > 40 || purity < 0.55;
        if (breach) { b = Math.sign(b) * Math.min(Math.abs(b), 40); w = Math.max(0.68, w + 0.1); }
        return sendJson(res, 200, { CouplingGain: Number(g.toFixed(6)), FrequencyThz: Number(f.toFixed(6)), WatermarkWt: Number(w.toFixed(6)), RegulatedBend: Number(b.toFixed(6)), BreachDetected: breach, Status: 'REGULATED_COMPLIANT' });
      } catch (err) { return sendJson(res, 400, { Error: err.message }); }
    });
    return;
  }

  if (req.method === 'POST' && route === '/api/stop') {
    sendJson(res, 200, { Status: 'STOPPING_NODE_BACKEND' });
    setTimeout(() => process.exit(0), 150);
    return;
  }

  sendJson(res, 404, { Error: 'Route not found' });
});

server.listen(PORT, '127.0.0.1', () => console.log(`[NODE STACK ONLINE] Listening on http://localhost:${PORT}/`));