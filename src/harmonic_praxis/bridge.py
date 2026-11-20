import json
import shutil
import subprocess
from pathlib import Path
from typing import Any


class HarmonicBridge:
    def __init__(self, root_dir: str | Path | None = None) -> None:
        self.root_dir = Path(root_dir) if root_dir else Path(__file__).resolve().parents[2]
        self.shell = shutil.which("pwsh") or shutil.which("powershell")
        if not self.shell:
            raise RuntimeError("Neither pwsh nor powershell executable was found on PATH.")

    def _run_ps(self, command: str) -> dict[str, Any]:
        proc = subprocess.run(
            [self.shell, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", command],
            cwd=str(self.root_dir),
            capture_output=True,
            text=True,
            check=True,
        )
        raw = proc.stdout.strip()
        start = raw.find("{")
        if start == -1:
            return {"raw_output": raw}
        return json.loads(raw[start:])

    def synthesize(
        self,
        profile: str = "PHOTONIC_CRYSTAL_HEX",
        psi: float = 0.50,
        gain: float = 0.72,
        purity: float = 0.88,
        alpha: float = 0.50,
        rows: int = 4,
        cols: int = 4,
        solve_equilibrium: bool = True,
        export_cad: bool = True,
        persist_vault: bool = False,
    ) -> dict[str, Any]:
        flags = [
            f"-MaterialProfile '{profile}'",
            f"-Psi {psi}",
            f"-Gain {gain}",
            f"-Purity {purity}",
            f"-Alpha {alpha}",
            f"-GridRows {rows}",
            f"-GridCols {cols}",
        ]
        if solve_equilibrium:
            flags.append("-SolveEquilibrium")
        if export_cad:
            flags.append("-ExportCad")
        if persist_vault:
            flags.append("-PersistVault")
        script = self.root_dir / "HarmonicMaterialApplicationEngine.ps1"
        return self._run_ps(f"& '{script}' {' '.join(flags)}")

    def snapshot(self) -> dict[str, Any]:
        script = self.root_dir / "Export-WorkspaceSnapshot.ps1"
        return self._run_ps(f"& '{script}'")

    def verify_edl_transit(self) -> dict[str, Any]:
        script = self.root_dir / "Invoke-EdlTokenizedTransit.ps1"
        return self._run_ps(f"& '{script}'")