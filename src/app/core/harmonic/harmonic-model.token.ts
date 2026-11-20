import { InjectionToken, Signal, inject, provideAppInitializer, signal } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { catchError, firstValueFrom, of } from 'rxjs';
import { HarmonicModelWeights } from './harmonic.contracts';

export const HARMONIC_MODEL_WEIGHTS = new InjectionToken<Signal<HarmonicModelWeights | null>>(
  'HARMONIC_MODEL_WEIGHTS',
  { providedIn: 'root', factory: () => signal<HarmonicModelWeights | null>(null) }
);

export function provideHarmonicModelLoader(manifestUrl = '/harmonic_model_weights.json') {
  return provideAppInitializer(async () => {
    const http = inject(HttpClient);
    const targetSignal = inject(HARMONIC_MODEL_WEIGHTS) as ReturnType<typeof signal<HarmonicModelWeights | null>>;
    const data = await firstValueFrom(http.get<HarmonicModelWeights>(manifestUrl).pipe(catchError(() => of(null))));
    if (
      data &&
      Array.isArray(data.WeightsFlat) &&
      Array.isArray(data.XMean) &&
      Array.isArray(data.XStd) &&
      data.WeightsFlat.length >= 48
    ) {
      targetSignal.set(data);
    }
  });
}
