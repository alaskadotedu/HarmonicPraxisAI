const PHI = (1 + Math.sqrt(5)) / 2;
const INV_SQRT2 = Math.SQRT1_2;

function recursiveDot(a, offA, b, offB, idx, len, acc = 0) {
  return idx >= len ? acc : recursiveDot(a, offA, b, offB, idx + 1, len, acc + (a[offA + idx] * b[offB + idx]));
}

function evaluateHarmonicState(input, model = null) {
  const psi = Number(input.psi ?? 0.5), gain = Number(input.gain ?? 0.5), purity = Number(input.purity ?? 0.8);
  const raw = Number(input.rawScore ?? 0.75), s0 = Number(input.s0 ?? 1.0), s1 = Number(input.s1 ?? -1.0);
  const s2 = Number(input.s2 ?? 0.4), s3 = Number(input.s3 ?? 0.01);
  const cP = Math.cos(psi), sP = Math.sin(psi), c2P = Math.cos(2 * psi), s2P = Math.sin(2 * psi);

  const ambient6D = [
    INV_SQRT2 * (cP * s0 - sP * s1), INV_SQRT2 * (sP * s0 + cP * s1),
    INV_SQRT2 * (c2P * s2 - s2P * s3), INV_SQRT2 * (s2P * s2 + c2P * s3),
    cP * psi, sP * psi
  ].map(v => Number(v.toFixed(6)));

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
  return {
    Psi: Number(psi.toFixed(4)), Ambient6D: ambient6D,
    CouplingGain: Number(g.toFixed(6)), FrequencyThz: Number(f.toFixed(6)),
    WatermarkWt: Number(w.toFixed(6)), RegulatedBend: Number(b.toFixed(6)),
    BreachDetected: breach, Status: 'REGULATED_COMPLIANT'
  };
}
module.exports = { PHI, recursiveDot, evaluateHarmonicState };