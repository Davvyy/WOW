# 앱 아이콘 원본 PNG 를 만든다: 브랜드 청록 바탕 + 흰 'C 링 + 불꽃'(Challenge + Calories).
# 불꽃은 앱이 쓰는 Icons.local_fire_department_rounded(0xf86b)를 Flutter SDK 의 Material Icons 폰트에서 외곽선으로 그린다.
#   powershell -ExecutionPolicy Bypass -File app/assets/icon/make_icon.ps1
# 만든 뒤 크기별 아이콘: cd app; dart run flutter_launcher_icons
param(
  [string]$Font = (Join-Path (Split-Path (Get-Command flutter).Source) 'cache\artifacts\material_fonts\materialicons-regular.otf')
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$out = Split-Path -Parent $MyInvocation.MyCommand.Path
$brand = [System.Drawing.ColorTranslator]::FromHtml('#0B6E70')   # lib/core/theme/tokens.dart 라이트 brand

$fonts = New-Object System.Drawing.Text.PrivateFontCollection
$fonts.AddFontFile($Font)
$family = $fonts.Families[0]

# 마크 비율(보이는 영역 한 변 대비): C 바깥 지름 0.58, 획 0.094, 열린 각 84°, 불꽃 높이 0.245(C 안쪽과 고르게 띄움).
# C 는 오른쪽이 열려 왼쪽으로 쏠려 보이므로 마크 전체를 0.012 만큼 오른쪽으로 옮기고, 불꽃은 C 의 정중앙에 둔다.
function Draw-Mark($g, [double]$cx, [double]$cy, [double]$visible) {
  $stroke = $visible * 0.094
  $r = $visible * 0.58 / 2 - $stroke / 2
  $x = $cx + $visible * 0.012
  $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::White), ([float]$stroke)
  $pen.StartCap = 'Round'; $pen.EndCap = 'Round'
  $g.DrawArc($pen, [float]($x - $r), [float]($cy - $r), [float](2 * $r), [float](2 * $r), [float]42, [float]276)

  $path = New-Object System.Drawing.Drawing2D.GraphicsPath
  $path.AddString([string][char]0xf86b, $family, 0, 1000, (New-Object System.Drawing.PointF 0, 0), [System.Drawing.StringFormat]::GenericTypographic)
  $b = $path.GetBounds()
  $s = $visible * 0.245 / $b.Height
  $m = New-Object System.Drawing.Drawing2D.Matrix
  $m.Translate([float]$x, [float]$cy)
  $m.Scale($s, $s)
  $m.Translate(-($b.X + $b.Width / 2), -($b.Y + $b.Height / 2))
  $path.Transform($m)
  $g.FillPath([System.Drawing.Brushes]::White, $path)
}

# visible: 캔버스 중 실제로 보이는 한 변(적응형 전경은 108dp 중 72dp)
function Save-Icon([string]$name, [double]$visible, $background) {
  $bmp = New-Object System.Drawing.Bitmap 1024, 1024, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = 'AntiAlias'
  $g.PixelOffsetMode = 'HighQuality'
  if ($background) { $g.Clear($background) } else { $g.Clear([System.Drawing.Color]::Transparent) }
  Draw-Mark $g 512 512 $visible
  $bmp.Save((Join-Path $out $name), [System.Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose(); $bmp.Dispose()
  "$name"
}

# iOS·옛 Android: 바탕까지 채운 정사각형(iOS 는 투명 영역 불가, 모서리는 OS 가 깎는다)
Save-Icon 'app_icon.png' 1024 $brand
# Android 적응형 전경: 108dp 캔버스 중 보이는 72dp 기준으로 같은 비율 → C 지름 ≈ 42dp(안전 영역 66dp 안)
Save-Icon 'app_icon_foreground.png' (1024 * 72 / 108) $null
# Android 13+ 테마 아이콘(단색)·앱 안 로고(색 입혀 씀): 마크만
Save-Icon 'app_icon_monochrome.png' (1024 * 72 / 108) $null
