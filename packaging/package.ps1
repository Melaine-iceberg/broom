<#
.SYNOPSIS
    broom 发布打包:自包含单文件便携包(zip)+ MSIX 安装包。

.DESCRIPTION
    1) dotnet publish 自包含发布两份:单文件版打便携 zip(带 portable.txt 便携模式标记),
       多文件版作为 MSIX 包布局;
    2) 从 Assets\broom.ico 生成 MSIX 所需 PNG 徽标,按 packaging\msix\AppxManifest.xml
       模板生成清单(版本取自 broom.csproj <Version>);
    3) makeappx.exe 打出 broom_<版本>_<架构>.msix,signtool.exe 签名 —— 给了 -CertThumbprint
       就用该证书,否则复用 / 生成 CurrentUser\My 下主题为 -Publisher 的自签名开发证书,
       并把公钥导出为 .cer 供建立信任。

    产物统一落在 artifacts\。构建 MSIX 需要 Windows SDK(用到 makeappx.exe / signtool.exe)。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File packaging\package.ps1

.EXAMPLE
    packaging\package.ps1 -Runtime win-arm64 -CertThumbprint 0123456789ABCDEF0123456789ABCDEF01234567
#>
[CmdletBinding()]
param(
    [string]$Configuration = "Release",
    [ValidateSet("win-x64", "win-arm64", "win-x86")]
    [string]$Runtime = "win-x64",
    [string]$Version = "",
    [string]$OutputDir = "",
    [string]$Publisher = "CN=broom",
    [string]$CertThumbprint = "",
    [switch]$SkipMsix,
    [switch]$SkipPortable)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$projectPath = Join-Path $repoRoot "broom.csproj"
$iconPath = Join-Path (Join-Path $repoRoot "Assets") "broom.ico"
$manifestTemplate = Join-Path (Join-Path $PSScriptRoot "msix") "AppxManifest.xml"
if (-not $OutputDir) { $OutputDir = Join-Path $repoRoot "artifacts" }

function Find-KitTool([string]$Name) {
    $kitsBin = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\bin"
    if (Test-Path $kitsBin) {
        $versions = Get-ChildItem $kitsBin -Directory |
            Where-Object { $_.Name -match '^\d+\.\d+\.\d+' } |
            Sort-Object { [version]$_.Name } -Descending
        foreach ($v in $versions) {
            foreach ($arch in @("x64", "x86")) {
                $path = Join-Path (Join-Path $v.FullName $arch) $Name
                if (Test-Path $path) { return $path }
            }
        }
    }

    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Invoke-Publish([string]$OutDir, [bool]$SingleFile) {
    Write-Host "==> dotnet publish ($Runtime 自包含) -> $OutDir"
    if (Test-Path $OutDir) { Remove-Item $OutDir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

    $publishArgs = @($projectPath, "-c", $Configuration, "-r", $Runtime, "--self-contained", "true",
        "-o", $OutDir, "--nologo", "-v", "minimal")
    if ($SingleFile) {
        $publishArgs += @("-p:PublishSingleFile=true", "-p:IncludeNativeLibrariesForSelfExtract=true")
    } else {
        $publishArgs += "-p:PublishSingleFile=false"
    }

    & dotnet publish @publishArgs
    if ($LASTEXITCODE -ne 0) { throw "dotnet publish 失败(退出码 $LASTEXITCODE)。" }
}

# MSIX 徽标:从 ico 取默认帧按比例放大到清单要求的尺寸(44 / 50 / 150 / 310 方形 + 310x150 宽)
function New-MsixLogos([string]$OutDir) {
    Add-Type -AssemblyName System.Drawing
    $icon = New-Object System.Drawing.Icon($iconPath)
    $src = $icon.ToBitmap()
    $targets = @(
        @{ Name = "Logo44.png"; Width = 44; Height = 44 },
        @{ Name = "StoreLogo.png"; Width = 50; Height = 50 },
        @{ Name = "Logo150.png"; Width = 150; Height = 150 },
        @{ Name = "Logo310.png"; Width = 310; Height = 310 },
        @{ Name = "Wide310.png"; Width = 310; Height = 150 }
    )

    foreach ($t in $targets) {
        $w = [int]$t.Width
        $h = [int]$t.Height
        $bmp = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        # 保持宽高比居中绘制:方形目标即铺满,宽目标两侧留透明
        $size = [Math]::Min($w, $h)
        $g.DrawImage($src, [int](($w - $size) / 2), [int](($h - $size) / 2), $size, $size)
        $g.Dispose()
        $bmp.Save((Join-Path $OutDir $t.Name), [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
    }

    $src.Dispose()
    $icon.Dispose()
}

function Write-MsixManifest([string]$OutPath, [string]$MsixVersion) {
    $text = [System.IO.File]::ReadAllText($manifestTemplate)
    $text = $text.Replace("{{VERSION}}", $MsixVersion)
    $text = $text.Replace("{{PUBLISHER}}", $Publisher)
    $text = $text.Replace("{{DISPLAY_NAME}}", "broom")
    $text = $text.Replace("{{PUBLISHER_DISPLAY_NAME}}", "broom")
    $text = $text.Replace("{{DESCRIPTION}}", "Windows 垃圾清理工具")
    [System.IO.File]::WriteAllText($OutPath, $text, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-SigningCert([string]$Thumbprint) {
    if ($Thumbprint) {
        $cert = Get-ChildItem Cert:\CurrentUser\My, Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
            Where-Object { $_.Thumbprint -eq $Thumbprint } |
            Select-Object -First 1
        if (-not $cert) { throw "找不到指纹为 $Thumbprint 的证书。" }
        return $cert
    }

    # 自签名开发证书:同主题、未过期、有私钥的代码签名证书(EKU 按 OID 匹配,友好名随系统语言变化)可复用,避免每次打包都生成一张
    $cert = Get-ChildItem Cert:\CurrentUser\My |
        Where-Object {
            $_.Subject -eq $Publisher -and $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date).AddDays(30) -and
            $_.EnhancedKeyUsageList.ObjectId -contains "1.3.6.1.5.5.7.3.3"
        } |
        Select-Object -First 1

    if (-not $cert) {
        Write-Host "==> 生成自签名开发证书($Publisher)"
        $cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject $Publisher `
            -CertStoreLocation Cert:\CurrentUser\My -KeyExportPolicy Exportable
    }

    return $cert
}

# ---------- 版本号(以 broom.csproj <Version> 为准) ----------
if (-not $Version) {
    [xml]$csproj = Get-Content -Path $projectPath -Raw
    $Version = @($csproj.Project.PropertyGroup | ForEach-Object { $_.Version }) |
        Where-Object { $_ } |
        Select-Object -First 1
    if (-not $Version) { throw "无法从 broom.csproj <Version> 读取版本号,请用 -Version 指定。" }
}

# MSIX 要求四段式版本
$msixVersion = $Version
if ($msixVersion -match '^\d+\.\d+\.\d+$') { $msixVersion = "$msixVersion.0" }
if ($msixVersion -notmatch '^\d+\.\d+\.\d+\.\d+$') {
    throw "版本号 '$Version' 不是 MAJOR.MINOR.PATCH[.BUILD] 形式。"
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
Write-Host "==> broom $Version($msixVersion)$Runtime $Configuration"
$artifactBase = "broom-$Version-$Runtime"

# ---------- 1. 便携包:自包含单文件 + 便携模式标记 ----------
if (-not $SkipPortable) {
    $portableDir = Join-Path $OutputDir "publish-portable"
    Invoke-Publish $portableDir $true

    # 便携标记:与 broom.exe 同目录即启用便携模式(设置 / 历史 / 隔离区写本目录 data\)
    $marker = @"
broom 便携模式标记:此文件与 broom.exe 同目录时,设置、清理历史与隔离区都写入本目录的 data\ 子目录,整个目录可直接拷走。
删除此文件则恢复常规模式(数据存 %APPDATA%\broom 与 %LOCALAPPDATA%\broom)。
"@
    [System.IO.File]::WriteAllText((Join-Path $portableDir "portable.txt"), $marker, (New-Object System.Text.UTF8Encoding($false)))

    $zipPath = Join-Path $OutputDir "$artifactBase-portable.zip"
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
    $tar = Get-Command tar -ErrorAction SilentlyContinue
    if ($tar) {
        Write-Host "==> 打便携包 -> $zipPath"
        & $tar.Source -a -c -f $zipPath -C $portableDir .
        if ($LASTEXITCODE -ne 0) { throw "打便携包失败(退出码 $LASTEXITCODE)。" }
    } else {
        Write-Host "==> 打便携包(Compress-Archive)-> $zipPath"
        Compress-Archive -Path (Join-Path $portableDir "*") -DestinationPath $zipPath -Force
    }
}

# ---------- 2. MSIX:布局 + 清单 + 徽标 + makeappx 打包 + 签名 ----------
if (-not $SkipMsix) {
    $makeappx = Find-KitTool "makeappx.exe"
    $signtool = Find-KitTool "signtool.exe"
    if (-not $makeappx) { throw "找不到 makeappx.exe:请安装 Windows SDK(打包 MSIX 必需)。" }
    if (-not $signtool) { throw "找不到 signtool.exe:请安装 Windows SDK(签名 MSIX 必需)。" }

    $msixPublishDir = Join-Path $OutputDir "publish-msix"
    Invoke-Publish $msixPublishDir $false

    $layoutDir = Join-Path $OutputDir "msix-layout"
    if (Test-Path $layoutDir) { Remove-Item $layoutDir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $layoutDir | Out-Null
    Write-Host "==> 拼 MSIX 包布局 -> $layoutDir"
    Copy-Item -Path (Join-Path $msixPublishDir "*") -Destination $layoutDir -Recurse -Force

    $assetsDir = Join-Path $layoutDir "Assets"
    New-Item -ItemType Directory -Force -Path $assetsDir | Out-Null
    New-MsixLogos $assetsDir
    Write-MsixManifest (Join-Path $layoutDir "AppxManifest.xml") $msixVersion

    $msixPath = Join-Path $OutputDir "$artifactBase.msix"
    Write-Host "==> makeappx pack -> $msixPath"
    & $makeappx pack /o /d $layoutDir /p $msixPath
    if ($LASTEXITCODE -ne 0) { throw "makeappx 打包失败(退出码 $LASTEXITCODE)。" }

    $cert = Get-SigningCert $CertThumbprint
    if ($cert.Subject -ne $Publisher) {
        throw "证书主题('$($cert.Subject)')与 -Publisher('$Publisher')不一致:MSIX 的 Identity.Publisher 必须与签名证书主题完全相同,请换 -Publisher 或换证书。"
    }

    Write-Host "==> signtool 签名(证书 $($cert.Thumbprint))"
    & $signtool sign /fd SHA256 /sha1 $cert.Thumbprint $msixPath
    if ($LASTEXITCODE -ne 0) { throw "signtool 签名失败(退出码 $LASTEXITCODE)。" }

    $cerPath = Join-Path $OutputDir "$artifactBase.cer"
    Export-Certificate -Cert $cert -FilePath $cerPath -Force | Out-Null
    Write-Host "==> 导出公钥证书 -> $cerPath"
}

# ---------- 3. 产物清单与安装说明 ----------
Write-Host ""
Write-Host "打包完成,产物在 $OutputDir :"
Get-ChildItem $OutputDir -File | Where-Object { $_.Extension -in ".zip", ".msix", ".cer" } |
    ForEach-Object { Write-Host ("  {0}  ({1:N1} MB)" -f $_.Name, ($_.Length / 1MB)) }

if (-not $SkipMsix) {
    Write-Host ""
    Write-Host "MSIX 安装:签名链须到受信任的根 —— 自签名开发证书要在目标机器上以管理员建立信任"
    Write-Host "(部署服务只认本机证书库,当前用户库无效),或改用正式代码签名证书:"
    Write-Host "  1. 信任证书(管理员):Import-Certificate -FilePath `"$artifactBase.cer`" -CertStoreLocation Cert:\LocalMachine\TrustedPeople"
    Write-Host "     若仍报 0x800B0109(根不受信任),再导入 Cert:\LocalMachine\Root"
    Write-Host "  2. 安装包:  Add-AppxPackage -Path `"$artifactBase.msix`""
    Write-Host "  3. 卸载:    Get-AppxPackage Broom.Desktop | Remove-AppxPackage"
    Write-Host "开发者模式(设置 → 面向开发人员)下可免信任证书直接注册包布局试用:"
    Write-Host "  Add-AppxPackage -Register `"<artifacts>\msix-layout\AppxManifest.xml`""
}
