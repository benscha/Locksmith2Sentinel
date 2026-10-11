[CmdletBinding()]
param(
    [string]$TaskName = 'Locksmith2-Ingestion',
    [string]$TaskSchedule,
    [int]$TaskModifier,
    [string]$ManagedIdentityClientId,
    [switch]$NonInteractive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:SkipScheduledTaskCreation = $false

function Write-Step {
    param([string]$Message)
    Write-Host "[INSTALL] $Message"
}

function Resolve-TaskScheduleSettings {
    if ($TaskSchedule -and $TaskModifier -gt 0) {
        return
    }

    if ($NonInteractive) {
        if (-not $TaskSchedule) { $script:TaskSchedule = 'DAILY' }
        if (-not $TaskModifier -or $TaskModifier -lt 1) { $script:TaskModifier = 1 }
        return
    }

    Write-Step 'Please choose the trigger interval for the scheduled task.'
    Write-Host '1) Every X minutes'
    Write-Host '2) Every X hours'
    Write-Host '3) Every X days'
    Write-Host '4) Skip (i will create my own Scheduled Tasks)'

    while ($true) {
        $selection = Read-Host 'Selection (1/2/3/4)'
        $selectedSchedule = switch ($selection) {
            '1' {
                'MINUTE'
                break
            }
            '2' {
                'HOURLY'
                break
            }
            '3' {
                'DAILY'
                break
            }
            '4' {
                $script:SkipScheduledTaskCreation = $true
                Write-Step 'Scheduled task creation will be skipped. You will create your own Scheduled Tasks.'
                return
            }
            default {
                Write-Warning 'Invalid selection. Only 1, 2, 3, or 4 are allowed.'
            }
        }

        if ($selectedSchedule) {
            $script:TaskSchedule = $selectedSchedule
            break
        }
    }

    $modifierInput = Read-Host 'Interval value (whole number > 0)'
    [int]$parsedModifier = 0
    if (-not [int]::TryParse($modifierInput, [ref]$parsedModifier) -or $parsedModifier -lt 1) {
        throw 'The interval value must be a whole number greater than 0.'
    }

    $script:TaskModifier = $parsedModifier
}

function Test-ExistingConfigFile {
    $configPath = Join-Path -Path $PSScriptRoot -ChildPath 'config.json'

    if (-not (Test-Path -Path $configPath -PathType Leaf)) {
        throw "config.json was not found: $configPath. Copy config.json.example and fill in the deployment outputs first."
    }

    $config = Get-Content -Path $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $requiredConfigKeys = @(
        'SourceDirectory',
        'SourcePattern',
        'ArchiveDirectory',
        'LogsDirectory',
        'DceUri',
        'DcrImmutableId',
        'StreamName'
    )

    foreach ($key in $requiredConfigKeys) {
        if (-not $config.PSObject.Properties[$key] -or [string]::IsNullOrWhiteSpace([string]$config.$key)) {
            throw "config.json entry '$key' is missing or empty."
        }
    }

    $configChanged = $false

    foreach ($obsoleteKey in @('ReportScriptPath', 'ReportScriptArguments')) {
        if ($config.PSObject.Properties[$obsoleteKey]) {
            $config.PSObject.Properties.Remove($obsoleteKey)
            $configChanged = $true
            Write-Step "Removed obsolete config entry '$obsoleteKey' from existing config.json."
        }
    }

    if (-not $config.PSObject.Properties['ReportForest']) {
        $config | Add-Member -NotePropertyName ReportForest -NotePropertyValue '' -Force
        $configChanged = $true
        Write-Step 'Added ReportForest to existing config.json (optional target forest for Locksmith scan).'
    }

    if (-not $config.PSObject.Properties['IngestNoFindingsRecord']) {
        $config | Add-Member -NotePropertyName IngestNoFindingsRecord -NotePropertyValue $true -Force
        $configChanged = $true
        Write-Step 'Added IngestNoFindingsRecord to existing config.json (ingest marker record when Locksmith returns no findings).'
    }

    if ($ManagedIdentityClientId -and (-not $config.PSObject.Properties['ManagedIdentityClientId'] -or $config.ManagedIdentityClientId -ne $ManagedIdentityClientId)) {
        $config | Add-Member -NotePropertyName ManagedIdentityClientId -NotePropertyValue $ManagedIdentityClientId -Force
        $configChanged = $true
    }

    if ($configChanged) {
        $config | ConvertTo-Json -Depth 5 | Set-Content -Path $configPath -Encoding UTF8
        Write-Step "config.json was updated: $configPath"
    }

    Write-Step "Using existing config.json: $configPath"
}

function Install-Locksmith2 {
    $zipUrl = 'https://github.com/jakehildreth/Locksmith2/archive/refs/heads/main.zip'
    $zipPath = Join-Path -Path $PSScriptRoot -ChildPath 'Locksmith2-main.zip'
    $extractPath = Join-Path -Path $PSScriptRoot -ChildPath 'Locksmith2-main'

    Write-Step 'Downloading Locksmith2 ZIP from GitHub.'
    Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing

    if (Test-Path -Path $extractPath -PathType Container) {
        Remove-Item -Path $extractPath -Recurse -Force
    }

    Write-Step 'Extracting Locksmith2 archive.'
    Expand-Archive -Path $zipPath -DestinationPath $PSScriptRoot -Force

    if (Test-Path -Path $zipPath -PathType Leaf) {
        Remove-Item -Path $zipPath -Force
        Write-Step 'Removed downloaded Locksmith2 ZIP file.'
    }
}

function Install-LocksmithPrerequisite {
    $requiredModules = @('PSCertutil')

    # The scheduled task runs as SYSTEM, whose PSModulePath does not include any
    # interactive user's per-user module path (Documents\WindowsPowerShell\Modules).
    # A plain "Get-Module -ListAvailable" would also find a CurrentUser-scoped
    # install (e.g. from manual testing or an older run of this script) and skip
    # the AllUsers install below, leaving SYSTEM unable to see the module at all.
    # Only a module found under a machine-wide module path counts as "available".
    $allUsersModulePaths = @(
        (Join-Path -Path $env:ProgramFiles -ChildPath 'WindowsPowerShell\Modules'),
        (Join-Path -Path $env:ProgramFiles -ChildPath 'PowerShell\Modules')
    )

    foreach ($moduleName in $requiredModules) {
        Write-Step "Ensuring required PowerShell module is available for Locksmith2: $moduleName"

        $moduleAvailable = [bool](Get-Module -ListAvailable -Name $moduleName | Where-Object {
                $moduleBase = $_.ModuleBase
                $allUsersModulePaths | Where-Object { $moduleBase.StartsWith($_, [System.StringComparison]::OrdinalIgnoreCase) }
            })

        if (-not $moduleAvailable) {
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

            Install-Module -Name $moduleName -Repository PSGallery -Scope AllUsers -Force -AllowClobber -ErrorAction Stop
        }

        try {
            Import-Module -Name $moduleName -ErrorAction Stop
        }
        catch {
            throw "Required module '$moduleName' is not loadable. $($_.Exception.Message)"
        }
    }
}

function New-OrUpdateScheduledTask {
    if ($script:SkipScheduledTaskCreation) {
        Write-Step 'Skipping scheduled task creation as requested.'
        return
    }

    $scriptDirectory = $PSScriptRoot
    $scriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'locksmith2Report.ps1'

    if (-not (Test-Path -Path $scriptPath -PathType Leaf)) {
        throw "Task script not found: $scriptPath"
    }

    $taskArguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $scriptPath
    $taskAction = New-ScheduledTaskAction `
        -Execute 'PowerShell.exe' `
        -Argument $taskArguments `
        -WorkingDirectory $scriptDirectory

    $schedule = $TaskSchedule.ToUpperInvariant()
    if ($schedule -notin @('MINUTE', 'HOURLY', 'DAILY')) {
        throw 'TaskSchedule must be MINUTE, HOURLY, or DAILY.'
    }

    $trigger = $null
    if ($schedule -eq 'MINUTE') {
        $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes $TaskModifier) -RepetitionDuration (New-TimeSpan -Days 3650)
    }
    elseif ($schedule -eq 'HOURLY') {
        $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Hours $TaskModifier) -RepetitionDuration (New-TimeSpan -Days 3650)
    }
    else {
        $trigger = New-ScheduledTaskTrigger -Daily -At '02:00' -DaysInterval $TaskModifier
    }

    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 2)
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest -LogonType ServiceAccount
    Write-Warning 'Scheduled task runs as SYSTEM. If Locksmith finds no data, run the task as a domain account (or gMSA) with AD read access to Public Key Services.'

    Register-ScheduledTask -TaskName $TaskName -Action $taskAction -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null

    Write-Step "Scheduled task created/updated: $TaskName"
}

Resolve-TaskScheduleSettings
Test-ExistingConfigFile

Install-Locksmith2
Install-LocksmithPrerequisite
New-OrUpdateScheduledTask

Write-Step 'Installation completed.'
