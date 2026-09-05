Set-Location -Path 'd:\gz\midu'
$git = 'C:\Program Files\Git\bin\git.exe'
if (-not (Test-Path $git)) { throw "git not found at $git" }
& $git status --short
Write-Output '---DIFF STAT---'
& $git diff --stat
exit 0