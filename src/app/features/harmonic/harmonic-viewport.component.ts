import { ChangeDetectionStrategy, Component, ElementRef, effect, inject, viewChild } from '@angular/core';
import { HarmonicPraxisService } from '../../core/harmonic/harmonic-praxis.service';

@Component({
  selector: 'app-harmonic-viewport',
  standalone: true,
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div style="background:#080c14;color:#e2e8f0;font-family:Consolas,monospace;padding:16px;border:1px solid #1e293b">
      <div style="display:flex;justify-content:space-between;margin-bottom:12px">
        <strong style="color:#38bdf8">HARMONIC PRAXIS // {{ state().status }}</strong>
        <span>m_cold ({{ state().massAugmentation.coldMass }}) &lt; m_low ({{ state().massAugmentation.lowMass }}) : {{ state().massAugmentation.invariantSatisfied }}</span>
      </div>
      <div style="display:grid;grid-template-columns:repeat(4,1fr);gap:12px;margin-bottom:14px">
        <label>PSI: {{ state().psi }}
          <input type="range" min="-3.14" max="3.14" step="0.01" [value]="state().psi" (input)="onParam('psi', $event)" style="width:100%" />
        </label>
        <label>GAIN: {{ state().couplingGain }}
          <input type="range" min="0.05" max="1" step="0.01" [value]="state().couplingGain" (input)="onParam('gain', $event)" style="width:100%" />
        </label>
        <label>PURITY: {{ service.stateInput().purity }}
          <input type="range" min="0.1" max="1" step="0.01" [value]="service.stateInput().purity" (input)="onParam('purity', $event)" style="width:100%" />
        </label>
        <label>SIDES (N): {{ state().polygonal.sides }}
          <input type="range" min="3" max="16" step="1" [value]="state().polygonal.sides" (input)="onParam('polygonSides', $event)" style="width:100%" />
        </label>
      </div>
      <canvas #canvas width="760" height="320" style="width:100%;background:#0f172a;border:1px solid #1e293b"></canvas>
      <pre style="margin-top:12px;font-size:12px;color:#38bdf8">{{ state().ambient6D.join(' | ') }}</pre>
    </div>
  `
})
export class HarmonicViewportComponent {
  readonly service = inject(HarmonicPraxisService);
  readonly state = this.service.evaluatedState;
  readonly canvasRef = viewChild.required<ElementRef<HTMLCanvasElement>>('canvas');

  constructor() {
    effect(() => {
      const s = this.state();
      const canvas = this.canvasRef().nativeElement;
      const ctx = canvas.getContext('2d');
      if (!ctx) return;

      const w = canvas.width, h = canvas.height, cx = w / 2, cy = h / 2, r = 110;
      ctx.clearRect(0, 0, w, h);

      ctx.strokeStyle = '#38bdf8';
      ctx.lineWidth = 2;
      ctx.beginPath();
      for (let i = 0; i <= s.polygonal.sides; i++) {
        const a = i * s.polygonal.sectorAngleRad;
        const x = cx + r * Math.cos(a), y = cy + r * Math.sin(a);
        i === 0 ? ctx.moveTo(x, y) : ctx.lineTo(x, y);
      }
      ctx.stroke();

      ctx.strokeStyle = '#22c55e';
      ctx.beginPath();
      ctx.moveTo(cx, cy);
      ctx.lineTo(cx + r * Math.cos(s.polygonal.snappedVertexRad), cy + r * Math.sin(s.polygonal.snappedVertexRad));
      ctx.stroke();

      ctx.fillStyle = s.breachDetected ? '#f59e0b' : '#38bdf8';
      ctx.beginPath();
      ctx.arc(cx + r * Math.cos(s.psi), cy + r * Math.sin(s.psi), 5, 0, Math.PI * 2);
      ctx.fill();
    });
  }

  onParam(key: 'psi' | 'gain' | 'purity' | 'polygonSides', event: Event): void {
    const val = Number((event.target as HTMLInputElement).value);
    this.service.updateInput({ [key]: val });
  }
}
