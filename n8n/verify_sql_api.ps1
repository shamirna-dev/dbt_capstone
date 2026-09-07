# Verifies the n8n -> Snowflake SQL API leg end to end.
# The token is created, used and revoked inside this one process and is never
# written to stdout. Nothing here is left behind.

# The snow CLI writes a harmless encoding warning to stderr, which PowerShell
# would otherwise promote to a terminating error.
$ErrorActionPreference = 'Continue'
$conn    = 'igtstwc-td17035'
$user    = 'SHAMIRNANORTHSTAR'
$host_   = 'igtstwc-td17035.snowflakecomputing.com'
$tokName = 'n8n_capstone_probe'
$tmp     = Join-Path $env:TEMP ("pat_" + [guid]::NewGuid().ToString() + ".json")

function Cleanup {
    if ($tmp -and (Test-Path -LiteralPath $tmp)) {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
    & snow sql -c $conn -q "ALTER USER $user REMOVE PROGRAMMATIC ACCESS TOKEN $tokName" 2>&1 | Out-Null
}

try {
    # Remove any stale token of the same name, then mint a fresh one.
    & snow sql -c $conn -q "ALTER USER $user REMOVE PROGRAMMATIC ACCESS TOKEN $tokName" 2>&1 | Out-Null
    & snow sql -c $conn -q "ALTER USER $user ADD PROGRAMMATIC ACCESS TOKEN $tokName ROLE_RESTRICTION = 'ACCOUNTADMIN' DAYS_TO_EXPIRY = 1" --format json 2>$null |
        Out-File -FilePath $tmp -Encoding utf8

    $raw = (Get-Content $tmp -Raw) -replace "`0", ""
    $m   = [regex]::Match($raw, '"token_secret"\s*:\s*"([^"]+)"')
    if (-not $m.Success) { throw 'could not obtain token from snow CLI output' }
    $tok = $m.Groups[1].Value

    $ErrorActionPreference = 'Stop'
    $hdr = @{
        'Authorization'                        = "Bearer $tok"
        'X-Snowflake-Authorization-Token-Type' = 'PROGRAMMATIC_ACCESS_TOKEN'
        'Content-Type'                         = 'application/json'
        # The SQL API rejects the request with 391902 without this.
        'Accept'                               = 'application/json'
    }
    $body = @{
        statement = "CALL CAPSTONE_AI_DLC.AGENTS.STAGE_QA('N8N_SQLAPI_PROBE', FALSE)"
        timeout   = 600
        database  = 'CAPSTONE_AI_DLC'
        schema    = 'AGENTS'
        warehouse = 'COMPUTE_WH'
        role      = 'ACCOUNTADMIN'
    } | ConvertTo-Json -Compress

    $resp = Invoke-RestMethod -Method Post `
        -Uri "https://$host_/api/v2/statements" -Headers $hdr -Body $body
    Write-Output 'SQL_API_STATUS: OK'
    Write-Output ('SQL_API_RESULT: ' + $resp.data[0][0])
}
catch {
    Write-Output ('SQL_API_STATUS: FAILED - ' + $_.Exception.Message)
    if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
        Write-Output ('DETAIL: ' + $_.ErrorDetails.Message)
    }
    elseif ($_.Exception.Response) {
        try {
            $s = $_.Exception.Response.GetResponseStream()
            $rd = New-Object System.IO.StreamReader($s)
            Write-Output ('DETAIL: ' + $rd.ReadToEnd())
        } catch { Write-Output 'DETAIL: could not read response body' }
    }
}
finally {
    $ErrorActionPreference = 'Continue'
    Cleanup
    Write-Output 'token revoked, temp file removed'
}
