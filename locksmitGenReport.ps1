[CmdletBinding()]
param(
    [string]$OutputDirectory = $PSScriptRoot,
    [string]$OutputPattern = '*-locksmith2.json',
    [string]$Forest
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# No Set-StrictMode here: this script loads and calls Locksmith2, third-party code
# that is not written to be strict-mode-safe (e.g. it reads $script:-scoped flags
# before they are first set, which is fine under the default mode but a terminating
# error under StrictMode). A real `Import-Module` would isolate that in the module's
# own session state; the dot-source fallback below does not, so strict mode must stay
# off for the whole process.

function Install-RequiredModuleIfMissing {
    param(
        [Parameter(Mandatory = $true)][string]$ModuleName
    )

    # Locksmith2 relies on this module being importable in whatever account runs
    # this script (typically SYSTEM, via the scheduled task). A module found only
    # under an interactive user's per-user path (Documents\WindowsPowerShell\Modules)
    # is invisible to SYSTEM and to other accounts, so "already available" only
    # counts if it lives under a machine-wide (AllUsers) module path.
    $allUsersModulePaths = @(
        (Join-Path -Path $env:ProgramFiles -ChildPath 'WindowsPowerShell\Modules'),
        (Join-Path -Path $env:ProgramFiles -ChildPath 'PowerShell\Modules')
    )

    $isAvailable = [bool](Get-Module -ListAvailable -Name $ModuleName | Where-Object {
            $moduleBase = $_.ModuleBase
            $allUsersModulePaths | Where-Object { $moduleBase.StartsWith($_, [System.StringComparison]::OrdinalIgnoreCase) }
        })

    if (-not $isAvailable) {
        Write-Warning "Required module '$ModuleName' was not found in a machine-wide module path. Installing it now (Scope: AllUsers)."

        try {
            $null = Get-PackageProvider -Name NuGet -ErrorAction Stop
        }
        catch {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers | Out-Null
        }

        try {
            $psGallery = Get-PSRepository -Name PSGallery -ErrorAction Stop
            if ($psGallery.InstallationPolicy -ne 'Trusted') {
                Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction Stop
            }
        }
        catch {
            Write-Warning "Could not set PSGallery as trusted: $($_.Exception.Message)"
        }

        Install-Module -Name $ModuleName -Repository PSGallery -Scope AllUsers -Force -AllowClobber -ErrorAction Stop
    }

    # Explicitly import even when the module was already available: Locksmith2's own
    # code (e.g. Set-CADisableExtensionList) probes for PSCertutil's commands via
    # "Get-Command -ErrorAction SilentlyContinue" instead of importing the module
    # itself. That relies on PowerShell's module auto-loading / command-analysis
    # cache, which is unreliable for a module that was just installed (or is new to
    # this account's session) - especially under SYSTEM. An explicit Import-Module
    # here guarantees the commands are registered before Locksmith2 looks for them.
    try {
        Import-Module -Name $ModuleName -Force -ErrorAction Stop
    }
    catch {
        throw "Required module '$ModuleName' could not be imported. $($_.Exception.Message)"
    }
}

function Resolve-OutputFilePath {
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string]$Pattern
    )

    $dateStamp = Get-Date -Format 'yyyyMMdd'
    $fileName = if ($Pattern -match '[*?]') {
        $Pattern.Replace('*', $dateStamp).Replace('?', 'x')
    }
    else {
        "$dateStamp-$Pattern"
    }

    if ($fileName -notmatch '(?i)\.json$') {
        $fileName = "$fileName.json"
    }

    return (Join-Path -Path $Directory -ChildPath $fileName)
}

function Test-TypeDataConflictException {
    param(
        [Parameter(Mandatory = $true)]$ErrorRecord
    )

    # FullyQualifiedErrorId is culture-invariant; the exception message text is
    # localized (e.g. German on a de-DE system) and must not be relied on alone.
    if ([string]$ErrorRecord.FullyQualifiedErrorId -match 'FormatXmlUpdateException') {
        return $true
    }

    $message = [string]$ErrorRecord.Exception.Message
    return ($message -match '(?i)extended type data file') -and ($message -match '(?i)already present')
}

function Import-Locksmith2ViaImportModule {
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath
    )

    # Locksmith2's RequiredModules (e.g. Microsoft.PowerShell.Security) are core
    # PowerShell modules that are already loaded in every session. Re-importing them
    # reprocesses their type-extension files (types.ps1xml), and the resulting
    # "member already present" duplicate is raised by Import-Module as a genuine
    # terminating exception that ignores -ErrorAction/-WarningAction - it must be
    # caught with try/catch, not suppressed via error preference. When that happens,
    # PowerShell discards the whole import (no commands get exported), so the caller
    # still needs to fall back to loading the module's script files directly.
    try {
        Import-Module -Name $ManifestPath -Force -ErrorAction Stop
    }
    catch {
        if (-not (Test-TypeDataConflictException -ErrorRecord $_)) {
            throw
        }

        Write-Warning "Import-Module reported a non-fatal type-data conflict while loading Locksmith2 (duplicate type extensions from an already-loaded required module). Details: $($_.Exception.Message)"
    }

    return [bool](Get-Command -Name 'Invoke-Locksmith2' -ErrorAction SilentlyContinue)
}

$moduleManifestPath = Join-Path -Path $PSScriptRoot -ChildPath 'Locksmith2-main\Locksmith2.psd1'
if (-not (Test-Path -Path $moduleManifestPath -PathType Leaf)) {
    throw "Locksmith2 module manifest was not found: $moduleManifestPath. Run install.ps1 to download Locksmith2."
}

if (-not (Import-Locksmith2ViaImportModule -ManifestPath $moduleManifestPath)) {
    # Dot-sourcing must happen here at script scope (not inside a function) - functions
    # defined via dot-sourcing inside a function are local to that function and would
    # disappear again once it returns.
    Write-Warning 'Invoke-Locksmith2 was not exported by Import-Module. Falling back to direct dot-sourcing of Locksmith2 script files.'

    $moduleRoot = Split-Path -Path $moduleManifestPath -Parent
    foreach ($folderName in @('Classes', 'Private', 'Public')) {
        $folderPath = Join-Path -Path $moduleRoot -ChildPath $folderName
        if (-not (Test-Path -Path $folderPath -PathType Container)) {
            continue
        }

        foreach ($scriptFile in (Get-ChildItem -Path $folderPath -Filter '*.ps1' -File -Recurse | Sort-Object FullName)) {
            # Sanitized content is dot-sourced from a sibling temp file rather than an
            # anonymous [scriptblock]::Create() instance. A scriptblock created that way
            # has no backing file, so $PSScriptRoot is an empty string for any function
            # defined inside it. Locksmith2's own functions (e.g. Invoke-Locksmith2) use
            # $PSScriptRoot internally (Join-Path $PSScriptRoot 'Modules\...') to locate
            # optional bundled dependencies; Join-Path rejects an empty -Path outright,
            # which - combined with this script's $ErrorActionPreference = 'Stop' leaking
            # into the dot-sourced code (no module scope isolation here) - turned an
            # otherwise harmless "optional dependency not found" check into a fatal error.
            # Writing the sanitized copy next to the original file keeps $PSScriptRoot
            # pointing at the real module folder.
            $tempScriptPath = Join-Path -Path $scriptFile.DirectoryName -ChildPath "$($scriptFile.BaseName).__sanitized.ps1"
            try {
                # Some Locksmith2 script files carry a #Requires line inside the function
                # body (not at the top of the file, where #Requires is normally required
                # to be). On this host that still triggers a real Import-Module call for
                # the required module, which re-hits the same type-data conflict - but
                # this time it aborts the file *before* the function definition is
                # reached, so the function never gets defined and simply swallowing the
                # error (as done for the top-level Import-Module above) silently loses
                # that function. Strip #Requires lines before dot-sourcing to avoid
                # re-triggering the conflict; the modules they name are core PowerShell
                # modules that are always present anyway.
                $rawContent = Get-Content -Path $scriptFile.FullName -Raw
                $sanitizedContent = $rawContent -replace '(?im)^\s*#requires\b.*$', ''
                Set-Content -Path $tempScriptPath -Value $sanitizedContent -Encoding UTF8
                . $tempScriptPath
            }
            catch {
                if (-not (Test-TypeDataConflictException -ErrorRecord $_)) {
                    Write-Warning "Failed to dot-source '$($scriptFile.FullName)': $($_.Exception.Message)"
                    throw
                }

                Write-Warning "Ignored a non-fatal type-data conflict while dot-sourcing '$($scriptFile.FullName)'. FullyQualifiedErrorId: $($_.FullyQualifiedErrorId)"
            }
            finally {
                if (Test-Path -Path $tempScriptPath -PathType Leaf) {
                    Remove-Item -Path $tempScriptPath -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }

    if (-not (Get-Command -Name 'Invoke-Locksmith2' -ErrorAction SilentlyContinue)) {
        throw "Locksmith2 could not be loaded: Invoke-Locksmith2 is not available after Import-Module and direct dot-sourcing. Manifest: $moduleManifestPath"
    }
}

if (-not (Test-Path -Path $OutputDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
}

Install-RequiredModuleIfMissing -ModuleName 'PSCertutil'

$invokeParams = @{
    Force               = $true
    SkipPowerShellCheck = $true
    Rescan              = $true
}
if (-not [string]::IsNullOrWhiteSpace($Forest)) {
    $invokeParams['Forest'] = $Forest
}

$reportItems = @(Invoke-Locksmith2 @invokeParams | Where-Object { $null -ne $_ })

$outputFilePath = Resolve-OutputFilePath -Directory $OutputDirectory -Pattern $OutputPattern

if ($reportItems.Count -gt 0) {
    $reportItems | ConvertTo-Json -Depth 15 | Set-Content -Path $outputFilePath -Encoding UTF8
    Write-Host "Report successfully saved: $outputFilePath" -ForegroundColor Green
}
else {
    '[]' | Set-Content -Path $outputFilePath -Encoding UTF8
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $forestInfo = if ([string]::IsNullOrWhiteSpace($Forest)) { 'auto-detected' } else { $Forest }
    Write-Warning "Locksmith report is empty ([]). Context: Identity=$identity; Forest=$forestInfo; Computer=$env:COMPUTERNAME. This usually means no findings were detected, or the running account cannot enumerate AD CS objects. An empty JSON report was written so ingestion can emit a NO_FINDINGS marker record."
    Write-Host "Empty Locksmith report saved: $outputFilePath" -ForegroundColor Yellow
}
