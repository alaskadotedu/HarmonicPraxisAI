import { ApplicationConfig, provideZonelessChangeDetection } from '@angular/core';
import { provideHttpClient } from '@angular/common/http';
import { provideHarmonicModelLoader } from './core/harmonic/harmonic-model.token';

export const appConfig: ApplicationConfig = {
  providers: [
    provideZonelessChangeDetection(),
    provideHttpClient(),
    provideHarmonicModelLoader('/harmonic_model_weights.json')
  ]
};
