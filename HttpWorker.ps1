param($Ctx)
# $Ctx: @{ Port; Key; State; WorkDir; TempDir; UiHtml; ScriptRoot }

$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Drawing | Out-Null

$u32src = @'
using System;
using System.Runtime.InteropServices;
public class U32 {
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT lpPoint);
  [DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, IntPtr dwExtraInfo);
  [DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
  [DllImport("user32.dll")] public static extern int GetSystemMetrics(int nIndex);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hwnd, IntPtr hdcBlt, uint nFlags);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
}
public struct POINT { public int X; public int Y; }
public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
'@
try { Add-Type -TypeDefinition $u32src -ReferencedAssemblies @('System.Drawing') -ErrorAction SilentlyContinue | Out-Null } catch {}
try { [U32]::SetProcessDPIAware() | Out-Null } catch {}

function Get-ScreenJpeg([int]$quality) {
    $x = [U32]::GetSystemMetrics(76); $y = [U32]::GetSystemMetrics(77)
    $w = [U32]::GetSystemMetrics(78); $h = [U32]::GetSystemMetrics(79)
    if ($w -lt 10 -or $h -lt 10) { $w = 1280; $h = 800; $x = 0; $y = 0 }
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($x, $y, 0, 0, $bmp.Size)
    $g.Dispose()
    $ms = New-Object System.IO.MemoryStream
    $codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' }
    $ep = New-Object System.Drawing.Imaging.EncoderParameters(1)
    $ep.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter([System.Drawing.Imaging.Encoder]::Quality, [long]$quality)
    $bmp.Save($ms, $codec, $ep)
    $bmp.Dispose()
    return $ms.ToArray()
}

function Send-Response($stream, [int]$code, [string]$statusText, [byte[]]$body, [string]$contentType, [hashtable]$extraHeaders) {
    $hdr = "HTTP/1.1 $code $statusText`r`nContent-Type: $contentType`r`nContent-Length: $($body.Length)`r`nConnection: close`r`nCache-Control: no-store`r`n"
    if ($extraHeaders) { foreach ($k in $extraHeaders.Keys) { $hdr += "$k`: $($extraHeaders[$k])`r`n" } }
    $hdr += "`r`n"
    $hb = [Text.Encoding]::ASCII.GetBytes($hdr)
    $stream.Write($hb, 0, $hb.Length)
    if ($body.Length -gt 0) { $stream.Write($body, 0, $body.Length) }
}

function Json($obj) { return ($obj | ConvertTo-Json -Compress -Depth 8) }
function UDec([string]$s) { return [Uri]::UnescapeDataString($s.Replace('+', ' ')) }
function ParseQuery([string]$q) {
    $m = @{}
    if ($q) { foreach ($pair in ($q -split '&')) { if ($pair -match '=') { $kv = $pair -split '=', 2; $m[(UDec $kv[0])] = (UDec $kv[1]) } elseif ($pair) { $m[(UDec $pair)] = '' } } }
    return $m
}

$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Any, $Ctx.Port)
$listener.Start()
$State = $Ctx.State
$State.HttpReady = $true

while (-not $State.Stop) {
    if (-not $listener.Pending()) { Start-Sleep -Milliseconds 120; continue }
    $client = $null
    try {
        $client = $listener.AcceptTcpClient()
        $client.ReceiveTimeout = 6000; $client.SendTimeout = 15000
        $stream = $client.GetStream()
        $buf = New-Object byte[] 65536
        $ms = New-Object System.IO.MemoryStream
        $headerEnd = -1
        while ($headerEnd -lt 0) {
            $n = $stream.Read($buf, 0, $buf.Length)
            if ($n -le 0) { throw 'eof' }
            $ms.Write($buf, 0, $n)
            $arr = $ms.ToArray()
            for ($i = 0; $i -lt $arr.Length - 3; $i++) {
                if ($arr[$i] -eq 13 -and $arr[$i+1] -eq 10 -and $arr[$i+2] -eq 13 -and $arr[$i+3] -eq 10) { $headerEnd = $i + 4; break }
            }
            if ($ms.Length -gt 262144) { throw 'too big header' }
        }
        $arr = $ms.ToArray()
        $headText = [Text.Encoding]::ASCII.GetString($arr, 0, $headerEnd)
        $lines = $headText -split "`r`n"
        $reqLine = $lines[0] -split ' '
        $method = $reqLine[0]; $rawUrl = $reqLine[1]
        $contentLength = 0
        foreach ($l in $lines) { if ($l -match '^Content-Length:\s*(\d+)') { $contentLength = [int]$matches[1] } }
        $body = [byte[]]@()
        if ($contentLength -gt 0) {
            $have = $arr.Length - $headerEnd
            $bodyBytes = New-Object System.Collections.Generic.List[byte]
            if ($have -gt 0) { $bodyBytes.AddRange([byte[]]($arr[$headerEnd..($arr.Length-1)])) }
            while ($bodyBytes.Count -lt $contentLength) {
                $n = $stream.Read($buf, 0, $buf.Length)
                if ($n -le 0) { break }
                $bodyBytes.AddRange([byte[]]($buf[0..($n-1)]))
            }
            $body = $bodyBytes.ToArray()[0..([Math]::Min($contentLength, $bodyBytes.Count)-1)]
        }

        $qmark = $rawUrl.IndexOf('?')
        if ($qmark -ge 0) { $path = UDec $rawUrl.Substring(0, $qmark); $q = ParseQuery $rawUrl.Substring($qmark + 1) }
        else { $path = UDec $rawUrl; $q = @{} }

        # ---- 鉴权 ----
        if ($q['key'] -ne $Ctx.Key) {
            $b = [Text.Encoding]::UTF8.GetBytes((Json @{ ok = $false; err = '需要有效的访问密钥 key' }))
            Send-Response $stream 401 'Unauthorized' $b 'application/json; charset=utf-8' $null
            $client.Close(); continue
        }

        switch -Regex ($path) {
            '^/$' {
                $html = [IO.File]::ReadAllText($Ctx.UiHtml, [Text.Encoding]::UTF8)
                $b = [Text.Encoding]::UTF8.GetBytes($html)
                Send-Response $stream 200 'OK' $b 'text/html; charset=utf-8' $null
            }
            '^/api/events$' {
                $since = 0; if ($q['since']) { $since = [int]$q['since'] }
                $ev = $State.Events
                $slice = @()
                $total = 0
                [System.Threading.Monitor]::Enter($State.SyncRoot)
                try {
                    $total = $ev.Count
                    if ($since -lt 0) { $since = 0 }
                    if ($since -lt $total) { for ($i = $since; $i -lt $total; $i++) { $slice += $ev[$i] } }
                } finally { [System.Threading.Monitor]::Exit($State.SyncRoot) }
                $pc = $null
                if ($State.PendingConfirm) { $pc = @{ id = $State.PendingConfirm.id; tool = $State.PendingConfirm.tool; preview = $State.PendingConfirm.preview } }
                $resp = @{ ok = $true; status = $State.Status; busy = [bool]$State.Busy; events = $slice; next = $total; queued = $State.Queue.Count; pendingConfirm = $pc; key = $Ctx.Key }
                $b = [Text.Encoding]::UTF8.GetBytes((Json $resp))
                Send-Response $stream 200 'OK' $b 'application/json; charset=utf-8' $null
            }
            '^/api/cmd$' {
                $text = ''
                if ($method -eq 'POST') {
                    $form = ParseQuery ([Text.Encoding]::UTF8.GetString($body))
                    $text = [string]$form['text']
                } elseif ($q['text']) { $text = [string]$q['text'] }
                $text = $text.Trim()
                if (-not $text) { $b = [Text.Encoding]::UTF8.GetBytes((Json @{ ok = $false; err = 'empty' })); Send-Response $stream 200 'OK' $b 'application/json; charset=utf-8' $null; $client.Close(); continue }
                if ($text.Length -gt 3500) { $b = [Text.Encoding]::UTF8.GetBytes((Json @{ ok = $false; err = '超过3500字上限' })); Send-Response $stream 200 'OK' $b 'application/json; charset=utf-8' $null; $client.Close(); continue }
                [System.Threading.Monitor]::Enter($State.SyncRoot)
                try { $State.Queue.Add($text) | Out-Null } finally { [System.Threading.Monitor]::Exit($State.SyncRoot) }
                $b = [Text.Encoding]::UTF8.GetBytes((Json @{ ok = $true; queued = $State.Queue.Count }))
                Send-Response $stream 200 'OK' $b 'application/json; charset=utf-8' $null
            }
            '^/api/confirm$' {
                $allow = $false
                if ($method -eq 'POST') {
                    $form = ParseQuery ([Text.Encoding]::UTF8.GetString($body))
                    $allow = ($form['allow'] -eq '1' -or $form['allow'] -eq 'true')
                } else { $allow = ($q['allow'] -eq '1') }
                $State.ConfirmResult = $allow
                $b = [Text.Encoding]::UTF8.GetBytes((Json @{ ok = $true; allow = $allow }))
                Send-Response $stream 200 'OK' $b 'application/json; charset=utf-8' $null
            }
            '^/api/reset$' {
                $State.Reset = $true
                $b = [Text.Encoding]::UTF8.GetBytes((Json @{ ok = $true }))
                Send-Response $stream 200 'OK' $b 'application/json; charset=utf-8' $null
            }
            '^/api/quit$' {
                $State.Stop = $true
                $b = [Text.Encoding]::UTF8.GetBytes((Json @{ ok = $true }))
                Send-Response $stream 200 'OK' $b 'application/json; charset=utf-8' $null
            }
            '^/shot\.jpg$' {
                $bytes = Get-ScreenJpeg 72
                Send-Response $stream 200 'OK' $bytes 'image/jpeg' $null
            }
            '^/api/files$' {
                $rel = [string]$q['p']
                $baseFull = [IO.Path]::GetFullPath($Ctx.WorkDir).TrimEnd('\')
                $target = if ($rel) { [IO.Path]::GetFullPath((Join-Path $baseFull $rel)) } else { $baseFull }
                if (-not ($target -eq $baseFull -or $target.StartsWith($baseFull + '\')) -or -not (Test-Path -LiteralPath $target -PathType Container)) {
                    $b = [Text.Encoding]::UTF8.GetBytes((Json @{ ok = $false; err = 'bad path' }))
                    Send-Response $stream 200 'OK' $b 'application/json; charset=utf-8' $null; $client.Close(); continue
                }
                $items = @()
                foreach ($it in (Get-ChildItem -LiteralPath $target -Force -ErrorAction SilentlyContinue)) {
                    $items += @{ name = $it.Name; dir = $it.PSIsContainer; size = $(if ($it.PSIsContainer) { 0 } else { $it.Length }); time = $it.LastWriteTime.ToString('MM-dd HH:mm') }
                }
                $relOut = if ($target.Length -gt $baseFull.Length) { $target.Substring($baseFull.Length + 1) } else { '' }
                $b = [Text.Encoding]::UTF8.GetBytes((Json @{ ok = $true; path = $relOut; items = $items }))
                Send-Response $stream 200 'OK' $b 'application/json; charset=utf-8' $null
            }
            '^/dl$' {
                $rel = [string]$q['p']
                $baseFull = [IO.Path]::GetFullPath($Ctx.WorkDir).TrimEnd('\')
                $target = [IO.Path]::GetFullPath((Join-Path $baseFull ([string]$rel)))
                if (-not ($target.StartsWith($baseFull + '\')) -or -not (Test-Path -LiteralPath $target -PathType Leaf)) {
                    $b = [Text.Encoding]::UTF8.GetBytes('not found')
                    Send-Response $stream 404 'Not Found' $b 'text/plain; charset=utf-8' $null; $client.Close(); continue
                }
                $bytes = [IO.File]::ReadAllBytes($target)
                $fn = [IO.Path]::GetFileName($target)
                $fnEnc = [Uri]::EscapeDataString($fn)
                Send-Response $stream 200 'OK' $bytes 'application/octet-stream' @{ 'Content-Disposition' = "attachment; filename*=UTF-8''$fnEnc" }
            }
            default {
                $b = [Text.Encoding]::UTF8.GetBytes('404')
                Send-Response $stream 404 'Not Found' $b 'text/plain; charset=utf-8' $null
            }
        }
    } catch {
        try {
            $errb = [Text.Encoding]::UTF8.GetBytes('500')
            Send-Response $stream 500 'Error' $errb 'text/plain; charset=utf-8' $null
        } catch {}
    } finally {
        if ($client) { try { $client.Close() } catch {} }
    }
}
$listener.Stop()
