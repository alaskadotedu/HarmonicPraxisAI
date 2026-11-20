# Harmonic Praxis AI

**Harmonic Praxis AI** unifies cybernetic systems theory, multivariate linear algebra, and physical CAD fabrication into a single deterministic, local-first workbench with zero external cloud dependencies.

## System Architecture

```text
[BROWSER STUDIO: material_hub.html]

   | /api/material      | /api/jacobian      | /download/gds
   v                    v                    v
[HTTP ORCHESTRATOR: Start-HarmonicFrontendStack.ps1]
   +--> [HarmonicJacobianEngine.ps1] (4x4 Jacobian, Newton-Raphson Solver)
   +--> [HarmonicMaterialApplicationEngine.ps1] (Constitutive Tensors, Profiles)
   +--> [Export-BinaryGds.js] -> lattice_layout.gds (4-Layer GDSII v6.0)
   +--> [harmonic_praxis_vault.db + middleware_audit.jsonl] (SHA-256 Lineage)
```

## Quantified Capabilities

* **Jacobian Tensor Core (`HarmonicJacobianEngine.ps1`):** 4x4 central-difference partial differentiation (`h = 1e-5`), Gaussian-Jordan matrix inversion, Frobenius condition number `k(J)`, power-iteration spectral radius `rho(J) < 1`, and 12-step damped Newton-Raphson equilibrium solver.
* **Material & CAD Compiler (`HarmonicMaterialApplicationEngine.ps1` & `Export-BinaryGds.js`):** 4 built-in lattice profiles (`N = 4, 6, 8, 12`) plus unlimited custom profiles; 4-layer GDSII v6.0 stream export (`Layers 1, 10, 15, 20` at `1 DBU = 1 pm`) alongside ASCII CIF and JSON.
* **Reproducibility & Persistence:** Canonical SHA-256 state hashing per frame, SQLite WAL database (`harmonic_praxis_vault.db`), JSONL audit log (`middleware_audit.jsonl`), and 48-state batch CSV sweeps (`jacobian_automation_matrix.csv`).

## Quick Start

```powershell
& "C:\Users\dmjal\HarmonicPraxisAI\Start-HarmonicFrontendStack.ps1"
& "C:\Users\dmjal\HarmonicPraxisAI\HarmonicMaterialApplicationEngine.ps1" -MaterialProfile 'PHOTONIC_CRYSTAL_HEX' -SolveEquilibrium -ExportCad -PersistVault
```