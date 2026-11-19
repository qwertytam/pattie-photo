<#
.SYNOPSIS
    Windows recycle bin file reviewer.

.DESCRIPTION
    TODO: describe what the script does.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RecycleBinItem {
    <#
    .SYNOPSIS
        Returns the items currently in the recycle bin.
    #>
    [CmdletBinding()]
    param()

    $shell = New-Object -ComObject Shell.Application
    # 10 = ssfBITBUCKET (Recycle Bin)
    $shell.Namespace(10).Items()
}

function Invoke-Main {
    [CmdletBinding()]
    param()

    Get-RecycleBinItem
}

# Only run when executed, not when dot-sourced (e.g. by tests).
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-Main
}
