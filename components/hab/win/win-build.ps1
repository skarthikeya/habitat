#!/usr/bin/env powershell

#Requires -Version 5

## Helper Functions
function New-PathString([string]$StartingPath, [string]$Path) {
    if (-not [string]::IsNullOrEmpty($path)) {
        if (-not [string]::IsNullOrEmpty($StartingPath)) {
            [string[]]$PathCollection = "$path;$StartingPath" -split ';'
            $Path = ($PathCollection |
              Select-Object -Unique | 
              where {-not [string]::IsNullOrEmpty($_.trim())} | 
              where {test-path "$_"}
              ) -join ';'
        }
      $path
    }
    else {
        $StartingPath
    }
}

function Test-AppVeyor {
    (test-path env:\APPVEYOR) -and ([bool]::Parse($env:APPVEYOR))
} 

# Make sure that chocolatey is installed and up to date
# (required for dependencies)
if (-not (get-command choco -ErrorAction SilentlyContinue)) {
    Write-Host "Installing Chocolatey"
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1')) | out-null
}
else {
    Write-Host "Making sure Chocolatey is current."
    choco upgrade chocolatey --confirm | Out-Null
}

# We need the native library dependencies for `hab`
# Until we have habitat packages on Windows, there is
# a chocolatey package hosted in MyGet with the native 
# dependencies built.
if ((choco list habitat_native_dependencies --local-only) -match '^1 packages installed\.$') {
    choco upgrade habitat_native_dependencies --confirm -s https://www.myget.org/F/habitat/api/v2  --allowemptychecksums
} 
else {
    choco install habitat_native_dependencies --confirm -s https://www.myget.org/F/habitat/api/v2  --allowemptychecksums
}

# set a few reference variables for later
$ChocolateyHabitatLibDir = "$env:ChocolateyInstall\lib\habitat_native_dependencies\builds\lib"
$ChocolateyHabitatIncludeDir = "$env:ChocolateyInstall\lib\habitat_native_dependencies\builds\include"
$ChocolateyHabitatBinDir = "$env:ChocolateyInstall\lib\habitat_native_dependencies\builds\bin"

if (-not (Test-AppVeyor)) {
    # We need the Visual C 2013 Runtime for the Win32 ABI Rust
    choco install 'vcredist2013' --confirm --allowemptychecksum

    # We need the Visual C++ tools to build Rust crates (provides a compiler and linker) 
    choco install 'visualcppbuildtools' --version '14.0.25123' --confirm --allowemptychecksum

    choco install 7zip --version '16.02.0.20160811' --confirm
}

# Install Rust Nightly (since there aren't MSVC nightly cargo builds)
if (get-command -Name rustup.exe -ErrorAction SilentlyContinue) {
    rustup install stable-x86_64-pc-windows-msvc
    $cargo = 'rustup run stable-x86_64-pc-windows-msvc cargo'
}
else {
    $env:PATH = New-PathString -StartingPath $env:PATH -Path "C:\Program Files\Rust stable MSVC 1.12\bin"
    if (-not (get-command rustc -ErrorAction SilentlyContinue)) {
        write-host "installing rust"
        Invoke-WebRequest -UseBasicParsing -Uri 'https://static.rust-lang.org/dist/rust-1.12.0-x86_64-pc-windows-msvc.msi' -OutFile "$env:TEMP/rust-12-stable.msi"
        start-process -filepath MSIExec.exe -argumentlist "/qn", "/i", "$env:TEMP\rust-12-stable.msi" -Wait
        $env:PATH = New-PathString -StartingPath $env:PATH -Path "C:\Program Files\Rust stable MSVC 1.12\bin"
        while (-not (get-command cargo -ErrorAction SilentlyContinue)) {
            Write-Warning "`tWaiting for `cargo` to be available."
            start-sleep -Seconds 1
        }
    }
    else {
        # TODO: version checking logic and upgrades
    }
    $cargo = 'cargo'
}

# Set Default Environmental Variables for Native Compilation
# AppVeyor will have these set already.
if (-not (Test-AppVeyor)) {
    $env:LIB = 'C:\Program Files (x86)\Microsoft Visual Studio 14.0\VC\LIB\amd64;C:\Program Files (x86)\Microsoft Visual Studio 14.0\VC\ATLMFC\LIB\amd64;C:\Program Files (x86)\Windows Kits\10\lib\10.0.10240.0\ucrt\x64;C:\Program Files (x86)\Windows Kits\NETFXSDK\4.6.1\lib\um\x64;C:\Program Files (x86)\Windows Kits\10\lib\10.0.10240.0\um\x64;'
    $env:INCLUDE = 'C:\Program Files (x86)\Microsoft Visual Studio 14.0\VC\INCLUDE;C:\Program Files (x86)\Microsoft Visual Studio 14.0\VC\ATLMFC\INCLUDE;C:\Program Files (x86)\Windows Kits\10\include\10.0.10240.0\ucrt;C:\Program Files (x86)\Windows Kits\NETFXSDK\4.6.1\include\um;C:\Program Files (x86)\Windows Kits\10\include\10.0.10240.0\shared;C:\Program Files (x86)\Windows Kits\10\include\10.0.10240.0\um;C:\Program Files (x86)\Windows Kits\10\include\10.0.10240.0\winrt;'
    $env:PATH = New-PathString -StartingPath $env:PATH -Path 'C:\Program Files (x86)\MSBuild\14.0\bin\amd64;C:\Program Files (x86)\Microsoft Visual Studio 14.0\VC\BIN\amd64;C:\Program Files (x86)\Microsoft Visual Studio 14.0\VC\VCPackages;C:\WINDOWS\Microsoft.NET\Framework64\v4.0.30319;C:\WINDOWS\Microsoft.NET\Framework64\;C:\Program Files (x86)\Windows Kits\10\bin\x64;C:\Program Files (x86)\Windows Kits\10\bin\x86;C:\Program Files (x86)\Microsoft SDKs\Windows\v10.0A\bin\NETFX 4.6.1 Tools\x64\'
}

# Set Environment Variables for the build
$env:PATH                       = New-PathString -StartingPath $env:PATH    -Path 'C:\Program Files\7-Zip'
$env:LIB                        = New-PathString -StartingPath $env:LIB     -Path $ChocolateyHabitatLibDir
$env:INCLUDE                    = New-PathString -StartingPath $env:INCLUDE -Path $ChocolateyHabitatIncludeDir
$env:PATH                       = New-PathString -StartingPath $env:PATH    -Path $ChocolateyHabitatBinDir
$env:SODIUM_STATIC              = $true
$env:SODIUM_LIB_DIR             = $ChocolateyHabitatLibDir
$env:LIBARCHIVE_INCLUDE_DIR     = $ChocolateyHabitatIncludeDir
$env:LIBARCHIVE_LIB_DIR         = $ChocolateyHabitatLibDir
$env:OPENSSL_LIBS               = 'ssleay32:libeay32'
$env:OPENSSL_LIB_DIR            = $ChocolateyHabitatLibDir
$env:OPENSSL_INCLUDE_DIR        = $ChocolateyHabitatIncludeDir
$env:OPENSSL_STATIC             = $true

if (Test-AppVeyor) { return }

# Start the build
Push-Location "$psscriptroot\.."
invoke-expression "$cargo clean"
Invoke-Expression "$cargo build --release" -ErrorAction Stop
Pop-Location

# Import origin key
if (!(Test-Path "/hab/cache/keys/core-*.sig.key")) {
    if(!$env:ORIGIN_KEY) {
       throw "You do not have the core origin key imported on this machine. Please ensure the key is exported to the ORIGIN_KEY environment variable."
    }
    $env:ORIGIN_KEY | & '..\..\..\target\Release\hab.exe' origin key import
}

# Create the archive
$pkgRoot = "results"
New-Item -ItemType Directory -Path $pkgRoot -ErrorAction SilentlyContinue -Force

$pkgName = 'hab'
$pkgOrigin = 'core'
$pkgRelease = (Get-Date).ToString('yyyyMMddhhmmss')
$pkgVersion = (Get-Content -Path ..\..\..\VERSION | Out-String).Trim()
$pkgArtifact = "$pkgRoot/$pkgOrigin-$pkgName-$pkgVersion-$pkgRelease-x86_64-windows"
$pkgFiles = @(
    '..\..\..\target\Release\hab.exe',
    'C:\Windows\System32\vcruntime140.dll',
    'C:\ProgramData\chocolatey\lib\habitat_native_dependencies\builds\bin\*.dll'
)
$pkgTempDir = "./hab/pkgs/$pkgOrigin/$pkgName/$pkgVersion/$pkgRelease" 
$pkgBinDir =  "$pkgTempDir/bin"
mkdir $pkgBinDir -Force | Out-Null
Copy-Item $pkgFiles -Destination $pkgBinDir
"$pkgOrigin/$pkgName/$pkgVersion/$pkgRelease" | out-file "$pkgTempDir/IDENT" -Encoding ascii
"" | out-file "$pkgTempDir/BUILD_DEPS" -Encoding ascii
"" | out-file "$pkgTempDir/BUILD_TDEPS" -Encoding ascii
"" | out-file "$pkgTempDir/FILES" -Encoding ascii
"" | out-file "$pkgTempDir/MANIFEST" -Encoding ascii
"/hab/pkgs/$pkgOrigin/$pkgName/$pkgVersion/$pkgRelease" | out-file "$pkgTempDir/PATH" -Encoding ascii
"" | out-file "$pkgTempDir/SVC_GROUP" -Encoding ascii
"" | out-file "$pkgTempDir/SVC_USER" -Encoding ascii
"x86_64-windows" | out-file "$pkgTempDir/TARGET" -Encoding ascii
7z.exe a -ttar "$pkgArtifact.tar" ./hab
7z.exe a -txz "$pkgArtifact.tar.xz" "$pkgArtifact.tar"
..\..\..\target\Release\hab.exe pkg sign --origin $pkgOrigin "$pkgArtifact.tar.xz" "$pkgArtifact.hart"
rm "$pkgArtifact.tar", "$pkgArtifact.tar.xz", "./hab" -Recurse -force

exit $LASTEXITCODE
