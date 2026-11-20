<#
.SYNOPSIS
    Review the Recycle Bin without Explorer: filter, preview, then restore or permanently delete.

.DESCRIPTION
    Reads the Recycle Bin directly from disk (much faster than Explorer on slow drives),
    lets you filter by file type, original folder, name, size and dates (deleted, created,
    modified), copies a selection to a staging folder for previewing, and then permanently
    deletes, restores, or keeps the selection. Staging copies are removed afterwards and every
    delete/restore is logged to pattie-photo-log.csv in the staging folder.

    For scripted use, import the module instead:
        Import-Module .\PattiePhoto.psm1
        Get-BinItem | Select-BinItem -Extension jpg -DeletedBefore 2024-01-01 | Remove-BinItem -WhatIf

.PARAMETER StagingPath
    Folder for preview copies and the action log. Ideally on a different disk.

.PARAMETER AllUsers
    Include every user's Recycle Bin (run PowerShell as Administrator).

.PARAMETER BinPath
    Only read these bin folders, e.g. 'E:\$Recycle.Bin\S-1-5-21-...'.

.EXAMPLE
    .\pattie-photo.ps1 -StagingPath D:\BinPreview
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$StagingPath,
    [switch]$AllUsers,
    [string[]]$BinPath
)

Import-Module (Join-Path $PSScriptRoot 'PattiePhoto.psm1') -Force
Start-BinReview @PSBoundParameters
