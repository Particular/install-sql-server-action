param (
    [string]$ContainerName,
    [string]$ConnectionStringName,
    [string]$Catalog = "nservicebus",
    [string]$Collation = "SQL_Latin1_General_CP1_CS_AS",
    [string]$SqlServerVersion = "2022",
    [string]$ExtraParams = "",
    [string]$EnableFullTextSearch = "false",
    [string]$EnableDistributedTransactions = "false"
)

$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'modules' 'WslTools'
Import-Module $modulePath -Force

function Save-State {
    param(
        [string]$Name,
        [string]$Value
    )

    if ($env:GITHUB_STATE) {
        "$Name=$Value" | Out-File -FilePath $env:GITHUB_STATE -Encoding utf8 -Append
    }
}

function Export-Env {
    param(
        [string]$Name,
        [string]$Value
    )

    "$Name=$Value" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
}

# Install SQL Server Full-Text Search inside the running container. The script is read from
# disk (no inline base64 dance), placeholders are filled in locally, and `docker cp` ships it
# into the container -- which means we never put a multi-line bash script on the docker exec
# command line, so WSL interop can't mangle its quoting on Windows.
function Install-FullTextSearch {
    param(
        [Parameter(Mandatory = $true)][string]$ContainerName,
        [Parameter(Mandatory = $true)][string]$RepoChannel,
        [Parameter(Mandatory = $true)][string]$SqlEngineMajor,
        [string]$WslDistribution
    )

    $ftsScriptPath = Join-Path $PSScriptRoot "scripts/install-fts.sh"
    if (-not (Test-Path $ftsScriptPath)) {
        throw "FTS install script not found at $ftsScriptPath"
    }

    $rendered = (Get-Content -Raw -Path $ftsScriptPath) `
        -replace '__CHANNEL__', $RepoChannel `
        -replace '__ENGINE__', $SqlEngineMajor

    $renderedPath = Join-Path ([System.IO.Path]::GetTempPath()) ("install-fts-" + [guid]::NewGuid().ToString("N") + ".sh")
    Set-Content -Path $renderedPath -Value $rendered -NoNewline -Encoding ASCII

    $containerScriptPath = "/tmp/install-fts.sh"
    if ($WslDistribution) {
        # The host file must be visible to the WSL filesystem before `wsl.exe ... docker cp`
        # can copy it into the container. WSL auto-mounts the Windows drive containing the
        # temp directory under /mnt/<drive>/, so we translate the host path ourselves instead
        # of round-tripping through `wslpath` -- the interop arg parser mangles backslashes.
        $wslRenderedPath = ConvertTo-WslPath -WindowsPath $renderedPath
        & wsl.exe --distribution $WslDistribution -- docker cp $wslRenderedPath "${ContainerName}:${containerScriptPath}"
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to copy FTS install script into the container"
        }
        & wsl.exe --distribution $WslDistribution -- docker exec -u 0 $ContainerName bash $containerScriptPath
    }
    else {
        docker cp $renderedPath "${ContainerName}:${containerScriptPath}"
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to copy FTS install script into the container"
        }
        docker exec -u 0 $ContainerName bash $containerScriptPath
    }

    if ($LASTEXITCODE -ne 0) {
        throw "Full-Text Search installation failed"
    }

    Remove-Item -Path $renderedPath -Force -ErrorAction SilentlyContinue
}

$runnerOs = $Env:RUNNER_OS ?? "Linux"

# SQL Server password policy requires chars from 3 of 4 sets. A hyphenated
# GUID (lowercase letters + digits + hyphens) satisfies this, matching the
# `uuidgen` based password used on Linux.
$saPassword = [guid]::NewGuid().ToString()
Write-Output "::add-mask::$saPassword"

$image = "mcr.microsoft.com/mssql/server:$SqlServerVersion-latest"
$port = 1433
$enableFts = $EnableFullTextSearch -eq "true"
$enableDtc = $EnableDistributedTransactions -eq "true"

Save-State -Name "EnableDistributedTransactions" -Value ($(if ($enableDtc) { "true" } else { "false" }))

if ($enableDtc -and $runnerOs -eq "Windows") {
    # SQL Server now runs in a container inside WSL, so DTC transactions are network
    # (host <-> WSL VM), not local. The host needs Network DTC Access, and since the
    # container's MSDTC doesn't authenticate RPC it must be "No Authentication Required".
    Write-Output "::group::Configuring host Local DTC for distributed transactions"

    $dtcService = Get-Service -Name MSDTC -ErrorAction SilentlyContinue
    if ($dtcService) {
        if ($dtcService.StartType -eq 'Disabled') {
            Set-Service -Name MSDTC -StartupType Manual
        }
        if ($dtcService.Status -ne 'Running') {
            Write-Output "Starting the MSDTC service"
            Start-Service -Name MSDTC
        }
    }

    Write-Output "Enabling Network DTC Access (inbound + outbound) with No Authentication"
    # Set Local DTC in the registry -- Set-DtcNetworkSetting NREs here (its CIM provider
    # isn't ready right after the service starts). Same values the cmdlet would write;
    # the restart below applies them.
    # See https://learn.microsoft.com/troubleshoot/windows/win32/new-functionality-in-msdtc-service
    $securityPath = "HKLM:\SOFTWARE\Microsoft\MSDTC\Security"
    $msdtcPath = "HKLM:\SOFTWARE\Microsoft\MSDTC"
    if (-not (Test-Path $securityPath)) { New-Item -Path $securityPath -Force | Out-Null }
    if (-not (Test-Path $msdtcPath)) { New-Item -Path $msdtcPath -Force | Out-Null }

    $networkAccess = @{
        NetworkDtcAccess             = 1
        NetworkDtcAccessAdmin        = 1
        NetworkDtcAccessClients      = 1
        NetworkDtcAccessTransactions = 1
        NetworkDtcAccessInbound      = 1
        NetworkDtcAccessOutbound     = 1
        LuTransactions               = 1
        XaTransactions               = 1
    }
    foreach ($name in $networkAccess.Keys) {
        Set-ItemProperty -Path $securityPath -Name $name -Value $networkAccess[$name] -Type DWord
    }

    # "No Authentication Required" -- the container's MSDTC doesn't authenticate RPC.
    $noAuthentication = @{
        AllowOnlySecureRpcCalls          = 0
        FallbackToUnsecureRPCIfNecessary = 0
        TurnOffRpcSecurity               = 1
    }
    foreach ($name in $noAuthentication.Keys) {
        Set-ItemProperty -Path $msdtcPath -Name $name -Value $noAuthentication[$name] -Type DWord
    }

    Write-Output "Restarting the MSDTC service to apply the registry changes"
    Restart-Service -Name MSDTC -Force

    Write-Output "Allowing DTC + RPC through Windows Firewall (all profiles)"
    # The container's SQL Server must call back to the host's DTC (the coordinator) over RPC:
    # the host endpoint mapper (135) and the dynamic RPC port the host DTC listens on. The
    # built-in DTC/RPC rules are Domain/Private only, but the WSL adapter sits on the Public
    # profile, so widen them to all profiles or the container->host callback is dropped.
    foreach ($group in @("Distributed Transaction Coordinator", "Remote Procedure Call (RPC)")) {
        $rules = Get-NetFirewallRule -DisplayGroup $group -ErrorAction SilentlyContinue
        if ($rules) {
            $rules | Set-NetFirewallRule -Profile Any -ErrorAction SilentlyContinue
            $rules | Enable-NetFirewallRule -ErrorAction SilentlyContinue
        }
    }

    Write-Output "::endgroup::"
}

if ($runnerOs -eq "Linux") {
    Write-Output "Running SQL Server in container $ContainerName using Docker"

    # Build the docker run arguments. Splatting an array keeps each value (incl. the SA password)
    # as a distinct argument, so no shell quoting is required.
    $dockerArgs = @(
        "run", "--name", $ContainerName, "--detach", "--restart", "unless-stopped",
        "--publish", "${port}:${port}",
        "-e", "ACCEPT_EULA=Y",
        "-e", "MSSQL_SA_PASSWORD=$saPassword",
        "-e", "MSSQL_PID=Developer",
        "-e", "MSSQL_COLLATION=$Collation",
        "-e", "SQLCMDSERVER=localhost",
        "-e", "SQLCMDUSER=sa",
        "-e", "SQLCMDPASSWORD=$saPassword"
    )

    if ($enableDtc) {
        Write-Output "Enabling distributed transactions (MSDTC) in the container"
        # 2019+ containers run as non-root and can't bind port 135, so the endpoint mapper
        # listens on 13500 and Docker maps host 135 -> 13500.
        # See https://learn.microsoft.com/sql/linux/containers/configure-distributed-transactions
        $dockerArgs += @(
            "-e", "MSSQL_RPC_PORT=13500",
            "-e", "MSSQL_DTC_TCP_PORT=51000",
            "-p", "135:13500",
            "-p", "51000:51000"
        )
    }

    if ($enableFts) {
        Write-Output "Starting SQL Server container in setup mode for Full-Text Search installation..."
        $dockerArgs += @("--entrypoint", "/bin/bash", $image, "-lc", "sleep infinity")
    }
    else {
        $dockerArgs += $image
    }

    Write-Output "::group::Starting SQL Server container"
    & docker @dockerArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to start SQL Server container"
    }
    & docker ps --filter "name=$ContainerName"
    Write-Output "::endgroup::"

    if ($enableFts) {
        switch ($SqlServerVersion) {
            "2025" { $sqlEngineMajor = 17; $repoChannel = "2025" }
            "2022" { $sqlEngineMajor = 16; $repoChannel = "2022" }
            "2019" { $sqlEngineMajor = 15; $repoChannel = "2019" }
            default {
                throw "Unsupported sqlserver-version for FTS: '$SqlServerVersion'. Supported values: 2019, 2022, 2025."
            }
        }

        Write-Output "::group::Installing Full-Text Search support in the SQL Server container"
        Install-FullTextSearch -ContainerName $ContainerName -RepoChannel $repoChannel -SqlEngineMajor $sqlEngineMajor
        Write-Output "::endgroup::"

        Write-Output "Starting SQL Server process..."
        docker exec -d $ContainerName /opt/mssql/bin/sqlservr
    }

    Write-Output "Creating `sqlcmd` bash script to forward commands via docker exec"
    New-Item -ItemType Directory -Force -Path ~/bin | Out-Null
    Set-Content -Path ~/bin/sqlcmd -Value "#!/bin/bash`ndocker exec $ContainerName /opt/mssql-tools18/bin/sqlcmd -C `"$@`"" -Encoding ASCII
    & chmod +x ~/bin/sqlcmd

    Write-Output "Adding sqlcmd forwarding script to PATH"
    "$HOME/bin" | Out-File -FilePath $Env:GITHUB_PATH -Encoding utf8 -Append
    # GITHUB_PATH only affects subsequent steps; the Setup server section below runs in this
    # same process and needs the shim on PATH right now.
    $Env:PATH = "$HOME/bin:$Env:PATH"

    Write-Output "Setting environment variable $ConnectionStringName to SQL connection string..."
    Export-Env -Name $ConnectionStringName -Value "Server=localhost;Database=$Catalog;User Id=sa;Password=$saPassword;Encrypt=false;$ExtraParams"

    # Export SQLCMD env vars so the "Check result" step (and any consumer step) can call
    # the bare `sqlcmd` without explicit credentials, mirroring the Windows path.
    Export-Env -Name "SQLCMDSERVER" -Value "localhost"
    Export-Env -Name "SQLCMDUSER" -Value "sa"
    Export-Env -Name "SQLCMDPASSWORD" -Value $saPassword
    $Env:SQLCMDSERVER = "localhost"
    $Env:SQLCMDUSER = "sa"
    $Env:SQLCMDPASSWORD = $saPassword
}
elseif ($runnerOs -eq "Windows") {
    Write-Output "Running SQL Server in container $ContainerName inside WSL"

    $wslDistribution = $Env:WSL_DISTRIBUTION_OVERRIDE ?? "Debian"

    # Constrain the WSL2 VM (memory) and keep it from being shut down when idle, so
    # that Docker and the container are not torn down between this setup step and the
    # later test steps. Only write when the file is absent so local development
    # configurations are left untouched.
    $wslConfigPath = Join-Path $Env:USERPROFILE ".wslconfig"
    if (-not (Test-Path $wslConfigPath)) {
        $wslMemory = $Env:WSL_MEMORY_OVERRIDE ?? "4GB"
        Write-Output "Writing $wslConfigPath (memory=$wslMemory) to constrain the WSL2 VM"
        Set-Content -Path $wslConfigPath -Value "[wsl2]`nmemory=$wslMemory`nvmIdleTimeout=-1" -Encoding ASCII
    }

    Write-Output "::group::Preparing WSL ($wslDistribution)"

    wsl.exe --set-default-version 2 | Out-Null

    # Install the distribution if it is not already registered.
    $installedDistributions = ((wsl.exe --list --quiet) -replace "`0", "") |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -ne "" }

    if ($installedDistributions -notcontains $wslDistribution) {
        Write-Output "Installing $wslDistribution in WSL"
        wsl.exe --install $wslDistribution --web-download --no-launch
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to install $wslDistribution in WSL"
        }
    }
    else {
        Write-Output "$wslDistribution is already installed"
    }

    # Ensure Docker is installed inside the WSL distribution.
    Write-Output "Ensuring Docker is installed inside $wslDistribution"
    Invoke-Wsl -Distribution $wslDistribution -CheckExitCode -Command "command -v docker >/dev/null 2>&1 || { apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install --yes docker.io; }"

    # Start the Docker daemon via systemd when available, otherwise via the SysV service.
    Write-Output "Starting Docker daemon inside $wslDistribution"
    Invoke-Wsl -Distribution $wslDistribution -CheckExitCode -Command "docker info >/dev/null 2>&1 || { if [ -d /run/systemd/system ]; then systemctl start docker; else service docker start; fi; }"

    # Keep the WSL instance alive for the rest of the job. WSL terminates an instance when no
    # processes remain under its init (PID 2); a plain background process (e.g. sleep) does not
    # prevent this, but a D-Bus session bus launched through `wsl --exec` does. vmIdleTimeout
    # above covers the VM-level idle timeout; this covers the separate instance-level shutdown.
    # See https://github.com/microsoft/WSL/issues/10138 and
    # https://blog.lecoteauverdoyant.co.uk/articles/wsl-keep-alive.html
    Write-Output "Starting a D-Bus session to keep the WSL instance alive for the job"
    # dbus-launch ships in the dbus-x11 package (not dbus). Verify it is present afterwards so a
    # packaging change can never silently leave the instance unguarded again.
    Invoke-Wsl -Distribution $wslDistribution -CheckExitCode -Command "command -v dbus-launch >/dev/null 2>&1 || { apt-get update && apt-get install -y dbus-x11; }; command -v dbus-launch >/dev/null 2>&1 || { echo 'dbus-launch is unavailable after installing dbus-x11' >&2; exit 1; }"
    wsl.exe --distribution $wslDistribution --user root --exec /usr/bin/dbus-launch true
    if ($LASTEXITCODE -ne 0) {
        throw "dbus-launch keep-alive failed with exit code $LASTEXITCODE"
    }

    Write-Output "::endgroup::"

    # Determine the WSL VM IPv4 address early -- it's needed for the container hostname (DTC)
    # and for the connection string, and the VM's IP is stable once WSL is running.
    $wslIp = ((wsl.exe --distribution $wslDistribution --user root -- hostname -I) -replace "`0", "").Trim().Split(" ", [System.StringSplitOptions]::RemoveEmptyEntries) |
        Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } |
        Select-Object -First 1

    if (-not $wslIp) {
        throw "Could not determine the WSL IPv4 address"
    }

    $ipAddress = $wslIp
    Write-Output "WSL address: $ipAddress"

    if ($enableDtc) {
        # The container's DTC puts the container's hostname in its "whereabouts" blob. The Windows
        # host DTC must resolve that hostname to push the transaction. By default the container
        # hostname is the container ID, which the host can't resolve (0x8004D02A push failure).
        # Set a fixed hostname on the container and map it to the WSL2 IP (where Docker publishes
        # the DTC ports) in the Windows hosts file.
        # See https://github.com/microsoft/mssql-docker/issues/492 -- same hostname-lookup issue.
        $hostsPath = "$Env:SystemRoot\System32\drivers\etc\hosts"
        $hostsMarker = "sqlserver"
        if (-not (Get-Content $hostsPath -ErrorAction SilentlyContinue | Select-String $hostsMarker)) {
            Write-Output "Adding hosts entry: $wslIp sqlserver"
            Add-Content -Path $hostsPath -Value "$wslIp sqlserver"
        }
    }

    # Build the docker run arguments. Splatting an array keeps each value (incl. the SA password)
    # as a distinct argument, so no shell quoting is required when forwarding through wsl.exe.
    $dockerArgs = @(
        "run", "--name", $ContainerName, "--detach", "--restart", "unless-stopped",
        "--publish", "${port}:${port}",
        "-e", "ACCEPT_EULA=Y",
        "-e", "MSSQL_SA_PASSWORD=$saPassword",
        "-e", "MSSQL_PID=Developer",
        "-e", "MSSQL_COLLATION=$Collation"
    )

    if ($enableDtc) {
        Write-Output "Enabling distributed transactions (MSDTC) in the container"
        # 2019+ containers run as non-root and can't bind port 135, so the endpoint mapper
        # listens on 13500 and Docker maps host 135 -> 13500.
        # See https://learn.microsoft.com/sql/linux/containers/configure-distributed-transactions
        $dockerArgs += @(
            "-e", "MSSQL_RPC_PORT=13500",
            "-e", "MSSQL_DTC_TCP_PORT=51000",
            "--publish", "135:13500",
            "--publish", "51000:51000",
            "--hostname", "sqlserver"
        )
    }

    if ($enableFts) {
        Write-Output "Starting SQL Server container in setup mode for Full-Text Search installation..."
        $dockerArgs += @("--entrypoint", "/bin/bash", $image, "-lc", "sleep infinity")
    }
    else {
        $dockerArgs += $image
    }

    Write-Output "::group::Starting SQL Server container"
    & wsl.exe --distribution $wslDistribution -- docker @dockerArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to start SQL Server container in WSL"
    }
    & wsl.exe --distribution $wslDistribution -- docker ps --filter "name=$ContainerName"
    Write-Output "::endgroup::"

    if ($enableFts) {
        switch ($SqlServerVersion) {
            "2025" { $sqlEngineMajor = 17; $repoChannel = "2025" }
            "2022" { $sqlEngineMajor = 16; $repoChannel = "2022" }
            "2019" { $sqlEngineMajor = 15; $repoChannel = "2019" }
            default {
                throw "Unsupported sqlserver-version for FTS: '$SqlServerVersion'. Supported values: 2019, 2022, 2025."
            }
        }

        Write-Output "::group::Installing Full-Text Search support in the SQL Server container"
        Install-FullTextSearch -ContainerName $ContainerName -RepoChannel $repoChannel -SqlEngineMajor $sqlEngineMajor -WslDistribution $wslDistribution
        Write-Output "::endgroup::"

        Write-Output "Starting SQL Server process..."
        & wsl.exe --distribution $wslDistribution -- docker exec -d $ContainerName /opt/mssql/bin/sqlservr
    }

    # The Windows runner ships a native sqlcmd (MSSQL.CMDLnUtils). Wrap it so the self-signed
    # container certificate is trusted (-C). This keeps the "bare sqlcmd" contract documented in
    # the README working from Windows too. Locate it on PATH first, then in the usual Binn folders.
    $sqlcmdExe = (Get-Command sqlcmd.exe -ErrorAction SilentlyContinue).Source
    if (-not $sqlcmdExe) {
        $sqlcmdExe = @(
            "C:\Program Files\Microsoft SQL Server\*\Tools\Binn\sqlcmd.exe",
            "C:\Program Files\Microsoft SQL Server\Client SDK\*\Tools\Binn\sqlcmd.exe"
        ) | ForEach-Object { Get-Item $_ -ErrorAction SilentlyContinue } |
            Sort-Object FullName |
            Select-Object -ExpandProperty FullName -First 1
        if (-not $sqlcmdExe) {
            throw "sqlcmd.exe was not found on the runner. Install the SQL Server Command Line Utilities (MSSQL.CMDLnUtils)."
        }
    }
    Write-Output "Using sqlcmd: $sqlcmdExe"

    $shimDir = Join-Path $Env:RUNNER_TEMP "sqlcmd-shim"
    New-Item -ItemType Directory -Force -Path $shimDir | Out-Null
    $shimPath = Join-Path $shimDir "sqlcmd.cmd"
    Set-Content -Path $shimPath -Encoding ASCII -Value "@echo off`r`n`"$sqlcmdExe`" -C %*"
    Write-Output "Adding sqlcmd forwarding script to PATH"
    $shimDir | Out-File -FilePath $Env:GITHUB_PATH -Encoding utf8 -Append
    # GITHUB_PATH only affects subsequent steps; the Setup server section below runs in this
    # same process and needs the shim on PATH right now.
    $Env:PATH = "$shimDir;$Env:PATH"

    # Make the native sqlcmd connect to the container without explicit login parameters, mirroring
    # how the in-container sqlcmd is configured on Linux. Set these in the current process so
    # the Setup server section below (which runs in the same pwsh process) sees them, and also
    # export them for any subsequent GitHub Actions step that calls sqlcmd.
    $Env:SQLCMDSERVER = $ipAddress
    $Env:SQLCMDUSER = "sa"
    $Env:SQLCMDPASSWORD = $saPassword
    Export-Env -Name "SQLCMDSERVER" -Value $ipAddress
    Export-Env -Name "SQLCMDUSER" -Value "sa"
    Export-Env -Name "SQLCMDPASSWORD" -Value $saPassword

    Write-Output "Setting environment variable $ConnectionStringName to SQL connection string..."
    Export-Env -Name $ConnectionStringName -Value "Server=$ipAddress;Database=$Catalog;User Id=sa;Password=$saPassword;Encrypt=false;$ExtraParams"
}
else {
    throw "$runnerOs not supported"
}

# Wait for SQL Server to come up, then create the catalog. Throw if it never gets there,
# so a failed start fails here instead of surfacing later as a baffling "server not found".
#
# Catalog creation is idempotent (no-op if the db exists) and retries with -t 30: a fresh
# instance can deadlock or block on CREATE DATABASE while settling, and the timeout+retry
# makes the next attempt succeed instead of hanging the job.
function Invoke-SqlScript {
    param([string[]]$Arguments)

    $output = & sqlcmd @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        # Write-Host, not Write-Output — Write-Output would pollute the pipeline and make the
        # return value a truthy array instead of a clean $false, masking login failures.
        Write-Host ("  - sqlcmd failed with exit code ${exitCode}: " + ($output -join "; "))
    }
    return $exitCode -eq 0
}

Write-Output "::group::Waiting for SQL Server to be ready"
$ready = $false
for ($i = 1; $i -le 30; $i++) {
    Write-Output "Attempt $i/30 to connect to SQL Server..."
    $ok = Invoke-SqlScript -Arguments @("-b", "-t", "30", "-Q", "SELECT @@SERVERNAME as ServerName", "-h", "-1")
    if ($ok) {
        Write-Output "  - SQL Server is now ready"
        $ready = $true
        break
    }
    Write-Output "  - Not ready, sleeping for 5s"
    Start-Sleep -seconds 5
}
Write-Output "::endgroup::"
if (-not $ready) {
    throw "SQL Server did not become ready within 150s."
}

Write-Output "::group::Creating initial catalog '$Catalog'"
$catalogReady = $false
for ($i = 1; $i -le 10; $i++) {
    $ok = Invoke-SqlScript -Arguments @("-b", "-t", "30", "-Q", "IF DB_ID('$Catalog') IS NULL CREATE DATABASE [$Catalog]")
    if ($ok) { $catalogReady = $true; break }
    Write-Output "  - Catalog not yet created (attempt $i/10), sleeping for 5s"
    Start-Sleep -seconds 5
}
Write-Output "::endgroup::"
if (-not $catalogReady) {
    throw "Failed to create initial catalog '$Catalog'; SQL Server may not be accepting connections."
}

# Only succeed once SQL Server is stably responsive to logins, not just because the
# catalog was created once. A fresh instance can be briefly slow to complete logins while
# warming up -- enough to time out a consumer's default 15s login timeout -- so keep
# opening fresh logins against the catalog until one answers promptly.
Write-Output "::group::Confirming catalog '$Catalog' accepts logins"
$confirmed = $false
for ($i = 1; $i -le 10; $i++) {
    $ok = Invoke-SqlScript -Arguments @("-b", "-Q", "SET NOCOUNT ON; SELECT DB_NAME() AS CatalogName", "-d", $Catalog)
    if ($ok) { $confirmed = $true; break }
    Write-Output "  - SQL Server not yet responsive (attempt $i/10), sleeping for 5s"
    Start-Sleep -seconds 5
}
Write-Output "::endgroup::"
if (-not $confirmed) {
    throw "Initial catalog '$Catalog' created but SQL Server is not responding to logins within the login timeout."
}
