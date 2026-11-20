# pattie-photo

Windows Recycle Bin file reviewer. It filters, previews, restores and permanently deletes
Recycle Bin items without opening the bin in Explorer, which can be very slow when the bin
holds thousands of files on a slow disk.

Requires Windows PowerShell 5.1 (Windows 10). Nothing else needs installing.

## How it works

Each drive keeps deleted items in a hidden folder, `X:\$Recycle.Bin\<user SID>\`, as pairs
of files:

- `$Ixxxxxx.ext` holds the metadata: original path, size and date deleted.
- `$Rxxxxxx.ext` is the deleted file itself, or a folder holding a deleted folder's contents.

pattie-photo reads these files directly instead of going through the Windows Shell. Files
inside deleted folders are listed one by one. Deleting permanently removes the `$R`/`$I`
pair, which is what emptying the Recycle Bin does. Restoring moves the file back to its
original path.

## Interactive use

```powershell
.\pattie-photo.ps1 -StagingPath D:\BinPreview
```

1. The script scans the Recycle Bin.
2. **[F] Set filter**: filter by file types, original folder, name, size, and date ranges
   for deleted, created and modified.
3. **[S] Summary**: counts and sizes grouped by file type, original folder and year deleted.
4. **[R] Review**: a picker window opens. Select files and click OK. The selection is copied
   to a temporary subfolder of the staging path and opened in Explorer. You then choose:
   - **[D] Delete permanently**. You must type `DELETE` to confirm.
   - **[R] Restore** to the original location. If a file already exists there, the item is
     skipped and stays in the bin.
   - **[K] Keep** the selection in the Recycle Bin.

   The staging copies are deleted afterwards. Each delete and restore is logged to
   `pattie-photo-log.csv` in the staging folder.

Add `-AllUsers` from an Administrator PowerShell to include other users' Recycle Bins.

If scripts are blocked, run
`powershell -ExecutionPolicy Bypass -File .\pattie-photo.ps1 -StagingPath D:\BinPreview`.

## Command use

```powershell
Import-Module .\PattiePhoto.psm1

$items = Get-BinItem                     # scan once; filter the variable as often as you like
$items | Select-BinItem -Extension jpg,png -OriginalPath 'C:\Users\Pat\Pictures' |
    Select-BinItem -DeletedAfter 2023-01-01 -DeletedBefore 2024-01-01 |
    Remove-BinItem -WhatIf               # dry run; drop -WhatIf to really delete

$items | Select-BinItem -Name 'IMG_2023*' | Restore-BinItem -LogPath .\log.csv

$session = New-BinStagingFolder -StagingPath D:\BinPreview
$items | Select-BinItem -Extension avi | Copy-BinItemToStaging -Destination $session
Remove-BinStagingFolder -Path $session
```

| Command | Purpose |
| --- | --- |
| `Get-BinItem` | List Recycle Bin files (`-AllUsers`, `-Path <bin folder>`) |
| `Select-BinItem` | Filter by `-Extension`, `-OriginalPath`, `-Name`, `-Deleted/Created/ModifiedAfter/Before`, `-MinSize/-MaxSize` |
| `Copy-BinItemToStaging` | Copy to a preview folder, mirroring the original path |
| `Remove-BinItem` | Permanently delete; supports `-WhatIf` and `-LogPath` |
| `Restore-BinItem` | Move back to the original location; supports `-WhatIf` and `-LogPath` |

Notes on filters:
- `*After` dates include the given date. `*Before` dates exclude it.
- An `-OriginalPath` without wildcards matches that folder and everything below it.

## Development

```powershell
Invoke-Pester .\tests
```

The tests build a fake Recycle Bin in Pester's TestDrive and never touch the real one.
They use Pester 3 syntax, which ships with Windows 10, and also run on Pester 4.
