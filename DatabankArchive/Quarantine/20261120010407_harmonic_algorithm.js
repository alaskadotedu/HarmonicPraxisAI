const PHI = (1 + Math.sqrt(5)) / 2;
const INV_SQRT2 = Math.SQRT1_2;

function recursiveDot(a, offA, b, offB, idx, len, acc = 0) {
  if (idx >= len) return acc;
  return recursiveDot(a, offA, b, offB, idx + 1, len, acc + (a[offA + idx] * b[offB + idx]));
}

function recursivePivotElim(aug, p, width, piv = 0) {
  if (piv >= p) return aug;
  let div = aug[piv * width + piv];
  if (Math.abs(div) < 1e-14) div = 1e-14;
  for (let c = piv; c < width; c++) aug[piv * width + c] /= div;
  for (let r = 0; r < p; r++) {
    if (r !== piv) {
      const fac = aug[r * width + piv];
      for (let c = piv; c < width; c++) aug[r * width + c] -= fac * aug[piv * width + c];
    }
  }
  return recursivePivotElim(aug, p, width, piv + 1);
}

function immerse5Dto6D(state5D, gain, purity) {
  const [s0, s1, s2, s3, psi] = state5D;
  const cP = Math.cos(psi), sP = Math.sin(psi);
  const c2P = Math.cos(2 * psi), s2P = Math.sin(2 * psi);

  const ambient6D = [
    INV_SQRT2 * (cP * s0 - sP * s1),
    INV_SQRT2 * (sP * s0 + cP * s1),
    INV_SQRT2 * (c2P * s2 - s2P * s3),
    INV_SQRT2 * (s2P * s2 + c2P * s3),
    cP * psi,
    sP * psi
  ];

  const k = (1 + 2.5 * gain) * (1.2 - 0.5 * purity);
  const bendingEnergy = (k * cP * (s0 * s0 + s1 * s1)) + (1.5 * k * psi * psi);
  return { ambient6D, bendingEnergy };
}

function harmonicPraxisStep(input, model = null, stepIndex = 0) {
  const psi = Number(input.psi ?? 0.5);
  const gain = Number(input.gain ?? 0.5);
  const purity = Number(input.purity ?? 0.8);
  const rawScore = Number(input.rawScore ?? 0.7);
  const s0 = Number(input.s0 ?? 1.0);
  const s1 = Number(input.s1 ?? -1.0);
  const s2 = Number(input.s2 ?? 0.5);
  const s3 = Number(input.s3 ?? 0.01);

  const { ambient6D, bendingEnergy } = immerse5Dto6D([s0, s1, s2, s3, psi], gain, purity);
  const phiWeight = Math.pow(PHI, -(stepIndex % 6));

  let predGain = gain;
  let predFreqThz = (299792458 / ((532 - 4 * gain) * 1e-9)) / 1e12;
  let predWatermark = 0.72;
  let predBend = bendingEnergy;

  if (model && Array.isArray(model.WeightsFlat)) {
    const cP = Math.cos(psi), sP = Math.sin(psi), c2P = Math.cos(2 * psi);
    const xRaw = [1, psi, gain, purity, rawScore, s0, s1, cP * s0, sP * s1, c2P, bendingEnergy, gain * purity];
    const xNorm = xRaw.map((v, j) => j === 0 ? 1 : (v - model.XMean[j]) / model.XStd[j]);
    const P = 12;
    predGain = recursiveDot(xNorm, 0, model.WeightsFlat, 0 * P, 0, P);
    predFreqThz = recursiveDot(xNorm, 0, model.WeightsFlat, 1 * P, 0, P);
    predWatermark = recursiveDot(xNorm, 0, model.WeightsFlat, 2 * P, 0, P);
    predBend = recursiveDot(xNorm, 0, model.WeightsFlat, 3 * P, 0, P);
  }

  const breach = Math.abs(predBend) > 40 || purity < 0.55;
  const regulatedBend = breach ? Math.sign(predBend) * Math.min(Math.abs(predBend), 40) : predBend;
  const regulatedWatermark = breach ? Math.max(0.68, predWatermark + 0.1) : predWatermark;
  const integrityRisk = Math.min(1, (0.08 * phiWeight) + (breach ? 0.65 : 0.0));

  return {
    ambient6D: ambient6D.map(v => Number(v.toFixed(6))),
    phiWeight: Number(phiWeight.toFixed(6)),
    integrityRisk: Number(integrityRisk.toFixed(6)),
    couplingGain: Number(predGain.toFixed(6)),
    frequencyThz: Number(predFreqThz.toFixed(6)),
    watermarkWt: Number(regulatedWatermark.toFixed(6)),
    regulatedBend: Number(regulatedBend.toFixed(6)),
    breachDetected: breach,
    status: 'REGULATED_COMPLIANT'
  };
}

if (require.main === module) {
  const fs = require('node:fs');
  const path = require('node:path');
  const mPath = path.join(__dirname, 'harmonic_recursive_remediation_v5_1.json');
  const model = fs.existsSync(mPath) ? JSON.parse(fs.readFileSync(mPath, 'utf8')) : null;
  const sample = harmonicPraxisStep({ psi: 1.25, gain: 0.85, purity: 0.49, rawScore: 0.78, s0: 3.6, s1: -3.1 }, model, 2);
  console.log(JSON.stringify(sample, null, 2));
}

module.exports = { PHI, recursiveDot, recursivePivotElim, immerse5Dto6D, harmonicPraxisStep };