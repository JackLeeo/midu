Set-Location -Path 'd:\gz\midu'
$git = 'C:\Program Files\Git\bin\git.exe'
if (-not (Test-Path $git)) { throw "git not found at $git" }
Write-Output '=== HEAD log ==='
& $git log --oneline -4
Write-Output '=== status ==='
& $git status --short
Write-Output '=== branch tracking ==='
& $git status -sb | Select-Object -First 1
exit 0