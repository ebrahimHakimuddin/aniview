# Run while AniView remains open on the playback error screen.
# Only HTTP status, byte counts and media signatures are printed; URLs stay private.
param([string]$Url)

$ErrorActionPreference = 'Stop'
if (-not $Url) {
    $Url = Read-Host 'Paste the complete http://127.0.0.1:... URL from the playback error (without the final sentence period)'
}
$address = $null
if (-not [Uri]::TryCreate($Url.Trim(), [UriKind]::Absolute, [ref]$address) -or
    $address.Scheme -ne 'http' -or $address.Host -ne '127.0.0.1') {
    throw 'Expected an AniView localhost HTTP URL.'
}

function Test-Relay([string]$Label, [bool]$BypassProxy) {
    $body = [IO.Path]::GetTempFileName()
    $errors = [IO.Path]::GetTempFileName()
    try {
        $arguments = @('--silent', '--max-time', '25', '--max-filesize', '16777216',
            '--output', $body, '--write-out', '%{http_code}', '--url', $address.AbsoluteUri)
        if ($BypassProxy) { $arguments += @('--noproxy', '*') }
        $status = & curl.exe @arguments 2> $errors
        $exitCode = $LASTEXITCODE
        $bytes = [IO.File]::ReadAllBytes($body)
        $kind = 'unknown'
        if ($bytes.Length -eq 0) {
            $kind = 'empty'
        } elseif ($bytes.Length -gt 376 -and $bytes[0] -eq 71 -and
            $bytes[188] -eq 71 -and $bytes[376] -eq 71) {
            $kind = 'MPEG-TS video'
        } else {
            $prefix = [Text.Encoding]::ASCII.GetString($bytes, 0, [Math]::Min(32, $bytes.Length))
            if ($prefix.StartsWith('#EXTM3U')) { $kind = 'HLS playlist' }
            elseif ($prefix -match '^\s*<') { $kind = 'HTML/XML response' }
        }
        Write-Output "$Label : HTTP=$status curl_exit=$exitCode bytes=$($bytes.Length) type=$kind"
    } finally {
        [IO.File]::Delete($body)
        [IO.File]::Delete($errors)
    }
}

Write-Output 'AniView Windows relay diagnostic'
Test-Relay 'Normal request' $false
Test-Relay 'Proxy bypass' $true
Write-Output 'Share the three report lines above. Do not share the URL.'
Write-Output 'HTTP 200 with video bytes means this request reached the relay and retrieved video; it does not prove the player decoded it.'
Write-Output 'HTTP 502 means the relay failed handling the request. curl_exit 7 means it could not connect; 28 means it timed out.'
