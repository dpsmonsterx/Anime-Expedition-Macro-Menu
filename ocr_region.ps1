param(
    [int]$X,
    [int]$Y,
    [int]$Width,
    [int]$Height
)

Add-Type -AssemblyName System.Drawing

$bitmap = New-Object System.Drawing.Bitmap $Width, $Height
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$graphics.CopyFromScreen($X, $Y, 0, 0, (New-Object System.Drawing.Size $Width, $Height))
$graphics.Dispose()

# Upscale smaller regions 2x before OCR - Windows OCR reads small game text much more reliably at
# a larger size (mirrors the persistent ocr_server.ps1). Coordinates are unaffected.
$tempFile = [System.IO.Path]::GetTempFileName() + ".png"
$scale = 1
if ($Height -lt 300 -and $Width -lt 900) { $scale = 2 }
if ($scale -ne 1) {
    $scaled = New-Object System.Drawing.Bitmap ($Width * $scale), ($Height * $scale)
    $sg = [System.Drawing.Graphics]::FromImage($scaled)
    $sg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $sg.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $sg.DrawImage($bitmap, 0, 0, ($Width * $scale), ($Height * $scale))
    $sg.Dispose()
    $scaled.Save($tempFile, [System.Drawing.Imaging.ImageFormat]::Png)
    $scaled.Dispose()
} else {
    $bitmap.Save($tempFile, [System.Drawing.Imaging.ImageFormat]::Png)
}
$bitmap.Dispose()

Add-Type -AssemblyName System.Runtime.WindowsRuntime

[Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime] | Out-Null
[Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime] | Out-Null
[Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics.Imaging, ContentType = WindowsRuntime] | Out-Null

Function Await($WinRtTask, $ResultType) {
    $asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
    })[0]
    $asTaskGeneric = $asTask.MakeGenericMethod($ResultType)
    $task = $asTaskGeneric.Invoke($null, @($WinRtTask))
    $task.Wait(-1) | Out-Null
    $task.Result
}

try {
    $file = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($tempFile)) ([Windows.Storage.StorageFile])
    $stream = Await ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
    $decoder = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
    $softwareBitmap = Await ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])

    $ocrEngine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
    if ($null -eq $ocrEngine) {
        Write-Output ""
    } else {
        $ocrResult = Await ($ocrEngine.RecognizeAsync($softwareBitmap)) ([Windows.Media.Ocr.OcrResult])
        Write-Output $ocrResult.Text
    }
} finally {
    Remove-Item $tempFile -ErrorAction SilentlyContinue
}
