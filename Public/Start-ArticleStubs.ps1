if (-not (Get-Command -Name Resolve-ArticleFolderPath -ErrorAction SilentlyContinue)) {
    . "$PSScriptRoot\Resolve-ArticleFolderPath.ps1"
}

function Start-ArticleStubs {
    param(
        [Parameter(Mandatory)]$Document,
        [Parameter(Mandatory)]$Files,
        [Parameter(Mandatory)][string]$ITGDocumentsPath,
        [Parameter(Mandatory)]$MatchedCompanies,
        $GlobalKBFolder,
        [switch]$IncludeIgnoredFirstDirectory
    )
            Write-Host "Starting $($doc.name)" -ForegroundColor Green
            $dir = $files | Where-Object { $_.PSIsContainer -eq $true -and $_.Name -match $doc.locator }
			# ITGlue sometimes has export oddities like multiple folders for the same article or various names on the articles. This is assuming only one HTML file.
			$DocumentFile = Get-ChildItem $dir -filter *.htm*
			if (-not $DocumentFile)  {
				Write-Host "HTML Files were not found under $($dir.fullname) this article will need to be migrated manually" -foregroundcolor red
				$Article = [PSCustomObject]@{
					"Name"       = $doc.name
					"Filename"   = $Filename
					"Path"       = $($dir.Fullname)
					"FullPath"   = $null
					"ITGID"      = $doc.id
					"ITGLocator" = $doc.locator
					"HuduID"     = $null
					"HuduObject" = $null
					"Folders"    = $folders
					"Imported"   = "Skipped - Missing File"
					"Company"    = $company
				}
				continue
			}
			elseif ($DocumentFile.count -gt 1) {Write-Warning "Found more than one HTML file for this article. This is a warning only"}
            $folderResolution = Resolve-ArticleFolderPath -BasePath $ITGDocumentsPath -FullPath $DocumentFile.Directory.FullName
            $RelativePath = $folderResolution.RelativePath
            $folders = $folderResolution.FolderSegments
            $foldersToInitialize = $folderResolution.FoldersToInitialize
            $FilenameFromFolder = $folderResolution.FilenameFromFolder
            # Disabling this line and using the found file name
			# $Filename = $FilenameFromFolder
			$Filename = $DocumentFile.name
            $company = $MatchedCompanies | Where-Object { $_.CompanyName -eq $doc.organization }


            if (($company | Measure-Object).count -eq 1) {

                $art_folder_id = $null
                if ($company.InternalCompany -eq $false) {
                    if ($foldersToInitialize.Count -gt 0) {
                        $art_folder_id = (Initialize-HuduFolder $foldersToInitialize -company_id $company.HuduID).id
                    }
                    $ArticleSplat = @{
                        name       = $doc.name
                        content    = "Migration in progress"
                        company_id = $company.HuduID
                        folder_id  = $art_folder_id
                    }	
                } else {
                    if ($foldersToInitialize.Count -gt 0) {
                        $targetFolders = @($foldersToInitialize)
                        if ($GlobalKBFolder) {
                            $targetFolders = @($GlobalKBFolder.name) + $targetFolders
                        }
                        $art_folder_id = (Initialize-HuduFolder $targetFolders).id
                    }
                    else {
                        # Check for GlobalKB Folder being set
                        if ($GlobalKBFolder) {
                            $art_folder_id = $GlobalKBFolder.id
                        }
                    }
                    $ArticleSplat = @{
                        name      = $doc.name
                        content   = "Migration in progress"
                        folder_id = $art_folder_id
                    }	
                }
		



            } else {
                Write-Host "Company $($doc.organization) Not Found Please migrate $($doc.name) manually"
                continue
            }


            $NewArticle = (New-HuduArticle @ArticleSplat).article
            if ($company.InternalCompany -eq $false) {
                Write-Host "Article created in $($company.CompanyName)"
            } else {
                Write-Host "Article created in GlobaL KB"
            }

            $Article = [PSCustomObject]@{
                "Name"       = $doc.name
                "Filename"   = $Filename
                "Path"       = $DocumentFile.Directory.FullName
                "FullPath"   = $DocumentFile.fullname
                "ITGID"      = $doc.id
                "ITGLocator" = $doc.locator
                "HuduID"     = $NewArticle.ID
                "HuduObject" = $NewArticle
                "Folders"    = $folders
                "Imported"   = "Stub-Created"
                "Company"    = $company
            }
return $Article
}
