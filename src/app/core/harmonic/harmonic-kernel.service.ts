import { Injectable } from '@angular/core';
import { HarmonicInput, HarmonicModelWeights, HarmonicStateOutput, INV_SQRT2, PHI } from './harmonic.contracts';

@Injectable({ providedIn: 'root' })
export class HarmonicKernelService {
  recursiveDot(a: number[], offA: number, b: number[], offB: number, idx: number, len: number, acc = 0): number {
    return idx >= len ? acc : this.recursiveDot(a, offA, b, offB, idx + 1, len, acc + a[offA + idx] * b[offB + idx]);
  }

  evaluate(input: HarmonicInput, model: HarmonicModelWeights | null): HarmonicStateOutput {
    const psi = Number(input.psi ?? 0.5);
    const gain = Number(input.gain ?? 0.5);
    const purity = Number(input.purity ?? 0.8);
    const raw = Number(input.rawScore ?? 0.75);
    const s0 = Number(input.s0 ?? 1.0);
    const s1 = Number(input.s1 ?? -1.0);
    const s2 = Number(input.s2 ?? 0.4);
    const s3 = Number(input.s3 ?? 0.01);
    const sides = Math.max(3, Math.floor(Number(input.polygonSides ?? 6)));

    const sectorAngle = (2 * Math.PI) / sides;
    const snappedVertex = Math.round(psi / sectorAngle) * sectorAngle;
    const angularResidual = psi - snappedVertex;
    const polygonalCoherence = Math.cos((angularResidual * sides) / 2);

    const lowMass = Math.pow(PHI, -1) * (1 + Math.max(0.05, gain));
    const coldMass = Math.min(Math.pow(PHI, -2) * Math.max(0.05, purity), lowMass * 0.94);
    const augmentationFactor = coldMass / lowMass;

    const cP = Math.cos(psi), sP = Math.sin(psi), c2P = Math.cos(2 * psi), s2P = Math.sin(2 * psi);
    const ambient6D = [
      INV_SQRT2 * (cP * s0 - sP * s1) * polygonalCoherence,
      INV_SQRT2 * (sP * s0 + cP * s1) * polygonalCoherence,
      INV_SQRT2 * (c2P * s2 - s2P * s3),
      INV_SQRT2 * (s2P * s2 + c2P * s3),
      cP * snappedVertex,
      sP * angularResidual
    ].map(v => Number(v.toFixed(6)));

    const k = (1 + 2.5 * gain) * (1.2 - 0.5 * purity) * (1 - 0.25 * augmentationFactor);
    const bendIn = k * cP * (s0 * s0 + s1 * s1) + 1.5 * k * psi * psi;

    let g = gain;
    let f = 299792458 / ((532 - 4 * gain) * 1e-9) / 1e12;
    let w = 0.72 + 0.08 * augmentationFactor;
    let b = bendIn;
    let modelApplied = false;

    if (model) {
      const xRaw = [1, psi, gain, purity, raw, s0, s1, cP * s0, sP * s1, c2P, bendIn, gain * purity];
      const P = 12;
      const xNorm = xRaw.map((v, j) => (j === 0 ? 1 : (v - model.XMean[j]) / (model.XStd[j] || 1)));
      g = this.recursiveDot(xNorm, 0, model.WeightsFlat, 0, 0, P);
      f = this.recursiveDot(xNorm, 0, model.WeightsFlat, P, 0, P);
      w = this.recursiveDot(xNorm, 0, model.WeightsFlat, 2 * P, 0, P);
      b = this.recursiveDot(xNorm, 0, model.WeightsFlat, 3 * P, 0, P) * (1 - 0.25 * augmentationFactor);
      modelApplied = true;
    }

    const breach = Math.abs(b) > 40 || purity < 0.55;
    if (breach) {
      b = Math.sign(b) * Math.min(Math.abs(b), 40);
      w = Math.max(0.68, w + 0.1);
    }

    const r6 = (n: number) => Number(n.toFixed(6));
    return {
      timestampUtc: new Date().toISOString(),
      psi: Number(psi.toFixed(4)),
      ambient6D,
      polygonal: {
        sides,
        sectorAngleRad: r6(sectorAngle),
        snappedVertexRad: r6(snappedVertex),
        angularResidualRad: r6(angularResidual),
        polygonalCoherence: r6(polygonalCoherence)
      },
      massAugmentation: {
        coldMass: r6(coldMass),
        lowMass: r6(lowMass),
        invariantSatisfied: coldMass < lowMass,
        augmentationFactor: r6(augmentationFactor)
      },
      modelApplied,
      couplingGain: r6(g),
      frequencyThz: r6(f),
      watermarkWt: r6(w),
      regulatedBend: r6(b),
      breachDetected: breach,
      status: breach ? 'AUGMENTED_CLAMPED' : 'REGULATED_COMPLIANT'
    };
  }
}
