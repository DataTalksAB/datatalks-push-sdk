# Renders the sandbox demos' icons and launch images from the SVGs in this folder, into every demo app. Run it from
# anywhere on Windows after changing an SVG: it needs only Microsoft Edge and Windows PowerShell 5.1 or later.
# The PNGs it writes are committed, so building a demo never needs this.

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repository = Resolve-Path (Join-Path $here '..\..')
$edge = @(
    (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe' -ErrorAction SilentlyContinue).'(default)',
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $edge) { throw 'Microsoft Edge was not found.' }
$work = Join-Path ([System.IO.Path]::GetTempPath()) "datatalks-sandbox-render-$PID"
New-Item -ItemType Directory -Force $work | Out-Null

# Edge draws the SVG into a page of exactly the size asked for. Plain --headless keeps a transparent background.
function Render([string] $svg, [int] $width, [int] $height, [string] $background, [string] $output) {
    $source = 'file:///' + ((Join-Path $here $svg) -replace '\\', '/')
    $page = Join-Path $work 'page.html'
    "<html><body style='margin:0;background:$background'><img src='$source' style='display:block;width:${width}px;height:${height}px'></body></html>" |
        Out-File -Encoding utf8 $page
    # The outputs are committed: without this, a failed render would leave the old image in place unnoticed.
    Remove-Item $output -Force -ErrorAction SilentlyContinue
    $arguments = @('--headless', '--disable-gpu', '--hide-scrollbars', '--force-device-scale-factor=1',
        '--default-background-color=00000000', '--allow-file-access-from-files', "--user-data-dir=`"$work\profile`"",
        "--window-size=$width,$height", "--screenshot=`"$output`"", ('file:///' + ($page -replace '\\', '/')))
    Start-Process -FilePath $edge -ArgumentList $arguments -Wait -WindowStyle Hidden
    if (-not (Test-Path $output)) { throw "Edge didn't render $svg." }
}

function Resize([string] $source, [int] $size, [string] $output) {
    $image = [System.Drawing.Image]::FromFile($source)
    try {
        $bitmap = New-Object System.Drawing.Bitmap $size, $size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $attributes = New-Object System.Drawing.Imaging.ImageAttributes
        $attributes.SetWrapMode([System.Drawing.Drawing2D.WrapMode]::TileFlipXY)
        $graphics.DrawImage($image, (New-Object System.Drawing.Rectangle 0, 0, $size, $size), 0, 0, $image.Width, $image.Height, [System.Drawing.GraphicsUnit]::Pixel, $attributes)
        New-Item -ItemType Directory -Force (Split-Path -Parent $output) | Out-Null
        $bitmap.Save($output, [System.Drawing.Imaging.ImageFormat]::Png)
        $graphics.Dispose()
        $bitmap.Dispose()
    }
    finally {
        $image.Dispose()
    }
}

function Copy-To([string] $source, [string] $output) {
    New-Item -ItemType Directory -Force (Split-Path -Parent $output) | Out-Null
    Copy-Item $source $output -Force
}

$icon = Join-Path $work 'icon.png'
$round = Join-Path $work 'icon-round.png'
$foreground = Join-Path $work 'icon-foreground.png'
Render 'icon.svg' 1024 1024 'transparent' $icon
Render 'icon-round.svg' 1024 1024 'transparent' $round
Render 'icon-foreground.svg' 1024 1024 'transparent' $foreground

# Android launcher icons: the legacy square and round ones, and the adaptive foreground over @color/ic_launcher_background.
$densities = @{ mdpi = 48; hdpi = 72; xhdpi = 96; xxhdpi = 144; xxxhdpi = 192 }
$capacitorApps = @('sdks\capacitor\samples\plain', 'sdks\capacitor\samples\ionic-react')
$androidResources = @('sdks\android\samples\compose\src\main\res') + ($capacitorApps | ForEach-Object { "$_\android\app\src\main\res" })
foreach ($resources in $androidResources) {
    foreach ($density in $densities.Keys) {
        $size = $densities[$density]
        $folder = Join-Path $repository "$resources\mipmap-$density"
        Resize $icon $size (Join-Path $folder 'ic_launcher.png')
        Resize $round $size (Join-Path $folder 'ic_launcher_round.png')
        Resize $foreground ([int]($size * 2.25)) (Join-Path $folder 'ic_launcher_foreground.png')
    }
}

# iOS app icons: one 1024 image each.
Copy-To $icon (Join-Path $repository 'sdks\ios\samples\swiftui\DataTalksPushSample\Assets.xcassets\AppIcon.appiconset\AppIcon.png')
foreach ($app in $capacitorApps) {
    Copy-To $icon (Join-Path $repository "$app\ios\App\App\Assets.xcassets\AppIcon.appiconset\AppIcon-512@2x.png")
}

# MAUI composes its icons itself, from a background and this foreground.
Copy-To $foreground (Join-Path $repository 'sdks\maui\samples\maui-app\Resources\AppIcon\appiconfg.png')

# The mark as it is, for the headers and MAUI's launch screen. The Android vector drawables (datatalks_mark.xml and
# ic_stat_datatalks.xml) carry the same path data and are kept by hand.
$mark = Join-Path $here 'mark.svg'
Copy-To $mark (Join-Path $repository 'sdks\ios\samples\swiftui\DataTalksPushSample\Assets.xcassets\DataTalksMark.imageset\mark.svg')
Copy-To $mark (Join-Path $repository 'sdks\maui\samples\maui-app\Resources\Images\datatalks_mark.svg')
Copy-To $mark (Join-Path $repository 'sdks\maui\samples\maui-app\Resources\Splash\splash.svg')

# Capacitor's launch images, at the sizes its template ships.
$splashes = @{
    'drawable\splash.png' = '480x320'
    'drawable-land-mdpi\splash.png' = '480x320'; 'drawable-land-hdpi\splash.png' = '800x480'
    'drawable-land-xhdpi\splash.png' = '1280x720'; 'drawable-land-xxhdpi\splash.png' = '1600x960'
    'drawable-land-xxxhdpi\splash.png' = '1920x1280'
    'drawable-port-mdpi\splash.png' = '320x480'; 'drawable-port-hdpi\splash.png' = '480x800'
    'drawable-port-xhdpi\splash.png' = '720x1280'; 'drawable-port-xxhdpi\splash.png' = '960x1600'
    'drawable-port-xxxhdpi\splash.png' = '1280x1920'
}
foreach ($path in $splashes.Keys) {
    $width, $height = $splashes[$path] -split 'x'
    $rendered = Join-Path $work 'splash.png'
    Render 'splash.svg' $width $height '#1F1451' $rendered
    foreach ($app in $capacitorApps) {
        Copy-To $rendered (Join-Path $repository "$app\android\app\src\main\res\$path")
    }
}
$iosSplash = Join-Path $work 'splash-ios.png'
Render 'splash.svg' 2732 2732 '#1F1451' $iosSplash
foreach ($app in $capacitorApps) {
    foreach ($name in 'splash-2732x2732.png', 'splash-2732x2732-1.png', 'splash-2732x2732-2.png') {
        Copy-To $iosSplash (Join-Path $repository "$app\ios\App\App\Assets.xcassets\Splash.imageset\$name")
    }
}

Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
Write-Output 'Rendered the sandbox icons and launch images.'
