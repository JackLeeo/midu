Set-Location -Path 'd:\gz\midu'
$git = 'C:\Program Files\Git\bin\git.exe'
if (-not (Test-Path $git)) { throw "git not found at $git" }
& $git diff '33eb668~1' 33eb668 -- lib/book_sources/legado/legado_runtime.dart
exit 0