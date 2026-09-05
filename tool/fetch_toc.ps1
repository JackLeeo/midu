# 抓取 zzs5（猪猪书网/久久小说共用镜像）本书详情页与目录页，落盘供离线验证选择器。
$ErrorActionPreference = 'Continue'
$ua = 'Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1'
$outDir = 'D:\gz\日志\toc'
$targets = @(
  @{ name = 'zzs5_detail_37326'; url = 'https://www.zzs5.net/book/37326/' },
  @{ name = 'zzs5_toc_37326';   url = 'https://www.zzs5.net/book/37326/' }
)
foreach ($t in $targets) {
  try {
    $r = Invoke-WebRequest -Uri $t.url -UseBasicParsing -TimeoutSec 25 -Headers @{ 'User-Agent' = $ua; 'Referer' = 'https://www.zzs5.net/' }
    $path = Join-Path $outDir "$($t.name).html"
    $r.Content | Out-File -FilePath $path -Encoding utf8
    "OK $($t.name) status=$($r.StatusCode) len=$($r.Content.Length) -> $path"
  } catch {
    "FAIL $($t.name) :: $($_.Exception.Message)"
  }
}