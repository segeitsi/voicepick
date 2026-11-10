param([string]$Python = "")

$ErrorActionPreference = "Stop"
Push-Location (Split-Path $PSScriptRoot -Parent)
try {
    if (!$Python) {
        $Python = & py -3.12-64 -c "import sys; print(sys.executable)"
        if ($LASTEXITCODE -ne 0) { throw "Install Python 3.12 x64 or pass -Python." }
    }
    & $Python -c "import sys,sysconfig; sys.exit(0 if sys.version_info[:2] == (3,12) and sysconfig.get_platform() == 'win-amd64' else 1)"
    if ($LASTEXITCODE -ne 0) { throw "Windows Python 3.12 x64 is required." }
    $venv = Join-Path (Get-Location) "build\windows-venv"
    if (!(Test-Path "$venv\Scripts\python.exe")) {
        & $Python -m venv $venv
        if ($LASTEXITCODE -ne 0) { throw "Could not create the Windows build environment." }
    }
    $buildPython = Join-Path $venv "Scripts\python.exe"
    & $buildPython -m pip install --disable-pip-version-check -r Sources/Windows/requirements.txt
    if ($LASTEXITCODE -ne 0) { throw "Could not install Windows dependencies." }
    & $buildPython scripts/prepare-windows-models.py
    if ($LASTEXITCODE -ne 0) { throw "Could not prepare the offline models." }
    $models = (Resolve-Path "build/windows-models").Path
    $manifest = (Resolve-Path "scripts/voicepick-windows.manifest").Path

    $bundle = @(
        "--noconfirm", "--onefile", "--windowed", "--noupx", "--name", "VoicePick",
        "--manifest", $manifest,
        "--distpath", "build/windows-dist", "--workpath", "build/windows-pyinstaller",
        "--specpath", "build/windows-pyinstaller", "--paths", "assets/face-mesh",
        "--add-data", "${models}:models",
        "--collect-all", "mediapipe", "--collect-all", "vosk",
        "--collect-data", "_sounddevice_data",
        "--hidden-import", "pynput.keyboard._win32", "--hidden-import", "pynput.mouse._win32",
        "--hidden-import", "win32timezone",
        "--exclude-module", "pytest", "--exclude-module", "IPython",
        "Sources/Windows/app.py"
    )
    & $buildPython -m PyInstaller @bundle
    if ($LASTEXITCODE -ne 0) { throw "PyInstaller could not build VoicePick.exe." }

    $exe = Get-Item "build/windows-dist/VoicePick.exe"
    $sha = (Get-FileHash -Algorithm SHA256 -LiteralPath $exe.FullName).Hash.ToLowerInvariant()
    "$sha  VoicePick.exe" | Set-Content -Encoding ascii "build/windows-dist/VoicePick.exe.sha256"
    Write-Output $exe.FullName
}
finally {
    Pop-Location
}
