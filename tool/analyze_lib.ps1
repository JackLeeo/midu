Set-Location -Path 'd:\gz\midu'
D:\flutter\bin\flutter.bat analyze lib 2>&1 | Select-String -Pattern 'error -|warning -' | Select-Object -First 25
exit $LASTEXITCODE