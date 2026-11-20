const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { HarmonicRepository } = require('./repositories/harmonicRepository.js');
const { evaluateHarmonicState } = require('./services/harmonicEngine.js');
const { createPipeline } = require('./middleware/pipeline.js');

const ROOT_DIR = path.resolve(__dirname, '..');
const PUBLIC_DIR = path.join(ROOT_DIR, 'public');
const PORT = Number(process.env.PORT || 8100);
const repo = new HarmonicRepository(ROOT_DIR);
const pipeline = createPipeline(ROOT_DIR, repo);

const MIME = { '.html': 'text/html; charset=utf-8', '.css': 'text/css; charset=utf-8', '.js': 'application/javascript; charset=utf-8', '.json': 'application/json' };
function json(res, code, obj) { const b = JSON.stringify(obj); res.writeHead(code, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(b) }); res.end(b); }

const server = http.createServer((req, res) => {
  pipeline(req, res, () => {
    const url = new URL(req.url, `http://localhost:${PORT}`);
    const route = url.pathname.toLowerCase();

    if (req.method === 'GET' && !route.startsWith('/api/')) {
      const rel = route === '/' ? 'index.html' : route.replace(/^\/+/, '');
      const filePath = path.join(PUBLIC_DIR, rel);
      if (filePath.startsWith(PUBLIC_DIR) && fs.existsSync(filePath) && fs.statSync(filePath).isFile()) {
        const ext = path.extname(filePath);
        const buf = fs.readFileSync(filePath);
        res.writeHead(200, { 'Content-Type': MIME[ext] || 'application/octet-stream', 'Content-Length': buf.length });
        return res.end(buf);
      }
      return json(res, 404, { error: 'Asset not found' });
    }

    if (req.method === 'GET' && route === '/api/health') {
      return json(res, 200, { status: 'ONLINE', version: '7.0.0-Enterprise', runtime: `Node.js ${process.version}`, port: PORT });
    }
    if (req.method === 'GET' && route === '/api/overview') {
      return json(res, 200, {
        utc: new Date().toISOString(),
        freeMemPct: Number(((os.freemem() / os.totalmem()) * 100).toFixed(2)),
        cabinets: repo.getCabinetSummary(),
        integrity: repo.auditCodebase(),
        audits: repo.listAudits(15)
      });
    }
    if (req.method === 'GET' && route === '/api/telemetry') {
      return json(res, 200, repo.listFrames(Number(url.searchParams.get('limit') || 25), Number(url.searchParams.get('offset') || 0)));
    }
    if (req.method === 'GET' && route === '/api/stream') {
      res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache', 'Connection': 'keep-alive' });
      let seq = 0;
      const timer = setInterval(() => {
        seq++;
        const psi = (((seq * 0.24) % (2 * Math.PI)) - Math.PI);
        const frame = evaluateHarmonicState({ psi, gain: 0.45 + 0.5 * Math.abs(Math.sin(psi)), purity: 0.48 + 0.48 * Math.abs(Math.cos(psi * 0.5)), s0: 3.8 * Math.cos(psi), s1: -3.4 * Math.sin(psi) }, repo.getModel());
        res.write(`id: ${seq}\nevent: frame\ndata: ${JSON.stringify(Object.assign({ seq, utc: new Date().toISOString() }, frame))}\n\n`);
      }, 600);
      req.on('close', () => clearInterval(timer));
      return;
    }
    if (req.method === 'POST' && route === '/api/remediate') {
      const result = evaluateHarmonicState(req.body || {}, repo.getModel());
      repo.saveFrame('API_REMEDIATE_POST', result);
      return json(res, 200, result);
    }
    if (req.method === 'POST' && route === '/api/stop') {
      json(res, 200, { status: 'STOPPING' });
      setTimeout(() => { repo.db.close(); process.exit(0); }, 100);
      return;
    }
    json(res, 404, { error: 'API route not found' });
  }).catch(err => json(res, 400, { error: err.message }));
});

server.listen(PORT, '0.0.0.0');