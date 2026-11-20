Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$BaseDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
. (Join-Path $BaseDir 'HarmonicMaterialApplicationEngine.ps1')

$Port = 8125
while ($true) {
    if (-not (Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue)) { break }
    $Port++
}
$Prefix = "http://localhost:$Port/"
$HtmlPath = Join-Path $BaseDir 'material_hub.html'

$Listener = New-Object System.Net.HttpListener
$Listener.Prefixes.Add($Prefix)
$Listener.Start()
Write-Host "[MATERIAL APPLICATION ENGINE ACTIVE] $Prefix" -ForegroundColor Green
Start-Process $Prefix

try {
    while ($Listener.IsListening) {
        $ctx = $Listener.GetContext(); $req = $ctx.Request; $res = $ctx.Response
        try {
            if ($req.Url.AbsolutePath -eq '/api/material') {
                $q = $req.QueryString
                $prof = if ($q['profile']) { $q['profile'] } else { 'PHOTONIC_CRYSTAL_HEX' }
                $psi  = if ($q['psi'])     { [double]$q['psi'] } else { 0.50 }
                $gain = if ($q['gain'])    { [double]$q['gain'] } else { 0.72 }
                $pur  = if ($q['purity'])  { [double]$q['purity'] } else { 0.88 }
                $alp  = if ($q['alpha'])   { [double]$q['alpha'] } else { 0.50 }
                $slv  = ($q['solve'] -eq '1')
                $pst  = ($q['persist'] -eq '1')

                $out = Invoke-MaterialSynthesis -Profile $prof -Psi $psi -Gain $gain -Purity $pur -Alpha $alp -SolveEquilibrium:$slv -Persist:$pst
                $buf = [System.Text.Encoding]::UTF8.GetBytes(($out | ConvertTo-Json -Depth 6))
                $res.ContentType = 'application/json; charset=utf-8'
            } else {
                $buf = [System.Text.Encoding]::UTF8.GetBytes((Get-Content -LiteralPath $HtmlPath -Raw))
                $res.ContentType = 'text/html; charset=utf-8'
            }
            $res.ContentLength64 = $buf.Length
            $res.OutputStream.Write($buf, 0, $buf.Length)
        } finally { $res.OutputStream.Close() }
    }
} finally { $Listener.Stop(); $Listener.Close() }
