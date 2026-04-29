 # Define ranges
 $groups = @{
    "SG" = 1..20 | ForEach-Object { "PRDAVDCDOSG-$_" }
    "SB" = 1..20 | ForEach-Object { "PRDAVDCDOSB-$_" }
}

$results = @()

foreach ($group in $groups.Keys) {
    foreach ($vm in $groups[$group]) {
        Write-Host "Testing $vm..." -ForegroundColor Yellow

        $isOnline = Test-Connection -ComputerName $vm -Count 1 -Quiet -ErrorAction SilentlyContinue
        $status   = if ($isOnline) { "Online" } else { "Offline" }
        $colour   = if ($isOnline) { "Green" } else { "Red" }

        # Live result
        Write-Host "$vm is $status" -ForegroundColor $colour

        # Store result
        $results += [PSCustomObject]@{
            Hostname = $vm
            Group    = $group
            Status   = $status
        }
    }
}

# Detailed table
Write-Host "`nDetailed Results:" -ForegroundColor Cyan
$results | Sort-Object Group, Hostname | Format-Table -AutoSize

# Summary table
$summary = $results | Group-Object Group, Status | ForEach-Object {
    $parts = $_.Name -split ","
    [PSCustomObject]@{
        Group  = $parts[0].Trim()
        Status = $parts[1].Trim()
        Count  = $_.Count
    }
}

Write-Host "`nSummary:" -ForegroundColor Cyan
$summary | Sort-Object Group, Status | Format-Table -AutoSize 
