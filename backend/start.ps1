# Tidal Echo relay - Windows launcher (replaces systemd)
# Reads relay.env as UTF-8 (PS 5.1 defaults to GBK and mangles Chinese values),
# sets env vars, then starts the backend.
# ASCII only in this file: PS 5.1 reads BOM-less .ps1 as GBK.
$here = $PSScriptRoot
if (-not $here) { $here = 'C:\Users\sxc\Tidal_Echo\backend' }

Get-Content (Join-Path $here 'relay.env') -Encoding UTF8 | ForEach-Object {
    $line = $_.Trim()
    if ($line -and -not $line.StartsWith('#')) {
        $i = $line.IndexOf('=')
        if ($i -gt 0) {
            $k = $line.Substring(0, $i).Trim()
            $v = $line.Substring($i + 1).Trim()
            [Environment]::SetEnvironmentVariable($k, $v, 'Process')
        }
    }
}

$env:PYTHONUTF8 = '1'
& (Join-Path $here '.venv\Scripts\python.exe') (Join-Path $here 'app.py')
