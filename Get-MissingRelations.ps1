
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
function Get-HuduIdFromItglueObject {
    param(
        $ITGObjectId,
        $AssetType
    )

    $ITGObjectId = [string]$ITGObjectId
    $FoundHuduAsset = $null
    $FoundHuduAssetType = $null

    switch ($AssetType) {
        'configuration' {
            $FoundHuduAsset = $MatchedConfigurationMap[$ITGObjectId]
            $FoundHuduAssetType = $FoundHuduAsset.HuduObject.object_type
        }
        'document' {
            $FoundHuduAsset = $MatchedArticleMap[$ITGObjectId]
            $FoundHuduAssetType = 'Article'
        }
        'flexible_asset' {
            $FoundHuduAsset = $MatchedAssetMap[$ITGObjectId]
            $FoundHuduAssetType = $FoundHuduAsset.HuduObject.object_type
        }
        'location' {
            $FoundHuduAsset = $MatchedLocationMap[$ITGObjectId]
            $FoundHuduAssetType = $FoundHuduAsset.HuduObject.object_type
        }
        'password' {
            $FoundHuduAsset = $MatchedPasswordMap[$ITGObjectId]
            $FoundHuduAssetType = 'AssetPassword'
        }
    }

    if ($FoundHuduAsset) {
        return [pscustomobject]@{
            HuduObject = $FoundHuduAsset.HuduObject
            Type       = $FoundHuduAssetType
        }
    }
    else {
        Write-Warning "Unable to match ITGlue $AssetType to Hudu object for ITG object $ITGObjectId"
    }
}
function Get-HuduRelationObject {
    param(
        $ITGlueSourceObjects
    )

    $NewHuduRelations = foreach ($ITGlueSourceObject in $ITGlueSourceObjects) {
        switch ($ITGlueSourceObject.data.type) {
            'flexible-assets' { $AssetType = 'flexible_asset' }
            'configurations'  { $AssetType = 'configuration' }
            'passwords'       { $AssetType = 'password' }
            'documents'       { $AssetType = 'document' }
            default { continue }
        }

        $FromableHudu = Get-HuduIdFromItglueObject -AssetType $AssetType -ITGObjectId $ITGlueSourceObject.data.id
        if (-not $FromableHudu) { continue }

        Write-Host "Determining Hudu objects for source $AssetType / ITGID: $($ITGlueSourceObject.data.id)" -ForegroundColor Cyan

        if (@($ITGlueSourceObject.included).Count -gt 0) {
              foreach ($LinkedITGlueObject in $ITGlueSourceObject.included) {
                $LinkedAssetType = $LinkedITGlueObject.attributes.'asset-type'
                $LinkedResourceId = $LinkedITGlueObject.attributes.'resource-id'

                if (-not $LinkedAssetType -or -not $LinkedResourceId) { continue }

                $LinkedHuduItem = Get-HuduIdFromItglueObject -AssetType $LinkedAssetType -ITGObjectId $LinkedResourceId
                if ($LinkedHuduItem) {
                    [pscustomobject]@{
                        FromableType = $FromableHudu.type
                        FromableID   = $FromableHudu.HuduObject.id
                        ToableType   = $LinkedHuduItem.type
                        ToableID     = $LinkedHuduItem.HuduObject.id
                    }
                }
            }
        }
        else {
            foreach ($LinkedRef in $ITGlueSourceObject.data.relationships.'related-items'.data) {
                $LinkedAssetType = $LinkedRef.attributes.'asset-type'
                $LinkedResourceId = $LinkedRef.attributes.'resource-id'

                if (-not $LinkedAssetType -or -not $LinkedResourceId) {
                    Write-Warning "Document relation reference missing asset-type/resource-id for source ITGID $($ITGlueSourceObject.data.id)"
                    continue
                }

                
                $LinkedHuduItem = Get-HuduIdFromItglueObject -AssetType $LinkedAssetType -ITGObjectId $LinkedResourceId
                if ($LinkedHuduItem) {
                    [pscustomobject]@{
                        FromableType = $FromableHudu.type
                        FromableID   = $FromableHudu.HuduObject.id
                        ToableType   = $LinkedHuduItem.type
                        ToableID     = $LinkedHuduItem.HuduObject.id
                    }
                }
            }
        }
    }

    return $NewHuduRelations
}


$FreshITGAssets= $MatchedAssets |% { Get-ITGlueFlexibleAssets -id $_.ITGObject.id -include related_items}
$RelatedAssets = $FreshITGAssets |? {$_.data.relationships.'related-items'.data}


$FreshConfigurations = $MatchedConfigurations | % {Get-ITGlueConfigurations -id $_.itgobject.id -include related_items}
$RelatedConfigurations = $FreshConfigurations |? {$_.data.relationships.'related-items'.data}

$FreshPasswords = $MatchedPasswords | % {Get-ITGluePasswords -id $_.itgobject.id -include related_items}
$RelatedPasswords = $FreshPasswords |? {$_.data.relationships.'related-items'.data}




$FreshDocuments = $MatchedArticles | ForEach-Object {
    Get-RelatedToDoc -DocID $_.ITGObject.id -OrganizationId $_.ITGObject.attributes.'organization-id' -ITGKey $ITGKey
}

$RelatedDocuments = $FreshDocuments | Where-Object {
    $_.data.relationships.'related-items'.data
}


$MatchedConfigurationMap = @{}
$MatchedConfigurations | ForEach-Object { $MatchedConfigurationMap[[string]$_.ITGID] = $_ }

$MatchedArticleMap = @{}
$MatchedArticles | ForEach-Object { $MatchedArticleMap[[string]$_.ITGID] = $_ }

$MatchedAssetMap = @{}
$MatchedAssets | ForEach-Object { $MatchedAssetMap[[string]$_.ITGID] = $_ }

$MatchedLocationMap = @{}
$MatchedLocations | ForEach-Object { $MatchedLocationMap[[string]$_.ITGID] = $_ }

$MatchedPasswordMap = @{}
$MatchedPasswords | ForEach-Object { $MatchedPasswordMap[[string]$_.ITGID] = $_ }

$matchedCodumentsMap = @{}
$matchedDocuments | ForEach-Object { $matchedCodumentsMap[[string]$_.ITGID] = $_ }

$DocumentRelationsToCreate = Get-HuduRelationObject -ITGlueSourceObjects $RelatedDocuments
$ConfigurationRelationsToCreate = Get-HuduRelationObject -ITGlueSourceObjects $RelatedConfigurations
$AssetRelationsToCreate = Get-HuduRelationObject -ITGlueSourceObjects $RelatedAssets
$PasswordRelationsToCreate = Get-HuduRelationObject -ITGlueSourceObjects $RelatedPasswords



<# Uncomment and run the block below
$createdConfigurationRelations =  $ConfigurationRelationsToCreate | % {New-HuduRelation -FromableType $_.FromableType -FromableID $_.FromableID -ToableID $_.ToableID -ToableType $_.ToableType}
$createdAssetRelations =  $AssetRelationsToCreate | % {New-HuduRelation -FromableType $_.FromableType -FromableID $_.FromableID -ToableID $_.ToableID -ToableType $_.ToableType}
$createdPasswordRelations =  $PasswordRelationsToCreate | % {New-HuduRelation -FromableType $_.FromableType -FromableID $_.FromableID -ToableID $_.ToableID -ToableType $_.ToableType}
#>
@($AssetRelationsToCreate) + @($DocumentRelationsToCreate) + @($PasswordRelationsToCreate) + @($ConfigurationRelationsToCreate) | ForEach-Object {try {New-HuduRelation -FromableType  $_.FromableType -FromableID    $_.FromableID -ToableType    $_.ToableType -ToableID      $_.ToableID} catch {Write-Host "Skipped or errored: $_" -ForegroundColor Yellow}}
$AllRelationsToCreate =
    @($AssetRelationsToCreate) +
    @($DocumentRelationsToCreate) +
    @($PasswordRelationsToCreate) +
    @($ConfigurationRelationsToCreate) |
    Where-Object { $_ } |
    Sort-Object FromableType, FromableID, ToableType, ToableID -Unique


$AllRelationsToCreate | ForEach-Object {
    try {
        New-HuduRelation -FromableType $_.FromableType -FromableID $_.FromableID -ToableType $_.ToableType -ToableID $_.ToableID
    }
    catch {
        Write-Host "Skipped or errored creating relation: $($_.FromableType):$($_.FromableID) -> $($_.ToableType):$($_.ToableID)" -ForegroundColor Yellow
        Write-Host $_.Exception.Message -ForegroundColor DarkYellow
    }
}