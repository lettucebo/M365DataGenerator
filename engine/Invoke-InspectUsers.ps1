function Invoke-InspectUsers {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, $Binding = $null, [Parameter(Mandatory)][string]$PresenterUpn, [string]$ReportPath)
    $record = Get-SeedSessionRecord $Session
    $record.ReadOnlyDepth++
    try {
        $report = @{
            TenantId = $record.TenantId; ServiceStatus = 'NotVerified'
            Users = @(Get-DemoUserInventory -Session $Session -Binding $Binding -PresenterUpn $PresenterUpn)
        }
        if ($ReportPath) {
            $ReportPath = Assert-SeedStatePath $ReportPath
            Assert-SeedNoSecrets $report
            $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($report | ConvertTo-Json -Depth 100) + "`n")
            $stream = [IO.FileStream]::new($ReportPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough)
            try { $stream.Write($bytes); $stream.Flush($true) } finally { $stream.Dispose() }
        }
        return $report
    } finally { $record.ReadOnlyDepth-- }
}
