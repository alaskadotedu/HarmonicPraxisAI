import { Injectable, computed, effect, inject, signal } from '@angular/core';
import { HarmonicInput, HarmonicStateOutput } from './harmonic.contracts';
import { HarmonicKernelService } from './harmonic-kernel.service';
import { HARMONIC_MODEL_WEIGHTS } from './harmonic-model.token';

@Injectable({ providedIn: 'root' })
export class HarmonicPraxisService {
  private readonly kernel = inject(HarmonicKernelService);
  private readonly modelWeights = inject(HARMONIC_MODEL_WEIGHTS);

  readonly stateInput = signal<HarmonicInput>({ psi: 0.5, gain: 0.7, purity: 0.85, polygonSides: 6 });
  readonly telemetryHistory = signal<HarmonicStateOutput[]>([]);
  readonly evaluatedState = computed<HarmonicStateOutput>(() =>
    this.kernel.evaluate(this.stateInput(), this.modelWeights())
  );

  constructor() {
    effect(() => {
      const frame = this.evaluatedState();
      this.telemetryHistory.update(hist => [...hist.slice(-59), frame]);
    });
  }

  updateInput(patch: Partial<HarmonicInput>): void {
    this.stateInput.update(prev => ({ ...prev, ...patch }));
  }
}
