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

function TestITGlueAPIKeyPasswordScope {
    [CmdletBinding()]
    param(
        [string]$ITGlueBaseUrl = $(Get-ITGlueBaseURI),
        [securestring]$ITGlueApiKey = $(Get-ITGlueAPIKey),
        [Nullable[Int64]]$PasswordId = $null,
        [switch]$Detailed,
        [switch]$ThrowOnFailure
    )

    $resolvedBaseUrl = $null
    $resolvedApiKey = $null
    $listUri = $null
    $showUri = $null

    try {
        if ([string]::IsNullOrWhiteSpace($ITGlueBaseUrl)) {
            throw "IT Glue base URL is not set."
        }

        if ($null -eq $ITGlueApiKey) {
            throw "IT Glue API key is not set."
        }

        $resolvedBaseUrl = $ITGlueBaseUrl.TrimEnd('/')
        $resolvedApiKey = (New-Object PSCredential 'user', $ITGlueApiKey).GetNetworkCredential().Password

        if ([string]::IsNullOrWhiteSpace($resolvedApiKey)) {
            throw "Resolved IT Glue API key is empty."
        }

        $headers = @{
            'x-api-key'     = $resolvedApiKey
            'Content-Type'  = 'application/vnd.api+json'
        }

        if (-not $PasswordId) {
            $listResult = $null
            $listBody = $null
            $listStatusCode = 200

            if (Get-Command -Name Get-ITGluePasswords -ErrorAction SilentlyContinue) {
                $listUri = "Get-ITGluePasswords -page_size 1"
                $listResult = Get-ITGluePasswords -page_size 1
                $listBody = $listResult
            } else {
                $listUri = "$resolvedBaseUrl/passwords?page[size]=1"
                $listResponse = Invoke-WebRequest `
                    -Method Get `
                    -Uri $listUri `
                    -Headers $headers `
                    -ContentType 'application/vnd.api+json' `
                    -SkipHttpErrorCheck `
                    -ErrorAction Stop

                $listStatusCode = [int]$listResponse.StatusCode
                $listBody = if ([string]::IsNullOrWhiteSpace($listResponse.Content)) {
                    $null
                } else {
                    $listResponse.Content | ConvertFrom-Json -Depth 20 -ErrorAction Stop
                }
            }

            if ($null -eq $listBody) {
                $result = [pscustomobject]@{
                    Success       = $false
                    Determined    = $true
                    StatusCode    = $listStatusCode
                    ListUri       = $listUri
                    ShowUri       = $null
                    PasswordId    = $null
                    Message       = "IT Glue password list request did not return usable data."
                    ResponseBody  = $listResult
                }

                if ($ThrowOnFailure) {
                    throw $result.Message
                }

                Write-Warning $result.Message
                if ($Detailed) { return $result }
                return $false
            }

            $PasswordId = $listBody.data | Select-Object -First 1 -ExpandProperty id
            if (-not $PasswordId) {
                $result = [pscustomobject]@{
                    Success       = $false
                    Determined    = $false
                    StatusCode    = $listStatusCode
                    ListUri       = $listUri
                    ShowUri       = $null
                    PasswordId    = $null
                    Message       = "IT Glue password records are accessible, but no passwords exist to verify whether the API key can read password values."
                    ResponseBody  = $listBody
                }

                Write-Warning $result.Message
                if ($ThrowOnFailure) {
                    throw $result.Message
                }
                if ($Detailed) { return $result }
                return $false
            }
        }

        $showBody = $null
        if (Get-Command -Name Get-ITGluePasswords -ErrorAction SilentlyContinue) {
            $showUri = "Get-ITGluePasswords -id $PasswordId -show_password `$true"
            $showBody = Get-ITGluePasswords -id $PasswordId -show_password $true
            $showStatusCode = if ($null -ne $showBody) { 200 } else { $null }
        } else {
            $showUri = "$resolvedBaseUrl/passwords/${PasswordId}?show_password=true"
            $showResponse = Invoke-WebRequest `
                -Method Get `
                -Uri $showUri `
                -Headers $headers `
                -ContentType 'application/vnd.api+json' `
                -SkipHttpErrorCheck `
                -ErrorAction Stop

            $showStatusCode = [int]$showResponse.StatusCode
            $showBody = if ([string]::IsNullOrWhiteSpace($showResponse.Content)) {
                $null
            } else {
                $showResponse.Content | ConvertFrom-Json -Depth 20 -ErrorAction Stop
            }
        }

        $passwordAttributes = $showBody.data.attributes
        $passwordProperty = if ($null -ne $passwordAttributes) {
            $passwordAttributes.PSObject.Properties['password']
        } else {
            $null
        }
        $hasPasswordValueAccess = (
            $showStatusCode -ge 200 -and
            $showStatusCode -lt 300 -and
            $null -ne $passwordProperty -and
            $null -ne $passwordProperty.Value
        )

        $message = if ($hasPasswordValueAccess) {
            "IT Glue API key can read password values from the Passwords API."
        } elseif ($showStatusCode -eq 401) {
            "IT Glue rejected the password details request with 401 Unauthorized."
        } elseif ($showStatusCode -eq 403) {
            "IT Glue rejected the password details request with 403 Forbidden."
        } elseif ($showStatusCode -ge 200 -and $showStatusCode -lt 300) {
            "IT Glue returned the password record, but not the password value. This usually means the API key can list password metadata but does not have Password Access enabled."
        } else {
            "IT Glue returned HTTP $showStatusCode while checking password value access."
        }

        $result = [pscustomobject]@{
            Success       = $hasPasswordValueAccess
            Determined    = $true
            StatusCode    = $showStatusCode
            ListUri       = $listUri
            ShowUri       = $showUri
            PasswordId    = $PasswordId
            Message       = $message
            ResponseBody  = $showBody
        }
    } catch {
        $result = [pscustomobject]@{
            Success       = $false
            Determined    = $false
            StatusCode    = $null
            ListUri       = $listUri
            ShowUri       = $showUri
            PasswordId    = $PasswordId
            Message       = "Failed to verify IT Glue password value access: $($_.Exception.Message)"
            ResponseBody  = $_
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
