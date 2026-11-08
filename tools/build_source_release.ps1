# Source release builder: strict allowlist. Never recursively copy the entire workspace.
[CmdletBinding()]
param(
    [string]$Version = '0.1.1-review',
    [string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $root 'release' }
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$temp = Join-Path ([IO.Path]::GetTempPath()) ('ysmb-release-' + [guid]::NewGuid().ToString('N'))
$packageName = "yandex-station-matter-bridge-$Version"
$stage = Join-Path $temp $packageName
New-Item -ItemType Directory -Force -Path $stage | Out-Null

# Only these source paths are eligible. Secrets, results, local configuration,
# generated obj/bin files and unreviewed additions are NEVER included by default.
$rootFiles = @('.gitignore', '.gitattributes', 'README.md', 'LICENSE', 'NOTICE',
    'CHANGELOG.md', 'CONTRIBUTING.md', 'SECURITY.md', 'RELEASE_NOTES.md',
    'client/pyproject.toml', 'client/config.example.toml', 'client/README.md',
    'client/LICENSE', 'client/NOTICE', 'client/SECURITY.md', 'client/CHANGELOG.md')
$sourceDirs = @(
    @{ Path = 'docs'; Extensions = @('.md'); Recursive = $true },
    @{ Path = 'examples'; Extensions = @('.psd1', '.http') },
    @{ Path = 'scripts'; Extensions = @('.ps1', '.py', '.sh'); Flat = $true },
    @{ Path = 'scripts/mock_ssh_launcher'; Extensions = @('.csproj', '.cs'); Flat = $true },
    @{ Path = 'tests'; Extensions = @('.ps1', '.py', '.sh'); Flat = $true },
    @{ Path = 'tools'; Extensions = @('.ps1', '.py'); Flat = $true },
    @{ Path = '.github/workflows'; Extensions = @('.yml', '.yaml'); Flat = $true },
    @{ Path = 'client/src'; Extensions = @('.py'); Recursive = $true },
    @{ Path = 'client/tests'; Extensions = @('.py'); Recursive = $true },
    @{ Path = 'client/station'; Extensions = @('.sh'); Recursive = $true },
    @{ Path = 'client/contrib'; Extensions = @('.service'); Recursive = $true },
    @{ Path = 'client/reports'; Extensions = @('.md'); Recursive = $true }
)

function Copy-ReleaseSource([string]$RelativePath) {
    if ($RelativePath -match '(^|[\\/])\.\.([\\/]|$)') { throw "Unsafe release path: $RelativePath" }
    $src = Join-Path $root $RelativePath
    $item = Get-Item -LiteralPath $src -Force
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Release source must be a regular file: $RelativePath"
    }
    $dest = Join-Path $stage $RelativePath
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
    Copy-Item -LiteralPath $src -Destination $dest -Force
}

try {
    foreach ($name in $rootFiles) { Copy-ReleaseSource $name }
    foreach ($spec in $sourceDirs) {
        $path = Join-Path $root $spec.Path
        if (-not (Test-Path -LiteralPath $path -PathType Container)) { throw "Missing source directory: $($spec.Path)" }
        $files = if($spec.ContainsKey('Recursive') -and [bool]$spec.Recursive){
            Get-ChildItem -LiteralPath $path -File -Force -Recurse
        }else{
            Get-ChildItem -LiteralPath $path -File -Force
        }
        foreach ($file in $files) {
            if ($spec.Extensions -notcontains $file.Extension) { continue }
            $relative = $file.FullName.Substring($root.Length + 1)
            Copy-ReleaseSource $relative
        }
    }
    $manifestPath = Join-Path $stage 'MANIFEST.sha256'
    $manifest = @(Get-ChildItem -LiteralPath $stage -Recurse -File -Force |
        Sort-Object FullName |
        ForEach-Object {
            $relative = $_.FullName.Substring($stage.Length + 1).Replace('\', '/')
            '{0}  {1}' -f (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant(), $relative
        })
    $manifest | Set-Content -LiteralPath $manifestPath -Encoding ascii

    $zip = Join-Path $OutputDirectory "$packageName-source.zip"
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory($temp, $zip, [IO.Compression.CompressionLevel]::Optimal, $false)
    $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $([IO.Path]::GetFileName($zip))" |
        Set-Content -LiteralPath (Join-Path $OutputDirectory 'SHA256SUMS.txt') -Encoding ascii
    [pscustomobject]@{
        Zip = $zip
        SHA256 = $hash
        Files = (Get-ChildItem -LiteralPath $stage -Recurse -File).Count
    }
} finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
