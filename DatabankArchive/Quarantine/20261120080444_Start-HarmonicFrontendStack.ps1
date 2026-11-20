Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$BaseDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
. (Join-Path $BaseDir 'HarmonicMaterialApplicationEngine.ps1')

$Port = 8135
while ($true) {
    $Listener = New-Object System.Net.HttpListener
    $Prefix = "http://localhost:$Port/"
    $Listener.Prefixes.Add($Prefix)
    try {
        $Listener.Start()
        break
    }
    catch {
        $Listener.Close()
        $Port++
    }
}

$HtmlPath = Join-Path $BaseDir 'material_hub.html'
Write-Host "[MATERIAL STUDIO + /download/gds ACTIVE] $Prefix" -ForegroundColor Green
Start-Process $Prefix

try {
    while ($Listener.IsListening) {
        $ctx = $Listener.GetContext(); $req = $ctx.Request; $res = $ctx.Response
        try {
            $path = $req.Url.AbsolutePath
            $q = $req.QueryString

            if ($path -eq '/download/gds') {
                $gdsFile = Join-Path $BaseDir 'lattice_layout.gds'
                if (-not (Test-Path -LiteralPath $gdsFile)) {
                    $initMat = Invoke-MaterialSynthesis -Profile 'PHOTONIC_CRYSTAL_HEX'
                    Export-CadGdsiiLattice -MaterialState $initMat -Rows 4 -Cols 4 | Out-Null
                }
                $buf = [System.IO.File]::ReadAllBytes($gdsFile)
                $res.ContentType = 'application/octet-stream'
                $res.AddHeader('Content-Disposition', 'attachment; filename="lattice_layout.gds"')
            }
            elseif ($path -eq '/api/profile/create') {
                $pName  = if ($q['name'])  { $q['name'] }          else { 'CUSTOM_LATTICE' }
                $pSides = if ($q['sides']) { [int]$q['sides'] }    else { 6 }
                $pEps   = if ($q['eps'])   { [double]$q['eps'] }   else { 10.0 }
                $pMu    = if ($q['mu'])    { [double]$q['mu'] }    else { 1.0 }
                $pDamp  = if ($q['damp'])  { [double]$q['damp'] }  else { 0.9 }
                $pLat   = if ($q['lat'])   { [double]$q['lat'] }   else { 450.0 }

                $reg = Register-CustomMaterialProfile -Name $pName -Sides $pSides -BaseEps $pEps -BaseMu $pMu -ThermalDamp $pDamp -LatticeNm $pLat
                $buf = [System.Text.Encoding]::UTF8.GetBytes(($reg | ConvertTo-Json -Depth 4))
                $res.ContentType = 'application/json; charset=utf-8'
            }
            elseif ($path -eq '/api/material') {
                $prof = if ($q['profile']) { $q['profile'] } else { 'PHOTONIC_CRYSTAL_HEX' }
                $psi  = if ($q['psi'])     { [double]$q['psi'] } else { 0.50 }
                $gain = if ($q['gain'])    { [double]$q['gain'] } else { 0.72 }
                $pur  = if ($q['purity'])  { [double]$q['purity'] } else { 0.88 }
                $alp  = if ($q['alpha'])   { [double]$q['alpha'] } else { 0.50 }
                $slv  = ($q['solve'] -eq '1')
                $pst  = ($q['persist'] -eq '1')
                $exp  = ($q['cad'] -eq '1')

                $mat = Invoke-MaterialSynthesis -Profile $prof -Psi $psi -Gain $gain -Purity $pur -Alpha $alp -SolveEquilibrium:$slv -Persist:$pst
                $cadSummary = if ($exp) { Export-CadGdsiiLattice -MaterialState $mat -Rows 4 -Cols 4 } else { $null }
                $cadPreview = if (Test-Path -LiteralPath (Join-Path $BaseDir 'cad_gdsii_lattice.json')) {
                    Get-Content -LiteralPath (Join-Path $BaseDir 'cad_gdsii_lattice.json') -Raw | ConvertFrom-Json
                } else { $null }

                $buf = [System.Text.Encoding]::UTF8.GetBytes(([ordered]@{ material = $mat; cad = $cadSummary; cadPreview = $cadPreview } | ConvertTo-Json -Depth 6))
                $res.ContentType = 'application/json; charset=utf-8'
            }
            else {
                $buf = [System.Text.Encoding]::UTF8.GetBytes((Get-Content -LiteralPath $HtmlPath -Raw))
                $res.ContentType = 'text/html; charset=utf-8'
            }

            $res.ContentLength64 = $buf.Length
            $res.OutputStream.Write($buf, 0, $buf.Length)
        }
        finally {
            $res.OutputStream.Close()
        }
    }
}
finally {
    $Listener.Stop()
    $Listener.Close()
}
