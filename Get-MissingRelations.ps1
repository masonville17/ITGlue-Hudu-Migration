
function Get-RelatedToDoc {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$ITGKey,

        [Parameter(Mandatory = $true)]
        [long]$OrganizationId,

        [Parameter(Mandatory = $true)]
        [long]$DocID,

        [string]$ITGlue_Base_URI = 'https://api.itglue.com'
    )

    if ($OrganizationId -le 0 -or $DocID -le 0) {
        Write-Warning "Skipping ITGlue document lookup because doc/org id is invalid. DocID=$DocID OrganizationId=$OrganizationId"
        return
    }

    $headers = @{
        'x-api-key'    = $ITGKey
        'Content-Type' = 'application/vnd.api+json'
    }

    $baseUri = $ITGlue_Base_URI.TrimEnd('/')
    $uri = "$baseUri/organizations/$OrganizationId/relationships/documents/$DocID"

    try {
        Invoke-RestMethod -Method GET -Uri $uri -Headers $headers
    }
    catch {
        Write-Warning "Failed to retrieve ITGlue document $DocID for organization $OrganizationId"
        if ($_.ErrorDetails.Message) {
            Write-Warning $_.ErrorDetails.Message
        } else {
            Write-Warning $_.Exception.Message
        }
    }
}
function Convert-ITGlueTypeToRelationAssetType {
    param(
        [string]$TypeName
    )

    switch -Regex (($TypeName ?? '').Trim().ToLower()) {
        '^flexible[-_\s]?assets?$' { return 'flexible_asset' }
        '^configurations?$' { return 'configuration' }
        '^passwords?$' { return 'password' }
        '^documents?$' { return 'document' }
        '^contacts?$' { return 'contact' }
        '^locations?$' { return 'location' }
        '^organizations?$' { return 'organization' }
        '^companies$' { return 'organization' }
        '^domains?$' { return 'domain' }
        '^websites?$' { return 'domain' }
        default { return $null }
    }
}
function Resolve-ITGlueRelationReference {
    param(
        $ITGlueRelationObject
    )

    if (-not $ITGlueRelationObject) {
        return $null
    }

    $AssetType = $null
    $ResourceId = $null

    if ($ITGlueRelationObject.attributes.'asset-type' -and $ITGlueRelationObject.attributes.'resource-id') {
        $AssetType = Convert-ITGlueTypeToRelationAssetType -TypeName $ITGlueRelationObject.attributes.'asset-type'
        $ResourceId = $ITGlueRelationObject.attributes.'resource-id'
    }
    elseif ($ITGlueRelationObject.attributes.'destination_type' -and $ITGlueRelationObject.attributes.'destination_id') {
        $AssetType = Convert-ITGlueTypeToRelationAssetType -TypeName $ITGlueRelationObject.attributes.'destination_type'
        $ResourceId = $ITGlueRelationObject.attributes.'destination_id'
    }
    elseif ($ITGlueRelationObject.type -and $ITGlueRelationObject.id) {
        $AssetType = Convert-ITGlueTypeToRelationAssetType -TypeName $ITGlueRelationObject.type
        $ResourceId = $ITGlueRelationObject.id
    }

    if (-not $AssetType -or -not $ResourceId) {
        return $null
    }

    return [pscustomobject]@{
        AssetType  = $AssetType
        ResourceId = [string]$ResourceId
    }
}
function Get-HuduIdFromItglueObject {
    param(
        $ITGObjectId,
        $AssetType
    )

    $ITGObjectId = [string]$ITGObjectId
    $FoundHuduObject = $null
    $FoundHuduAssetType = $null

    switch ($AssetType) {
        'configuration' {
            $FoundHuduObject = $MatchedConfigurationMap[$ITGObjectId].HuduObject
            $FoundHuduAssetType = "Asset"
        }
        'document' {
            $FoundHuduObject = $MatchedArticleMap[$ITGObjectId].HuduObject
            $FoundHuduAssetType = 'Article'
        }
        'contact' {
            $FoundHuduObject = $MatchedContactMap[$ITGObjectId].HuduObject
            $FoundHuduAssetType = 'Asset'
        }
        'flexible_asset' {
            $FoundHuduObject = $MatchedAssetMap[$ITGObjectId].HuduObject
            $FoundHuduAssetType = "Asset"
        }
        'location' {
            $FoundHuduObject = $MatchedLocationMap[$ITGObjectId].HuduObject
            $FoundHuduAssetType = "Asset"
        }
        'password' {
            $FoundHuduObject = $MatchedPasswordMap[$ITGObjectId].HuduObject
            $FoundHuduAssetType = 'AssetPassword'
        }
        'organization' {
            $FoundHuduObject = $MatchedCompanyMap[$ITGObjectId].HuduCompanyObject
            $FoundHuduAssetType = 'Company'
        }
        'domain' {
            $FoundHuduObject = $MatchedWebsiteMap[$ITGObjectId].HuduObject
            $FoundHuduAssetType = 'Website'
        }
    }

    if ($FoundHuduObject) {
        return [pscustomobject]@{
            HuduObject = $FoundHuduObject
            Type       = $FoundHuduAssetType
        }
    }
    else {
        Write-Warning "Unable to match ITGlue $AssetType to Hudu object for ITG object $ITGObjectId"
    }
}
function Get-SingleRelationValue {
    param(
        $Value,
        [string]$Label
    )

    $Values = @($Value | Where-Object { $null -ne $_ -and "$_".Trim() -ne '' } | Select-Object -Unique)
    if ($Values.Count -eq 1) {
        return $Values[0]
    }

    if ($Values.Count -gt 1) {
        Write-Warning "Skipping relation because $Label resolved to multiple values: $($Values -join ', ')"
    }

    return $null
}
function Get-ArticleLookupInfo {
    param(
        $Article
    )

    $ResolvedDocId = Get-SingleRelationValue -Value @(
        $Article.ITGID
        $Article.ITGObject.id
    ) -Label 'Document ITGID'

    $ResolvedOrganizationId = Get-SingleRelationValue -Value @(
        $Article.Company.ITGID
        $Article.Company.ITGCompanyObject.id
        $Article.ITGObject.attributes.'organization-id'
    ) -Label 'Document OrganizationId'

    if (-not $ResolvedDocId -or -not $ResolvedOrganizationId) {
        return $null
    }

    return [pscustomobject]@{
        DocID          = [long]$ResolvedDocId
        OrganizationId = [long]$ResolvedOrganizationId
    }
}
function Get-HuduRelationObject {
    param(
        $ITGlueSourceObjects
    )

    $NewHuduRelations = foreach ($ITGlueSourceObject in $ITGlueSourceObjects) {
        $AssetType = Convert-ITGlueTypeToRelationAssetType -TypeName $ITGlueSourceObject.data.type
        if (-not $AssetType) { continue }

        $FromableHudu = Get-HuduIdFromItglueObject -AssetType $AssetType -ITGObjectId $ITGlueSourceObject.data.id
        if (-not $FromableHudu) { continue }

        Write-Host "Determining Hudu objects for source $AssetType / ITGID: $($ITGlueSourceObject.data.id)" -ForegroundColor Cyan

        foreach ($LinkedITGlueObject in @($ITGlueSourceObject.included) + @($ITGlueSourceObject.data.relationships.'related-items'.data)) {
            $LinkedReference = Resolve-ITGlueRelationReference -ITGlueRelationObject $LinkedITGlueObject
            if (-not $LinkedReference) { continue }

            $LinkedHuduItem = Get-HuduIdFromItglueObject -AssetType $LinkedReference.AssetType -ITGObjectId $LinkedReference.ResourceId
            if ($LinkedHuduItem) {
                $FromableType = Get-SingleRelationValue -Value $FromableHudu.type -Label 'FromableType'
                $FromableID = Get-SingleRelationValue -Value $FromableHudu.HuduObject.id -Label 'FromableID'
                $ToableType = Get-SingleRelationValue -Value $LinkedHuduItem.type -Label 'ToableType'
                $ToableID = Get-SingleRelationValue -Value $LinkedHuduItem.HuduObject.id -Label 'ToableID'

                if (-not $FromableType -or -not $FromableID -or -not $ToableType -or -not $ToableID) {
                    continue
                }

                [pscustomobject]@{
                    FromableType = [string]$FromableType
                    FromableID   = [int]$FromableID
                    ToableType   = [string]$ToableType
                    ToableID     = [int]$ToableID
                }
            }
        }
    }

    return $NewHuduRelations
}


if (-not $MatchedAssets) {$MatchedAssets = (Get-Content -path "$MigrationLogs\Assets.json" | ConvertFrom-json -depth 100) }
if (-not $matchedConfigurations) {$matchedConfigurations = (Get-Content -path "$MigrationLogs\Configurations.json" | ConvertFrom-json -depth 100) }
if (-not $MatchedPasswords) {$MatchedPasswords = (Get-Content -path "$MigrationLogs\Passwords.json" | ConvertFrom-json -depth 100) }
if (-not $MatchedContacts) {$MatchedContacts = (Get-Content -path "$MigrationLogs\Contacts.json" | ConvertFrom-json -depth 100) }
if (-not $MatchedArticles) {$MatchedArticles = (Get-Content -path "$MigrationLogs\Articles.json" | ConvertFrom-json -depth 100) }
if (-not $MatchedLocations) {$MatchedLocations = (Get-Content -path "$MigrationLogs\Locations.json" | ConvertFrom-json -depth 100) }
if (-not $MatchedPasswords) {$MatchedPasswords = (Get-Content -path "$MigrationLogs\Passwords.json" | ConvertFrom-json -depth 100) }
if (-not $MatchedWebsites) {$MatchedWebsites = (Get-Content -path "$MigrationLogs\websites.json" | ConvertFrom-json -depth 100) }


write-host "refreshing $($MatchedAssets.count) assets"
$FreshITGAssets= $MatchedAssets |% { Get-ITGlueFlexibleAssets -id $_.ITGObject.id -include related_items}
$RelatedAssets = $FreshITGAssets |? {$_.data.relationships.'related-items'.data}

write-host "refreshing $($MatchedConfigurations.count) configs"
$FreshConfigurations = $MatchedConfigurations | % {Get-ITGlueConfigurations -id $_.itgobject.id -include related_items}
$RelatedConfigurations = $FreshConfigurations |? {$_.data.relationships.'related-items'.data}

write-host "refreshing $($MatchedPasswords.count) passwords"
$FreshPasswords = $MatchedPasswords | % {Get-ITGluePasswords -id $_.itgobject.id -include related_items}
$RelatedPasswords = $FreshPasswords |? {$_.data.relationships.'related-items'.data}

write-host "refreshing $($MatchedContacts.count) contacts"
$FreshContacts = $MatchedContacts | % {Get-ITGlueContacts -id $_.ITGObject.id -include related_items}
$RelatedContacts = $FreshContacts |? {$_.data.relationships.'related-items'.data}

write-host "refreshing $($MatchedArticles.count) articles"
$FreshDocuments = $MatchedArticles | ForEach-Object {
    $ArticleLookup = Get-ArticleLookupInfo -Article $_
    if ($ArticleLookup) {
        Get-RelatedToDoc -DocID $ArticleLookup.DocID -OrganizationId $ArticleLookup.OrganizationId -ITGKey $ITGKey -ITGlue_Base_URI $settings.ITGAPIEndpoint
    }
}
$RelatedDocuments = $FreshDocuments | Where-Object {
    $_.data.relationships.'related-items'.data
}

write-host "mapping configs"
$MatchedConfigurationMap = @{}
$MatchedConfigurations | ForEach-Object { $MatchedConfigurationMap[[string]$_.ITGID] = $_ }

write-host "mapping articles"
$MatchedArticleMap = @{}
$MatchedArticles | ForEach-Object { $MatchedArticleMap[[string]$_.ITGID] = $_ }

write-host "mapping contacts"
$MatchedContactMap = @{}
$MatchedContacts | ForEach-Object { $MatchedContactMap[[string]$_.ITGID] = $_ }

write-host "mapping assets"
$MatchedAssetMap = @{}
$MatchedAssets | ForEach-Object { $MatchedAssetMap[[string]$_.ITGID] = $_ }

write-host "mapping companies"
$MatchedCompanyMap = @{}
$MatchedCompanies | ForEach-Object { $MatchedCompanyMap[[string]$_.ITGID] = $_ }

write-host "mapping locations"
$MatchedLocationMap = @{}
$MatchedLocations | ForEach-Object { $MatchedLocationMap[[string]$_.ITGID] = $_ }

write-host "mapping passwords"
$MatchedPasswordMap = @{}
$MatchedPasswords | ForEach-Object { $MatchedPasswordMap[[string]$_.ITGID] = $_ }

write-host "mapping websites"
$MatchedWebsiteMap = @{}
$MatchedWebsites | ForEach-Object { $MatchedWebsiteMap[[string]$_.ITGID] = $_ }

$DocumentRelationsToCreate = Get-HuduRelationObject -ITGlueSourceObjects $RelatedDocuments
$ContactRelationsToCreate = Get-HuduRelationObject -ITGlueSourceObjects $RelatedContacts
$ConfigurationRelationsToCreate = Get-HuduRelationObject -ITGlueSourceObjects $RelatedConfigurations
$AssetRelationsToCreate = Get-HuduRelationObject -ITGlueSourceObjects $RelatedAssets
$PasswordRelationsToCreate = Get-HuduRelationObject -ITGlueSourceObjects $RelatedPasswords



$AllRelationsToCreate =
    @($AssetRelationsToCreate) +
    @($DocumentRelationsToCreate) +
    @($ContactRelationsToCreate) +
    @($PasswordRelationsToCreate) +
    @($ConfigurationRelationsToCreate) |
    Where-Object { $_ } |
    Sort-Object FromableType, FromableID, ToableType, ToableID -Unique


if (get-command -name Set-HapiErrorsDirectory -ErrorAction SilentlyContinue){try {Set-HapiErrorsDirectory -skipRetry $true} catch {}}
write-host "Creating approximately $($AllRelationsToCreate.count) relations"
$NewRelationsCreated = @(
    $AllRelationsToCreate | ForEach-Object {
        New-HuduRelation -FromableType $_.FromableType -FromableID $_.FromableID -ToableType $_.ToableType -ToableID $_.ToableID
    }
)

$AllRelationsToCreate | ConvertTo-Json -Depth 75 | Out-File (Join-Path $settings.MigrationLogs 'relations-to-create.json')
$NewRelationsCreated | ConvertTo-Json -Depth 75 | Out-File (Join-Path $settings.MigrationLogs 'relations-created.json')
