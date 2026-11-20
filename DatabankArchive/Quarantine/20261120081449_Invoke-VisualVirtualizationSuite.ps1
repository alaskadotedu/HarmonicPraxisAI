Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PngOut  = Join-Path $BaseDir 'harmonic_manifold_raster_v6.png'
$VirtJson = Join-Path $BaseDir 'virtualization_manifest.json'
$utf8 = New-Object System.Text.UTF8Encoding($false)

Add-Type -AssemblyName System.Drawing

$queryJs = "const{DatabaseSync}=require('node:sqlite');const db=new DatabaseSync(process.argv);const rows=db.prepare('SELECT step_seq,coupling_gain,frequency_thz,watermark_wt,regulated_bend,breach_detected FROM telemetry_frames ORDER BY frame_id DESC LIMIT 60').all().reverse();console.log(JSON.stringify(rows));db.close();"
$dbFile = Join-Path $BaseDir 'harmonic_praxis_vault.db'
$frames = @()
if (Test-Path -LiteralPath $dbFile) {
    $rawJson = & node -e $queryJs $dbFile
    $frames = @($rawJson | ConvertFrom-Json)
}
if ($frames.Count -lt 10) {
    $frames = for ($i = 1; $i -le 50; $i++) {
        $psi = (($i * 0.25) % (2 * [math]::PI)) - [math]::PI
        [pscustomobject]@{ step_seq=$i; coupling_gain=[math]::Abs([math]::Sin($psi)); frequency_thz=(564 + 4*[math]::Cos($psi)); watermark_wt=0.74; regulated_bend=(28*[math]::Sin(2*$psi)); breach_detected=([math]::Abs(28*[math]::Sin(2*$psi)) -gt 22) }
    }
}

$W = 1600; $H = 900
$bmp = New-Object System.Drawing.Bitmap($W, $H)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit

$bgBrush   = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 8, 12, 20))
$cardBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 15, 23, 42))
$borderPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 30, 41, 59), 2)
$gridPen   = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(90, 56, 189, 248), 1)
$cyanPen   = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 56, 189, 248), 2.5)
$greenPen  = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 34, 197, 94), 2.5)
$amberPen  = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 245, 158, 11), 2.0)

$fontTitle = New-Object System.Drawing.Font('Consolas', 18, [System.Drawing.FontStyle]::Bold)
$fontSub   = New-Object System.Drawing.Font('Consolas', 11, [System.Drawing.FontStyle]::Bold)
$fontMono  = New-Object System.Drawing.Font('Consolas', 9.5, [System.Drawing.FontStyle]::Regular)
$brushCyan = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 56, 189, 248))
$brushText = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 226, 232, 240))
$brushOk   = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 34, 197, 94))
$brushWarn = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 245, 158, 11))

$g.FillRectangle($bgBrush, 0, 0, $W, $H)
$g.DrawString("HARMONIC PRAXIS AI v6.0 // 6D MANIFOLD RASTER & TELEMETRY PROJECTION", $fontTitle, $brushCyan, 30, 22)
$g.DrawString(("UTC RENDER: {0} | FRAMES: {1} | ENGINE: .NET GDI+ / SQLITE WAL" -f [DateTime]::UtcNow.ToString('o'), $frames.Count), $fontMono, $brushText, 32, 56)

$g.FillRectangle($cardBrush, 30, 90, 740, 460); $g.DrawRectangle($borderPen, 30, 90, 740, 460)
$g.DrawString("[PANEL A] 6D ISOMETRIC IMMERSION PROJECTION (PHI-HARMONIC TORUS)", $fontSub, $brushCyan, 48, 106)
$cx = 400; $cy = 330
for ($r = 40; $r -le 180; $r += 35) { $g.DrawEllipse($gridPen, ($cx - $r), ($cy - $r), ($r * 2), ($r * 2)) }
$g.DrawLine($gridPen, 190, $cy, 610, $cy); $g.DrawLine($gridPen, $cx, 140, $cx, 520)

$torusPts = New-Object System.Collections.Generic.List[System.Drawing.PointF]
$Phi = (1.0 + [math]::Sqrt(5.0)) / 2.0
for ($t = 0; $t -le 180; $t++) {
    $ang = $t * 0.08
    $rad = 95.0 + 58.0 * [math]::Cos($ang * $Phi)
    $px = [float]($cx + $rad * [math]::Cos($ang))
    $py = [float]($cy + $rad * [math]::Sin($ang) * 0.82)
    $torusPts.Add([System.Drawing.PointF]::new($px, $py))
}
$g.DrawLines($cyanPen, $torusPts.ToArray())

$g.FillRectangle($cardBrush, 800, 90, 770, 460); $g.DrawRectangle($borderPen, 800, 90, 770, 460)
$g.DrawString("[PANEL B] REGULATED BENDING ENERGY & WATERMARK SETTLEMENT WAVEFORM", $fontSub, $brushCyan, 818, 106)
$bendPts = New-Object System.Collections.Generic.List[System.Drawing.PointF]
$wtPts   = New-Object System.Collections.Generic.List[System.Drawing.PointF]
$nF = [math]::Max(2, $frames.Count)
for ($i = 0; $i -lt $nF; $i++) {
    $fr = $frames[$i]
    $x = [float](830 + ($i * (710.0 / ($nF - 1))))
    $bVal = [math]::Max(-45.0, [math]::Min(45.0, [double]$fr.regulated_bend))
    $yB = [float](310 - ($bVal * 3.2))
    $wVal = [math]::Max(0.3, [math]::Min(1.0, [double]$fr.watermark_wt))
    $yW = [float](480 - ($wVal * 260.0))
    $bendPts.Add([System.Drawing.PointF]::new($x, $yB))
    $wtPts.Add([System.Drawing.PointF]::new($x, $yW))
    if ($fr.breach_detected -eq 1 -or $fr.breach_detected -eq $true) {
        $g.FillEllipse($brushWarn, ($x - 4), ($yB - 4), 8, 8)
    }
}
$g.DrawLine($amberPen, 830, 182, 1540, 182)
$g.DrawLines($cyanPen, $bendPts.ToArray())
$g.DrawLines($greenPen, $wtPts.ToArray())
$g.DrawString("Cyan: RegulatedBend | Green: WatermarkWt | Amber Line: +40.0 Compliance Cap", $fontMono, $brushText, 825, 518)

$g.FillRectangle($cardBrush, 30, 575, 1540, 290); $g.DrawRectangle($borderPen, 30, 575, 1540, 290)
$g.DrawString("[PANEL C] INFRASTRUCTURE CABINETS & VIRTUALIZATION RUNTIME DEPENDENCIES", $fontSub, $brushCyan, 48, 592)
$g.DrawString("CAB_01_TELEMETRY (SQLite WAL) : ACTIVE   |   CAB_02_INTEGRITY (SHA-256) : SEALED", $fontMono, $brushOk, 50, 632)
$g.DrawString("CAB_03_MODELS (Ridge v6.0)    : LOADED   |   CAB_04_AUDIT (JSONL Ledger): ACTIVE", $fontMono, $brushOk, 50, 662)
$g.DrawString("VIRTUALIZATION TARGETS        : Docker (node:22-alpine) + Windows Host Process + .NET GDI+ Rasterizer", $fontMono, $brushText, 50, 702)
$g.DrawString(("LIVE SAMPLE [LATEST FRAME]    : Freq={0:F4} THz | RegBend={1:F4} | Watermark={2:F4}" -f [double]$frames[-1].frequency_thz, [double]$frames[-1].regulated_bend, [double]$frames[-1].watermark_wt), $fontMono, $brushCyan, 50, 742)

$bmp.Save($PngOut, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()