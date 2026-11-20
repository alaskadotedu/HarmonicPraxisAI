const test = require('node:test');
const assert = require('node:assert/strict');
const { evaluateHarmonicState } = require('../src/services/harmonicEngine.js');

test('evaluateHarmonicState enforces regulatory clamping on breach', () => {
  const out = evaluateHarmonicState({ psi: 1.4, gain: 0.9, purity: 0.45, s0: 5.0, s1: -5.0 });
  assert.equal(out.BreachDetected, true);
  assert.ok(Math.abs(out.RegulatedBend) <= 40);
  assert.ok(out.WatermarkWt >= 0.68);
  assert.equal(out.Status, 'REGULATED_COMPLIANT');
});