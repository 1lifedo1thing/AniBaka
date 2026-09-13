param(
    [Parameter(Mandatory)][string]$Version,
    [Parameter(Mandatory)][ValidateSet('test-signing', 'release-signing')][string]$Policy,
    [string]$InputDirectory = 'signpath-output',
    [string]$OutputDirectory = 'release-stage'
)

$ErrorActionPreference = 'Stop'
$testCertificatePath = Join-Path $PSScriptRoot '../signpath/test-certificate-2026.cer'
$testCertificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new(
    (Resolve-Path -LiteralPath $testCertificatePath).Path
)
if ($testCertificate.Thumbprint -ne '81E3C1900F59996736DFC0752E940B331C0DE907') {
    throw 'The checked-in SignPath test certificate has an unexpected fingerprint.'
}

$packagePaths = @{}
foreach ($extension in 'exe', 'msix', 'zip') {
    $name = "baka-${Version}-windows-x64.$extension"
    $files = @(Get-ChildItem -LiteralPath $InputDirectory -Recurse -File | Where-Object Name -eq $name)
    if ($files.Count -ne 1) { throw "Expected exactly one signed output named $name, found $($files.Count)" }
    $packagePaths[$extension] = $files[0].FullName
}

$signedFiles = @($packagePaths.exe, $packagePaths.msix)
$temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) "anibaka-signature-$([guid]::NewGuid())"
$testRootStore = $null
$testRootInstalled = $false
New-Item -ItemType Directory -Path $temporaryDirectory | Out-Null
try {
    if ($Policy -eq 'test-signing') {
        # The test certificate is self-signed, so Windows only reports a valid signature once the
        # certificate is trusted as a root. Without that, Get-AuthenticodeSignature returns
        # UnknownError with the "terminated in a root certificate which is not trusted by the trust
        # provider" message, which is also what corrupt signatures report. Trust exactly this pinned
        # certificate for the duration of the verification so the signature itself is validated.
        $testRootStore = [Security.Cryptography.X509Certificates.X509Store]::new(
            [Security.Cryptography.X509Certificates.StoreName]::Root,
            [Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser
        )
        $testRootStore.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
        $alreadyTrusted = [bool]($testRootStore.Certificates |
            Where-Object Thumbprint -eq $testCertificate.Thumbprint)
        if (-not $alreadyTrusted) {
            $testRootStore.Add($testCertificate)
            $testRootInstalled = $true
        }
    }

    foreach ($extension in 'zip', 'msix') {
        $destination = Join-Path $temporaryDirectory $extension
        [IO.Compression.ZipFile]::ExtractToDirectory($packagePaths[$extension], $destination)
        $executable = Join-Path $destination 'baka.exe'
        if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
            throw "Missing baka.exe in the signed $extension package."
        }
        $signedFiles += $executable
    }

    foreach ($file in $signedFiles) {
        $signature = Get-AuthenticodeSignature -LiteralPath $file
        if ($null -eq $signature.SignerCertificate) { throw "SignPath did not sign $file" }
        if ($Policy -eq 'test-signing') {
            if ($signature.SignerCertificate.Thumbprint -ne $testCertificate.Thumbprint) {
                throw "Unexpected test signing certificate for $file"
            }
            if ($signature.Status -ne 'Valid') {
                throw "Invalid test signature for ${file}: $($signature.Status) / $($signature.StatusMessage)"
            }
        } else {
            $commonName = $signature.SignerCertificate.GetNameInfo(
                [Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false
            )
            if ($commonName -ne 'SignPath Foundation' -or $signature.Status -ne 'Valid') {
                throw "Invalid release signature for ${file}: $($signature.SignerCertificate.Subject) / $($signature.Status)"
            }
        }
        Write-Host "Verified $file ($($signature.Status))"
    }

    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    foreach ($file in $packagePaths.Values) {
        Copy-Item -LiteralPath $file -Destination $OutputDirectory
    }
    $metadata = @("policy=$Policy")
    if ($Policy -eq 'test-signing') {
        Copy-Item -LiteralPath $testCertificatePath -Destination (Join-Path $OutputDirectory 'anibaka-signpath-test-2026.cer')
        $metadata += "certificate_sha1=$($testCertificate.Thumbprint)"
        $metadata += 'Self-signed TEST certificate; not a publicly trusted release signature.'
        Write-Host '::warning::Windows packages use the self-signed SignPath TEST certificate.'
    }
    $metadata | Set-Content -Encoding utf8 -LiteralPath (Join-Path $OutputDirectory "baka-${Version}-windows-signing-metadata.txt")
    if ($env:GITHUB_STEP_SUMMARY) {
        "### Windows code signing`n$($metadata -join "`n")" >> $env:GITHUB_STEP_SUMMARY
    }
} finally {
    if ($null -ne $testRootStore) {
        if ($testRootInstalled) { $testRootStore.Remove($testCertificate) }
        $testRootStore.Close()
    }
    # This absolute directory was created above with a unique name for this invocation.
    Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force
}
