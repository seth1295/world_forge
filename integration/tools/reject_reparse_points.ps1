param(
    [Parameter(Mandatory = $true)]
    [string]$BundlePath
)

$ErrorActionPreference = 'Stop'
$root = Get-Item -LiteralPath $BundlePath -Force
if (($root.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    exit 2
}

$pending = [System.Collections.Generic.Stack[string]]::new()
$pending.Push($root.FullName)
while ($pending.Count -gt 0) {
    $directory = $pending.Pop()
    foreach ($item in Get-ChildItem -LiteralPath $directory -Force) {
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            exit 3
        }
        if ($item.PSIsContainer) {
            $pending.Push($item.FullName)
        }
    }
}
exit 0
