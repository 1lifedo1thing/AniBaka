# Exercise validation/staging with mocked Authenticode results. No certificates
# are installed; real Windows trust validation must also run on the CI runner.
$ErrorActionPreference = 'Stop'
$verifier = Join-Path $PSScriptRoot '../verify-windows-signing.ps1'
$fixtureRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$fixture = Join-Path $fixtureRoot "anibaka-verification-test-$([guid]::NewGuid())"
$originalSummary = $env:GITHUB_STEP_SUMMARY
$env:GITHUB_STEP_SUMMARY = ''
New-Item -ItemType Directory -Path $fixture | Out-Null

function Get-AuthenticodeSignature {
    param([string]$LiteralPath)
    $testState.CheckedFiles.Add($LiteralPath)
    $certificate = [pscustomobject]@{ Subject = "CN=$($testState.Signer)" }
    $certificate | Add-Member ScriptMethod GetNameInfo { param($type, $issuer) $this.Subject.Substring(3) }
    [pscustomobject]@{
        SignerCertificate = $(if ($testState.Status -ne 'NotSigned') { $certificate })
        Status = $testState.Status
        StatusMessage = 'Fixture signature status'
    }
}

try {
    $inputPath = Join-Path $fixture 'input'
    $contents = Join-Path $fixture 'contents'
    New-Item -ItemType Directory -Path $inputPath, $contents | Out-Null
    Set-Content -LiteralPath (Join-Path $contents 'baka.exe') -Value 'fixture executable'
    Set-Content -LiteralPath (Join-Path $inputPath 'baka-1.2.3-windows-x64.exe') -Value 'fixture installer'
    foreach ($extension in 'zip', 'msix') {
        [IO.Compression.ZipFile]::CreateFromDirectory($contents, (Join-Path $inputPath "baka-1.2.3-windows-x64.$extension"))
    }

    foreach ($scenario in @(
        @{ Name = 'valid'; Status = 'Valid'; Signer = 'SignPath Foundation'; Error = $null }
        @{ Name = 'tampered'; Status = 'HashMismatch'; Signer = 'SignPath Foundation'; Error = 'Invalid release signature*' }
        @{ Name = 'untrusted'; Status = 'UnknownError'; Signer = 'SignPath Foundation'; Error = 'Invalid release signature*' }
        @{ Name = 'unsigned'; Status = 'NotSigned'; Signer = 'SignPath Foundation'; Error = 'SignPath did not sign*' }
        @{ Name = 'wrong-signer'; Status = 'Valid'; Signer = 'Unexpected signer'; Error = 'Invalid release signature*' }
    )) {
        $testState = @{
            CheckedFiles = [Collections.Generic.List[string]]::new()
            Status = $scenario.Status
            Signer = $scenario.Signer
        }
        $outputPath = Join-Path $fixture $scenario.Name
        $failure = $null
        try {
            & $verifier -Version '1.2.3' -Policy release-signing -InputDirectory $inputPath -OutputDirectory $outputPath
        } catch {
            $failure = $_.Exception.Message
        }
        if ($scenario.Error) {
            if ($failure -notlike $scenario.Error) { throw "Unexpected failure for $($scenario.Name): $failure" }
            if (Test-Path -LiteralPath $outputPath) { throw "Invalid artifacts were staged for $($scenario.Name)." }
        } else {
            if ($failure) { throw $failure }
            if ($testState.CheckedFiles.Count -ne 4) { throw 'Expected installer, MSIX, ZIP executable, and MSIX executable checks.' }
            if (@(Get-ChildItem -LiteralPath $outputPath -File).Count -ne 4) { throw 'Expected three packages and signing metadata.' }
        }
        Write-Host "PASS: $($scenario.Name)"
    }
} finally {
    $env:GITHUB_STEP_SUMMARY = $originalSummary
    $resolvedFixture = (Resolve-Path -LiteralPath $fixture).Path
    if (-not $resolvedFixture.StartsWith($fixtureRoot, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolvedFixture) -notlike 'anibaka-verification-test-*') {
        throw "Refusing to clean unexpected fixture path: $resolvedFixture"
    }
    Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
}
