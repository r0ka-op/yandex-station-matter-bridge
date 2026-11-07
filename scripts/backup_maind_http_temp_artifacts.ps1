[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$SshAlias,
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $root ('results\runtime\pre-visual-color-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$ssh = Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
$archivePath = Join-Path $OutputDirectory 'station-temp-artifacts.tar'
$extractPath = Join-Path $OutputDirectory 'extracted'
New-Item -ItemType Directory -Path $extractPath -Force | Out-Null

function Invoke-SshCaptureBytes([string]$RemoteCommand, [string]$Destination) {
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $ssh
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($argument in @('-T','-o','BatchMode=yes','-o','ConnectTimeout=10',$SshAlias,$RemoteCommand)) {
        [void]$psi.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $psi
    if (-not $process.Start()) { throw 'Could not start SSH archive transport' }
    try {
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $stream = [IO.File]::Open($Destination,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try { $copyTask = $process.StandardOutput.BaseStream.CopyToAsync($stream); [void]$copyTask.GetAwaiter().GetResult() }
        finally { $stream.Dispose() }
        $process.WaitForExit()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $stderr | Set-Content -Encoding UTF8 (Join-Path $OutputDirectory 'archive.ssh_stderr.txt')
        if ($process.ExitCode -ne 0) { throw "SSH archive transport failed with code $($process.ExitCode): $stderr" }
    } finally { $process.Dispose() }
}

$remoteManifestCommand = @'
set -eu
for root in /tmp/maind-http-test /tmp/maind_http_runtime_test_remote.sh; do
  if [ -f "$root" ]; then sha256sum "$root"; fi
  if [ -d "$root" ]; then find "$root" -type f -exec sha256sum {} \; | sort; fi
done
'@
$remoteManifest = & $ssh -T -o BatchMode=yes -o ConnectTimeout=10 $SshAlias $remoteManifestCommand
if ($LASTEXITCODE -ne 0) { throw 'Could not obtain remote artifact manifest' }
$remoteManifest | Set-Content -Encoding ASCII (Join-Path $OutputDirectory 'remote.sha256')
if (@($remoteManifest).Count -eq 0) { throw 'No completed experiment artifacts were found to back up' }

Invoke-SshCaptureBytes "tar -C /tmp -cf - maind-http-test maind_http_runtime_test_remote.sh" $archivePath
if ((Get-Item -LiteralPath $archivePath).Length -le 0) { throw 'Downloaded TAR is empty' }
& tar.exe -tf $archivePath | Set-Content -Encoding UTF8 (Join-Path $OutputDirectory 'archive.list.txt')
if ($LASTEXITCODE -ne 0) { throw 'Downloaded TAR failed validation' }
& tar.exe -xf $archivePath -C $extractPath
if ($LASTEXITCODE -ne 0) { throw 'Downloaded TAR extraction failed' }

$checks = [Collections.Generic.List[object]]::new()
foreach ($line in $remoteManifest) {
    if ($line -notmatch '^([0-9a-fA-F]{64})\s+(.+)$') { throw "Invalid remote manifest line: $line" }
    $remoteHash = $Matches[1].ToLowerInvariant()
    $remotePath = $Matches[2]
    if ($remotePath.StartsWith('/tmp/')) { $relative = $remotePath.Substring(5) }
    else { throw "Unexpected remote artifact path: $remotePath" }
    $localPath = Join-Path $extractPath ($relative -replace '/', [IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $localPath -PathType Leaf)) { throw "Archived file missing locally: $relative" }
    $localHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $localPath).Hash.ToLowerInvariant()
    $checks.Add([pscustomobject][ordered]@{path=$remotePath;remote_sha256=$remoteHash;local_sha256=$localHash;match=($remoteHash -ceq $localHash)})
}
if (@($checks | Where-Object { -not $_.match }).Count -ne 0) { throw 'Remote/local SHA-256 mismatch' }
$result = [ordered]@{
    generated_utc = [DateTime]::UtcNow.ToString('o')
    ssh_alias = $SshAlias
    archive = $archivePath
    archive_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $archivePath).Hash.ToLowerInvariant()
    verified_file_count = $checks.Count
    all_file_hashes_match = $true
    files = @($checks)
}
$result | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 (Join-Path $OutputDirectory 'backup_manifest.json')
"DIAGNOSTICS_BACKUP=PASS`nOUTPUT=$OutputDirectory`nARCHIVE_SHA256=$($result.archive_sha256)"
