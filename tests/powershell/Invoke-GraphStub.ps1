function New-GraphStub {
    [CmdletBinding()]
    param([hashtable]$Routes = @{})
    $ledger = [System.Collections.Generic.List[object]]::new()
    $queues = @{}
    foreach ($key in $Routes.Keys) {
        $queues[$key] = [System.Collections.Generic.Queue[object]]::new()
        foreach ($response in @($Routes[$key])) { $queues[$key].Enqueue($response) }
    }
    $transport = {
        param($Method, $Path, $Body, $RawBody)
        $ledger.Add(@{ Method = $Method; Path = $Path; Body = $Body; RawBody = $RawBody })
        $key = "$Method $Path"
        if (-not $queues.ContainsKey($key) -or $queues[$key].Count -eq 0) {
            throw [InvalidOperationException]::new('Unconfigured offline Graph request.')
        }
        $value = $queues[$key].Dequeue()
        if ($value -is [Exception]) { throw $value }
        if ($value -is [scriptblock]) { return & $value $Method $Path $Body $RawBody }
        return $value
    }.GetNewClosure()
    [pscustomobject]@{ Transport = $transport; Ledger = $ledger }
}

function New-GraphStubError {
    param([int]$StatusCode = 503, [int]$RetryAfterSeconds = 0)
    $errorObject = [InvalidOperationException]::new('SECRET password=hidden token=hidden https://hidden.invalid/?capability=hidden')
    $errorObject.Data['StatusCode'] = $StatusCode
    $errorObject.Data['RetryAfterSeconds'] = $RetryAfterSeconds
    return $errorObject
}
