#Requires -Version 7.5
[CmdletBinding()]
param([string]$Mode, [string]$PresenterUpn, [string]$PackPath, [string]$PersonaPackPath, [string]$ConfigPath,
    [switch]$NonInteractive, [string]$ConfirmTarget, [Alias('personas-only')][switch]$PersonasOnly)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
foreach ($file in @('Seed-GraphRead','Seed-RunState','Seed-Idempotency','Connect-GraphApp','Connect-GraphAdmin',
    'Seed-Identity','Invoke-SeedPreflight','Seed-PersonaPlan','Invoke-InspectUsers','Invoke-InitializePersonas',
    'Seed-OneDriveOwnership','Invoke-SeedSharePoint','Invoke-UploadFiles','Invoke-SeedEmails','Invoke-SeedTeamsChannel',
    'Seed-ResourceLinks','Seed-Console')) {
    . (Join-Path $PSScriptRoot "engine\$file.ps1")
}
$result = Invoke-SeedConsole @PSBoundParameters
exit $result.ExitCode
