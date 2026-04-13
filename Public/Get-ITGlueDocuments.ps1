function Get-ITGDocuments {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$ITGKey,

        [Parameter(Mandatory = $true)]
        [long]$OrganizationId,

        [Nullable[long]]$DocumentFolderId = $null,

        [int]$PageSize = 1000,

        [string]$ITGlue_Base_URI = 'https://api.itglue.com'
    )

    $headers = @{
        'x-api-key'    = $ITGKey
        'Content-Type' = 'application/vnd.api+json'
    }

    $baseUri = $ITGlue_Base_URI.TrimEnd('/')
    $allDocs = @()
    $page = 1

    do {
        $uriBuilder = [System.UriBuilder]::new("$baseUri/organizations/$OrganizationId/relationships/documents")
        $query = [System.Web.HttpUtility]::ParseQueryString([string]::Empty)
        $query['page[number]'] = $page
        $query['page[size]']   = $PageSize

        if ($null -ne $DocumentFolderId) {
            $query['filter[document_folder_id]'] = $DocumentFolderId
        }

        $uriBuilder.Query = $query.ToString()
        $uri = $uriBuilder.Uri.AbsoluteUri

        try {
            $resp = Invoke-RestMethod -Method GET -Uri $uri -Headers $headers
            $batch = @($resp.data)
            $allDocs += $batch
            $page++
        }
        catch {
            Write-Error "Failed to retrieve ITGlue documents for organization $OrganizationId from '$uri': $($_.Exception.Message)"
            break
        }
    }
    while ($batch.Count -gt 0)

    return $allDocs
}

