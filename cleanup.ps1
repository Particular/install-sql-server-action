param (
    [string]$ContainerName,
    [string]$EnableDistributedTransactions = "false"
)

$ErrorActionPreference = 'Continue'

$runnerOs = $Env:RUNNER_OS ?? "Linux"
$enableDtc = $EnableDistributedTransactions -eq "true"

if ($runnerOs -eq "Linux") {
    if (-not $ContainerName) {
        Write-Output "No container name supplied, nothing to clean up"
        return
    }

    Write-Output "Killing Docker container $ContainerName"
    docker kill $ContainerName 2>$null

    Write-Output "Removing Docker container $ContainerName"
    docker rm $ContainerName 2>$null
}
elseif ($runnerOs -eq "Windows") {
    $wslDistribution = $Env:WSL_DISTRIBUTION_OVERRIDE ?? "Debian"

    if ($ContainerName) {
        Write-Output "Removing WSL Docker container $ContainerName"
        wsl.exe --distribution $wslDistribution --user root -- bash -c "docker rm --force ${ContainerName} 2>/dev/null || true"
    }

    if ($enableDtc) {
        Write-Output "Restoring host DTC firewall rules to their original profiles"
        foreach ($group in @("Distributed Transaction Coordinator", "Remote Procedure Call (RPC)")) {
            $rules = Get-NetFirewallRule -DisplayGroup $group -ErrorAction SilentlyContinue
            if ($rules) {
                # Restore the default profiles (Domain + Private) -- the action widened to Any
                # so container->host callbacks reach the DTC over the WSL adapter (Public).
                $rules | Set-NetFirewallRule -Profile Domain,Private -ErrorAction SilentlyContinue
            }
        }
    }
}
else {
    Write-Output "$runnerOs not supported"
    exit 1
}
