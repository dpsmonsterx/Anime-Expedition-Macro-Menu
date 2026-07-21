# Persistent OCR helper. Loads the .NET/WinRT OCR assemblies and creates the OCR engine ONCE at
# startup, then loops servicing scan requests via a tiny file-based protocol - so the macro pays
# the (~0.5s) assembly/engine startup only once for the whole session instead of on every scan.
#
# Protocol (all files live in -Dir):
#   ocr_ready.txt  - written once the engine is up; the macro waits for this before sending requests
#   ocr_req.txt    - request written by the macro: "<token>|<x>|<y>|<w>|<h>" (this server deletes it)
#   ocr_resp.txt   - response written by this server: "<token>|<recognized text>"
#   ocr_stop.txt   - the macro writes this to ask the server to exit cleanly
# Both req and resp are written to a ".tmp" first and then renamed, so a reader never sees a
# half-written file.
param([string]$Dir)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Runtime.WindowsRuntime

[Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime] | Out-Null
[Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime] | Out-Null
[Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics.Imaging, ContentType = WindowsRuntime] | Out-Null

# Reflection handle for turning a WinRT IAsyncOperation into an awaitable Task - resolved once.
$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
})[0]
function Await($WinRtTask, $ResultType) {
    $m = $asTaskGeneric.MakeGenericMethod($ResultType)
    $task = $m.Invoke($null, @($WinRtTask))
    $task.Wait(-1) | Out-Null
    $task.Result
}

$reqFile   = Join-Path $Dir 'ocr_req.txt'
$respFile  = Join-Path $Dir 'ocr_resp.txt'
$respTmp   = Join-Path $Dir 'ocr_resp.txt.tmp'
$readyFile = Join-Path $Dir 'ocr_ready.txt'
$stopFile  = Join-Path $Dir 'ocr_stop.txt'
$tempPng   = Join-Path $Dir 'ocr_capture.png'

$ocrEngine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()

# Signal readiness only after the engine exists, so the macro's first request isn't sent into a
# still-initializing process.
[System.IO.File]::WriteAllText($readyFile, '1')

while ($true) {
    if (Test-Path $stopFile) { break }
    if (-not (Test-Path $reqFile)) { Start-Sleep -Milliseconds 15; continue }

    $line = $null
    try { $line = [System.IO.File]::ReadAllText($reqFile) } catch { Start-Sleep -Milliseconds 5; continue }
    try { Remove-Item $reqFile -Force -ErrorAction SilentlyContinue } catch {}
    if ([string]::IsNullOrWhiteSpace($line)) { continue }

    $parts = $line.Trim() -split '\|'
    if ($parts.Count -lt 5) { continue }
    $token = $parts[0]
    $text = ''

    $bmp = $null; $graphics = $null; $scaled = $null; $sg = $null; $stream = $null; $softwareBitmap = $null
    try {
        $x = [int]$parts[1]; $y = [int]$parts[2]; $w = [int]$parts[3]; $h = [int]$parts[4]
        if ($w -gt 0 -and $h -gt 0 -and $null -ne $ocrEngine) {
            $bmp = New-Object System.Drawing.Bitmap $w, $h
            $graphics = [System.Drawing.Graphics]::FromImage($bmp)
            $graphics.CopyFromScreen($x, $y, 0, 0, (New-Object System.Drawing.Size $w, $h))
            $graphics.Dispose(); $graphics = $null

            # Windows OCR recognizes small text (game banners/buttons) far more reliably when the
            # image is enlarged. Upscale smaller regions 2x with high-quality interpolation; leave
            # already-large regions at 1x so OCR doesn't slow down needlessly. Coordinates are
            # unaffected - only the captured pixels are scaled before recognition.
            $scale = 1
            if ($h -lt 300 -and $w -lt 900) { $scale = 2 }
            if ($scale -ne 1) {
                $scaled = New-Object System.Drawing.Bitmap ($w * $scale), ($h * $scale)
                $sg = [System.Drawing.Graphics]::FromImage($scaled)
                $sg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $sg.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
                $sg.DrawImage($bmp, 0, 0, ($w * $scale), ($h * $scale))
                $sg.Dispose(); $sg = $null
                $scaled.Save($tempPng, [System.Drawing.Imaging.ImageFormat]::Png)
                $scaled.Dispose(); $scaled = $null
            } else {
                $bmp.Save($tempPng, [System.Drawing.Imaging.ImageFormat]::Png)
            }
            $bmp.Dispose(); $bmp = $null

            $file = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($tempPng)) ([Windows.Storage.StorageFile])
            $stream = Await ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
            $decoder = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
            $softwareBitmap = Await ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
            $ocrResult = Await ($ocrEngine.RecognizeAsync($softwareBitmap)) ([Windows.Media.Ocr.OcrResult])
            $text = $ocrResult.Text
        }
    } catch {
        $text = ''
    } finally {
        # Dispose everything so thousands of scans over a long session don't leak handles/memory.
        if ($null -ne $softwareBitmap) { try { $softwareBitmap.Dispose() } catch {} }
        if ($null -ne $stream)         { try { $stream.Dispose() } catch {} }
        if ($null -ne $sg)             { try { $sg.Dispose() } catch {} }
        if ($null -ne $scaled)         { try { $scaled.Dispose() } catch {} }
        if ($null -ne $graphics)       { try { $graphics.Dispose() } catch {} }
        if ($null -ne $bmp)            { try { $bmp.Dispose() } catch {} }
    }

    try {
        [System.IO.File]::WriteAllText($respTmp, ($token + '|' + $text))
        Move-Item -Path $respTmp -Destination $respFile -Force
    } catch {}
}

# Cleanup on exit.
foreach ($f in @($readyFile, $stopFile, $tempPng)) {
    try { Remove-Item $f -Force -ErrorAction SilentlyContinue } catch {}
}
