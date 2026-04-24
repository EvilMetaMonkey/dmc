$ErrorActionPreference = 'Stop'

# Define our paths
$sourceDir = Join-Path $PSScriptRoot 'build\dmc\bundle'
$binBase = 'C:\bin'
$targetDir = Join-Path $binBase 'dmc'
$targetBinDir = Join-Path $targetDir 'bin'

if (-not (Test-Path -LiteralPath $sourceDir)) {
    Write-Error "Build not found. Please run 'dart build cli -o build/dmc' first."
}

# Ensure C:\bin exists
if (-not (Test-Path -LiteralPath $binBase)) {
    New-Item -Path $binBase -ItemType Directory | Out-Null
}

# Clear out any old installation
if (Test-Path -LiteralPath $targetDir) {
    Remove-Item -Path $targetDir -Recurse -Force
}

# Move the new bundle
Move-Item -Path $sourceDir -Destination $targetDir -Force
Write-Host "Installed DMC bundle to $targetDir"

# Update the System PATH to point to the new bin/ folder
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$pathParts = @()
if (-not [string]::IsNullOrWhiteSpace($userPath)) {
    $pathParts = $userPath -split ';'
}

$hasBin = $false
foreach ($part in $pathParts) {
    if ($part.Trim().TrimEnd('\') -ieq $targetBinDir.TrimEnd('\')) {
        $hasBin = $true
        break
    }
}

if (-not $hasBin) {
    $newUserPath = if ([string]::IsNullOrWhiteSpace($userPath)) {
        $targetBinDir
    }
    else {
        "$userPath;$targetBinDir"
    }
    [Environment]::SetEnvironmentVariable('Path', $newUserPath, 'User')
    Write-Host "Added $targetBinDir to your user PATH!"
}
else {
    Write-Host "$targetBinDir is already in your user PATH."
}

Write-Host "Installation complete! Restart your terminal to use 'dmc' globally."
