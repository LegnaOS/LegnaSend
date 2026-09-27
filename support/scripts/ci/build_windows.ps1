param([ValidateSet('x64','arm64')][string]$Architecture)
$ErrorActionPreference = 'Stop'
function CheckExit { if ($LASTEXITCODE -ne 0) { throw "Command failed: $LASTEXITCODE" } }
# CMake requires the helper at install time; unsigned portable bundles exclude it.
$SdkArch = if ($Architecture -eq 'arm64') { 'arm64' } else { 'x64' }
$kit = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\10.*\$SdkArch\makepri.exe" | Sort-Object FullName | Select-Object -Last 1
if (!$kit) { throw 'Windows SDK makepri was not found' }
$makeappx = Join-Path $kit.Directory.FullName 'makeappx.exe'
if (!(Test-Path $makeappx)) { throw 'Windows SDK makeappx was not found' }
if ($Architecture -eq 'arm64') {
  $manifest = 'support/build/msix/content/AppxManifest.xml'
  (Get-Content $manifest -Raw).Replace('ProcessorArchitecture="x64"','ProcessorArchitecture="arm64"') | Set-Content $manifest
}
& $kit.FullName new /pr support/build/msix/content /cf support/build/msix/priconfig.xml /mn support/build/msix/content/AppxManifest.xml /of support/build/msix/content/resources.pri /o
CheckExit
& $makeappx pack /o /d support/build/msix/content /nv /p app/windows/localsend_msix_helper.msix
CheckExit
Push-Location app
try {
  fvm flutter pub get; CheckExit
  # Flutter selects the native Windows target; older supported SDKs expose no target-platform flag.
  $dart = fvm dart --version 2>&1 | Out-String
  if ($dart -notmatch "windows_$Architecture") { throw "Expected native windows_$Architecture Dart SDK: $dart" }
  fvm flutter build windows --release; CheckExit
} finally { Pop-Location }
$bundle = "app/build/windows/$Architecture/runner/Release"
# Keep Microsoft's existing CRT signatures; do not borrow upstream signing identities.
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs = & $vswhere -latest -products '*' -property installationPath
$crt = Get-ChildItem "$vs\VC\Redist\MSVC\*\$Architecture\Microsoft.VC*.CRT" -Directory | Sort-Object FullName | Select-Object -Last 1
if (!$crt) { throw "Visual C++ runtime for $Architecture was not found" }
$runtimeProof = @{}
$hostArch = if ($Architecture -eq 'arm64') { 'Hostarm64' } else { 'Hostx64' }
$dumpbin = Get-ChildItem "$vs\VC\Tools\MSVC\*\bin\$hostArch\$Architecture\dumpbin.exe" | Sort-Object FullName | Select-Object -Last 1
foreach ($dll in Get-ChildItem "$($crt.FullName)/*.dll") {
  $bytes = [IO.File]::ReadAllBytes($dll.FullName)
  $offset = [BitConverter]::ToInt32($bytes, 0x3c)
  $machine = [BitConverter]::ToUInt16($bytes, $offset + 4)
  $expected = if ($Architecture -eq 'arm64') { 0xaa64 } else { 0x8664 }
  if ($machine -ne $expected) {
    $headers = if ($dumpbin) { & $dumpbin.FullName /headers $dll.FullName | Out-String } else { '' }
    $signature = Get-AuthenticodeSignature $dll.FullName
    if ($Architecture -eq 'arm64' -and $headers -match 'ARM64X' -and $signature.Status -eq 'Valid' -and $signature.SignerCertificate.Subject -match 'Microsoft Corporation') {
      $runtimeProof[$dll.Name] = @{ sha256 = (Get-FileHash $dll.FullName -Algorithm SHA256).Hash.ToLower(); arm64x = $true; microsoftSignatureVerified = $true }
      Write-Host "Verified Microsoft ARM64X runtime: $($dll.Name)"
    } else {
      Write-Host "Exclude non-native CRT: $($dll.Name), machine $($machine.ToString('x'))"
      Remove-Item "$bundle/$($dll.Name)" -ErrorAction SilentlyContinue
      continue
    }
  }
  Copy-Item $dll.FullName $bundle
}
ConvertTo-Json -InputObject $runtimeProof | Set-Content "$bundle/ci-runtime-provenance.json" -Encoding utf8
foreach ($file in @('localsend_msix_helper.msix','install_msix_helper.ps1','localsend_app.exe.manifest')) {
  Remove-Item "$bundle/$file" -ErrorAction SilentlyContinue
}
python support/scripts/ci/package_release.py windows $Architecture $bundle
CheckExit
