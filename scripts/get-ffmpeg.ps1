# Downloads the LGPL shared FFmpeg 9 build (DLLs only) into native/ffmpeg.
$ErrorActionPreference = 'Stop'
$dst = Join-Path $PSScriptRoot '..\native\ffmpeg'
if ((Test-Path $dst) -and (Get-ChildItem $dst -Filter 'avcodec-*.dll' -ErrorAction SilentlyContinue)) { Write-Host "FFmpeg already present"; return }
New-Item -ItemType Directory -Force $dst | Out-Null
$url = 'https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-n9.0-latest-win64-lgpl-shared-9.0.zip'
$zip = Join-Path $env:TEMP 'ffmpeg-lgpl-shared.zip'
Write-Host "Downloading $url"
Invoke-WebRequest $url -OutFile $zip
$tmp = Join-Path $env:TEMP 'ffmpeg-extract'
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Expand-Archive $zip $tmp
Get-ChildItem $tmp -Recurse -Filter '*.dll' | Where-Object { $_.DirectoryName -like '*\bin' } | Copy-Item -Destination $dst -Force
Write-Host ("FFmpeg DLLs: " + (Get-ChildItem $dst -Filter *.dll).Count)
