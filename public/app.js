document.querySelectorAll('.tabs button').forEach(btn => {
  btn.addEventListener('click', () => {
    document.querySelectorAll('.tabs button, .view').forEach(el => el.classList.remove('active'));
    btn.classList.add('active');
    document.getElementById(btn.dataset.tab).classList.add('active');
  });
});

async function syncData() {
  const [ov, tel] = await Promise.all([fetch('/api/overview').then(r => r.json()), fetch('/api/telemetry?limit=20').then(r => r.json())]);
  document.getElementById('kMem').textContent = ov.freeMemPct + '%';
  document.getElementById('kTel').textContent = ov.cabinets.counts.CAB_01_TELEMETRY;
  document.getElementById('kInt').textContent = ov.cabinets.counts.CAB_02_INTEGRITY;
  document.getElementById('kAud').textContent = ov.cabinets.counts.CAB_04_AUDIT;
  document.getElementById('intBody').innerHTML = ov.integrity.map(r => `<tr><td>${r.seq}</td><td><code>${r.artifact}</code></td><td>${r.sizeKB}</td><td><code>${r.sha256Short}</code></td><td>${r.phiWeight}</td><td><span class="pill">${r.status}</span></td></tr>`).join('');
  document.getElementById('audBody').innerHTML = ov.audits.map(a => `<tr><td><b>${a.method}</b></td><td>${a.route}</td><td>${a.status}</td><td>${a.latency_ms} ms</td><td>${a.created_utc}</td></tr>`).join('');
  document.getElementById('telBody').innerHTML = tel.rows.map(f => `<tr><td>${f.id}</td><td>${f.source}</td><td>${f.psi}</td><td>${f.frequency_thz}</td><td>${f.regulated_bend}</td><td>${f.watermark_wt}</td><td><span class="pill ${f.breach?'warn':''}">${f.status}</span></td></tr>`).join('');
}

document.getElementById('btnRun').addEventListener('click', async () => {
  const res = await fetch('/api/remediate', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-API-Key': document.getElementById('fKey').value.trim() },
    body: JSON.stringify({ psi: Number(document.getElementById('fPsi').value), gain: Number(document.getElementById('fGain').value), purity: Number(document.getElementById('fPur').value), s0: 3.6, s1: -3.1 })
  });
  document.getElementById('outJson').textContent = JSON.stringify(await res.json(), null, 2);
  syncData();
});

const es = new EventSource('/api/stream');
es.addEventListener('frame', e => {
  const p = JSON.parse(e.data);
  document.getElementById('sseBar').innerHTML = `<span>LIVE SSE <b>#${p.seq}</b></span><span>PSI: <b>${p.Psi}</b></span><span>FREQ: <b>${p.FrequencyThz} THz</b></span><span>BEND: <b>${p.RegulatedBend}</b></span><span>BREACH: <b style="color:${p.BreachDetected?'#f59e0b':'#22c55e'}">${p.BreachDetected}</b></span>`;
});

syncData(); setInterval(syncData, 6000);