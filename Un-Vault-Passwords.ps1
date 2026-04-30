$csvpath = $null
while ([string]::IsNullOrWhiteSpace($csvpath) -or -not (Test-Path -Path $csvpath -PathType Leaf)) {
    $csvpath = Read-Host "Please enter the path to the CSV file containing the unvaulted passwords (or type 'exit' to quit)"
    if ($csvpath -eq 'exit') {
        Write-Host "Exiting script."
        return
    }
    if (-not (Test-Path -Path $csvpath -PathType Leaf)) {
        Write-Warning "The file path you entered does not exist or is not a file. Please try again."
        $csvpath = $null
    }
}

$MatchedPasswordsJson =  "$MigrationLogs\Passwords.json"
$MatchedPasswords = $MatchedPasswords ?? $(Get-Content -LiteralPath $MatchedPasswordsJson -Raw | ConvertFrom-Json -Depth 100)
$unvaultedpasswords = Import-Csv -Path $csvpath

$hudupasswords = Get-HuduPasswords | Where-Object { $_.password -ilike "A256GCM.*" }
if ($hudupasswords.Count -eq 0 -or ($unvaultedpasswords.Count -eq 0)) {
    Write-Warning "No Hudu passwords with A256GCM format found or no unvaulted passwords found. Please ensure you have the correct JSON file and CSV file and that they contain the expected data."
    return
}
function Get-PropertyValueSafe {
    param(
        [Parameter(Mandatory = $true)]
        $Object,

        [Parameter(Mandatory = $true)]
        [string]$PropertyName
    )

    if ($null -eq $Object) {
        return $null
    }

    $property = $Object.PSObject.Properties[$PropertyName]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Get-NestedPropertyValueSafe {
    param(
        [Parameter(Mandatory = $true)]
        $Object,

        [Parameter(Mandatory = $true)]
        [string[]]$Path
    )

    $current = $Object
    foreach ($segment in $Path) {
        if ($null -eq $current) {
            return $null
        }

        $current = Get-PropertyValueSafe -Object $current -PropertyName $segment
    }

    return $current
}

function Get-PasswordIdFromItGlueUrl {
    param(
        [string]$Url
    )

    if ([string]::IsNullOrWhiteSpace($Url)) {
        return $null
    }

    $match = [regex]::Match($Url, '/passwords/(\d+)(?:$|[/?#])', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success) {
        return $null
    }

    return $match.Groups[1].Value
}

function Get-FirstNonEmptyString {
    param(
        [AllowNull()]
        [object[]]$Values
    )

    if ($null -eq $Values) {
        return $null
    }

    foreach ($value in $Values) {
        if ($null -eq $value) {
            continue
        }

        $stringValue = [string]$value
        if (-not [string]::IsNullOrWhiteSpace($stringValue)) {
            return $stringValue
        }
    }

    return $null
}

$matchedByHuduId = @{}
foreach ($matchedPassword in @($MatchedPasswords)) {
    $possibleHuduIds = @(
        (Get-PropertyValueSafe -Object $matchedPassword -PropertyName 'HuduID'),
        (Get-NestedPropertyValueSafe -Object $matchedPassword -Path @('HuduObject', 'id'))
    )

    foreach ($possibleHuduId in $possibleHuduIds) {
        $key = Get-FirstNonEmptyString -Values @($possibleHuduId)
        if ([string]::IsNullOrWhiteSpace($key)) {
            continue
        }

        if (-not $matchedByHuduId.ContainsKey($key)) {
            $matchedByHuduId[$key] = $matchedPassword
        }
    }
}

$csvByItgId = @{}
foreach ($csvPassword in @($unvaultedpasswords)) {
    $csvId = Get-FirstNonEmptyString -Values @(
        (Get-PropertyValueSafe -Object $csvPassword -PropertyName 'id'),
        (Get-PropertyValueSafe -Object $csvPassword -PropertyName 'ID')
    )

    if ([string]::IsNullOrWhiteSpace($csvId)) {
        continue
    }

    if (-not $csvByItgId.ContainsKey($csvId)) {
        $csvByItgId[$csvId] = $csvPassword
    }
}

$MatchedFromJson = foreach ($pass in @($hudupasswords)) {
    $huduId = [string]$pass.id
    $match = $matchedByHuduId[$huduId]

    $itgId = Get-FirstNonEmptyString -Values @(
        (Get-PropertyValueSafe -Object $match -PropertyName 'ITGID'),
        (Get-NestedPropertyValueSafe -Object $match -Path @('ITGObject', 'id')),
        (Get-PasswordIdFromItGlueUrl -Url (Get-NestedPropertyValueSafe -Object $match -Path @('HuduObject', 'login_url'))),
        (Get-PasswordIdFromItGlueUrl -Url (Get-PropertyValueSafe -Object $pass -PropertyName 'login_url'))
    )

    $csvUnvault = if ($itgId) { $csvByItgId[[string]$itgId] } else { $null }
    $passwordUnvaulted = if ($csvUnvault) { $csvUnvault.password } else { "Not Found in CSV" }

    if ($match) {
        Write-Host "Matched Hudu ID $huduId to ITG ID $itgId"
    } else {
        Write-Host "No matched JSON row found for Hudu ID $huduId"
    }

    [PSCustomObject]@{
        HuduID            = $huduId
        ITGID             = $itgId
        Name              = $pass.name
        HuduPassword      = $pass.password
        UnvaultedPassword = $passwordUnvaulted
        MatchedInJson     = if ($match) { "Yes" } else { "No" }
        FoundInCsv        = if ($csvUnvault) { "Yes" } else { "No" }
        MatchSource       = if ($match) { "MatchedPasswords.json" } else { "NotFound" }
        MatchedJson       = $match
        CsvRow            = $csvUnvault
    }
}
Write-Host "Please review the matched results below. When you're ready, press Enter to continue with updating Hudu passwords based on the unvaulted passwords from the CSV. If you want to exit without making changes, perform a CTRL+C to stop the script."
$MatchedFromJson
read-host "If you want to exit without making changes, perform a CTRL+C to stop the script. Otherwise, press Enter to continue with updating Hudu passwords based on the unvaulted passwords from the CSV."

$MatchedFromJJson | Where-Object {$_.MatchedInJson -eq "Yes" -and $_.FoundInCsv -eq "Yes"} | ForEach-Object {Set-HuduPassword -id $_.HuduID -Password $_.UnvaultedPassword}

write-host "All set- you can repeat for other companies with vaulted passwords." -ForegroundColor Green