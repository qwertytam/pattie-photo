<#
    PattiePhoto - review, preview, restore and permanently delete Recycle Bin items
    without going through Explorer.

    Each drive keeps deleted items in X:\$Recycle.Bin\<user SID>\ as pairs of files:
      $Ixxxxxx.ext  metadata: original path, size, date deleted
      $Rxxxxxx.ext  the deleted file itself (or a folder holding the deleted folder's contents)
    Reading these directly is much faster than the Shell / Explorer view.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:StagingPrefix = 'pattie-photo-staging-'

#region Reading the bin

function Read-RecycleBinInfoFile {
    <#
    .SYNOPSIS
        Parses a $I metadata file from the Recycle Bin.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 28) { throw "Not a valid Recycle Bin info file (too short): $Path" }

    $version = [BitConverter]::ToInt64($bytes, 0)
    $size = [BitConverter]::ToInt64($bytes, 8)
    $deleted = [DateTime]::FromFileTime([BitConverter]::ToInt64($bytes, 16))

    if ($version -eq 1) {
        # Vista - 8.1: fixed 260-character path buffer.
        $start = 24
        $byteCount = [Math]::Min(520, $bytes.Length - 24)
    } elseif ($version -eq 2) {
        # Windows 10+: 4-byte character count, then the path.
        $start = 28
        $byteCount = [Math]::Min([BitConverter]::ToInt32($bytes, 24) * 2, $bytes.Length - 28)
    } else {
        throw ("Unsupported Recycle Bin info file version {0}: {1}" -f $version, $Path)
    }

    $originalPath = [System.Text.Encoding]::Unicode.GetString($bytes, $start, $byteCount).Split([char]0)[0]

    [pscustomobject]@{
        Version      = $version
        Size         = $size
        DeletedDate  = $deleted
        OriginalPath = $originalPath
    }
}

function Get-RecycleBinFolder {
    <#
    .SYNOPSIS
        Returns the Recycle Bin folders for the current user (or all users) on local drives.
    #>
    [CmdletBinding()]
    param([switch]$AllUsers)

    $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
        if ($drive.DriveType -notin 'Fixed', 'Removable' -or -not $drive.IsReady) { continue }
        $root = Join-Path $drive.RootDirectory.FullName '$Recycle.Bin'
        if (-not (Test-Path -LiteralPath $root)) { continue }

        if ($AllUsers) {
            try {
                Get-ChildItem -LiteralPath $root -Directory -Force -Filter 'S-1-*' | ForEach-Object { $_.FullName }
            } catch {
                Write-Warning "Cannot list '$root': $($_.Exception.Message) Run PowerShell as Administrator to use -AllUsers."
            }
        } else {
            $path = Join-Path $root $sid
            if (Test-Path -LiteralPath $path) { $path }
        }
    }
}

function New-BinItemObject {
    param($File, [string]$OriginalPath, $Meta, [string]$InfoPath, [string]$ContainerPath, [bool]$InFolder)

    [pscustomobject]@{
        PSTypeName     = 'PattiePhoto.BinItem'
        Name           = [System.IO.Path]::GetFileName($OriginalPath)
        Extension      = [System.IO.Path]::GetExtension($OriginalPath).ToLowerInvariant()
        OriginalFolder = [System.IO.Path]::GetDirectoryName($OriginalPath)
        OriginalPath   = $OriginalPath
        Size           = $File.Length
        DeletedDate    = $Meta.DeletedDate
        CreatedDate    = $File.CreationTime
        ModifiedDate   = $File.LastWriteTime
        InFolder       = $InFolder
        BinPath        = $File.FullName
        InfoPath       = $InfoPath
        ContainerPath  = $ContainerPath
    }
}

function Get-BinItem {
    <#
    .SYNOPSIS
        Lists the files in the Recycle Bin. Files inside deleted folders are listed individually.
    .PARAMETER Path
        Specific bin folder(s) to read, e.g. 'E:\$Recycle.Bin\S-1-5-21-...'. Defaults to the
        current user's bin on every local drive.
    .PARAMETER AllUsers
        Read every user's bin (requires an elevated PowerShell).
    #>
    [CmdletBinding()]
    param(
        [string[]]$Path,
        [switch]$AllUsers
    )

    if (-not $Path) { $Path = @(Get-RecycleBinFolder -AllUsers:$AllUsers) }

    foreach ($bin in $Path) {
        # One directory listing per bin, then look entries up by name (avoids a disk hit per item).
        $entries = @{}
        foreach ($entry in @(Get-ChildItem -LiteralPath $bin -Force)) { $entries[$entry.Name] = $entry }

        foreach ($name in @($entries.Keys | Where-Object { $_ -like '$I*' })) {
            $info = $entries[$name]
            $dataName = '$R' + $name.Substring(2)
            if (-not $entries.ContainsKey($dataName)) {
                Write-Verbose "Skipping $($info.FullName): no matching data entry."
                continue
            }
            try {
                $meta = Read-RecycleBinInfoFile -Path $info.FullName
            } catch {
                Write-Warning $_.Exception.Message
                continue
            }

            $data = $entries[$dataName]
            if ($data.PSIsContainer) {
                $files = @(Get-ChildItem -LiteralPath $data.FullName -Recurse -File -Force -ErrorAction SilentlyContinue)
                foreach ($file in $files) {
                    $relative = $file.FullName.Substring($data.FullName.Length).TrimStart('\')
                    New-BinItemObject -File $file -OriginalPath ([System.IO.Path]::Combine($meta.OriginalPath, $relative)) `
                        -Meta $meta -InfoPath $info.FullName -ContainerPath $data.FullName -InFolder $true
                }
            } else {
                New-BinItemObject -File $data -OriginalPath $meta.OriginalPath `
                    -Meta $meta -InfoPath $info.FullName -ContainerPath $data.FullName -InFolder $false
            }
        }
    }
}

#endregion

#region Filtering

function Test-AnyLike {
    param([string]$Value, [string[]]$Pattern)
    foreach ($p in $Pattern) { if ($Value -like $p) { return $true } }
    $false
}

function Select-BinItem {
    <#
    .SYNOPSIS
        Filters Recycle Bin items. All supplied criteria must match.
    .PARAMETER Extension
        File types, e.g. jpg, .png, *.avi (case-insensitive).
    .PARAMETER OriginalPath
        Original location. Without wildcards it matches that folder and everything below it;
        with wildcards (* ?) it is matched as a pattern against the full original path.
    .PARAMETER Name
        Wildcard pattern for the file name, e.g. 'IMG_*'.
    .NOTES
        *After parameters are inclusive; *Before parameters are exclusive.
        Sizes are in bytes (use 5MB, 1GB, etc.).
    #>
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline)][psobject]$InputObject,
        [string[]]$Extension,
        [string[]]$OriginalPath,
        [string[]]$Name,
        [datetime]$DeletedAfter,
        [datetime]$DeletedBefore,
        [datetime]$CreatedAfter,
        [datetime]$CreatedBefore,
        [datetime]$ModifiedAfter,
        [datetime]$ModifiedBefore,
        [long]$MinSize,
        [long]$MaxSize
    )

    begin {
        $bound = $PSBoundParameters
        $extensions = @(foreach ($e in @($Extension)) {
                if ($e) { '.' + $e.Trim().TrimStart('*').TrimStart('.').ToLowerInvariant() }
            })
        $pathPatterns = @(foreach ($p in @($OriginalPath)) {
                if (-not $p) { continue }
                if ([System.Management.Automation.WildcardPattern]::ContainsWildcardCharacters($p)) {
                    $p
                } else {
                    $escaped = [System.Management.Automation.WildcardPattern]::Escape($p.TrimEnd('\'))
                    $escaped
                    $escaped + '\*'
                }
            })
        $dateChecks = @(
            @{ Param = 'Deleted'; Property = 'DeletedDate' },
            @{ Param = 'Created'; Property = 'CreatedDate' },
            @{ Param = 'Modified'; Property = 'ModifiedDate' }
        )
    }

    process {
        if ($null -eq $InputObject) { return }
        $item = $InputObject

        if ($extensions.Count -and $extensions -notcontains $item.Extension) { return }
        if ($pathPatterns.Count -and -not (Test-AnyLike $item.OriginalPath $pathPatterns)) { return }
        if ($Name -and -not (Test-AnyLike $item.Name $Name)) { return }
        if ($bound.ContainsKey('MinSize') -and $item.Size -lt $MinSize) { return }
        if ($bound.ContainsKey('MaxSize') -and $item.Size -gt $MaxSize) { return }

        foreach ($check in $dateChecks) {
            $value = $item.($check.Property)
            $after = $check.Param + 'After'
            $before = $check.Param + 'Before'
            if ($bound.ContainsKey($after) -and $value -lt $bound[$after]) { return }
            if ($bound.ContainsKey($before) -and $value -ge $bound[$before]) { return }
        }

        $item
    }
}

#endregion

#region Staging (preview copies)

function New-BinStagingFolder {
    <#
    .SYNOPSIS
        Creates a fresh session folder inside StagingPath for preview copies and returns its path.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StagingPath)

    $root = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($StagingPath)
    $session = Join-Path $root ($script:StagingPrefix + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
    [void][System.IO.Directory]::CreateDirectory($session)
    $session
}

function Copy-BinItemToStaging {
    <#
    .SYNOPSIS
        Copies Recycle Bin items into a staging folder for previewing, mirroring the original
        path (C:\Pics\a.jpg -> <Destination>\C\Pics\a.jpg). Items stay in the Recycle Bin.
        Outputs each item with a StagedPath property added.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)][psobject]$InputObject,
        [Parameter(Mandatory)][string]$Destination
    )

    begin { $root = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($Destination) }

    process {
        $relative = $InputObject.OriginalPath.Replace(':', '').TrimStart('\')
        $target = [System.IO.Path]::Combine($root, $relative)
        [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($target))
        [System.IO.File]::Copy($InputObject.BinPath, $target, $true)
        Add-Member -InputObject $InputObject -NotePropertyName StagedPath -NotePropertyValue $target -Force -PassThru
    }
}

function Remove-BinStagingFolder {
    <#
    .SYNOPSIS
        Deletes a staging session folder created by New-BinStagingFolder.
        Refuses to delete any other folder.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Path)

    $leaf = Split-Path -Leaf $Path
    if ($leaf -notlike ($script:StagingPrefix + '*')) {
        throw "Refusing to delete '$Path': it is not a pattie-photo staging folder."
    }
    if (-not (Test-Path -LiteralPath $Path)) { return }
    if ($PSCmdlet.ShouldProcess($Path, 'Delete staging folder')) {
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force
        } catch {
            Write-Warning "Could not fully remove staging folder '$Path' (is a preview still open?): $($_.Exception.Message)"
        }
    }
}

#endregion

#region Acting on items

function New-BinActionResult {
    param([string]$Action, [string]$Result, $Item, [string]$Message)
    [pscustomobject]@{
        Timestamp    = (Get-Date).ToString('s')
        Action       = $Action
        Result       = $Result
        OriginalPath = $Item.OriginalPath
        BinPath      = $Item.BinPath
        Message      = $Message
    }
}

function Write-BinActionLog {
    param($Result, [string]$LogPath)
    if ($LogPath) {
        $Result | Export-Csv -LiteralPath $LogPath -Append -NoTypeInformation -Encoding UTF8
    }
}

# After a file has left the bin, remove its $I entry -- or for a deleted folder, remove the
# folder and its $I entry once no files remain in it.
function Remove-EmptyBinEntry {
    param($Item)
    if ($Item.InFolder) {
        if (-not (Test-Path -LiteralPath $Item.ContainerPath)) { return }
        $remaining = Get-ChildItem -LiteralPath $Item.ContainerPath -Recurse -File -Force | Select-Object -First 1
        if ($remaining) { return }
        Remove-Item -LiteralPath $Item.ContainerPath -Recurse -Force
    }
    if (Test-Path -LiteralPath $Item.InfoPath) {
        Remove-Item -LiteralPath $Item.InfoPath -Force
    }
}

function Remove-BinItem {
    <#
    .SYNOPSIS
        Permanently deletes Recycle Bin items. This cannot be undone.
        Supports -WhatIf; asks for confirmation unless -Confirm:$false.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory, ValueFromPipeline)][psobject]$InputObject,
        [string]$LogPath
    )

    process {
        $item = $InputObject
        if (-not $PSCmdlet.ShouldProcess($item.OriginalPath, 'Permanently delete from Recycle Bin')) { return }
        try {
            Remove-Item -LiteralPath $item.BinPath -Force
            Remove-EmptyBinEntry -Item $item
            $result = New-BinActionResult 'Delete' 'Deleted' $item ''
        } catch {
            Write-Warning "Failed to delete '$($item.OriginalPath)': $($_.Exception.Message)"
            $result = New-BinActionResult 'Delete' 'Failed' $item $_.Exception.Message
        }
        Write-BinActionLog $result $LogPath
        $result
    }
}

function Restore-BinItem {
    <#
    .SYNOPSIS
        Moves Recycle Bin items back to their original location. Items whose original path is
        already taken are skipped and left in the bin.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory, ValueFromPipeline)][psobject]$InputObject,
        [string]$LogPath
    )

    process {
        $item = $InputObject
        if (-not $PSCmdlet.ShouldProcess($item.OriginalPath, 'Restore from Recycle Bin')) { return }
        try {
            if (Test-Path -LiteralPath $item.OriginalPath) {
                Write-Warning "Skipped '$($item.OriginalPath)': a file already exists there."
                $result = New-BinActionResult 'Restore' 'Skipped' $item 'Destination already exists'
            } else {
                [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($item.OriginalPath))
                [System.IO.File]::Move($item.BinPath, $item.OriginalPath)
                Remove-EmptyBinEntry -Item $item
                $result = New-BinActionResult 'Restore' 'Restored' $item ''
            }
        } catch {
            Write-Warning "Failed to restore '$($item.OriginalPath)': $($_.Exception.Message)"
            $result = New-BinActionResult 'Restore' 'Failed' $item $_.Exception.Message
        }
        Write-BinActionLog $result $LogPath
        $result
    }
}

#endregion

#region Interactive mode

function Format-ByteSize {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return '{0:N1} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N0} KB' -f ($Bytes / 1KB) }
    '{0:N0} bytes' -f $Bytes
}

function Get-TotalSize {
    param([object[]]$Items)
    $total = [long]0
    foreach ($i in @($Items)) { if ($i) { $total += $i.Size } }
    $total
}

function Read-DateInput {
    param([string]$Prompt)
    while ($true) {
        $text = Read-Host $Prompt
        if (-not $text) { return $null }
        $date = [datetime]::MinValue
        if ([datetime]::TryParse($text, [ref]$date)) { return $date }
        Write-Host "  Could not read '$text' as a date. Try e.g. 2024-03-15." -ForegroundColor Yellow
    }
}

function Read-SizeInput {
    param([string]$Prompt)
    while ($true) {
        $text = Read-Host $Prompt
        if (-not $text) { return $null }
        $mb = 0.0
        if ([double]::TryParse($text, [ref]$mb)) { return [long]($mb * 1MB) }
        Write-Host "  Please enter a number of MB." -ForegroundColor Yellow
    }
}

function Read-BinFilter {
    Write-Host ''
    Write-Host 'Set filter (press Enter to skip any question; dates like 2024-03-15).' -ForegroundColor Cyan
    $filter = @{}

    $text = Read-Host 'File types, comma separated (e.g. jpg,png,avi)'
    if ($text) { $filter.Extension = @($text -split '[,\s]+' | Where-Object { $_ }) }

    $text = Read-Host 'Original folder (includes subfolders; wildcards * allowed)'
    if ($text) { $filter.OriginalPath = $text }

    $text = Read-Host 'File name contains'
    if ($text) { $filter.Name = "*$text*" }

    foreach ($kind in 'Deleted', 'Created', 'Modified') {
        $from = Read-DateInput "$kind from (inclusive)"
        if ($from) { $filter["${kind}After"] = $from }
        $to = Read-DateInput "$kind to (inclusive)"
        if ($to) {
            # A plain date means "through the end of that day".
            if ($to.TimeOfDay -eq [TimeSpan]::Zero) { $to = $to.AddDays(1) }
            $filter["${kind}Before"] = $to
        }
    }

    $min = Read-SizeInput 'Minimum size in MB'
    if ($null -ne $min) { $filter.MinSize = $min }
    $max = Read-SizeInput 'Maximum size in MB'
    if ($null -ne $max) { $filter.MaxSize = $max }

    $filter
}

function Format-BinFilter {
    param([hashtable]$Filter)
    if (-not $Filter.Count) { return '(none)' }
    $parts = foreach ($key in ($Filter.Keys | Sort-Object)) {
        $value = $Filter[$key]
        if ($value -is [datetime]) { $value = $value.ToString('yyyy-MM-dd HH:mm') }
        '{0}={1}' -f $key, (@($value) -join ',')
    }
    $parts -join '; '
}

function Show-BinSummary {
    param([object[]]$Items)
    $Items = @($Items | Where-Object { $_ })
    if (-not $Items.Count) { Write-Host 'No matching items.'; return }

    Write-Host ''
    Write-Host 'By file type:' -ForegroundColor Cyan
    $Items | Group-Object Extension | Sort-Object Count -Descending | ForEach-Object {
        [pscustomobject]@{ Type = $_.Name; Files = $_.Count; Size = Format-ByteSize (Get-TotalSize $_.Group) }
    } | Format-Table -AutoSize | Out-Host

    Write-Host 'Top original folders:' -ForegroundColor Cyan
    $Items | Group-Object OriginalFolder | Sort-Object Count -Descending | Select-Object -First 20 | ForEach-Object {
        [pscustomobject]@{ Files = $_.Count; Size = Format-ByteSize (Get-TotalSize $_.Group); Folder = $_.Name }
    } | Format-Table -AutoSize | Out-Host

    Write-Host 'By year deleted:' -ForegroundColor Cyan
    $Items | Group-Object { $_.DeletedDate.Year } | Sort-Object Name | ForEach-Object {
        [pscustomobject]@{ Year = $_.Name; Files = $_.Count; Size = Format-ByteSize (Get-TotalSize $_.Group) }
    } | Format-Table -AutoSize | Out-Host
}

# One review round: pick items, preview copies, choose an action.
# Returns the BinPaths of items that left the bin.
function Invoke-BinReviewRound {
    param([object[]]$Items, [string]$StagingPath, [string]$LogPath)

    $Items = @($Items | Where-Object { $_ })
    if (-not $Items.Count) { Write-Host 'No matching items to review.'; return @() }

    $byPath = @{}
    foreach ($i in $Items) { $byPath[$i.BinPath] = $i }

    Write-Host 'Opening picker... select files (Ctrl/Shift+click, Ctrl+A for all) and click OK.'
    $view = $Items | Select-Object Name, Extension, OriginalFolder,
        @{ n = 'SizeMB'; e = { [math]::Round($_.Size / 1MB, 2) } },
        DeletedDate, CreatedDate, ModifiedDate, BinPath
    $picked = @($view | Out-GridView -PassThru -Title "Select Recycle Bin files to review ($($Items.Count) shown)")
    if (-not $picked.Count) { Write-Host 'Nothing selected.'; return @() }
    $selected = @(foreach ($p in $picked) { $byPath[$p.BinPath] })

    $total = Get-TotalSize $selected
    Write-Host ("Selected {0} files ({1})." -f $selected.Count, (Format-ByteSize $total))

    $session = $null
    try {
        $answer = Read-Host 'Copy them to the staging folder to preview? [Y/n]'
        if ($answer -notmatch '^[nN]') {
            $session = New-BinStagingFolder -StagingPath $StagingPath
            $n = 0
            foreach ($item in $selected) {
                $n++
                Write-Progress -Activity 'Copying to staging' -Status $item.Name -PercentComplete ($n * 100 / $selected.Count)
                try {
                    Copy-BinItemToStaging -InputObject $item -Destination $session | Out-Null
                } catch {
                    Write-Warning "Could not copy '$($item.OriginalPath)': $($_.Exception.Message)"
                }
            }
            Write-Progress -Activity 'Copying to staging' -Completed
            Write-Host "Preview copies are in: $session"
            Invoke-Item -LiteralPath $session
        }

        while ($true) {
            Write-Host ''
            Write-Host ("What should happen to these {0} files?" -f $selected.Count) -ForegroundColor Cyan
            Write-Host '  [D] Delete permanently   [R] Restore to original location   [K] Keep in Recycle Bin'
            $choice = (Read-Host 'Choose').Trim().ToUpperInvariant()
            $results = $null
            if ($choice -eq 'K') { return @() }
            if ($choice -eq 'D') {
                $confirm = Read-Host ("Type DELETE to permanently delete {0} files ({1}). This cannot be undone" -f $selected.Count, (Format-ByteSize $total))
                if ($confirm -cne 'DELETE') { Write-Host 'Not deleted.'; continue }
                if ($session) { Remove-BinStagingFolder -Path $session; $session = $null }
                $results = @($selected | Remove-BinItem -LogPath $LogPath -Confirm:$false)
            } elseif ($choice -eq 'R') {
                if ($session) { Remove-BinStagingFolder -Path $session; $session = $null }
                $results = @($selected | Restore-BinItem -LogPath $LogPath -Confirm:$false)
            } else {
                continue
            }
            $results | Group-Object Result | ForEach-Object { Write-Host ("  {0}: {1}" -f $_.Name, $_.Count) }
            return @($results | Where-Object { $_.Result -in 'Deleted', 'Restored' } | ForEach-Object { $_.BinPath })
        }
    } finally {
        if ($session) {
            Read-Host 'Close any preview windows, then press Enter to clean up the staging copies' | Out-Null
            Remove-BinStagingFolder -Path $session
        }
    }
}

function Start-BinReview {
    <#
    .SYNOPSIS
        Interactive menu: filter Recycle Bin files, preview copies, then delete, restore or keep.
    .PARAMETER StagingPath
        Folder where preview copies are placed (in a temporary subfolder that is removed
        afterwards). The action log pattie-photo-log.csv is also written here.
        Ideally on a different disk from the one being reviewed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StagingPath,
        [switch]$AllUsers,
        [string[]]$BinPath
    )

    $StagingPath = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($StagingPath)
    [void][System.IO.Directory]::CreateDirectory($StagingPath)
    $logPath = Join-Path $StagingPath 'pattie-photo-log.csv'

    Write-Host 'Scanning Recycle Bin...'
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $getArgs = @{ AllUsers = $AllUsers }
    if ($BinPath) { $getArgs.Path = $BinPath }
    $all = @(Get-BinItem @getArgs)
    Write-Host ("Found {0} files in {1:N1} seconds." -f $all.Count, $timer.Elapsed.TotalSeconds)

    $filter = @{}
    while ($true) {
        $current = @($all | Select-BinItem @filter)
        Write-Host ''
        Write-Host '==== pattie-photo ====' -ForegroundColor Cyan
        Write-Host ("In Recycle Bin : {0} files ({1})" -f $all.Count, (Format-ByteSize (Get-TotalSize $all)))
        Write-Host ("Filter         : {0}" -f (Format-BinFilter $filter))
        Write-Host ("Matching       : {0} files ({1})" -f $current.Count, (Format-ByteSize (Get-TotalSize $current)))
        Write-Host '[F] Set filter  [C] Clear filter  [S] Summary of matches  [R] Review matches  [Q] Quit'

        switch ((Read-Host 'Choose').Trim().ToUpperInvariant()) {
            'F' { $filter = Read-BinFilter }
            'C' { $filter = @{} }
            'S' { Show-BinSummary $current }
            'R' {
                $gone = @(Invoke-BinReviewRound -Items $current -StagingPath $StagingPath -LogPath $logPath)
                if ($gone.Count) {
                    $goneSet = @{}
                    foreach ($p in $gone) { $goneSet[$p] = $true }
                    $all = @($all | Where-Object { -not $goneSet.ContainsKey($_.BinPath) })
                }
            }
            'Q' {
                if (Test-Path -LiteralPath $logPath) { Write-Host "Actions were logged to $logPath" }
                return
            }
        }
    }
}

#endregion

Export-ModuleMember -Function @(
    'Read-RecycleBinInfoFile'
    'Get-RecycleBinFolder'
    'Get-BinItem'
    'Select-BinItem'
    'New-BinStagingFolder'
    'Copy-BinItemToStaging'
    'Remove-BinStagingFolder'
    'Remove-BinItem'
    'Restore-BinItem'
    'Start-BinReview'
)
