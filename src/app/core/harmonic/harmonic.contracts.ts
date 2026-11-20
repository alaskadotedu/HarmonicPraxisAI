export const PHI = (1 + Math.sqrt(5)) / 2;
export const INV_SQRT2 = Math.SQRT1_2;

export interface HarmonicModelWeights {
  version: string;
  featureCount: number;
  WeightsFlat: number[];
  XMean: number[];
  XStd: number[];
}

export interface HarmonicInput {
  psi?: number;
  gain?: number;
  purity?: number;
  rawScore?: number;
  s0?: number;
  s1?: number;
  s2?: number;
  s3?: number;
  polygonSides?: number;
}

export interface HarmonicStateOutput {
  timestampUtc: string;
  psi: number;
  ambient6D: number[];
  polygonal: {
    sides: number;
    sectorAngleRad: number;
    snappedVertexRad: number;
    angularResidualRad: number;
    polygonalCoherence: number;
  };
  massAugmentation: {
    coldMass: number;
    lowMass: number;
    invariantSatisfied: boolean;
    augmentationFactor: number;
  };
  modelApplied: boolean;
  couplingGain: number;
  frequencyThz: number;
  watermarkWt: number;
  regulatedBend: number;
  breachDetected: boolean;
  status: 'REGULATED_COMPLIANT' | 'AUGMENTED_CLAMPED';
}
