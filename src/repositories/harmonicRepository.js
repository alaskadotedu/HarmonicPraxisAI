const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { DatabaseSync } = require('node:sqlite');
const { PHI } = require('../services/harmonicEngine.js');

class HarmonicRepository {
  constructor(rootDir) {
    this.rootDir = rootDir;
    this.dbPath = path.join(rootDir, 'data', 'harmonic_enterprise_v7.db');
    this.db = new DatabaseSync(this.dbPath);
    this._migrate();
  }

  _migrate() {
    this.db.exec(`
      PRAGMA journal_mode = WAL;
      PRAGMA foreign_keys = ON;
      CREATE TABLE IF NOT EXISTS cabinet_topology (cabinet_id TEXT PRIMARY KEY, name TEXT NOT NULL, tier TEXT NOT NULL, retention TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS telemetry_frames (id INTEGER PRIMARY KEY AUTOINCREMENT, source TEXT NOT NULL, psi REAL, coupling_gain REAL, frequency_thz REAL, watermark_wt REAL, regulated_bend REAL, breach INTEGER NOT NULL, status TEXT NOT NULL, created_utc TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS integrity_registry (artifact TEXT PRIMARY KEY, sha256 TEXT NOT NULL, size_bytes INTEGER NOT NULL, phi_weight REAL NOT NULL, status TEXT NOT NULL, verified_utc TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS audit_ledger (id INTEGER PRIMARY KEY AUTOINCREMENT, req_id TEXT UNIQUE NOT NULL, method TEXT NOT NULL, route TEXT NOT NULL, status INTEGER NOT NULL, latency_ms REAL NOT NULL, created_utc TEXT NOT NULL);
    `);
    const ins = this.db.prepare('INSERT OR REPLACE INTO cabinet_topology VALUES (?, ?, ?, ?)');
    ins.run('CAB_01_TELEMETRY', 'Manifold Telemetry Vault', 'HOT_OLTP', '90_DAYS');
    ins.run('CAB_02_INTEGRITY', 'Cryptographic SHA-256 Registry', 'IMMUTABLE', 'PERENNIAL');
    ins.run('CAB_03_MODELS', 'Ridge Surrogate Model Store', 'GOVERNANCE', 'PERENNIAL');
    ins.run('CAB_04_AUDIT', 'HTTP Middleware Audit Ledger', 'COMPLIANCE', '365_DAYS');
  }

  getModel() {
    const p = path.join(this.rootDir, 'harmonic_recursive_remediation_v5_1.json');
    return fs.existsSync(p) ? JSON.parse(fs.readFileSync(p, 'utf8')) : null;
  }

  saveFrame(source, frame) {
    this.db.prepare('INSERT INTO telemetry_frames (source, psi, coupling_gain, frequency_thz, watermark_wt, regulated_bend, breach, status, created_utc) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)')
      .run(source, frame.Psi, frame.CouplingGain, frame.FrequencyThz, frame.WatermarkWt, frame.RegulatedBend, frame.BreachDetected ? 1 : 0, frame.Status, new Date().toISOString());
  }

  listFrames(limit = 25, offset = 0) {
    const total = this.db.prepare('SELECT COUNT(*) AS c FROM telemetry_frames').get().c;
    const rows = this.db.prepare('SELECT * FROM telemetry_frames ORDER BY id DESC LIMIT ? OFFSET ?').all(limit, offset);
    return { total, limit, offset, rows };
  }

  recordAudit(entry) {
    try {
      this.db.prepare('INSERT OR IGNORE INTO audit_ledger (req_id, method, route, status, latency_ms, created_utc) VALUES (?, ?, ?, ?, ?, ?)')
        .run(entry.reqId, entry.method, entry.route, entry.status, entry.latencyMs, entry.ts);
    } catch {}
  }

  listAudits(limit = 20) {
    return this.db.prepare('SELECT * FROM audit_ledger ORDER BY id DESC LIMIT ?').all(limit);
  }

  auditCodebase() {
    const targets = ['package.json', 'src/server.js', 'src/middleware/pipeline.js', 'src/repositories/harmonicRepository.js', 'src/services/harmonicEngine.js', 'public/index.html', 'public/app.js', 'public/styles.css'];
    const now = new Date().toISOString();
    const ins = this.db.prepare('INSERT OR REPLACE INTO integrity_registry VALUES (?, ?, ?, ?, ?, ?)');
    return targets.filter(rel => fs.existsSync(path.join(this.rootDir, rel))).map((rel, idx) => {
      const buf = fs.readFileSync(path.join(this.rootDir, rel));
      const sha = crypto.createHash('sha256').update(buf).digest('hex');
      const phiW = Number(Math.pow(PHI, -(idx % 6)).toFixed(4));
      ins.run(rel, sha, buf.length, phiW, 'VERIFIED_SEALED', now);
      return { seq: idx + 1, artifact: rel, sizeKB: Number((buf.length / 1024).toFixed(2)), sha256Short: sha.slice(0, 14).toUpperCase(), phiWeight: phiW, status: 'VERIFIED_SEALED' };
    });
  }

  getCabinetSummary() {
    return {
      topology: this.db.prepare('SELECT * FROM cabinet_topology').all(),
      counts: {
        CAB_01_TELEMETRY: this.db.prepare('SELECT COUNT(*) AS c FROM telemetry_frames').get().c,
        CAB_02_INTEGRITY: this.db.prepare('SELECT COUNT(*) AS c FROM integrity_registry').get().c,
        CAB_03_MODELS: this.getModel() ? 1 : 0,
        CAB_04_AUDIT: this.db.prepare('SELECT COUNT(*) AS c FROM audit_ledger').get().c
      }
    };
  }
}
module.exports = { HarmonicRepository };