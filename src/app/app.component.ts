import { ChangeDetectionStrategy, Component } from '@angular/core';
import { HarmonicViewportComponent } from './features/harmonic/harmonic-viewport.component';

@Component({
  selector: 'app-root',
  standalone: true,
  imports: [HarmonicViewportComponent],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `<app-harmonic-viewport />`
})
export class AppComponent {}
export { AppComponent as App };
