# PLCNextSeniorScript.ps1 - Запуск проектов PLCnext (.pcwef, flat, .pcwex)
param(
    [Parameter(Mandatory=$true)]
    [string]$ProjectPath,
    [switch]$UseFlat,          # Принудительно flat
    [switch]$KeepExtracted     # Не удалять временные файлы после .pcwex
)

# ---------------- Функции ----------------
function Write-Log {
    param([string]$Message)
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogMessage = "[$Timestamp] $Message"
    Write-Host $LogMessage
    Add-Content -Path $LogFile -Value $LogMessage -Encoding UTF8
}

function Extract-VersionFromFolder {
    param([string]$FolderName)
    if ($FolderName -match 'PLCnext Engineer (\d+\.\d+(\.\d+)?)') { return $matches[1] }
    return $null
}

function Get-VersionNumber {
    param([string]$VerStr)
    if ($VerStr -match '^\d+\.\d+') { return [Version]$VerStr }
    return [Version]"0.0"
}

function Get-VersionFromPcwex {
    param([string]$PcwexPath)
    
    Write-Log "Extracting version from .pcwex archive: $PcwexPath"
    
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
        
        $Zip = [System.IO.Compression.ZipFile]::OpenRead($PcwexPath)
        $Entry = $Zip.Entries | Where-Object { 
            $_.FullName -eq "_properties/additional.xml" -or 
            $_.FullName -eq "_properties/additional.xml/"
        }
        
        if ($Entry) {
            Write-Log "Found _properties/additional.xml in archive"
            $Stream = $Entry.Open()
            $XmlDoc = New-Object System.Xml.XmlDocument
            $XmlDoc.Load($Stream)
            $Stream.Close()

            $Node = $XmlDoc.SelectSingleNode('//Property[@Key="ProductVersion"]')
            if ($Node -and $Node.Attributes["Value"]) {
                $Version = $Node.Attributes["Value"].Value
                Write-Log "Found ProductVersion in .pcwex: $Version"
                $Zip.Dispose()
                return $Version
            }
        } else {
            Write-Log "_properties/additional.xml not found in archive"
        }
        
        $Zip.Dispose()
    } catch { 
        Write-Log ("Error reading version from .pcwex: " + $_.Exception.Message) 
    }
    
    return $null
}

function Get-VersionFromAdditionalXml {
    param([string]$ProjectDir)
    
    $AdditionalXmlPath = Join-Path $ProjectDir "_properties\additional.xml"
    if (Test-Path $AdditionalXmlPath) {
        try {
            Write-Log "Reading version from _properties\additional.xml"
            $XmlContent = Get-Content $AdditionalXmlPath -Encoding UTF8 -Raw
            $XmlDoc = New-Object System.Xml.XmlDocument
            $XmlDoc.LoadXml($XmlContent)
            
            $ProductVersionNode = $XmlDoc.SelectSingleNode("//Property[@Key='ProductVersion']")
            if ($ProductVersionNode -and $ProductVersionNode.Attributes["Value"]) {
                $Version = $ProductVersionNode.Attributes["Value"].Value
                Write-Log "Found ProductVersion in additional.xml: $Version"
                return $Version
            }
        } catch {
            Write-Log "Error reading additional.xml: $($_.Exception.Message)"
        }
    }
    return $null
}

function Get-VersionFromStorageProperties {
    param([string]$ProjectDir)
    
    $ContentPath = Join-Path $ProjectDir "content"
    if (Test-Path $ContentPath) {
        $StorageFiles = Get-ChildItem -Path $ContentPath -Filter "StorageProperties*.xml" -ErrorAction SilentlyContinue
        foreach ($StorageFile in $StorageFiles) {
            try {
                Write-Log "Checking version in $($StorageFile.Name)"
                $Content = Get-Content $StorageFile.FullName -Encoding UTF8 -Raw
                if ($Content -match 'Key="ProductVersion"[^>]*Value="([^"]+)"') { 
                    $Version = $matches[1]
                    Write-Log "Found ProductVersion '$Version' in $($StorageFile.Name)"
                    return $Version
                }
            } catch { 
                Write-Log ("Warning parsing $($StorageFile.Name): " + $_.Exception.Message) 
            }
        }
    }
    return $null
}

function Test-PLCnextProject {
    param([string]$ProjectPath)
    
    Write-Log "Testing project structure: $ProjectPath"
    
    if (-not (Test-Path $ProjectPath)) {
        Write-Log "Project path does not exist"
        return $false
    }
    
    $Ext = [System.IO.Path]::GetExtension($ProjectPath).ToLower()
    
    if ($Ext -eq ".pcwex") {
        Write-Log "Testing .pcwex archive integrity"
        try {
            Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
            $Zip = [System.IO.Compression.ZipFile]::OpenRead($ProjectPath)
            $HasProjectFiles = $Zip.Entries | Where-Object { 
                $_.FullName -match "_(properties|data)/" -or 
                $_.FullName -match "\.(xml|pcwg)$" -or
                $_.FullName -eq "Solution.xml" -or
                $_.FullName -eq "Project.xml"
            }
            $Zip.Dispose()
            
            if ($HasProjectFiles) {
                Write-Log ".pcwex archive appears valid"
                return $true
            } else {
                Write-Log ".pcwex archive missing project files"
                return $false
            }
        } catch {
            Write-Log "Error testing .pcwex archive: $($_.Exception.Message)"
            return $false
        }
    }
    elseif ($Ext -eq ".pcwef") {
        Write-Log "Testing .pcwef launcher file"
        if ((Get-Item $ProjectPath).Length -lt 102400) {
            Write-Log ".pcwef file size looks correct"
            return $true
        } else {
            Write-Log "Suspicious .pcwef file size"
            return $false
        }
    }
    else {
        Write-Log "Testing flat project structure"
        $KeyFiles = @("Solution.xml", "Project.xml", "Project.pcwg")
        $KeyFolders = @("content", "_properties", "components")
        
        foreach ($File in $KeyFiles) {
            if (Test-Path (Join-Path $ProjectPath $File)) {
                Write-Log "Found key file: $File"
                return $true
            }
        }
        
        foreach ($Folder in $KeyFolders) {
            if (Test-Path (Join-Path $ProjectPath $Folder)) {
                Write-Log "Found key folder: $Folder"
                return $true
            }
        }
        
        Write-Log "No PLCnext project structure found"
        return $false
    }
}

# === НОВАЯ ФУНКЦИЯ: Определение версии по запущенному процессу ===
function Get-RunningIDEVersion {
    $Processes = Get-Process | Where-Object { $_.Name -match 'PLCNENG64|PLCnextEngineer' } | Select-Object Name, Path, Id -ErrorAction SilentlyContinue
    $RunningVersions = @{}

    foreach ($Proc in $Processes) {
        if ($Proc.Path) {
            $Dir = Split-Path $Proc.Path -Parent
            $FolderName = Split-Path $Dir -Leaf
            $Ver = Extract-VersionFromFolder $FolderName
            if ($Ver) {
                $RunningVersions[$Ver] = @{
                    Path = $Proc.Path
                    PID = $Proc.Id
                    Process = $Proc
                }
                Write-Log "Detected running IDE v$Ver at $($Proc.Path) (PID: $($Proc.Id))"
            }
        }
    }
    return $RunningVersions
}

# === НОВАЯ ФУНКЦИЯ: Закрытие всех экземпляров IDE ===
function Stop-AllIDE {
    Write-Log "Closing all running PLCnext Engineer instances..."
    $Processes = Get-Process | Where-Object { $_.Name -match 'PLCNENG64|PLCnextEngineer' } -ErrorAction SilentlyContinue
    foreach ($Proc in $Processes) {
        try {
            Write-Log "Terminating PID $($Proc.Id) ($($Proc.Path))"
            $Proc.CloseMainWindow() | Out-Null
            if (!$Proc.WaitForExit(10000)) {
                Write-Log "Force killing PID $($Proc.Id)"
                $Proc.Kill()
            }
        } catch {
            Write-Log "Failed to close PID $($Proc.Id): $($_.Exception.Message)"
        }
    }
    Start-Sleep -Seconds 3
}

# ---------------- Инициализация ----------------
$LogFile = "$env:TEMP\plcnext_open.log"
Write-Log "Starting script for project: $ProjectPath (UseFlat: $UseFlat, KeepExtracted: $KeepExtracted)"

if (-not (Test-Path $ProjectPath)) { 
    Write-Log "Error: Project path not found: $ProjectPath"
    exit 1 
}

$Ext = [System.IO.Path]::GetExtension($ProjectPath).ToLower()
$IsPcwefLauncher = $Ext -eq ".pcwef"
$IsPcwexArchive  = $Ext -eq ".pcwex"
$ProjectDir = $null
$LaunchPath = $ProjectPath
$Version = $null
$TempExtractDir = $null

# ---------------- Проверка целостности проекта ----------------
Write-Log "Verifying project integrity..."
$ProjectValid = Test-PLCnextProject -ProjectPath $ProjectPath

if (-not $ProjectValid) {
    Write-Log "Warning: Project may be corrupted or incomplete"
    $Continue = Read-Host "Project validation failed. Continue anyway? (y/n)"
    if ($Continue -ne 'y') {
        Write-Log "User cancelled due to project validation failure"
        exit 1
    }
}

# ---------------- Обработка .pcwex ----------------
if ($IsPcwexArchive) {
    Write-Log "Detected .pcwex archive project"
    $Version = Get-VersionFromPcwex -PcwexPath $ProjectPath
    
    if (-not $Version) {
        Write-Log "Could not extract version from archive directly, using temporary extraction"
        $TempExtractDir = Join-Path $env:TEMP ("PLCnextExtract_" + [IO.Path]::GetFileNameWithoutExtension($ProjectPath) + "_" + (Get-Random))
        Write-Log "Temporarily extracting .pcwex to: $TempExtractDir"
        
        try { 
            Expand-Archive -Path $ProjectPath -DestinationPath $TempExtractDir -Force
            Write-Log "Temporary extraction completed" 
            
            $PossibleRoots = @(
                (Join-Path $TempExtractDir "Project"),
                (Join-Path $TempExtractDir "project"),
                (Join-Path $TempExtractDir ([IO.Path]::GetFileNameWithoutExtension($ProjectPath))),
                $TempExtractDir
            )
            
            foreach ($Root in $PossibleRoots) {
                $AdditionalXmlPath = Join-Path $Root "_properties\additional.xml"
                $SolutionXmlPath = Join-Path $Root "Solution.xml"
                $ProjectXmlPath = Join-Path $Root "Project.xml"
                
                if ((Test-Path $AdditionalXmlPath) -or (Test-Path $SolutionXmlPath) -or (Test-Path $ProjectXmlPath)) {
                    $ProjectDir = $Root
                    Write-Log "Found project structure in: $ProjectDir"
                    break
                }
            }
            
            if (-not $ProjectDir) { $ProjectDir = $TempExtractDir }
            
            $Version = Get-VersionFromAdditionalXml -ProjectDir $ProjectDir
            if (-not $Version) {
                $Version = Get-VersionFromStorageProperties -ProjectDir $ProjectDir
            }
        } catch { 
            Write-Log ("Error during temporary extraction: " + $_.Exception.Message)
        }
    }
    
    $LaunchPath = $ProjectPath
    Write-Log "Will open original .pcwex file: $LaunchPath"
}

# ---------------- Обработка .pcwef ----------------
elseif ($IsPcwefLauncher) {
    $FileSize = (Get-Item $ProjectPath).Length
    Write-Log ".pcwef detected. Size: $FileSize bytes"

    $BaseName = [System.IO.Path]::GetFileNameWithoutExtension($ProjectPath)
    $FlatFolder = Join-Path (Split-Path $ProjectPath) "${BaseName}Flat"
    
    if (Test-Path $FlatFolder) { 
        $ProjectDir = $FlatFolder
        Write-Log "Associated flat folder found: $ProjectDir" 
        
        $Version = Get-VersionFromAdditionalXml -ProjectDir $ProjectDir
        if (-not $Version) {
            $Version = Get-VersionFromStorageProperties -ProjectDir $ProjectDir
        }
    } 
    
    if ($UseFlat -or -not $ProjectDir) {
        if (-not $ProjectDir) {
            Write-Host "Flat folder not found automatically. Enter flat folder path:" -ForegroundColor Yellow
            $ProjectDir = Read-Host
            if (-not (Test-Path $ProjectDir)) { 
                Write-Log "Error: Flat folder not found: $ProjectDir"
                exit 1 
            }
            
            $Version = Get-VersionFromAdditionalXml -ProjectDir $ProjectDir
            if (-not $Version) {
                $Version = Get-VersionFromStorageProperties -ProjectDir $ProjectDir
            }
        }
        $LaunchPath = $ProjectDir
        Write-Log "Using flat launch: $LaunchPath"
    } else {
        Write-Log "Using .pcwef launch: $LaunchPath"
    }
}

# ---------------- Flat проект ----------------
else { 
    $ProjectDir = Split-Path -Parent $ProjectPath
    Write-Log "Flat project - launch path: $LaunchPath" 
    
    $Version = Get-VersionFromAdditionalXml -ProjectDir $ProjectDir
    if (-not $Version) {
        $Version = Get-VersionFromStorageProperties -ProjectDir $ProjectDir
    }
}

# ---------------- Абсолютный путь ----------------
try {
    $AbsLaunchPath = (Resolve-Path $LaunchPath -ErrorAction Stop).Path
    Write-Log "Absolute launch path: $AbsLaunchPath"
} catch {
    Write-Log "Error: Cannot resolve launch path: $LaunchPath"
    exit 1
}

if ($Version) {
    Write-Log "Final detected project version: $Version"
} else {
    Write-Log "Warning: Could not detect project version"
}

# ---------------- Поиск IDE ----------------
$IDEBase = "C:\Program Files\PHOENIX CONTACT"
$ExeNames = @("PLCNENG64.exe", "PLCnextEngineer.exe")
$AvailableVersions = @{}

if (Test-Path $IDEBase) {
    $AvailableFolders = Get-ChildItem $IDEBase -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^PLCnext Engineer \d+\.\d+' }
    
    foreach ($Folder in $AvailableFolders) {
        $Ver = Extract-VersionFromFolder $Folder.Name
        if ($Ver) { 
            foreach ($Exe in $ExeNames) { 
                $FullPath = Join-Path $Folder.FullName $Exe
                if (Test-Path $FullPath) { 
                    $AvailableVersions[$Ver] = $FullPath
                    Write-Log "Found IDE version $Ver at $FullPath"
                    break 
                }
            } 
        }
    }
}

Write-Log "Available IDE versions: $($AvailableVersions.Keys -join ', ')"

# ---------------- Проверка запущенных IDE ----------------
$RunningIDEs = Get-RunningIDEVersion
$TargetIDEPath = $null

if ($Version -and $AvailableVersions.ContainsKey($Version)) {
    $TargetIDEPath = $AvailableVersions[$Version]
    Write-Log "Target IDE version: $Version -> $TargetIDEPath"
} else {
    $SortedVersions = $AvailableVersions.Keys | Sort-Object { Get-VersionNumber $_ } -Descending
    $ProjectVersion = if ($Version) { Get-VersionNumber $Version } else { [Version]"0.0" }
    $HigherMatch = $SortedVersions | Where-Object { (Get-VersionNumber $_) -ge $ProjectVersion } | Select-Object -First 1
    if ($HigherMatch) { 
        $TargetIDEPath = $AvailableVersions[$HigherMatch]
        Write-Log "Using closest higher version: $HigherMatch -> $TargetIDEPath"
    } elseif ($SortedVersions.Count -gt 0) {
        $Latest = $SortedVersions | Select-Object -First 1
        $TargetIDEPath = $AvailableVersions[$Latest]
        Write-Log "Using latest available version: $Latest -> $TargetIDEPath"
    }
}

if (-not $TargetIDEPath) {
    Write-Host "No suitable IDE found. Enter full path to PLCnext Engineer executable:" -ForegroundColor Yellow
    $TargetIDEPath = Read-Host
    if (-not (Test-Path $TargetIDEPath)) { 
        Write-Log "Error: IDE path not found: $TargetIDEPath"
        exit 1 
    }
}

# === ЛОГИКА УПРАВЛЕНИЯ ЗАПУЩЕННЫМИ IDE ===
if ($RunningIDEs.Count -gt 0) {
    $TargetVersion = Extract-VersionFromFolder (Split-Path (Split-Path $TargetIDEPath -Parent) -Leaf)

    if ($RunningIDEs.ContainsKey($TargetVersion)) {
        Write-Log "Correct IDE version $TargetVersion is already running. Opening project in existing instance."
        $IDEPath = $RunningIDEs[$TargetVersion].Path
    } else {
        Write-Log "Wrong IDE version running. Closing all instances and starting correct one: $TargetVersion"
        Stop-AllIDE
        $IDEPath = $TargetIDEPath
    }
} else {
    Write-Log "No IDE running. Starting required version: $TargetIDEPath"
    $IDEPath = $TargetIDEPath
}

Write-Log "Final IDE to use: $IDEPath"

# ---------------- Запуск ----------------
try {
    $AbsIDEPath = (Resolve-Path $IDEPath -ErrorAction Stop).Path
    $WorkingDir = Split-Path $AbsLaunchPath -Parent
    
    Write-Log "Launching IDE ($AbsIDEPath) with project: $AbsLaunchPath"
    Write-Log "Working directory: $WorkingDir"
    
    $LaunchCommand = "`"$AbsIDEPath`" `"$AbsLaunchPath`""
    Write-Log "EXECUTE COMMAND: $LaunchCommand"
    
    $Process = Start-Process -FilePath $AbsIDEPath -ArgumentList "`"$AbsLaunchPath`"" -WorkingDirectory $WorkingDir -PassThru
    Start-Sleep -Seconds 3
    
    if ($Process.HasExited) {
        Write-Log "IDE exited immediately. Exit code: $($Process.ExitCode)"
        # Попытка через папку (для .pcwex)
        if ($IsPcwexArchive -and $TempExtractDir -and (Test-Path $TempExtractDir)) {
            Write-Log "Trying to open extracted folder: $TempExtractDir"
            Start-Process -FilePath $AbsIDEPath -ArgumentList "`"$TempExtractDir`"" -WorkingDirectory (Split-Path $TempExtractDir -Parent)
        }
    } else {
        Write-Log "IDE launched successfully (PID: $($Process.Id))"
    }
    
} catch {
    Write-Log "Error launching IDE: $($_.Exception.Message)"
    Write-Host "Failed to launch IDE." -ForegroundColor Red
}

# ---------------- Очистка временной распаковки ----------------
if ($TempExtractDir -and (Test-Path $TempExtractDir) -and -not $KeepExtracted) {
    try { 
        Start-Sleep -Seconds 10
        if (Get-Process | Where-Object { $_.Name -match 'PLCNENG64|PLCnextEngineer' } -ErrorAction SilentlyContinue) {
            Write-Log "IDE is running — keeping temp files"
            Write-Host "Temporary files: $TempExtractDir" -ForegroundColor Yellow
        } else {
            Remove-Item -Path $TempExtractDir -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log "Temporary extraction removed: $TempExtractDir" 
        }
    } catch { 
        Write-Log ("Warning: Could not remove temp folder: " + $_.Exception.Message) 
    }
}

Write-Log "Script execution completed. Log: $LogFile"
# SIG # Begin signature block





# SIG # Begin signature block
# MIIFsAYJKoZIhvcNAQcCoIIFoTCCBZ0CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCD9YYYr9RBtmU/r
# 8gPWSsq3RPGj7FTVR+DOU1eW7wWypqCCAxwwggMYMIICAKADAgECAhB2esVCiLME
# m0HhZey9WXtWMA0GCSqGSIb3DQEBCwUAMCQxIjAgBgNVBAMMGVBvd2VyU2hlbGwg
# U2NyaXB0IFNpZ25pbmcwHhcNMjUxMDE0MDYyNDIyWhcNMjYxMDE0MDY0NDIyWjAk
# MSIwIAYDVQQDDBlQb3dlclNoZWxsIFNjcmlwdCBTaWduaW5nMIIBIjANBgkqhkiG
# 9w0BAQEFAAOCAQ8AMIIBCgKCAQEAxnVSptSHaGuPo4a6+dY3PKxNt10IuFJqawLI
# WAmxbw4N9N5DSw9ZTb8z0bFf01SXWNlCRejltOw8pa2IfT3IMUVw3aMHVEVtBc0+
# PGROFppci0GnjDPnJfzLtqcaxp5xUrzrnfo7XxpVugICaucdzhl0pmwSuDIPuMow
# /CvCpS/b0ACXhQ4rlyut+aRU9bI8qdEIJ3AG/0SBFcL34KCrtSrheMNCNmqXP4CI
# KTPhp9FUML3yJ3BfdtWvWjWsywyg0EzjnpY22ixalrQwhjnAn9LuTLjtMIjM8xBB
# YuEEVbjKiWQ1KTaSGUl55yzlRP/GUMgRwRRowkRjw+ovZG/bHQIDAQABo0YwRDAO
# BgNVHQ8BAf8EBAMCB4AwEwYDVR0lBAwwCgYIKwYBBQUHAwMwHQYDVR0OBBYEFMFJ
# PJL/lauc4uEaeH7Ak5nvpKECMA0GCSqGSIb3DQEBCwUAA4IBAQB3zQ5311Ck5Mdx
# WUi9BxN8B43NGxZUTQ4F7zJx6E4HEzNiMXoveGTO1osCezO3HtYepSdTMbDJrv/o
# FOiP3Ah4/S98I6O1sdZ7iORu7bSifFa1Mmb0kQmdg5cRN5uNXW8tGj+lFYgF4siU
# Xh/M8+GiDvMJNKG7LmJvlLZhhNmMoFrx/Ig8dfOc3/3/24JsK+2iXfobv2KLbobN
# ZZDh3kwDxA3LT0ylgJ+raCneCmH1um8C1igOQGrKfNnKvJCybT7Bw/6hvU0QMGQH
# h2yhcpg4BWoYuXLRf4jueM1WN2/CyRTmAi0nxaKq9pxo5Qgc6Wjb8SiU2oI1OXiy
# Di9fueZ5MYIB6jCCAeYCAQEwODAkMSIwIAYDVQQDDBlQb3dlclNoZWxsIFNjcmlw
# dCBTaWduaW5nAhB2esVCiLMEm0HhZey9WXtWMA0GCWCGSAFlAwQCAQUAoIGEMBgG
# CisGAQQBgjcCAQwxCjAIoAKAAKECgAAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcC
# AQQwHAYKKwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIE
# IPP5pvttWP05Wd6gz+sjE29p7k0rwmVT9eEjhOf15WKdMA0GCSqGSIb3DQEBAQUA
# BIIBAHSzBDsjmTxgzyEd0r/9f7eljobUoOWQxm9xh5XgHwLRuP2f46+iXuiuCDZ2
# HuiEiwvNG6fFBkm9m8UMpwvNEKyr8SBUU0KOWfnRzxIioNkern7OeG4wqxASmROD
# x2HhOGjQdxNZPXMRr0ruq32duvIKhq2CS89JfmJclqUhCUDKlvG+6OKNt9DA/W4u
# RcYstiUlMN03N5ZfLArQ3x7+8h6QFmF2ZIOhurI6HN6f2XjeLxiJKnIzoXctfRvI
# 7aGb/LjGloywBVHGHEpxKP4XZRUbZwMca7nUrdjUzkKQ0R9ig3PH/5go8YcQyfeD
# KHVrGc6C+J++05SVvqSxfF+byx0=
# SIG # End signature block
