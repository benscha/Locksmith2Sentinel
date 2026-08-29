param(
    [string]$ConfigPath = (Join-Path -Path $PSScriptRoot -ChildPath 'config.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('INFO', 'WARN', 'ERROR')] [string]$Level,
        [Parameter(Mandatory = $true)] [string]$Message
    )

    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $line = "[$timestamp] [$Level] $Message"
    Add-Content -Path $script:LogFile -Value $line -Encoding UTF8

    if ($Level -eq 'ERROR') {
        Write-Error $Message
    }
    elseif ($Level -eq 'WARN') {
        Write-Warning $Message
    }
    else {
        Write-Host $Message
    }
}

function Get-SourceFiles {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Config
    )

    $archiveFullPath = [System.IO.Path]::GetFullPath($Config.ArchiveDirectory).TrimEnd('\')
    $archivePrefix = Join-Path -Path $archiveFullPath -ChildPath ''

    return @(Get-ChildItem -Path $Config.SourceDirectory -Filter $Config.SourcePattern -File |
        Where-Object {
            $fileFullPath = [System.IO.Path]::GetFullPath($_.FullName)
            return (-not $fileFullPath.StartsWith($archivePrefix, [System.StringComparison]::OrdinalIgnoreCase))
        } |
        Sort-Object LastWriteTime -Descending)
}

function Remove-AnsiEscapeCode {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
    )

    # Locksmith2 prints a colorful truecolor banner on load (CSI SGR sequences, e.g.
    # ESC[38;2;R;G;Bm). Captured via file redirection instead of a real console, these
    # land in the log as raw, unreadable escape bytes. Strip standard CSI sequences
    # (ESC '[' ... final byte) so logged output stays human-readable.
    #
    # NOTE: the backtick escape "`e" (ESC) only exists from PowerShell 6.0 onward. This
    # script runs under Windows PowerShell 5.1 (invoked as powershell.exe), where "`e"
    # is not a recognized escape and silently degrades to the literal letter "e" -
    # which made this filter a no-op. [char]27 works on both editions.
    $escapeChar = [char]27
    return [System.Text.RegularExpressions.Regex]::Replace($Text, "$escapeChar\[[0-9;]*[a-zA-Z]", '')
}

function ConvertTo-QuotedArgumentString {
    param(
        [Parameter(Mandatory = $true)][string[]]$ArgumentList
    )

    # Windows PowerShell 5.1's ProcessStartInfo has no ArgumentList collection (that
    # was added in .NET Core/5+); it only accepts a single pre-quoted command-line
    # string, so arguments must be quoted manually here.
    return ($ArgumentList | ForEach-Object {
            $escaped = $_ -replace '"', '\"'
            '"' + $escaped + '"'
        }) -join ' '
}

function Invoke-ExternalPowerShellScript {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [Parameter()][string[]]$ScriptArguments = @(),
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )

    # Start-Process combined with -RedirectStandardOutput/-RedirectStandardError (file
    # paths) plus manual WaitForExit() proved unreliable in this environment (SYSTEM
    # account, Task Scheduler, hidden window): WaitForExit(timeout) returned true while
    # .ExitCode still read $null, and since $null -ne 0 is $true in PowerShell, a
    # genuinely successful run was reported as failed - reproducibly, even after adding
    # a follow-up parameterless WaitForExit() call.
    #
    # An earlier attempt at fixing this drove System.Diagnostics.Process directly with
    # Register-ObjectEvent + BeginOutputReadLine/BeginErrorReadLine (the commonly cited
    # "safe" .NET pattern). That also proved unreliable here: PowerShell's event-queue
    # relay between the underlying .NET event firing and the registered -Action
    # scriptblock running can lag behind WaitForExit() returning, so reading the output
    # StringBuilders immediately afterwards could race and return them still empty.
    #
    # Reading StandardOutput/StandardError via StreamReader.ReadToEndAsync() and
    # blocking on the resulting Tasks (rather than going through PowerShell's event
    # subsystem at all) avoids both problems: the async reads start immediately (so the
    # pipes can't fill and deadlock the process), and awaiting the Tasks directly
    # guarantees the content is fully available with no relay lag. Verified reliable
    # across repeated runs under real Windows PowerShell 5.1.
    $argumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath)
    if ($ScriptArguments.Count -gt 0) {
        $argumentList += $ScriptArguments
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = ConvertTo-QuotedArgumentString -ArgumentList $argumentList
    $psi.WorkingDirectory = $PSScriptRoot
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi

    try {
        $null = $process.Start()

        $stdOutTask = $process.StandardOutput.ReadToEndAsync()
        $stdErrTask = $process.StandardError.ReadToEndAsync()

        $completed = $process.WaitForExit($TimeoutSeconds * 1000)

        if (-not $completed) {
            try { $process.Kill() } catch { Write-Log -Level WARN -Message "Could not kill timed-out process: $($_.Exception.Message)" }
            throw "Report generation timed out after $TimeoutSeconds seconds."
        }

        # The process has exited; the async reads should complete almost immediately.
        # A bounded wait still guards against ReadToEndAsync itself ever hanging.
        [System.Threading.Tasks.Task]::WaitAll(@($stdOutTask, $stdErrTask), 30000) | Out-Null

        $exitCode = $process.ExitCode
        $stdOut = Remove-AnsiEscapeCode -Text $stdOutTask.Result
        $stdErr = Remove-AnsiEscapeCode -Text $stdErrTask.Result

        if ($exitCode -ne 0) {
            $details = @()
            if (-not [string]::IsNullOrWhiteSpace($stdErr)) { $details += "stderr: $($stdErr.Trim())" }
            if (-not [string]::IsNullOrWhiteSpace($stdOut)) { $details += "stdout: $($stdOut.Trim())" }
            $suffix = if ($details.Count -gt 0) { " Details: $($details -join ' | ')" } else { '' }
            throw "Report generation failed with exit code $exitCode.$suffix"
        }

        if (-not [string]::IsNullOrWhiteSpace($stdOut)) {
            Write-Log -Level INFO -Message "Report generation output: $($stdOut.Trim())"
        }
        if (-not [string]::IsNullOrWhiteSpace($stdErr)) {
            Write-Log -Level WARN -Message "Report generation stderr: $($stdErr.Trim())"
        }
    }
    finally {
        $process.Dispose()
    }
}

function Resolve-ExpectedOutputFilePath {
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

function Invoke-ReportGeneration {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Config
    )

    if (-not [bool]$Config.GenerateReportBeforeIngestion) {
        Write-Log -Level INFO -Message 'Report generation is disabled by configuration.'
        return $null
    }

    [int]$timeoutSeconds = [int]$Config.ReportGenerationTimeoutSeconds
    if ($timeoutSeconds -lt 30) {
        $timeoutSeconds = 30
    }

    $generatorScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'locksmitGenReport.ps1'
    if (-not (Test-Path -Path $generatorScriptPath -PathType Leaf)) {
        throw "Report generator script was not found: $generatorScriptPath"
    }

    $expectedOutputFilePath = Resolve-ExpectedOutputFilePath -Directory ([string]$Config.SourceDirectory) -Pattern ([string]$Config.SourcePattern)
    $generatorArgs = @(
        '-OutputDirectory', ([string]$Config.SourceDirectory),
        '-OutputPattern', ([string]$Config.SourcePattern)
    )
    if (-not [string]::IsNullOrWhiteSpace([string]$Config.ReportForest)) {
        $generatorArgs += @('-Forest', ([string]$Config.ReportForest))
    }

    Write-Log -Level INFO -Message "Generating Locksmith report using: $generatorScriptPath"
    Invoke-ExternalPowerShellScript -ScriptPath $generatorScriptPath -ScriptArguments $generatorArgs -TimeoutSeconds $timeoutSeconds
    Write-Log -Level INFO -Message 'Report generation completed. Report file detection follows in the next step.'
    return $expectedOutputFilePath
}

function Wait-ForStableFile {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [int]$Checks = 3,
        [int]$IntervalSeconds = 2,
        [int]$TimeoutSeconds = 120
    )

    if ($Checks -lt 1) { $Checks = 1 }
    if ($IntervalSeconds -lt 1) { $IntervalSeconds = 1 }
    if ($TimeoutSeconds -lt 5) { $TimeoutSeconds = 5 }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastLength = -1L
    $stableMatches = 0

    while ((Get-Date) -lt $deadline) {
        if (-not (Test-Path -Path $FilePath -PathType Leaf)) {
            throw "Source file was not found while waiting for stability: $FilePath"
        }

        $currentLength = (Get-Item -Path $FilePath -ErrorAction Stop).Length
        if ($currentLength -eq $lastLength) {
            $stableMatches++
        }
        else {
            $lastLength = $currentLength
            $stableMatches = 0
        }

        if ($stableMatches -ge ($Checks - 1)) {
            Write-Log -Level INFO -Message "Source file is stable and ready: $FilePath"
            return
        }

        Start-Sleep -Seconds $IntervalSeconds
    }

    throw "Timed out while waiting for source file stability: $FilePath"
}

function Get-ImdsAccessToken {
    param(
        [string]$ManagedIdentityClientId,
        [int]$TimeoutSeconds = 20,
        [int]$RetryCount = 3,
        [int]$RetryDelaySeconds = 2
    )

    if ($TimeoutSeconds -lt 5) { $TimeoutSeconds = 5 }
    if ($RetryCount -lt 1) { $RetryCount = 1 }
    if ($RetryDelaySeconds -lt 1) { $RetryDelaySeconds = 1 }

    # This host is an Azure Arc-connected server, not a native Azure VM: there is no
    # IMDS at 169.254.169.254. Arc's Hybrid Instance Metadata Service (HIMDS) instead
    # listens locally on localhost:40342 and requires a challenge/response handshake -
    # the first request is expected to fail with 401, whose WWW-Authenticate header
    # names a local secret-key file readable only by privileged accounts (SYSTEM,
    # local Administrators, or "Hybrid Agent Extension Applications"). That file's
    # content is sent back as a Basic auth header to obtain the actual token.
    # https://learn.microsoft.com/azure/azure-arc/servers/managed-identity-authentication
    $resource = [System.Uri]::EscapeDataString('https://monitor.azure.com/')
    $tokenUri = "http://localhost:40342/metadata/identity/oauth2/token?api-version=2020-06-01&resource=$resource"
    if ($ManagedIdentityClientId) {
        $encodedClientId = [System.Uri]::EscapeDataString($ManagedIdentityClientId)
        $tokenUri = "$tokenUri&client_id=$encodedClientId"
    }

    $headers = @{ Metadata = 'true' }
    $lastErrorMessage = $null

    for ($attempt = 1; $attempt -le $RetryCount; $attempt++) {
        try {
            $secretFilePath = $null
            try {
                Invoke-WebRequest -Method Get -Uri $tokenUri -Headers $headers -TimeoutSec $TimeoutSeconds -UseBasicParsing | Out-Null
                throw 'Expected a 401 challenge from the Arc identity endpoint, but the initial unauthenticated request unexpectedly succeeded.'
            }
            catch {
                $challengeResponse = $_.Exception.Response
                if (-not $challengeResponse) {
                    throw
                }

                $wwwAuthHeader = $challengeResponse.Headers['WWW-Authenticate']
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

            return $response.access_token
        }
        catch {
            $lastErrorMessage = $_.Exception.Message
            if ($attempt -ge $RetryCount) {
                break
            }

            $delaySeconds = [Math]::Min(30, [int]($RetryDelaySeconds * [Math]::Pow(2, ($attempt - 1))))
            Write-Log -Level WARN -Message "Arc managed identity token request failed (attempt $attempt/$RetryCount): $($_.Exception.Message). Retrying in $delaySeconds second(s)."
            Start-Sleep -Seconds $delaySeconds
        }
    }

    throw "Failed to retrieve a managed identity token from the Azure Arc identity endpoint after $RetryCount attempt(s). TimeoutSeconds=$TimeoutSeconds. Endpoint=$tokenUri. Verify the Connected Machine Agent (himds) service is running and this account (SYSTEM, local Administrators, or 'Hybrid Agent Extension Applications') can read its challenge secret file. Last error: $lastErrorMessage"
}

function Get-JwtClaimValue {
    param(
        [Parameter(Mandatory = $true)][string]$Token,
        [Parameter(Mandatory = $true)][string]$ClaimName
    )

    try {
        $parts = $Token.Split('.')
        if ($parts.Count -lt 2) {
            return ''
        }

        $payloadSegment = $parts[1].Replace('-', '+').Replace('_', '/')
        switch ($payloadSegment.Length % 4) {
            2 { $payloadSegment += '==' }
            3 { $payloadSegment += '=' }
            0 { }
            default { return '' }
        }

        $jsonPayload = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($payloadSegment))
        $payloadObject = $jsonPayload | ConvertFrom-Json
        if ($payloadObject -and $payloadObject.PSObject.Properties[$ClaimName]) {
            return [string]$payloadObject.$ClaimName
        }

        return ''
    }
    catch {
        return ''
    }
}

function Get-AccessTokenSummary {
    param(
        [Parameter(Mandatory = $true)][string]$Token
    )

    $aud = Get-JwtClaimValue -Token $Token -ClaimName 'aud'
    $tid = Get-JwtClaimValue -Token $Token -ClaimName 'tid'
    $oid = Get-JwtClaimValue -Token $Token -ClaimName 'oid'
    $appid = Get-JwtClaimValue -Token $Token -ClaimName 'appid'
    $xmsMirid = Get-JwtClaimValue -Token $Token -ClaimName 'xms_mirid'

    $parts = @()
    if (-not [string]::IsNullOrWhiteSpace($aud)) { $parts += "aud=$aud" }
    if (-not [string]::IsNullOrWhiteSpace($tid)) { $parts += "tid=$tid" }
    if (-not [string]::IsNullOrWhiteSpace($oid)) { $parts += "oid=$oid" }
    if (-not [string]::IsNullOrWhiteSpace($appid)) { $parts += "appid=$appid" }
    if (-not [string]::IsNullOrWhiteSpace($xmsMirid)) { $parts += "xms_mirid=$xmsMirid" }

    return ($parts -join ', ')
}

function Validate-LocksmithRecord {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Record
    )

    $requiredFields = @(
        'Technique',
        'Forest',
        'Name',
        'DistinguishedName',
        'ObjectClass',
        'Issue',
        'Fix',
        'Revert'
    )

    foreach ($field in $requiredFields) {
        if (-not $Record.PSObject.Properties[$field]) {
            throw "Required field '$field' is missing in a Locksmith record."
        }
    }
}

function Get-LocksmithPayload {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath
    )

    $rawJson = Get-Content -Path $FilePath -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($rawJson)) {
        throw "File '$FilePath' is empty."
    }

    # ConvertFrom-Json's -Depth parameter only exists from PowerShell 6.0 onward; this
    # script runs under Windows PowerShell 5.1, where that parameter doesn't exist at
    # all (unlike ConvertTo-Json, which has had -Depth since 5.1). Its default parsing
    # depth (1024) is already far beyond what this JSON structure needs.
    $parsed = $rawJson | ConvertFrom-Json
    $records = @($parsed)

    if ($records.Count -eq 0) {
        Write-Log -Level WARN -Message "File '$FilePath' does not contain any records. No ingestion payload will be created."
        return @()
    }

    $timeGenerated = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $payload = New-Object System.Collections.Generic.List[object]
    $recordIndex = -1

    foreach ($record in $records) {
        $recordIndex++
        try {
            Validate-LocksmithRecord -Record $record

            $enriched = [ordered]@{
                TimeGenerated          = $timeGenerated
                Technique              = $record.Technique
                Forest                 = $record.Forest
                Name                   = $record.Name
                DistinguishedName      = $record.DistinguishedName
                ObjectClass            = $record.ObjectClass
                IdentityReference      = $record.IdentityReference
                IdentityReferenceSID   = $record.IdentityReferenceSID
                IdentityReferenceClass = $record.IdentityReferenceClass
                ActiveDirectoryRights  = $record.ActiveDirectoryRights
                AceObjectTypeGUID      = $record.AceObjectTypeGUID
                AceObjectTypeName      = $record.AceObjectTypeName
                Enabled                = $record.Enabled
                EnabledOn              = $record.EnabledOn
                CAFullName             = $record.CAFullName
                Owner                  = $record.Owner
                HasNonStandardOwner    = $record.HasNonStandardOwner
                MemberCount            = $record.MemberCount
                Issue                  = $record.Issue
                Fix                    = $record.Fix
                Revert                 = $record.Revert
            }

            $payload.Add([pscustomobject]$enriched)
        }
        catch {
            $stackFlat = $_.ScriptStackTrace -replace '\r?\n', ' <- '
            throw "Record #$recordIndex (Technique='$($record.Technique)', Name='$($record.Name)') failed: $($_.Exception.GetType().FullName): $($_.Exception.Message) | Stack: $stackFlat"
        }
    }

    return $payload.ToArray()
}

function New-NoFindingsPayload {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Config,
        [Parameter(Mandatory = $true)][string]$SourceFileName
    )

    $timeGenerated = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $forestValue = [string]$Config.ReportForest

    $record = [ordered]@{
        TimeGenerated          = $timeGenerated
        Technique              = 'NO_FINDINGS'
        Forest                 = $forestValue
        Name                   = [string]$env:COMPUTERNAME
        DistinguishedName      = ''
        ObjectClass            = 'Locksmith2Run'
        IdentityReference      = ''
        IdentityReferenceSID   = ''
        IdentityReferenceClass = ''
        ActiveDirectoryRights  = ''
        AceObjectTypeGUID      = ''
        AceObjectTypeName      = ''
        Enabled                = $false
        EnabledOn              = @()
        CAFullName             = ''
        Owner                  = ''
        HasNonStandardOwner    = $false
        MemberCount            = [int64]0
        Issue                  = "No findings detected by Locksmith2 (source file: $SourceFileName)."
        Fix                    = 'None'
        Revert                 = 'None'
    }

    return @([pscustomobject]$record)
}

function Send-LawIngestion {
    param(
        [Parameter(Mandatory = $true)][array]$Payload,
        [Parameter(Mandatory = $true)][pscustomobject]$Config,
        [Parameter(Mandatory = $true)][string]$AccessToken,
        [int]$MaxAttempts = 3,
        [int]$BaseDelaySeconds = 2
    )

    $ingestionUri = '{0}/dataCollectionRules/{1}/streams/{2}?api-version={3}' -f `
        $Config.DceUri.TrimEnd('/'),
    $Config.DcrImmutableId,
    $Config.StreamName,
    $Config.ApiVersion

    $headers = @{ Authorization = "Bearer $AccessToken" }
    $body = $Payload | ConvertTo-Json -Depth 20 -Compress

    if ($MaxAttempts -lt 1) { $MaxAttempts = 1 }
    if ($BaseDelaySeconds -lt 1) { $BaseDelaySeconds = 1 }

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            Write-Log -Level INFO -Message "Sending $($Payload.Count) records to $ingestionUri (attempt $attempt/$MaxAttempts)."
            Invoke-RestMethod -Method Post -Uri $ingestionUri -Headers $headers -Body $body -ContentType 'application/json' -TimeoutSec 120 | Out-Null
            return
        }
        catch {
            $statusCode = $null
            $responseBody = $null
            if ($_.Exception -and $_.Exception.PSObject.Properties['Response'] -and $null -ne $_.Exception.Response) {
                try {
                    $statusCode = [int]$_.Exception.Response.StatusCode.value__
                }
                catch {
                    $statusCode = $null
                }

                try {
                    $responseStream = $_.Exception.Response.GetResponseStream()
                    if ($null -ne $responseStream) {
                        $reader = New-Object System.IO.StreamReader($responseStream)
                        try {
                            $responseBody = $reader.ReadToEnd()
                        }
                        finally {
                            $reader.Dispose()
                        }
                    }
                }
                catch {
                    $responseBody = $null
                }
            }

            $isRetryable = ($null -eq $statusCode -or $statusCode -eq 429 -or $statusCode -ge 500)
            if (-not $isRetryable -or $attempt -eq $MaxAttempts) {
                $bodyFlat = if ([string]::IsNullOrWhiteSpace([string]$responseBody)) { '' } else { ($responseBody -replace '\s+', ' ').Trim() }
                $statusText = if ($null -eq $statusCode) { 'unknown' } else { [string]$statusCode }
                $hint = if ($statusCode -eq 403) { ' Verify role "Monitoring Metrics Publisher" on the DCR for the token principal (oid/appid from the access-token claims log line).' } else { '' }
                throw "Log Ingestion API request failed. StatusCode=$statusText. ResponseBody='$bodyFlat'.$hint"
            }

            $delaySeconds = [Math]::Min(60, [int]($BaseDelaySeconds * [Math]::Pow(2, ($attempt - 1))))
            Write-Log -Level WARN -Message "Upload failed with status '$statusCode'. Retrying in $delaySeconds seconds."
            Start-Sleep -Seconds $delaySeconds
        }
    }
}

function Move-ToArchive {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string]$ArchiveDirectory,
        [bool]$PrefixTimestamp = $true
    )

    $fileName = Split-Path -Path $FilePath -Leaf
    if ($PrefixTimestamp) {
        $prefix = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
        $fileName = "$prefix-$fileName"
    }

    $targetPath = Join-Path -Path $ArchiveDirectory -ChildPath $fileName
    Move-Item -Path $FilePath -Destination $targetPath -Force
    Write-Log -Level INFO -Message "File archived: $targetPath"
}

if (-not (Test-Path -Path $ConfigPath -PathType Leaf)) {
    throw "Config file not found: $ConfigPath"
}

$config = Get-Content -Path $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json

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
        throw "Config entry '$key' is missing or empty."
    }
}

$configDefaults = [ordered]@{
    ApiVersion                        = '2023-01-01'
    ArchivePrefixTimestamp            = $true
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

foreach ($key in $configDefaults.Keys) {
    if (-not $config.PSObject.Properties[$key]) {
        $config | Add-Member -NotePropertyName $key -NotePropertyValue $configDefaults[$key] -Force
    }
}

if (-not (Test-Path -Path $config.ArchiveDirectory -PathType Container)) {
    New-Item -Path $config.ArchiveDirectory -ItemType Directory -Force | Out-Null
}

if (-not (Test-Path -Path $config.LogsDirectory -PathType Container)) {
    New-Item -Path $config.LogsDirectory -ItemType Directory -Force | Out-Null
}

$script:LogFile = Join-Path -Path $config.LogsDirectory -ChildPath ("locksmith2Report-{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
Write-Log -Level INFO -Message 'Ingestion run started.'

$sourceFilesBeforeGeneration = @(Get-SourceFiles -Config $config)
$previousFiles = [System.Collections.Generic.Dictionary[string, psobject]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($file in $sourceFilesBeforeGeneration) {
    $previousFiles[[string]$file.FullName] = [pscustomobject]@{
        LastWriteTimeUtcTicks = $file.LastWriteTimeUtc.Ticks
        Length                = $file.Length
    }
}

try {
    $generatedReportPath = Invoke-ReportGeneration -Config $config
    $sourceFiles = @(Get-SourceFiles -Config $config)

    if (-not $sourceFiles -or $sourceFiles.Count -eq 0) {
        Write-Log -Level INFO -Message "No matching files found ($($config.SourcePattern))."
        exit 0
    }

    $newlyGeneratedFiles = @($sourceFiles | Where-Object { -not $previousFiles.ContainsKey([string]$_.FullName) })
    $updatedFiles = @($sourceFiles | Where-Object {
            $filePath = [string]$_.FullName
            if (-not $previousFiles.ContainsKey($filePath)) {
                return $false
            }

            $before = $previousFiles[$filePath]
            return ($_.LastWriteTimeUtc.Ticks -gt [int64]$before.LastWriteTimeUtcTicks -or $_.Length -ne [int64]$before.Length)
        })

    $latestFile = $null
    if (-not [string]::IsNullOrWhiteSpace([string]$generatedReportPath) -and (Test-Path -Path $generatedReportPath -PathType Leaf)) {
        $latestFile = Get-Item -Path $generatedReportPath -ErrorAction Stop
        Write-Log -Level INFO -Message "Using report generated in the current run: $($latestFile.FullName)"
    }
    elseif ($newlyGeneratedFiles.Count -gt 0) {
        $latestFile = $newlyGeneratedFiles | Select-Object -First 1
        Write-Log -Level INFO -Message "Using newly generated report for ingestion: $($latestFile.FullName)"
    }
    elseif ($updatedFiles.Count -gt 0) {
        $latestFile = $updatedFiles | Select-Object -First 1
        Write-Log -Level INFO -Message "Using updated report for ingestion: $($latestFile.FullName)"
    }
    else {
        $latestFile = $sourceFiles | Select-Object -First 1
        Write-Log -Level WARN -Message "No newly generated or updated report file was detected. Reusing most recent existing report: $($latestFile.FullName)"
    }

    Wait-ForStableFile `
        -FilePath $latestFile.FullName `
        -Checks ([int]$config.FileStabilityChecks) `
        -IntervalSeconds ([int]$config.FileStabilityCheckIntervalSeconds) `
        -TimeoutSeconds ([int]$config.FileStabilityTimeoutSeconds)

    $accessToken = Get-ImdsAccessToken `
        -ManagedIdentityClientId $config.ManagedIdentityClientId `
        -TimeoutSeconds ([int]$config.ImdsTimeoutSeconds) `
        -RetryCount ([int]$config.ImdsRetryCount) `
        -RetryDelaySeconds ([int]$config.ImdsRetryDelaySeconds)
    $accessTokenSummary = Get-AccessTokenSummary -Token $accessToken
    if ([string]::IsNullOrWhiteSpace($accessTokenSummary)) {
        Write-Log -Level INFO -Message 'Access token was retrieved.'
    }
    else {
        Write-Log -Level INFO -Message "Access token was retrieved. Claims: $accessTokenSummary"
    }
}
catch {
    # Task Scheduler does not capture stdout/stderr by default, so any exception
    # thrown here (report generation, file-stability wait, token acquisition) would
    # otherwise vanish - only the process exit code would be visible. Log it before
    # rethrowing so unattended runs leave a diagnosable trail.
    Write-Log -Level ERROR -Message "Error before ingestion could start: $($_.Exception.Message) | At: $($_.InvocationInfo.PositionMessage -replace '\s+', ' ')"
    throw
}

Write-Log -Level INFO -Message "Processing file: $($latestFile.FullName)"
try {
    $payload = Get-LocksmithPayload -FilePath $latestFile.FullName
    if ($payload.Count -eq 0 -and [bool]$config.IngestNoFindingsRecord) {
        $payload = New-NoFindingsPayload -Config $config -SourceFileName $latestFile.Name
        Write-Log -Level WARN -Message "Report '$($latestFile.Name)' contained no findings. Creating and ingesting a NO_FINDINGS marker record."
    }

    if ($payload.Count -gt 0) {
        Send-LawIngestion -Payload $payload -Config $config -AccessToken $accessToken -MaxAttempts ([int]$config.UploadRetryCount) -BaseDelaySeconds ([int]$config.UploadRetryBaseDelaySeconds)
        Write-Log -Level INFO -Message "Upload successful: $($latestFile.Name)"
    }
    else {
        Write-Log -Level WARN -Message "Skipping upload because the generated report contains no ingestible records: $($latestFile.Name)"
    }

    Move-ToArchive -FilePath $latestFile.FullName -ArchiveDirectory $config.ArchiveDirectory -PrefixTimestamp ([bool]$config.ArchivePrefixTimestamp)
}
catch {
    # A bare $_.Exception.Message on a generic .NET exception (e.g. "Argument types
    # do not match") gives no clue which line threw it. Include position info so
    # failures here are diagnosable from the log alone, without needing another
    # round-trip to reproduce and re-log.
    Write-Log -Level ERROR -Message "Error while processing file '$($latestFile.Name)': $($_.Exception.Message) | At: $($_.InvocationInfo.PositionMessage -replace '\s+', ' ')"
    throw
}

Write-Log -Level INFO -Message 'Ingestion run completed.'
