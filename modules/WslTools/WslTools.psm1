function Invoke-Wsl {
    param(
        [Parameter(Mandatory = $true)][string]$Distribution,
        [Parameter(Mandatory = $true)][string]$Command,
        [switch]$CheckExitCode
    )

    wsl.exe --distribution $Distribution --user root -- bash -c $Command

    if ($CheckExitCode -and $LASTEXITCODE -ne 0) {
        throw "WSL command failed with exit code $LASTEXITCODE`: $Command"
    }
}

# Convert a Windows path (e.g. "D:\a\foo\bar.sh" or "\\?\D:\foo\bar.sh") to the equivalent
# path inside the default WSL distribution (e.g. "/mnt/d/a/foo/bar.sh"). We do this in pure
# PowerShell rather than round-tripping through `wsl.exe -- wslpath -u` because the WSL
# interop arg parser mangles the backslashes when a Windows path is passed as a single argv
# element (the path arrives at the WSL side as a slash-less string).
function ConvertTo-WslPath {
    param(
        [Parameter(Mandatory = $true)][string]$WindowsPath
    )

    if ($WindowsPath -notmatch '^[A-Za-z]:') {
        throw "ConvertTo-WslPath expects a Windows-style absolute path with a drive letter, got: $WindowsPath"
    }

    # Strip the extended-length \\?\ prefix and the drive letter, normalise separators.
    $trimmed = $WindowsPath -replace '^\\\\\?\\', ''
    $drive = $trimmed.Substring(0, 1).ToLowerInvariant()
    $rest = $trimmed.Substring(2) -replace '\\', '/'
    return "/mnt/$drive/$rest"
}

Export-ModuleMember -Function Invoke-Wsl, ConvertTo-WslPath
