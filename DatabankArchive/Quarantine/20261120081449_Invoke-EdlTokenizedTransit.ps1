param(
    [string]$RawJwt = "",
    [string]$EndpointUrl = "https://nasa.gov",
    [switch]$StoreOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RootDir   = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$dpapiPath = Join-Path $RootDir "edl_token.dpapi"

if (-not [string]::IsNullOrWhiteSpace($RawJwt)) {
    $sec = ConvertTo-SecureString -String $RawJwt.Trim() -AsPlainText -Force
    $enc = ConvertFrom-SecureString -SecureString $sec
    [System.IO.File]::WriteAllText($dpapiPath, $enc, (New-Object System.Text.UTF8Encoding($false)))
    $RawJwt = ""
}

if (-not (Test-Path -LiteralPath $dpapiPath)) {
    throw "No DPAPI-sealed EDL token found at $dpapiPath."
}

$encryptedText = (Get-Content -LiteralPath $dpapiPath -Raw).Trim()
$secureToken   = ConvertTo-SecureString -String $encryptedText
$bstr          = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
try {
    $token = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
} finally {
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
}

$parts = [string[]]$token.Split('.')
if ($parts.Length -lt 2) { throw "Malformed JWT structure." }
$payloadSegment = [System.Linq.Enumerable]::ElementAt($parts, 1)
$b64 = $payloadSegment.Replace('-', '+').Replace('_', '/')
switch ($b64.Length % 4) { 2 { $b64 += '==' } 3 { $b64 += '=' } }
$claims = ([System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($b64))) | ConvertFrom-Json

$expUtc    = [DateTimeOffset]::FromUnixTimeSeconds([long]$claims.exp).UtcDateTime
$isExpired = ([DateTime]::UtcNow -ge $expUtc)
if ($isExpired) { throw "EDL Bearer JWT expired at $($expUtc.ToString('o'))." }

$transitStatus = "DPAPI_SEALED_READY"
$httpCode      = 0
if (-not $StoreOnly) {
    $headers = @{
        "Authorization" = "Bearer $token"
        "Accept"        = "application/json"
        "User-Agent"    = "HarmonicPraxisAI/9.0"
    }
    try {
        $resp = Invoke-WebRequest -Uri $EndpointUrl -Headers $headers -Method Get -TimeoutSec 15 -UseBasicParsing
        $httpCode      = [int]$resp.StatusCode
        $transitStatus = "FEDERATED_BEARER_AUTHORIZED"
    } catch {
        $httpCode      = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        $transitStatus = "TRANSIT_PROBE_COMPLETE ($($_.Exception.Message))"
    }
}

$token = $null
$receipt = [pscustomobject]@{
    TimestampUtc   = [DateTime]::UtcNow.ToString('o')
    Issuer         = $claims.iss
    SubjectUid     = $claims.uid
    IdentityProv   = $claims.identity_provider
    AssuranceLevel = $claims.assurance_level
    ExpiresUtc     = $expUtc.ToString('o')
    TokenValid     = (-not $isExpired)
    TransitStatus  = $transitStatus
    HttpStatus     = $httpCode
}

[System.IO.File]::WriteAllText((Join-Path $RootDir "edl_transit_receipt.json"), ($receipt | ConvertTo-Json -Depth 3), (New-Object System.Text.UTF8Encoding($false)))
$receipt | ConvertTo-Json -Depth 3