# Run with: Invoke-Pester .\tests

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here '..\pattie-photo.ps1')

Describe 'pattie-photo' {
    It 'defines Get-RecycleBinItem' {
        Get-Command Get-RecycleBinItem -ErrorAction SilentlyContinue | Should Not BeNullOrEmpty
    }
}
