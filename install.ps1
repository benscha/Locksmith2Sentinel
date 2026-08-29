[CmdletBinding(DefaultParameterSetName = 'Deploy')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Deploy')][string]$SubscriptionId,
    [Parameter(Mandatory = $true, ParameterSetName = 'Deploy')][string]$ResourceGroupName,
    [Parameter(Mandatory = $true, ParameterSetName = 'Deploy')][string]$WorkspaceName,
    [Parameter(Mandatory = $true, ParameterSetName = 'Deploy')][string]$Location,
    [string]$CustomTableName = 'Locksmith2_CL',
    [string]$DataCollectionEndpointName = 'dce-locksmith2',
    [string]$DataCollectionRuleName = 'dcr-locksmith2',
    [string]$StreamName = 'Custom-Locksmith2Stream',
    [string]$TaskName = 'Locksmith2-Ingestion',
    [string]$TaskSchedule,
    [int]$TaskModifier,
    [string]$ManagedIdentityClientId,
    [string]$ManagedIdentityPrincipalId,
    [string]$ManagedIdentityResourceGroupName,
    [string]$ManagedIdentityMachineName,
    [switch]$NonInteractive,
    [Parameter(ParameterSetName = 'SkipDeployment')][switch]$SkipDeployment
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ManagedIdentityPrincipalId = $ManagedIdentityPrincipalId
$script:ManagedIdentityResourceGroupName = $ManagedIdentityResourceGroupName
$script:ManagedIdentityMachineName = $ManagedIdentityMachineName
$script:ManagedIdentityMachineType = ''
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
        switch ($selection) {
            '1' {
                $script:TaskSchedule = 'MINUTE'
                break
            }
            '2' {
                $script:TaskSchedule = 'HOURLY'
                break
            }
            '3' {
                $script:TaskSchedule = 'DAILY'
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
    }

    $modifierInput = Read-Host 'Interval value (whole number > 0)'
    [int]$parsedModifier = 0
    if (-not [int]::TryParse($modifierInput, [ref]$parsedModifier) -or $parsedModifier -lt 1) {
        throw 'The interval value must be a whole number greater than 0.'
    }

    $script:TaskModifier = $parsedModifier
}

function Install-AzCli {
    if (Get-Command az -ErrorAction SilentlyContinue) {
        Write-Step 'Azure CLI is available.'
        return
    }

    Write-Step 'Azure CLI not found. Starting installation.'

    if (Get-Command winget -ErrorAction SilentlyContinue) {
        winget install --id Microsoft.AzureCLI --exact --accept-package-agreements --accept-source-agreements --silent
    }
    else {
        throw 'Azure CLI is missing and winget is not available. Please install Azure CLI manually: https://aka.ms/installazurecliwindows'
    }

    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw 'Azure CLI installation could not be verified.'
    }
}

function Connect-AzureLogin {
    $account = az account show --output json 2>$null
    if (-not $account) {
        Write-Step 'No active Azure login found. Starting az login.'
        az login --output none
    }

    az account set --subscription $SubscriptionId --output none
    Write-Step "Subscription set: $SubscriptionId"
}

function Test-DeploymentPermissions {
    Write-Step 'Checking Azure roles for the current user.'

    try {
        $signedInObjectId = az ad signed-in-user show --query id -o tsv
        if (-not $signedInObjectId) {
            Write-Warning 'Could not determine the object ID of the signed-in user. Continuing deployment.'
            return
        }

        $scope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName"
        $rolesJson = az role assignment list --assignee-object-id $signedInObjectId --scope $scope --include-inherited --output json
        $roles = $rolesJson | ConvertFrom-Json

        if (-not $roles) {
            Write-Warning "No direct role assignments found for the current user on scope '$scope'. This can happen with PIM/group-based access. Continuing deployment."
            return
        }

        $requiredRoles = @('Owner', 'Contributor', 'Log Analytics Contributor', 'Monitoring Contributor')
        $roleNames = @($roles | ForEach-Object { $_.roleDefinitionName } | Select-Object -Unique)

        $isAllowed = $false
        foreach ($requiredRole in $requiredRoles) {
            if ($roleNames -contains $requiredRole) {
                $isAllowed = $true
                break
            }
        }

        if (-not $isAllowed) {
            Write-Warning "No expected deployment role found in direct assignments on scope '$scope'. Detected roles: $($roleNames -join ', '). Continuing deployment and relying on ARM authorization."
            return
        }

        Write-Step "Permission check successful. Roles: $($roleNames -join ', ')"
    }
    catch {
        Write-Warning "Permission pre-check failed with '$($_.Exception.Message)'. Continuing deployment and relying on ARM authorization."
    }
}

function Install-BicepSupport {
    Write-Step 'Ensuring Bicep is available in Azure CLI.'
    az bicep install --output none
}

function Deploy-Infrastructure {
    Write-Step 'Running Bicep deployment.'

    $templatePath = Join-Path -Path $PSScriptRoot -ChildPath 'main.bicep'
    if (-not (Test-Path -Path $templatePath -PathType Leaf)) {
        throw "Bicep file not found: $templatePath"
    }

    $principalIdForBicep = if ($script:ManagedIdentityPrincipalId) { $script:ManagedIdentityPrincipalId } else { '' }
    $machineRgForBicep = if ($script:ManagedIdentityResourceGroupName) { $script:ManagedIdentityResourceGroupName } else { '' }
    $arcMachineNameForBicep = if ($script:ManagedIdentityMachineType -eq 'Arc') { $script:ManagedIdentityMachineName } else { '' }
    $vmMachineNameForBicep = if ($script:ManagedIdentityMachineType -eq 'Vm') { $script:ManagedIdentityMachineName } else { '' }

    $outputsJson = az deployment group create `
        --resource-group $ResourceGroupName `
        --template-file $templatePath `
        --parameters location=$Location `
        logAnalyticsWorkspaceName=$WorkspaceName `
        customTableName=$CustomTableName `
        dataCollectionEndpointName=$DataCollectionEndpointName `
        dataCollectionRuleName=$DataCollectionRuleName `
        streamName=$StreamName `
        managedIdentityPrincipalId=$principalIdForBicep `
        managedIdentityResourceGroupName=$machineRgForBicep `
        managedIdentityArcMachineName=$arcMachineNameForBicep `
        managedIdentityVmName=$vmMachineNameForBicep `
        --query properties.outputs `
        --output json

    if (-not $outputsJson) {
        throw 'Deployment returned no outputs.'
    }

    return ($outputsJson | ConvertFrom-Json)
}

function Get-JwtClaimValue {
    param(
        [Parameter(Mandatory = $true)][string]$Token,
        [Parameter(Mandatory = $true)][string]$ClaimName
    )

    try {
        $parts = $Token.Split('.')
        if ($parts.Count -lt 2) {
            return $null
        }

        $payloadSegment = $parts[1].Replace('-', '+').Replace('_', '/')
        switch ($payloadSegment.Length % 4) {
            2 { $payloadSegment += '==' }
            3 { $payloadSegment += '=' }
            0 { }
            default { return $null }
        }

        $jsonPayload = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($payloadSegment))
        $payloadObject = $jsonPayload | ConvertFrom-Json
        if ($payloadObject -and $payloadObject.PSObject.Properties[$ClaimName]) {
            return [string]$payloadObject.$ClaimName
        }
    }
    catch {
        return $null
    }

    return $null
}

function Get-HttpHeaderValue {
    param(
        [Parameter(Mandatory = $true)]$Headers,
        [Parameter(Mandatory = $true)][string]$HeaderName
    )

    if ($null -eq $Headers) {
        return $null
    }

    try {
        if ($Headers -is [System.Collections.IDictionary]) {
            return [string]$Headers[$HeaderName]
        }

        $headerValues = $null
        if ($Headers.PSObject.Methods['TryGetValues']) {
            $found = $Headers.TryGetValues($HeaderName, [ref]$headerValues)
            if ($found -and $headerValues) {
                return [string]($headerValues -join ', ')
            }
        }

        if ($Headers.PSObject.Methods['GetValues']) {
            $headerValues = $Headers.GetValues($HeaderName)
            if ($headerValues) {
                return [string]($headerValues -join ', ')
            }
        }

        if ($Headers.PSObject.Properties[$HeaderName]) {
            return [string]$Headers.$HeaderName
        }
    }
    catch {
        return $null
    }

    return $null
}

function Get-ArcManagedIdentityAccessToken {
    param(
        [string]$ManagedIdentityClientId,
        [int]$TimeoutSeconds = 20
    )

    $resource = [System.Uri]::EscapeDataString('https://monitor.azure.com/')
    $tokenUri = "http://localhost:40342/metadata/identity/oauth2/token?api-version=2020-06-01&resource=$resource"
    if ($ManagedIdentityClientId) {
        $encodedClientId = [System.Uri]::EscapeDataString($ManagedIdentityClientId)
        $tokenUri = "$tokenUri&client_id=$encodedClientId"
    }

    $headers = @{ Metadata = 'true' }
    $secretFilePath = $null

    try {
        Invoke-WebRequest -Method Get -Uri $tokenUri -Headers $headers -TimeoutSec $TimeoutSeconds -UseBasicParsing | Out-Null
        throw 'Expected a 401 challenge from the Arc identity endpoint, but the initial unauthenticated request unexpectedly succeeded.'
    }
    catch {
        if (-not $_.Exception.Response) {
            throw
        }

        $wwwAuthHeader = Get-HttpHeaderValue -Headers $_.Exception.Response.Headers -HeaderName 'WWW-Authenticate'
        if (-not $wwwAuthHeader -or $wwwAuthHeader -notmatch 'Basic realm=(.+)') {
            throw "Arc identity endpoint did not return the expected WWW-Authenticate challenge. Response header: $wwwAuthHeader"
        }

        $secretFilePath = $Matches[1].Trim()
    }

    if (-not (Test-Path -Path $secretFilePath -PathType Leaf)) {
        throw "Arc identity challenge secret file was not found or is not readable by this account: $secretFilePath"
    }

    $secret = Get-Content -Path $secretFilePath -Raw
    $authHeaders = @{ Metadata = 'true'; Authorization = "Basic $secret" }
    $response = Invoke-RestMethod -Method Get -Uri $tokenUri -Headers $authHeaders -TimeoutSec $TimeoutSeconds
    if (-not $response.access_token) {
        throw 'Arc identity endpoint did not return an access token.'
    }

    return [string]$response.access_token
}

function Resolve-ManagedIdentityPrincipalId {
    if ($ManagedIdentityPrincipalId) {
        Write-Step "Using provided ManagedIdentityPrincipalId: $ManagedIdentityPrincipalId"
        return $true
    }

    if ($ManagedIdentityClientId) {
        try {
            $resolvedFromClientId = az ad sp show --id $ManagedIdentityClientId --query id -o tsv 2>$null
            if ($resolvedFromClientId) {
                $script:ManagedIdentityPrincipalId = [string]$resolvedFromClientId
                Write-Step "Resolved ManagedIdentityPrincipalId from ManagedIdentityClientId via Microsoft Graph: $script:ManagedIdentityPrincipalId"
                return $true
            }
        }
        catch {
            Write-Warning "Could not resolve ManagedIdentityPrincipalId from ManagedIdentityClientId '$ManagedIdentityClientId' via Graph: $($_.Exception.Message)"
        }
    }

    try {
        $miToken = Get-ArcManagedIdentityAccessToken -ManagedIdentityClientId $ManagedIdentityClientId
        $resolvedFromToken = Get-JwtClaimValue -Token $miToken -ClaimName 'oid'
        if ($resolvedFromToken) {
            $script:ManagedIdentityPrincipalId = [string]$resolvedFromToken
            Write-Step "Resolved ManagedIdentityPrincipalId from Arc managed identity token claim 'oid': $script:ManagedIdentityPrincipalId"
            return $true
        }

        Write-Warning 'Arc managed identity access token was retrieved, but claim "oid" was not found. RBAC assignment may be skipped.'
    }
    catch {
        Write-Warning "Automatic managed identity principal resolution failed: $($_.Exception.Message)"
    }

    return $false
}

function Resolve-ManagedIdentityResourceReference {
    $script:ManagedIdentityMachineName = if ($ManagedIdentityMachineName) { $ManagedIdentityMachineName } else { $env:COMPUTERNAME }
    if (-not $script:ManagedIdentityMachineName) {
        Write-Warning 'Managed identity source machine name could not be determined.'
        return $false
    }

    Write-Step "Managed identity source machine name: $script:ManagedIdentityMachineName"

    if ($ManagedIdentityResourceGroupName) {
        $script:ManagedIdentityResourceGroupName = $ManagedIdentityResourceGroupName
    }
    else {
        try {
            $arcRg = az resource list --name $script:ManagedIdentityMachineName --resource-type Microsoft.HybridCompute/machines --query "[0].resourceGroup" -o tsv 2>$null
            if ($arcRg) {
                $script:ManagedIdentityResourceGroupName = [string]$arcRg
                $script:ManagedIdentityMachineType = 'Arc'
                Write-Step "Resolved managed identity source as Arc machine in resource group '$script:ManagedIdentityResourceGroupName'."
                return $true
            }
        }
        catch {
            Write-Warning "Arc machine resource group auto-detection failed: $($_.Exception.Message)"
        }

        try {
            $vmRg = az vm list --query "[?name=='$($script:ManagedIdentityMachineName)'][0].resourceGroup" -o tsv 2>$null
            if ($vmRg) {
                $script:ManagedIdentityResourceGroupName = [string]$vmRg
                $script:ManagedIdentityMachineType = 'Vm'
                Write-Step "Resolved managed identity source as Azure VM in resource group '$script:ManagedIdentityResourceGroupName'."
                return $true
            }
        }
        catch {
            Write-Warning "Azure VM resource group auto-detection failed: $($_.Exception.Message)"
        }
    }

    if (-not $script:ManagedIdentityResourceGroupName) {
        Write-Warning 'ManagedIdentityResourceGroupName could not be resolved automatically.'
        return $false
    }

    try {
        $arcId = az resource show --resource-group $script:ManagedIdentityResourceGroupName --name $script:ManagedIdentityMachineName --resource-type Microsoft.HybridCompute/machines --query id -o tsv 2>$null
        if ($arcId) {
            $script:ManagedIdentityMachineType = 'Arc'
            Write-Step "Managed identity source confirmed as Arc machine in resource group '$script:ManagedIdentityResourceGroupName'."
            return $true
        }
    }
    catch {
        Write-Warning "Arc machine lookup in provided resource group failed: $($_.Exception.Message)"
    }

    try {
        $vmId = az vm show --resource-group $script:ManagedIdentityResourceGroupName --name $script:ManagedIdentityMachineName --query id -o tsv 2>$null
        if ($vmId) {
            $script:ManagedIdentityMachineType = 'Vm'
            Write-Step "Managed identity source confirmed as Azure VM in resource group '$script:ManagedIdentityResourceGroupName'."
            return $true
        }
    }
    catch {
        Write-Warning "Azure VM lookup in provided resource group failed: $($_.Exception.Message)"
    }

    Write-Warning "No Arc machine or VM named '$script:ManagedIdentityMachineName' with managed identity source was found in resource group '$script:ManagedIdentityResourceGroupName'."
    return $false
}

function Write-ConfigFile {
    param(
        [Parameter(Mandatory = $true)]$DeploymentOutputs
    )

    $configPath = Join-Path -Path $PSScriptRoot -ChildPath 'config.json'
    $archivePath = Join-Path -Path $PSScriptRoot -ChildPath 'archive'
    $logsPath = Join-Path -Path $PSScriptRoot -ChildPath 'logs'

    if (-not (Test-Path -Path $archivePath -PathType Container)) {
        New-Item -Path $archivePath -ItemType Directory -Force | Out-Null
    }

    if (-not (Test-Path -Path $logsPath -PathType Container)) {
        New-Item -Path $logsPath -ItemType Directory -Force | Out-Null
    }

    $configObject = [ordered]@{
        SourceDirectory                   = $PSScriptRoot
        SourcePattern                     = '*-locksmith2.json'
        ArchiveDirectory                  = $archivePath
        ArchivePrefixTimestamp            = $true
        LogsDirectory                     = $logsPath
        DceUri                            = $DeploymentOutputs.dataCollectionEndpointUri.value
        DcrImmutableId                    = $DeploymentOutputs.dataCollectionRuleImmutableId.value
        StreamName                        = $DeploymentOutputs.streamNameOut.value
        ApiVersion                        = '2023-01-01'
        ManagedIdentityClientId           = $ManagedIdentityClientId
        GenerateReportBeforeIngestion     = $true
        ReportForest                      = ''
        IngestNoFindingsRecord            = $true
        ReportGenerationTimeoutSeconds    = 900
        FileStabilityChecks               = 3
        FileStabilityCheckIntervalSeconds = 2
        FileStabilityTimeoutSeconds       = 120
        UploadRetryCount                  = 3
        UploadRetryBaseDelaySeconds       = 2
        ImdsTimeoutSeconds                = 20
        ImdsRetryCount                    = 3
        ImdsRetryDelaySeconds             = 2
    }

    $configObject | ConvertTo-Json -Depth 5 | Set-Content -Path $configPath -Encoding UTF8
    Write-Step "config.json created: $configPath"
}

function Test-ExistingConfigFile {
    $configPath = Join-Path -Path $PSScriptRoot -ChildPath 'config.json'

    if (-not (Test-Path -Path $configPath -PathType Leaf)) {
        throw "SkipDeployment is active, but config.json was not found: $configPath"
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
            throw "SkipDeployment is active, but config entry '$key' is missing or empty."
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

if ($SkipDeployment) {
    Write-Step 'SkipDeployment is active: Bicep deployment and RBAC assignment are being skipped.'
    Test-ExistingConfigFile
}
else {
    Install-AzCli
    Connect-AzureLogin
    Test-DeploymentPermissions
    Install-BicepSupport

    $principalResolved = Resolve-ManagedIdentityPrincipalId
    $resourceReferenceResolved = Resolve-ManagedIdentityResourceReference

    if (-not $principalResolved -and -not $resourceReferenceResolved) {
        throw 'Managed identity could not be resolved for DCR RBAC assignment. Provide -ManagedIdentityPrincipalId, or provide/allow auto-detection of -ManagedIdentityMachineName and -ManagedIdentityResourceGroupName.'
    }

    $outputs = Deploy-Infrastructure
    Write-ConfigFile -DeploymentOutputs $outputs
}

Install-Locksmith2
Install-LocksmithPrerequisite
New-OrUpdateScheduledTask

Write-Step 'Installation completed.'
