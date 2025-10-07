# open_plcnext.ps1 - Гарантированный запуск с .pcwef (fallback только при краше IDE)
param(
    [Parameter(Mandatory=$true)]
    [string]$ProjectPath,
    [switch]$UseFlat  # Опционально: принудительно flat (игнорировать .pcwef)
)

# Функция для логирования
function Write-Log {
    param([string]$Message)
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogMessage = "[$Timestamp] $Message"
    Write-Host $LogMessage
    Add-Content -Path $LogFile -Value $LogMessage -Encoding UTF8
}

# Функция для извлечения версии из имени папки
function Extract-VersionFromFolder {
    param([string]$FolderName)
    if ($FolderName -match 'PLCnext Engineer (\d+\.\d+(\.\d+)?)') {
        return $matches[1]
    }
    return $null
}

# Функция для парсинга версии из строки для сортировки
function Get-VersionNumber {
    param([string]$VerStr)
    if ($VerStr -match '^\d+\.\d+') {
        return [Version]$VerStr
    }
    return [Version]"0.0"
}

# Инициализация
$LogFile = "$env:TEMP\plcnext_open.log"
Write-Log "Starting script for project: $ProjectPath (UseFlat: $UseFlat)"

if (-not (Test-Path $ProjectPath)) {
    Write-Log "Error: Project path not found: $ProjectPath"
    exit 1
}

# Проверка типа: .pcwef-launcher или flat
$IsPcwefLauncher = [System.IO.Path]::GetExtension($ProjectPath).ToLower() -eq ".pcwef"
$ProjectDir = $null
$LaunchPath = $ProjectPath  # По умолчанию .pcwef или flat

if ($IsPcwefLauncher) {
    $FileSize = (Get-Item $ProjectPath).Length
    Write-Log ".pcwef launcher detected. Size: ${FileSize} bytes"
    
    # Авто-определение flat ТОЛЬКО для парсинга версии (не для запуска)
    $BaseName = [System.IO.Path]::GetFileNameWithoutExtension($ProjectPath)
    $FlatFolder = Join-Path (Split-Path $ProjectPath) "${BaseName}Flat"
    if (Test-Path $FlatFolder) {
        $ProjectDir = $FlatFolder
        Write-Log "Associated flat for version parsing: $ProjectDir"
    } else {
        Write-Host "Enter path to flat folder for version parsing (e.g., D:\work\Git\Folder\ProjectFlat):" -ForegroundColor Yellow
        $ProjectDir = Read-Host
        if (-not (Test-Path $ProjectDir)) {
            Write-Log "Error: Flat folder not found: $ProjectDir"
            exit 1
        }
    }
    
    # Запуск ВСЕГДА с .pcwef (игнор размера, fallback только при краше)
    if ($UseFlat) {
        $LaunchPath = $ProjectDir
        Write-Log "Forced flat launch (ignoring .pcwef)"
    } else {
        Write-Log "Launch path: .pcwef file ($LaunchPath)"
    }
} else {
    $ProjectDir = Split-Path -Parent $ProjectPath
    Write-Log "Flat project - launch path: $LaunchPath"
}

# Абсолютный путь для IDE (фикс DriveInfo)
$AbsLaunchPath = (Resolve-Path $LaunchPath).Path
Write-Log "Absolute launch path: $AbsLaunchPath"

# Проверка структуры в ProjectDir (для версии)
$KeyFiles = @("Solution.xml", "Project.xml", "content\StorageProperties*.xml")
$IsValid = $false
foreach ($Pattern in $KeyFiles) {
    $Files = Get-ChildItem -Path $ProjectDir -Filter $Pattern -Recurse -Depth 2 -ErrorAction SilentlyContinue
    if ($Files.Count -gt 0) {
        $IsValid = $true
        break
    }
}
if (-not $IsValid) {
    Write-Log "Error: Invalid PLCnext structure in $ProjectDir"
    exit 1
}

# Поиск версии в ProjectDir (из flat)
$Version = $null
$StorageFiles = Get-ChildItem -Path (Join-Path $ProjectDir "content") -Filter "StorageProperties*.xml" -ErrorAction SilentlyContinue
foreach ($StorageFile in $StorageFiles) {
    try {
        $Content = Get-Content $StorageFile.FullName -Encoding UTF8 -Raw -ErrorAction SilentlyContinue
        if ($Content -match 'Key="ProductVersion"[^>]*Value="([^"]+)"') {
            $Version = $matches[1].Trim()
            Write-Log "Found ProductVersion '${Version}' in ${StorageFile.Name}"
            break
        }
    } catch {
        Write-Log "Warning: Could not parse ${StorageFile.Name}: $($_.Exception.Message)"
    }
}

# Fallback на другие файлы
if (-not $Version) {
    $VersionFiles = @("Solution.xml", "Project.xml", "VersionInformation.xml")
    foreach ($File in $VersionFiles) {
        $XmlPath = Join-Path $ProjectDir $File
        if (Test-Path $XmlPath) {
            try {
                $Content = Get-Content $XmlPath -Encoding UTF8 -Raw -ErrorAction SilentlyContinue
                if ($Content -match 'BuildNumber="([^"]+)"') {
                    $Version = $matches[1]
                    Write-Log "Found BuildNumber '${Version}' in $File"
                    break
                } elseif ($Content -match 'PlatformVersion="([^"]+)"') {
                    $Version = $matches[1]
                    Write-Log "Found PlatformVersion '${Version}' in $File"
                    break
                } elseif ($Content -match 'FirmwareVersion="([^"]+)"') {
                    $Version = $matches[1]
                    Write-Log "Found FirmwareVersion '${Version}' in $File"
                    break
                }
            } catch {
                Write-Log "Warning: Could not parse $File : $($_.Exception.Message)"
            }
        }
    }
}

# Поиск IDE (PHOENIX CONTACT)
$IDEBase = "C:\Program Files\PHOENIX CONTACT"
$ExeNames = @("PLCNENG64.exe", "PLCnextEngineer.exe")

$AvailableFolders = Get-ChildItem $IDEBase -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^PLCnext Engineer \d+\.\d+' }
$AvailableVersions = @{}
foreach ($Folder in $AvailableFolders) {
    $Ver = Extract-VersionFromFolder $Folder.Name
    if ($Ver) {
        foreach ($Exe in $ExeNames) {
            $FullPath = Join-Path $Folder.FullName $Exe
            if (Test-Path $FullPath) {
                $AvailableVersions[$Ver] = $FullPath
                Write-Log "Found version ${Ver} at $FullPath"
                break
            }
        }
    }
}

Write-Log "Available IDE versions: $($AvailableVersions.Keys -join ', ')"

# Определение IDEPath
$IDEPath = $null
if ($Version -and $AvailableVersions.ContainsKey($Version)) {
    $IDEPath = $AvailableVersions[$Version]
    Write-Log "Using exact match for version ${Version} : $IDEPath"
} elseif ($AvailableVersions.Count -gt 0) {
    $SortedVersions = $AvailableVersions.Keys | Sort-Object { Get-VersionNumber $_ } -Descending
    $HigherMatch = $SortedVersions | Where-Object { (Get-VersionNumber $_) -ge (Get-VersionNumber $Version) } | Select-Object -First 1
    if ($HigherMatch) {
        $IDEPath = $AvailableVersions[$HigherMatch]
        Write-Log "No exact $Version. Using closest higher: ${HigherMatch} at $IDEPath"
        $Version = $HigherMatch
    } else {
        $Latest = $SortedVersions | Select-Object -First 1
        $IDEPath = $AvailableVersions[$Latest]
        Write-Log "No matching. Using latest: ${Latest} at $IDEPath (compatibility warning)"
        $Version = $Latest
    }
} else {
    foreach ($Exe in $ExeNames) {
        $RootPath = Join-Path $IDEBase $Exe
        if (Test-Path $RootPath) {
            $IDEPath = $RootPath
            Write-Log "Using root exe: $IDEPath"
            break
        }
    }
    if (-not $IDEPath) {
        Write-Host "No IDE found. Enter full path to exe:" -ForegroundColor Yellow
        $IDEPath = Read-Host
        if (-not (Test-Path $IDEPath)) {
            Write-Log "Error: Path not found: $IDEPath"
            exit 1
        }
    }
}

Write-Log "Final IDE path: $IDEPath"

# Запуск с абсолютным .pcwef/flat
$AbsIDEPath = (Resolve-Path $IDEPath).Path
$WorkingDir = (Split-Path $AbsLaunchPath)
Write-Log "Launching IDE ($AbsIDEPath) with path: $AbsLaunchPath (working dir: $WorkingDir)"
$Process = Start-Process -FilePath $AbsIDEPath -ArgumentList "`"$AbsLaunchPath`"" -WorkingDirectory $WorkingDir -PassThru

# Проверка запуска
Start-Sleep -Seconds 5
if ($Process.HasExited) {
    Write-Log "Warning: IDE exited early (possible crash). Check %TEMP%\PLCnext Engineer\Ade.log"
    Write-Log "Tip: If ArgumentException, create valid .pcwef: Open flat in IDE, File > Save As > Compressed."
    # Fallback на flat, если .pcwef
    if ($IsPcwefLauncher -and -not $UseFlat -and (Test-Path $ProjectDir)) {
        Write-Log "Fallback to flat launch"
        $FallbackProcess = Start-Process -FilePath $AbsIDEPath -ArgumentList "`"$ProjectDir`"" -WorkingDirectory $ProjectDir -PassThru
        if (-not $FallbackProcess.HasExited) {
            Write-Log "Fallback successful (PID: $($FallbackProcess.Id))"
        }
    }
} else {
    Write-Log "IDE launched successfully (PID: $($Process.Id))"
}

Write-Log "Done. Log: $LogFile"