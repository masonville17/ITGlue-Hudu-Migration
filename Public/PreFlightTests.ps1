function TestHuduAPIKeyScope {
    [CmdletBinding()]
    param(
        [string]$HuduBaseUrl = $(Get-HuduBaseURL),
        [securestring]$HuduApiKey = $(Get-HuduApiKey),
        [switch]$Detailed,
        [switch]$ThrowOnFailure
    )

    $resolvedBaseUrl = $null
    $resolvedApiKey = $null
    $requestUri = $null

    try {
        if ([string]::IsNullOrWhiteSpace($HuduBaseUrl)) {
            throw "Hudu base URL is not set."
        }

        if ($null -eq $HuduApiKey) {
            throw "Hudu API key is not set."
        }

        $resolvedBaseUrl = $HuduBaseUrl.TrimEnd('/')
        $resolvedApiKey = (New-Object PSCredential 'user', $HuduApiKey).GetNetworkCredential().Password

        if ([string]::IsNullOrWhiteSpace($resolvedApiKey)) {
            throw "Resolved Hudu API key is empty."
        }

        $requestUri = "$resolvedBaseUrl/api/v1/asset_passwords?page=1&page_size=1"
        $response = Invoke-WebRequest `
            -Method Get `
            -Uri $requestUri `
            -Headers @{ 'x-api-key' = $resolvedApiKey } `
            -ContentType 'application/json; charset=utf-8' `
            -SkipHttpErrorCheck `
            -ErrorAction Stop

        $statusCode = [int]$response.StatusCode
        $rawContent = $response.Content
        $parsedContent = $null

        if (-not [string]::IsNullOrWhiteSpace($rawContent)) {
            $parsedContent = try {
                $rawContent | ConvertFrom-Json -Depth 10 -ErrorAction Stop
            } catch {
                $rawContent
            }
        }

        $success = $statusCode -ge 200 -and $statusCode -lt 300
        $message = switch ($statusCode) {
            { $_ -ge 200 -and $_ -lt 300 } {
                "Hudu API key can access password endpoints."
                break
            }
            401 {
                "Hudu rejected the password endpoint request with 401 Bad credentials. This usually means the API key is invalid or is missing password access."
                break
            }
            403 {
                "Hudu authenticated the API key but denied access to password endpoints with 403 Forbidden."
                break
            }
            default {
                "Hudu returned HTTP $statusCode while checking password endpoint access."
                break
            }
        }

        $result = [pscustomobject]@{
            Success      = $success
            StatusCode   = $statusCode
            Uri          = $requestUri
            Message      = $message
            ResponseBody = $parsedContent
        }
    } catch {
        $result = [pscustomobject]@{
            Success      = $false
            StatusCode   = $null
            Uri          = $requestUri
            Message      = "Failed to verify Hudu password endpoint access: $($_.Exception.Message)"
            ResponseBody = $_
        }
    }

    if (-not $result.Success) {
        Write-Warning $result.Message
        if ($ThrowOnFailure) {
            throw $result.Message
        }
    }

    if ($Detailed) {
        return $result
    }

    return $result.Success
}
