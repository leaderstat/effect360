# scripts/strip_bom.ps1
# Removes the UTF-8 BOM from the given files.
# The `edit` tool on Windows re-adds a BOM, which the Gleam parser rejects.
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Paths)

$root = Split-Path -Parent $PSScriptRoot

foreach ($p in $Paths) {
    $full = if ([System.IO.Path]::IsPathRooted($p)) { $p } else { Join-Path $root $p }
    if (-not (Test-Path -LiteralPath $full)) {
        Write-Output "missing: $full"
        continue
    }
    $b = [System.IO.File]::ReadAllBytes($full)
    if ($b.Length -lt 3) { continue }
    if ($b[0] -eq 239 -and $b[1] -eq 187 -and $b[2] -eq 191) {
        $i = 0
        while ($i -lt $b.Length -and ($b[$i] -eq 239 -or $b[$i] -eq 187 -or $b[$i] -eq 191)) { $i++ }
        [System.IO.File]::WriteAllBytes($full, $b[$i..($b.Length-1)])
        Write-Output "stripped BOM: $full"
    }
}
