param(
  [string]$TestFile = 'test/probe_dump_zzs5_test.dart'
)
Set-Location -Path 'd:\gz\midu'
Remove-Item Env:FILTER_SRC -ErrorAction SilentlyContinue
Remove-Item Env:BOOK_SOURCE_PROXY -ErrorAction SilentlyContinue
D:\flutter\bin\flutter.bat test $TestFile -j 1 2>&1 | Select-Object -Last 300
exit $LASTEXITCODE