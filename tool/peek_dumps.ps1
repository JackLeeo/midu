# 扫描 dump 下的 html，识别各 dump 属于哪本书（h1）与是否含目录链接
$files = Get-ChildItem 'D:\gz\日志\dump' -Filter *.html
foreach ($f in $files) {
  $t = Get-Content $f.FullName -TotalCount 500 -Encoding UTF8 | Out-String
  $title = ''
  if ($t -match '<h1[^>]*>([^<]{1,60})') { $title = $matches[1] }
  $bookLinks = ([regex]::Matches($t, '/book/[\d]+')).Count
  $listDdA = ([regex]::Matches($t, 'class="list[^"]*"')).Count
  "$($f.Name) | h1=$title | /book/ links=$bookLinks | .list nodes=$listDdA"
}