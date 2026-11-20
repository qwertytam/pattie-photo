# Run with: Invoke-Pester .\tests
# Written in Pester 3 syntax (ships with Windows 10); also runs on Pester 4.

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $here '..\PattiePhoto.psm1') -Force

function New-FakeInfoBytes {
    param([string]$OriginalPath, [long]$Size, [datetime]$Deleted, [int]$Version = 2)
    $ms = New-Object System.IO.MemoryStream
    $w = New-Object System.IO.BinaryWriter($ms)
    $w.Write([long]$Version)
    $w.Write([long]$Size)
    $w.Write([long]$Deleted.ToFileTime())
    $pathBytes = [System.Text.Encoding]::Unicode.GetBytes($OriginalPath + [char]0)
    if ($Version -eq 2) {
        $w.Write([int]($OriginalPath.Length + 1))
        $w.Write($pathBytes)
    } else {
        $buffer = New-Object byte[] 520
        [Array]::Copy($pathBytes, $buffer, $pathBytes.Length)
        $w.Write($buffer)
    }
    $w.Flush()
    $ms.ToArray()
}

# Creates an isolated fake bin folder and a folder to use for "original" paths.
function New-TestBin {
    $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    $bin = Join-Path $root 'bin'
    $orig = Join-Path $root 'orig'
    [void][System.IO.Directory]::CreateDirectory($bin)
    [void][System.IO.Directory]::CreateDirectory($orig)
    [pscustomobject]@{ Root = $root; Bin = $bin; Orig = $orig }
}

function Add-FakeBinFile {
    param($Bin, [string]$Id, [string]$OriginalPath, [datetime]$Deleted = '2024-03-15 10:30:00',
        [string]$Content = 'data', [int]$Version = 2)
    $ext = [System.IO.Path]::GetExtension($OriginalPath)
    $infoPath = Join-Path $Bin.Bin ('$I' + $Id + $ext)
    $dataPath = Join-Path $Bin.Bin ('$R' + $Id + $ext)
    [System.IO.File]::WriteAllText($dataPath, $Content)
    [System.IO.File]::WriteAllBytes($infoPath, (New-FakeInfoBytes $OriginalPath $Content.Length $Deleted $Version))
    [pscustomobject]@{ InfoPath = $infoPath; DataPath = $dataPath }
}

function Add-FakeBinFolder {
    param($Bin, [string]$Id, [string]$OriginalPath, [hashtable]$Files, [datetime]$Deleted = '2024-03-15 10:30:00')
    $infoPath = Join-Path $Bin.Bin ('$I' + $Id)
    $dataPath = Join-Path $Bin.Bin ('$R' + $Id)
    foreach ($rel in $Files.Keys) {
        $p = Join-Path $dataPath $rel
        [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $p))
        [System.IO.File]::WriteAllText($p, $Files[$rel])
    }
    [System.IO.File]::WriteAllBytes($infoPath, (New-FakeInfoBytes $OriginalPath 0 $Deleted 2))
    [pscustomobject]@{ InfoPath = $infoPath; DataPath = $dataPath }
}

Describe 'Read-RecycleBinInfoFile' {
    It 'parses a Windows 10 (version 2) $I file' {
        $b = New-TestBin
        $f = Add-FakeBinFile $b 'AAAAA1' 'C:\Pics\holiday.jpg' -Deleted '2024-03-15 10:30:00' -Content 'hello'
        $info = Read-RecycleBinInfoFile -Path $f.InfoPath
        $info.Version | Should Be 2
        $info.OriginalPath | Should Be 'C:\Pics\holiday.jpg'
        $info.Size | Should Be 5
        $info.DeletedDate | Should Be ([datetime]'2024-03-15 10:30:00')
    }

    It 'parses a Vista-8.1 (version 1) $I file' {
        $b = New-TestBin
        $f = Add-FakeBinFile $b 'AAAAA2' 'D:\Video\clip.avi' -Version 1
        $info = Read-RecycleBinInfoFile -Path $f.InfoPath
        $info.Version | Should Be 1
        $info.OriginalPath | Should Be 'D:\Video\clip.avi'
    }

    It 'rejects a file that is too short' {
        $b = New-TestBin
        $p = Join-Path $b.Bin '$IBROKEN'
        [System.IO.File]::WriteAllBytes($p, [byte[]](1, 2, 3))
        { Read-RecycleBinInfoFile -Path $p } | Should Throw
    }
}

Describe 'Get-BinItem' {
    It 'returns a deleted file with its original details' {
        $b = New-TestBin
        $f = Add-FakeBinFile $b 'AAAAA1' 'C:\Pics\Holiday.JPG' -Content '12345'
        (Get-Item -LiteralPath $f.DataPath).CreationTime = [datetime]'2020-01-02'
        $items = @(Get-BinItem -Path $b.Bin)
        $items.Count | Should Be 1
        $items[0].Name | Should Be 'Holiday.JPG'
        $items[0].Extension | Should Be '.jpg'
        $items[0].OriginalFolder | Should Be 'C:\Pics'
        $items[0].Size | Should Be 5
        $items[0].DeletedDate | Should Be ([datetime]'2024-03-15 10:30:00')
        $items[0].CreatedDate | Should Be ([datetime]'2020-01-02')
        $items[0].InFolder | Should Be $false
        $items[0].BinPath | Should Be $f.DataPath
    }

    It 'lists the files inside a deleted folder, including subfolders' {
        $b = New-TestBin
        Add-FakeBinFolder $b 'FOLDER' 'C:\Pics\Trip' @{ 'a.jpg' = 'a'; 'day2\b.png' = 'bb' } -Deleted '2023-07-01' | Out-Null
        $items = @(Get-BinItem -Path $b.Bin | Sort-Object Name)
        $items.Count | Should Be 2
        $items[0].OriginalPath | Should Be 'C:\Pics\Trip\a.jpg'
        $items[1].OriginalPath | Should Be 'C:\Pics\Trip\day2\b.png'
        $items[1].InFolder | Should Be $true
        $items[1].DeletedDate | Should Be ([datetime]'2023-07-01')
    }

    It 'skips $I entries whose data is missing' {
        $b = New-TestBin
        $f = Add-FakeBinFile $b 'AAAAA1' 'C:\Pics\gone.jpg'
        Remove-Item -LiteralPath $f.DataPath
        @(Get-BinItem -Path $b.Bin).Count | Should Be 0
    }
}

Describe 'Select-BinItem' {
    $b = New-TestBin
    Add-FakeBinFile $b 'AAAAA1' 'C:\Pics\a.jpg' -Deleted '2024-01-10' -Content '1' | Out-Null
    Add-FakeBinFile $b 'AAAAA2' 'C:\Pics\Sub\b.PNG' -Deleted '2024-02-10' -Content '1234567890' | Out-Null
    Add-FakeBinFile $b 'AAAAA3' 'C:\Pics2\c.avi' -Deleted '2024-03-10' -Content '12345' | Out-Null
    $all = @(Get-BinItem -Path $b.Bin)

    It 'filters by extension in any common form' {
        @($all | Select-BinItem -Extension 'jpg').Count | Should Be 1
        @($all | Select-BinItem -Extension '.PNG', '*.avi').Count | Should Be 2
    }

    It 'treats a folder without wildcards as that folder and its subfolders' {
        $names = @($all | Select-BinItem -OriginalPath 'C:\Pics' | ForEach-Object Name | Sort-Object)
        ($names -join ',') | Should Be 'a.jpg,b.PNG'
    }

    It 'supports wildcards in the original path' {
        @($all | Select-BinItem -OriginalPath 'C:\Pics*').Count | Should Be 3
    }

    It 'filters by deleted date (After inclusive, Before exclusive)' {
        $r = @($all | Select-BinItem -DeletedAfter '2024-02-10' -DeletedBefore '2024-03-10')
        $r.Count | Should Be 1
        $r[0].Name | Should Be 'b.PNG'
    }

    It 'filters by size' {
        @($all | Select-BinItem -MinSize 5).Count | Should Be 2
        @($all | Select-BinItem -MaxSize 4).Count | Should Be 1
    }

    It 'filters by name wildcard' {
        @($all | Select-BinItem -Name 'c.*').Count | Should Be 1
    }
}

Describe 'Staging' {
    It 'copies items under their original path and cleans up afterwards' {
        $b = New-TestBin
        Add-FakeBinFile $b 'AAAAA1' 'C:\Pics\a.jpg' -Content 'pic' | Out-Null
        $staging = Join-Path $b.Root 'staging'
        $session = New-BinStagingFolder -StagingPath $staging
        $copied = @(Get-BinItem -Path $b.Bin | Copy-BinItemToStaging -Destination $session)
        $copied[0].StagedPath | Should Be (Join-Path $session 'C\Pics\a.jpg')
        [System.IO.File]::ReadAllText($copied[0].StagedPath) | Should Be 'pic'
        # The original stays in the bin.
        @(Get-BinItem -Path $b.Bin).Count | Should Be 1

        Remove-BinStagingFolder -Path $session
        $session | Should Not Exist
        $staging | Should Exist
    }

    It 'refuses to delete a folder it did not create' {
        $b = New-TestBin
        { Remove-BinStagingFolder -Path $b.Orig } | Should Throw
        $b.Orig | Should Exist
    }
}

Describe 'Remove-BinItem' {
    It 'permanently deletes a file and its $I entry' {
        $b = New-TestBin
        $f = Add-FakeBinFile $b 'AAAAA1' 'C:\Pics\a.jpg'
        $result = Get-BinItem -Path $b.Bin | Remove-BinItem -Confirm:$false
        $result.Result | Should Be 'Deleted'
        $f.DataPath | Should Not Exist
        $f.InfoPath | Should Not Exist
    }

    It 'keeps a deleted folder until its last file is removed' {
        $b = New-TestBin
        $f = Add-FakeBinFolder $b 'FOLDER' 'C:\Pics\Trip' @{ 'a.jpg' = 'a'; 'sub\b.jpg' = 'b' }
        Get-BinItem -Path $b.Bin | Select-BinItem -Name 'a.jpg' | Remove-BinItem -Confirm:$false | Out-Null
        $f.DataPath | Should Exist
        $f.InfoPath | Should Exist
        @(Get-BinItem -Path $b.Bin).Count | Should Be 1

        Get-BinItem -Path $b.Bin | Remove-BinItem -Confirm:$false | Out-Null
        $f.DataPath | Should Not Exist
        $f.InfoPath | Should Not Exist
    }

    It 'does nothing with -WhatIf' {
        $b = New-TestBin
        $f = Add-FakeBinFile $b 'AAAAA1' 'C:\Pics\a.jpg'
        Get-BinItem -Path $b.Bin | Remove-BinItem -WhatIf
        $f.DataPath | Should Exist
        $f.InfoPath | Should Exist
    }

    It 'writes a CSV log entry' {
        $b = New-TestBin
        Add-FakeBinFile $b 'AAAAA1' 'C:\Pics\a.jpg' | Out-Null
        $log = Join-Path $b.Root 'log.csv'
        Get-BinItem -Path $b.Bin | Remove-BinItem -Confirm:$false -LogPath $log | Out-Null
        $rows = @(Import-Csv -LiteralPath $log)
        $rows.Count | Should Be 1
        $rows[0].Action | Should Be 'Delete'
        $rows[0].OriginalPath | Should Be 'C:\Pics\a.jpg'
    }
}

Describe 'Restore-BinItem' {
    It 'moves a file back to its original location' {
        $b = New-TestBin
        $target = Join-Path $b.Orig 'Pics\a.jpg'
        $f = Add-FakeBinFile $b 'AAAAA1' $target -Content 'pic'
        $result = Get-BinItem -Path $b.Bin | Restore-BinItem -Confirm:$false
        $result.Result | Should Be 'Restored'
        [System.IO.File]::ReadAllText($target) | Should Be 'pic'
        $f.DataPath | Should Not Exist
        $f.InfoPath | Should Not Exist
    }

    It 'restores files from a deleted folder, recreating subfolders' {
        $b = New-TestBin
        $folder = Join-Path $b.Orig 'Trip'
        $f = Add-FakeBinFolder $b 'FOLDER' $folder @{ 'a.jpg' = 'a'; 'day2\b.jpg' = 'b' }
        Get-BinItem -Path $b.Bin | Restore-BinItem -Confirm:$false | Out-Null
        (Join-Path $folder 'a.jpg') | Should Exist
        (Join-Path $folder 'day2\b.jpg') | Should Exist
        $f.DataPath | Should Not Exist
        $f.InfoPath | Should Not Exist
    }

    It 'skips a file when something already exists at the original path' {
        $b = New-TestBin
        $target = Join-Path $b.Orig 'a.jpg'
        [System.IO.File]::WriteAllText($target, 'newer')
        $f = Add-FakeBinFile $b 'AAAAA1' $target -Content 'older'
        $result = Get-BinItem -Path $b.Bin | Restore-BinItem -Confirm:$false
        $result.Result | Should Be 'Skipped'
        [System.IO.File]::ReadAllText($target) | Should Be 'newer'
        $f.DataPath | Should Exist
        $f.InfoPath | Should Exist
    }
}
