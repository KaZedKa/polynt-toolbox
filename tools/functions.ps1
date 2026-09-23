Set-StrictMode -Version 2.0

$script:PolyntAdminUser = if ($env:POLYNT_ADMIN_USER) { $env:POLYNT_ADMIN_USER } else { '' }
$script:PolyntLabelScript = if ($env:POLYNT_LABEL_SCRIPT) { $env:POLYNT_LABEL_SCRIPT } else { '' }
$script:PolyntCredentialPath = Join-Path $(if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { $env:TEMP }) 'PolyntToolbox\credentials.xml'
$script:PolyntLegacyCredentialPath = Join-Path $(if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { $env:TEMP }) 'PolyntToolbox\credential.xml'
$script:PsExecPath = Join-Path $PSScriptRoot 'PsExec.exe'
$script:AssystSettingsPath = Join-Path $(if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { $env:TEMP }) 'PolyntToolbox\assyst.xml'
$script:AssystApiBase = if ($env:ASSYST_API_BASE) { $env:ASSYST_API_BASE.TrimEnd('/') } else { 'https://itsupporttest.polynt.net/assystREST/v2' }
$script:AssystAllowUntrustedCertificate = $true
$script:AssystDefaultMovementReason = 'CUSTOMER REQ'
$script:AssystReferenceCache = @{}
$script:AssystMovementReasonCache = @{}
if (Test-Path -LiteralPath $script:AssystSettingsPath) {
    try {
        $savedAssystSettings = Import-Clixml -LiteralPath $script:AssystSettingsPath -ErrorAction Stop
        $savedAssystApiBase = [string]$savedAssystSettings.ApiBase
        if (-not $env:ASSYST_API_BASE -and $savedAssystApiBase -match '^https?://') { $script:AssystApiBase = $savedAssystApiBase.TrimEnd('/') }
        if ($savedAssystSettings.PSObject.Properties['AllowUntrustedCertificate']) { $script:AssystAllowUntrustedCertificate = [bool]$savedAssystSettings.AllowUntrustedCertificate }
        if ($savedAssystSettings.PSObject.Properties['DefaultMovementReason'] -and [string]$savedAssystSettings.DefaultMovementReason -in @('ACQUISITION','CUSTOMER REQ','ILLEGAL MOVE','INITIAL LOAD','PROJECT MOVE','REPLACEMENT','RETIREMENT')) { $script:AssystDefaultMovementReason = [string]$savedAssystSettings.DefaultMovementReason }
    } catch { Write-Warning 'The saved assyst settings could not be read and will be ignored.' }
}
if (-not ('PolyntCertificateValidation' -as [type])) {
    Add-Type -TypeDefinition @'
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;

public static class PolyntCertificateValidation
{
    public static readonly RemoteCertificateValidationCallback AcceptAll =
        delegate(object sender, X509Certificate certificate, X509Chain chain, SslPolicyErrors errors)
        {
            return true;
        };
}
'@
}

function Resolve-PolyntDomain {
    param([AllowEmptyString()][string]$Domain)
    if ([string]::IsNullOrWhiteSpace($Domain)) { return '' }
    switch ($Domain.Trim().ToLowerInvariant()) {
        'polynt' { 'polynt.net' }
        { $_ -in @('resins','rsn') } { 'rsn.chem.corp.local' }
        'reichhold' { 'eu.reichhold.com' }
        default { $Domain }
    }
}

function Resolve-PolyntCredentialDomain {
    param([AllowEmptyString()][string]$Domain)
    $resolved = Resolve-PolyntDomain $Domain
    if ([string]::IsNullOrWhiteSpace($resolved)) { return 'polynt.net' }
    $resolved.Trim().ToLowerInvariant()
}

function Assert-CommandAvailable {
    param([Parameter(Mandatory)][string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        $requirement = if ($Name -like '*-AD*' -or $Name -in @('Unlock-ADAccount','Move-ADObject')) { 'ActiveDirectory' } elseif ($Name -like '*Laps*') { 'LAPS' } else { $Name }
        throw "MISSING_REQUIREMENT:$requirement|Required command '$Name' was not found."
    }
}

function Install-PolyntRequirement {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('ActiveDirectory','LAPS')][string]$Requirement)
    switch ($Requirement) {
        'ActiveDirectory' {
            $command = "Add-WindowsCapability -Online -Name 'Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0'"
            $process = Start-Process powershell.exe -Verb RunAs -ArgumentList @('-NoProfile','-Command',$command) -Wait -PassThru
            if ($process.ExitCode -ne 0) { throw "RSAT Active Directory installation failed with exit code $($process.ExitCode)." }
            Import-Module ActiveDirectory -Force -ErrorAction Stop
        }
        'LAPS' {
            $modulePath = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\Modules\LAPS'
            if (Test-Path -LiteralPath $modulePath) { Import-Module LAPS -Force -ErrorAction Stop; return }
            throw 'The Windows LAPS module is delivered by Windows Update. Install current Windows updates, then reopen the toolbox.'
        }
    }
}

function Get-PolyntCredentialEntries {
    $entries = @()
    if (Test-Path -LiteralPath $script:PolyntCredentialPath) {
        try {
            $saved = Import-Clixml -LiteralPath $script:PolyntCredentialPath -ErrorAction Stop
            if ($saved.PSObject.Properties['Credentials']) { $entries = @($saved.Credentials) }
        } catch { Write-Warning 'The saved domain credentials could not be read and will be ignored.' }
    }
    if (-not $entries.Count -and (Test-Path -LiteralPath $script:PolyntLegacyCredentialPath)) {
        try {
            $legacy = Import-Clixml -LiteralPath $script:PolyntLegacyCredentialPath -ErrorAction Stop
            if ($legacy -is [pscredential]) { $entries = @([pscustomobject]@{Domain='polynt.net';Credential=$legacy}) }
        } catch { Write-Warning 'The legacy saved credential could not be read and will be ignored.' }
    }
    @($entries | Where-Object { $_.Domain -and $_.Credential })
}

function Get-PolyntCredentialUserName {
    [CmdletBinding()]
    param([string]$Domain = 'polynt')
    $credentialDomain = Resolve-PolyntCredentialDomain $Domain
    $entry = @(Get-PolyntCredentialEntries | Where-Object { ([string]$_.Domain).ToLowerInvariant() -eq $credentialDomain } | Select-Object -First 1)
    if ($entry.Count) { return [string]$entry[0].Credential.UserName }
    if ($credentialDomain -eq 'polynt.net') { return [string]$script:PolyntAdminUser }
    ''
}

function Get-PolyntCredential {
    [CmdletBinding()]
    param([string]$Domain = 'polynt', [switch]$PromptIfMissing)
    $credentialDomain = Resolve-PolyntCredentialDomain $Domain
    $entry = @(Get-PolyntCredentialEntries | Where-Object { ([string]$_.Domain).ToLowerInvariant() -eq $credentialDomain } | Select-Object -First 1)
    if ($entry.Count) { return $entry[0].Credential }
    $password = if ($credentialDomain -eq 'polynt.net') { $env:POLYNT_ADMIN_PASSWORD } else { $null }
    if ($password) {
        if ([string]::IsNullOrWhiteSpace($script:PolyntAdminUser)) { throw 'POLYNT_ADMIN_USER must be set when POLYNT_ADMIN_PASSWORD is used.' }
        return [pscredential]::new($script:PolyntAdminUser, (ConvertTo-SecureString $password -AsPlainText -Force))
    }
    if ($PromptIfMissing) {
        $userName = Get-PolyntCredentialUserName -Domain $credentialDomain
        if ($userName) { return Get-Credential -UserName $userName -Message "Enter administrator credentials for $credentialDomain" }
        return Get-Credential -Message "Enter administrator credentials for $credentialDomain"
    }
    throw "No administrator credential is saved for $credentialDomain. Save it in Settings first."
}

function Set-PolyntCredential {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$UserName,
        [Parameter(Mandatory)][securestring]$Password,
        [string]$Domain = 'polynt'
    )
    $credentialDomain = Resolve-PolyntCredentialDomain $Domain
    $entries = @(Get-PolyntCredentialEntries | Where-Object { ([string]$_.Domain).ToLowerInvariant() -ne $credentialDomain })
    $entries += [pscustomobject]@{Domain=$credentialDomain;Credential=[pscredential]::new($UserName,$Password)}
    $folder = Split-Path -Parent $script:PolyntCredentialPath
    if (-not (Test-Path -LiteralPath $folder)) { [void](New-Item -ItemType Directory -Path $folder -Force) }
    [pscustomobject]@{Version=2;Credentials=$entries} | Export-Clixml -LiteralPath $script:PolyntCredentialPath -Force
    if ($credentialDomain -eq 'polynt.net') { $script:PolyntAdminUser = $UserName }
    [pscustomobject]@{Domain=$credentialDomain;UserName=$UserName;Status='Credential saved'}
}

function Set-AssystSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ApiBase,
        [securestring]$BasicValue,
        [bool]$AllowUntrustedCertificate = $true,
        [ValidateSet('ACQUISITION','CUSTOMER REQ','ILLEGAL MOVE','INITIAL LOAD','PROJECT MOVE','REPLACEMENT','RETIREMENT')]
        [string]$DefaultMovementReason = $script:AssystDefaultMovementReason
    )
    $normalizedApiBase = $ApiBase.Trim().TrimEnd('/')
    if ($normalizedApiBase -notmatch '^https?://') { throw 'The assyst API base URL must begin with http:// or https://.' }
    $script:AssystApiBase = $normalizedApiBase
    $script:AssystAllowUntrustedCertificate = $AllowUntrustedCertificate
    $script:AssystDefaultMovementReason = $DefaultMovementReason
    $script:AssystReferenceCache.Clear()
    $folder = Split-Path -Parent $script:AssystSettingsPath
    if (-not (Test-Path -LiteralPath $folder)) { [void](New-Item -ItemType Directory -Path $folder -Force) }
    $assystCredential = $null
    if ($BasicValue) {
        $assystCredential = [pscredential]::new('AssystBasic', $BasicValue)
    } elseif (Test-Path -LiteralPath $script:AssystSettingsPath) {
        try { $assystCredential = (Import-Clixml -LiteralPath $script:AssystSettingsPath -ErrorAction Stop).Credential } catch {}
    }
    if (-not $assystCredential -and -not $env:ASSYST_BASIC_AUTH) {
        throw 'Enter the assyst Basic value for the initial setup. It can be left blank on later changes.'
    }
    [pscustomobject]@{
        ApiBase=$script:AssystApiBase
        AllowUntrustedCertificate=$script:AssystAllowUntrustedCertificate
        DefaultMovementReason=$script:AssystDefaultMovementReason
        Credential=$assystCredential
    } | Export-Clixml -LiteralPath $script:AssystSettingsPath -Force
}

function Get-AssystBasicValue {
    if ($env:ASSYST_BASIC_AUTH) { return $env:ASSYST_BASIC_AUTH }
    if (-not (Test-Path -LiteralPath $script:AssystSettingsPath)) {
        throw 'No assyst Basic authentication value is configured. Save it in Settings first.'
    }
    try {
        $settings = Import-Clixml -LiteralPath $script:AssystSettingsPath -ErrorAction Stop
        if (-not $settings.Credential) { throw 'The saved file does not contain a credential.' }
        $value = $settings.Credential.GetNetworkCredential().Password
        if ([string]::IsNullOrWhiteSpace($value)) { throw 'The saved Basic authentication value is empty.' }
        if ($value -notmatch '^Basic\s+') { $value = "Basic $value" }
        $value
    } catch { throw "Unable to read the saved assyst authentication value. Save it again in Settings. $($_.Exception.Message)" }
}

function Invoke-AssystRestRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Get','Post','Put','Delete')][string]$Method,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$RelativePath,
        [object]$Body
    )
    $uri = "$($script:AssystApiBase.TrimEnd('/'))/$($RelativePath.TrimStart('/'))"
    $headers = @{Accept='application/json';Authorization=(Get-AssystBasicValue)}
    if ($Method -in @('Post','Put','Delete')) { $headers['X-CSRF-Header'] = 'true' }
    $requestParameters = @{Method=$Method;Uri=$uri;Headers=$headers;UseBasicParsing=$true;ErrorAction='Stop'}
    if ($PSBoundParameters.ContainsKey('Body')) {
        $requestParameters.Body = $Body | ConvertTo-Json -Depth 10 -Compress
        $requestParameters.ContentType = 'application/json'
    }
    $previousCertificateCallback = [Net.ServicePointManager]::ServerCertificateValidationCallback
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        if ($script:AssystAllowUntrustedCertificate) { [Net.ServicePointManager]::ServerCertificateValidationCallback = [PolyntCertificateValidation]::AcceptAll }
        Invoke-RestMethod @requestParameters
    } catch {
        $statusText = ''
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode) { $statusText = " (HTTP $([int]$_.Exception.Response.StatusCode))" }
        $responseBody = ''
        if ($_.Exception.Response) {
            try {
                $responseStream = $_.Exception.Response.GetResponseStream()
                if ($responseStream) {
                    $responseReader = New-Object IO.StreamReader($responseStream)
                    $responseBody = $responseReader.ReadToEnd()
                    $responseReader.Dispose()
                }
            } catch {}
        }
        $exceptionMessages = @()
        $currentException = $_.Exception
        while ($currentException) {
            if ($currentException.Message -and $currentException.Message -notin $exceptionMessages) { $exceptionMessages += $currentException.Message }
            $currentException = $currentException.InnerException
        }
        $failureMessage = "Assyst API $Method failed${statusText}: $($exceptionMessages -join ' -> ')`r`nRequest: $uri"
        if (-not [string]::IsNullOrWhiteSpace($responseBody)) { $failureMessage += "`r`n`r`nAssyst response:`r`n$responseBody" }
        throw $failureMessage
    } finally {
        [Net.ServicePointManager]::ServerCertificateValidationCallback = $previousCertificateCallback
    }
}

function ConvertFrom-AssystCollection {
    param([object]$Response)
    if ($null -eq $Response) {
        @()
    } elseif ($Response -is [array]) {
        @($Response)
    } elseif ($Response.PSObject.Properties['items']) {
        @($Response.items)
    } elseif ($Response.PSObject.Properties['value']) {
        @($Response.value)
    } else {
        @($Response)
    }
}

function Get-AssystReferenceById {
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Resource,
        [long]$Id
    )
    if ($Id -le 0) { return $null }
    $cacheKey = "$Resource/$Id"
    if (-not $script:AssystReferenceCache.ContainsKey($cacheKey)) {
        try { $script:AssystReferenceCache[$cacheKey] = Invoke-AssystRestRequest -Method Get -RelativePath "$cacheKey`?fields=*" }
        catch { $script:AssystReferenceCache[$cacheKey] = $null }
    }
    $script:AssystReferenceCache[$cacheKey]
}

function Get-AssystObjectValue {
    param([object]$Object,[Parameter(Mandatory)][string]$PropertyName)
    if ($null -ne $Object -and $Object.PSObject.Properties[$PropertyName]) { return $Object.$PropertyName }
    $null
}

function Add-AssystEffectiveMovementData {
    param([Parameter(Mandatory,ValueFromPipeline)][object]$Item)
    process {
        $movements = @(ConvertFrom-AssystCollection (Invoke-AssystRestRequest -Method Get -RelativePath "itemMovements?itemId=$($Item.id)"))
        $latestMovement = @($movements | Sort-Object id -Descending | Select-Object -First 1)
        if ($latestMovement.Count) {
            $movement = $latestMovement[0]
            $costCentre = Get-AssystReferenceById -Resource 'costCentres' -Id ([long]$movement.costCentreId)
            $department = Get-AssystReferenceById -Resource 'departments' -Id ([long]$movement.departmentId)
            $room = Get-AssystReferenceById -Resource 'rooms' -Id ([long]$movement.roomId)
            $status = Get-AssystReferenceById -Resource 'itemStatuses' -Id ([long]$movement.itemStatusId)
            $contactUser = Get-AssystReferenceById -Resource 'contactUsers' -Id ([long]$movement.contactUserId)
            $Item | Add-Member -NotePropertyName EffectiveCostCentre -NotePropertyValue $costCentre -Force
            $Item | Add-Member -NotePropertyName EffectiveDepartment -NotePropertyValue $department -Force
            $Item | Add-Member -NotePropertyName EffectiveRoom -NotePropertyValue $room -Force
            $Item | Add-Member -NotePropertyName EffectiveStatus -NotePropertyValue $status -Force
            $Item | Add-Member -NotePropertyName EffectiveContactUser -NotePropertyValue $contactUser -Force
        }
        $rentLeaseId = [long](Get-AssystObjectValue $Item 'rentLeaseId')
        if ($rentLeaseId -le 0) { $rentLeaseId = [long](Get-AssystObjectValue $Item 'rentalAndLeaseId') }
        if ($rentLeaseId -gt 0) {
            $Item | Add-Member -NotePropertyName EffectiveContract -NotePropertyValue (Get-AssystReferenceById -Resource 'rentalsAndLeases' -Id $rentLeaseId) -Force
        }
        $Item
    }
}

function ConvertTo-AssystItemSummary {
    [CmdletBinding()]
    param([Parameter(Mandatory,ValueFromPipeline)][object]$Item)
    process {
        $effectiveCostCentre = if ($Item.PSObject.Properties['EffectiveCostCentre'] -and $Item.EffectiveCostCentre) { $Item.EffectiveCostCentre } else { $null }
        $effectiveDepartment = if ($Item.PSObject.Properties['EffectiveDepartment'] -and $Item.EffectiveDepartment) { $Item.EffectiveDepartment } else { $null }
        $effectiveRoom = if ($Item.PSObject.Properties['EffectiveRoom'] -and $Item.EffectiveRoom) { $Item.EffectiveRoom } else { $null }
        $effectiveStatus = if ($Item.PSObject.Properties['EffectiveStatus'] -and $Item.EffectiveStatus) { $Item.EffectiveStatus } else { $null }
        $effectiveUser = if ($Item.PSObject.Properties['EffectiveContactUser'] -and $Item.EffectiveContactUser) { $Item.EffectiveContactUser } else { $null }
        $effectiveContract = if ($Item.PSObject.Properties['EffectiveContract'] -and $Item.EffectiveContract) { $Item.EffectiveContract } elseif ($Item.PSObject.Properties['rentLease'] -and $Item.rentLease) { $Item.rentLease } elseif ($Item.PSObject.Properties['rentalAndLease'] -and $Item.rentalAndLease) { $Item.rentalAndLease } else { $null }
        $effectiveStatusName = Get-AssystObjectValue $effectiveStatus 'name'
        $effectiveOwnerEmail = Get-AssystObjectValue $effectiveUser 'emailAddress'
        if (-not $effectiveOwnerEmail) { $effectiveOwnerEmail = Get-AssystObjectValue $effectiveUser 'shortCode' }
        $effectiveCostCentreName = Get-AssystObjectValue $effectiveCostCentre 'name'
        $effectiveDepartmentName = Get-AssystObjectValue $effectiveDepartment 'name'
        $contractName = Get-AssystObjectValue $effectiveContract 'name'
        if (-not $contractName) { $contractName = Get-AssystObjectValue $Item 'rentLeaseName' }
        if (-not $contractName) { $contractName = Get-AssystObjectValue $Item 'rentalAndLeaseName' }
        if (-not $contractName) { $contractName = Get-AssystObjectValue $Item 'contractName' }
        $effectiveBuildingName = Get-AssystObjectValue $effectiveRoom 'buildingName'
        $effectiveRoomName = Get-AssystObjectValue $effectiveRoom 'name'
        $effectiveLocation = if ($effectiveBuildingName) { $effectiveBuildingName } elseif ($effectiveRoomName) { $effectiveRoomName } else { $Item.buildingName }
        $summary = [pscustomobject]@{
            ShortCode=$Item.shortCode
            SerialNumber=$Item.serialNumber
            Product=$Item.productName
            Status=if ($effectiveStatusName) {$effectiveStatusName} else {$Item.statusName}
            OwnerEmail=if ($effectiveOwnerEmail) {$effectiveOwnerEmail} else {$Item.userSC}
            CostCentreName=if ($effectiveCostCentreName) {$effectiveCostCentreName} else {$Item.costCentreName}
            ContractName=$contractName
            Department=$effectiveDepartmentName
            Supplier=$Item.supplierName
            AcquiredMethod=$Item.acquiredMethodEnum
            AcquiredDate=$Item.acquiredDate
            WarrantyMonths=$Item.warrantyPeriod
            ContractExpiry=$Item.expiryDate
            Location=$effectiveLocation
            Discontinued=$Item.discontinued
            ItemId=$Item.id
        }
        $summary.PSObject.TypeNames.Insert(0, 'Polynt.AssystItemSummary')
        $summary
    }
}

function Get-AssystItemDirectMatch {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ShortCode)
    $normalizedShortCode = $ShortCode.Trim()
    $encodedShortCode = [Uri]::EscapeDataString($normalizedShortCode)
    $response = Invoke-AssystRestRequest -Method Get -RelativePath "items?shortCode=$encodedShortCode&includeDiscontinued=true"
    $exactItems = @(ConvertFrom-AssystCollection $response | Where-Object { -not $_.PSObject.Properties['shortCode'] -or ([string]$_.shortCode -ieq $normalizedShortCode) })
    if (-not $exactItems.Count) { throw "No exact assyst item match was found for '$normalizedShortCode'." }
    $expandedFields = [Uri]::EscapeDataString('*,rentLease[*]')
    foreach ($itemReference in $exactItems) {
        $itemId = [long](Get-AssystObjectValue $itemReference 'id')
        $item = if ($itemId -gt 0) {
            Invoke-AssystRestRequest -Method Get -RelativePath "items/$itemId`?fields=$expandedFields"
        } else {
            $itemReference
        }
        $item | Add-AssystEffectiveMovementData | ConvertTo-AssystItemSummary
    }
}

function Get-AssystContactUserByEmail {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$EmailAddress)
    $normalizedEmail = $EmailAddress.Trim()
    $encodedEmail = [Uri]::EscapeDataString($normalizedEmail)
    $response = Invoke-AssystRestRequest -Method Get -RelativePath "contactUsers?emailAddress=$encodedEmail"
    $users = @(ConvertFrom-AssystCollection $response)
    $exactUsers = @($users | Where-Object {
        ($_.PSObject.Properties['shortCode'] -and ([string]$_.shortCode -ieq $normalizedEmail)) -or
        ($_.PSObject.Properties['emailAddress'] -and ([string]$_.emailAddress -ieq $normalizedEmail))
    })
    if (-not $exactUsers.Count) { throw "No exact assyst contact user was found for '$normalizedEmail'." }
    if ($exactUsers.Count -gt 1) { throw "More than one assyst contact user matched '$normalizedEmail'." }
    $exactUsers[0]
}

function Get-AssystItemsByOwnerEmail {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$EmailAddress)
    $user = Get-AssystContactUserByEmail -EmailAddress $EmailAddress
    $fields = [Uri]::EscapeDataString('*,userItems[*]')
    $userWithItems = Invoke-AssystRestRequest -Method Get -RelativePath "contactUsers/$($user.id)?fields=$fields"
    $itemIds = @($userWithItems.userItems | ForEach-Object { [long]$_.itemId } | Where-Object { $_ -gt 0 } | Sort-Object -Unique)
    if (-not $itemIds.Count) { return @() }
    $items = foreach ($itemId in $itemIds) {
        Invoke-AssystRestRequest -Method Get -RelativePath "items/$itemId`?fields=*"
    }
    $items | Sort-Object shortCode | Add-AssystEffectiveMovementData | ConvertTo-AssystItemSummary
}

function Get-AssystItemStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Name)
    $normalizedName = $Name.Trim()
    $statuses = @(ConvertFrom-AssystCollection (Invoke-AssystRestRequest -Method Get -RelativePath 'itemStatuses'))
    $matches = @($statuses | Where-Object { ([string]$_.name -ieq $normalizedName) -or ([string]$_.shortCode -ieq $normalizedName) })
    if (-not $matches.Count) { throw "Assyst item status '$normalizedName' was not found." }
    if ($matches.Count -gt 1) { throw "More than one Assyst item status matched '$normalizedName'." }
    $matches[0]
}

function Get-AssystMovementReason {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Code)
    $normalizedCode = $Code.Trim()
    $cacheKey = $normalizedCode.ToUpperInvariant()
    if ($script:AssystMovementReasonCache.ContainsKey($cacheKey)) { return $script:AssystMovementReasonCache[$cacheKey] }
    $resources = @('itemMoveReasons','itemMovementReasons','moveReasons','movementReasons')
    foreach ($resource in $resources) {
        try {
            $reasons = @(ConvertFrom-AssystCollection (Invoke-AssystRestRequest -Method Get -RelativePath $resource))
            foreach ($reason in $reasons) {
                $reasonCode = [string](Get-AssystObjectValue $reason 'shortCode')
                $reasonName = [string](Get-AssystObjectValue $reason 'name')
                if ($reasonCode) { $script:AssystMovementReasonCache[$reasonCode.ToUpperInvariant()] = $reason }
                if ($reasonName) { $script:AssystMovementReasonCache[$reasonName.ToUpperInvariant()] = $reason }
            }
            $matches = @($reasons | Where-Object {
                ([string](Get-AssystObjectValue $_ 'shortCode') -ieq $normalizedCode) -or
                ([string](Get-AssystObjectValue $_ 'name') -ieq $normalizedCode)
            })
            if ($matches.Count -eq 1) { return $matches[0] }
            if ($matches.Count -gt 1) { throw "More than one Assyst movement reason matched '$normalizedCode'." }
        } catch {
            if ($_.Exception.Message -like 'More than one Assyst movement reason*') { throw }
        }
    }
    if ($normalizedCode -ieq 'CUSTOMER REQ' -or $normalizedCode -ieq 'Customer Request') {
        $fallback = [pscustomobject]@{id=1;name='Customer Request';shortCode='CUSTOMER REQ'}
        $script:AssystMovementReasonCache['CUSTOMER REQ'] = $fallback
        $script:AssystMovementReasonCache['CUSTOMER REQUEST'] = $fallback
        return $fallback
    }
    throw "Assyst movement reason '$normalizedCode' could not be resolved. None of the movement-reason API resources returned a matching record."
}

function Set-AssystItemOwner {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][long]$ItemId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$NewOwnerEmail,
        [ValidateSet('Deployed','In Stock')][string]$StatusName = 'Deployed',
        [ValidateSet('ACQUISITION','CUSTOMER REQ','ILLEGAL MOVE','INITIAL LOAD','PROJECT MOVE','REPLACEMENT','RETIREMENT')]
        [string]$MovementReason = $script:AssystDefaultMovementReason
    )
    $matchedUser = Get-AssystContactUserByEmail -EmailAddress $NewOwnerEmail
    $targetUser = Invoke-AssystRestRequest -Method Get -RelativePath "contactUsers/$($matchedUser.id)`?fields=*"
    $targetStatus = Get-AssystItemStatus -Name $StatusName
    $targetMovementReason = Get-AssystMovementReason -Code $MovementReason
    $itemFields = [Uri]::EscapeDataString('*,itemUsers[*]')
    $currentItem = Invoke-AssystRestRequest -Method Get -RelativePath "items/$ItemId`?fields=$itemFields"
    $currentAssignments = @($currentItem.itemUsers | Where-Object { -not $_.discontinued })
    $currentAssignment = @($currentAssignments | Where-Object { [int64]$_.userId -eq [int64]$currentItem.userId } | Sort-Object id | Select-Object -First 1)
    if (-not $currentAssignment.Count) { $currentAssignment = @($currentAssignments | Sort-Object id | Select-Object -First 1) }
    if ($PSCmdlet.ShouldProcess($currentItem.shortCode, "Assign to $($targetUser.shortCode) and set status to $($targetStatus.name)")) {
        $movement = [ordered]@{
            itemId=[long]$ItemId
            contactUserId=[long]$targetUser.id
            departmentId=[long]$targetUser.departmentId
            costCentreId=[long]$targetUser.costCentreId
            roomId=[long]$targetUser.roomId
            itemStatusId=[long]$targetStatus.id
            slaId=[long]$targetUser.slaId
            moveReasonId=[long]$targetMovementReason.id
            moveDate=[DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        }
        $createdMovement = Invoke-AssystRestRequest -Method Post -RelativePath 'itemMovements' -Body $movement
        if ($createdMovement -and $createdMovement.PSObject.Properties['id'] -and $createdMovement.id) {
            $verifiedMovement = Invoke-AssystRestRequest -Method Get -RelativePath "itemMovements/$($createdMovement.id)"
        } else {
            $verifiedMovement = @(ConvertFrom-AssystCollection (Invoke-AssystRestRequest -Method Get -RelativePath "itemMovements?itemId=$ItemId") | Sort-Object id -Descending | Select-Object -First 1)[0]
        }
        if (-not $verifiedMovement) { throw 'Assyst accepted the movement request, but the created movement could not be read back.' }
        $movementChecks = [ordered]@{
            itemId=[long]$ItemId
            contactUserId=[long]$targetUser.id
            departmentId=[long]$targetUser.departmentId
            costCentreId=[long]$targetUser.costCentreId
            roomId=[long]$targetUser.roomId
            itemStatusId=[long]$targetStatus.id
            slaId=[long]$targetUser.slaId
            moveReasonId=[long]$targetMovementReason.id
        }
        $incorrectMovementFields = @($movementChecks.Keys | Where-Object { [long]$verifiedMovement.$_ -ne [long]$movementChecks[$_] })
        if ($incorrectMovementFields.Count) {
            throw "Assyst created movement '$($verifiedMovement.id)', but these fields do not match the requested values: $($incorrectMovementFields -join ', '). The user assignment was not changed."
        }

        $association = [ordered]@{
            itemId=[long]$ItemId
            userId=[long]$targetUser.id
            defaultSlaId=[long]$targetUser.defaultSlaId
            slaId=[long]$targetUser.slaId
            numUsers=1
            userItemAssociationReasonId=5
        }
        if ($currentAssignment.Count) {
            if ($null -ne $currentAssignment[0].version) { $association.version = [long]$currentAssignment[0].version }
            if ($null -ne $currentAssignment[0].numUsers) { $association.numUsers = [long]$currentAssignment[0].numUsers }
            if ($currentAssignment[0].userItemAssociationReasonId) { $association.userItemAssociationReasonId = [long]$currentAssignment[0].userItemAssociationReasonId }
            try {
                [void](Invoke-AssystRestRequest -Method Post -RelativePath "userItems/$($currentAssignment[0].id)" -Body $association)
            } catch {
                throw "The Assyst movement was created, but the visible user assignment could not be updated. Do not create another movement before checking the item. $($_.Exception.Message)"
            }
        } else {
            try {
                [void](Invoke-AssystRestRequest -Method Post -RelativePath 'userItems' -Body $association)
            } catch {
                throw "The Assyst movement was created, but the visible user assignment could not be created. Do not create another movement before checking the item. $($_.Exception.Message)"
            }
        }

        $keptAssociationId = if ($currentAssignment.Count) { [long]$currentAssignment[0].id } else { 0 }
        $staleAssignments = @($currentAssignments | Where-Object { [long]$_.id -ne $keptAssociationId })
        foreach ($staleAssignment in $staleAssignments) {
            try {
                [void](Invoke-AssystRestRequest -Method Delete -RelativePath "userItems/$($staleAssignment.id)")
            } catch {
                throw "The Assyst movement and new owner assignment were saved, but previous user assignment '$($staleAssignment.id)' could not be removed. Check the item before retrying. $($_.Exception.Message)"
            }
        }

        $verifiedItem = Invoke-AssystRestRequest -Method Get -RelativePath "items/$ItemId`?fields=$itemFields"
        $verifiedAssignments = @($verifiedItem.itemUsers | Where-Object { -not $_.discontinued })
        $targetAssignments = @($verifiedAssignments | Where-Object { [int64]$_.userId -eq [int64]$targetUser.id })
        if ([int64]$verifiedItem.userId -ne [int64]$targetUser.id -or $verifiedAssignments.Count -ne 1 -or $targetAssignments.Count -ne 1) {
            throw "Assyst accepted the movement and user-assignment request, but item '$($verifiedItem.shortCode)' does not yet report exactly one active assignment for '$($targetUser.shortCode)'."
        }
        $verifiedItem | Add-AssystEffectiveMovementData | ConvertTo-AssystItemSummary
    }
}

function Set-AssystItemInStock {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ShortCode,
        [Parameter(Mandatory)][ValidateSet('Drocourt','Bordeaux')][string]$Site,
        [ValidateSet('ACQUISITION','CUSTOMER REQ','ILLEGAL MOVE','INITIAL LOAD','PROJECT MOVE','REPLACEMENT','RETIREMENT')]
        [string]$MovementReason = $script:AssystDefaultMovementReason
    )
    $stockOwner = switch ($Site) {
        'Drocourt' { 'GENERIC-FR-DRT-IT@polynt.net' }
        'Bordeaux' { 'GENERIC-FR-BOR-IT@polynt.net' }
    }
    $items = @(Get-AssystItemDirectMatch -ShortCode $ShortCode)
    if ($items.Count -ne 1) { throw "Expected one exact Assyst item for '$ShortCode', but found $($items.Count)." }
    if ($PSCmdlet.ShouldProcess($items[0].ShortCode, "Put in $Site stock")) {
        Set-AssystItemOwner -ItemId ([long]$items[0].ItemId) -NewOwnerEmail $stockOwner -StatusName 'In Stock' -MovementReason $MovementReason -Confirm:$false
    }
}

function Get-AssystItemsByContractNumber {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ContractNumber)
    $normalizedContract = $ContractNumber.Trim()
    $encodedContract = [Uri]::EscapeDataString($normalizedContract)
    $contracts = @(ConvertFrom-AssystCollection (Invoke-AssystRestRequest -Method Get -RelativePath "rentalsAndLeases?shortCode=$encodedContract"))
    $contract = @($contracts | Where-Object { ([string](Get-AssystObjectValue $_ 'shortCode') -ieq $normalizedContract) -or ([string](Get-AssystObjectValue $_ 'name') -ieq $normalizedContract) })
    if (-not $contract.Count) { throw "Assyst contract '$normalizedContract' was not found." }
    if ($contract.Count -gt 1) { throw "More than one Assyst contract matched '$normalizedContract'." }
    try {
        $items = @(ConvertFrom-AssystCollection (Invoke-AssystRestRequest -Method Get -RelativePath "items?rentLeaseId=$($contract[0].id)&includeDiscontinued=true"))
    } catch {
        try {
            $items = @(ConvertFrom-AssystCollection (Invoke-AssystRestRequest -Method Get -RelativePath "items?rentLeaseSC=$encodedContract&includeDiscontinued=true"))
        } catch {
            $contractFields = [Uri]::EscapeDataString('*,items[*]')
            $expandedContract = Invoke-AssystRestRequest -Method Get -RelativePath "rentalsAndLeases/$($contract[0].id)`?fields=$contractFields"
            if (-not $expandedContract.PSObject.Properties['items']) { throw "Assyst could not return items for contract '$normalizedContract'. $($_.Exception.Message)" }
            $items = @($expandedContract.items)
        }
    }
    foreach ($item in $items) {
        $summary = $item | Add-AssystEffectiveMovementData | ConvertTo-AssystItemSummary
        [pscustomobject]@{
            ContractNumber=$contract[0].shortCode
            Owner=$summary.OwnerEmail
            Serial=$summary.SerialNumber
            Model=$summary.Product
        }
    }
}

function Export-AssystContractItems {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$ContractNumber,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path
    )
    $rows = @($ContractNumber | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Sort-Object -Unique | ForEach-Object { Get-AssystItemsByContractNumber -ContractNumber $_ })
    if (-not $rows.Count) { throw 'No Assyst items were found for the supplied contract numbers.' }
    $rows | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8 -Delimiter ';'
    $rows
}

function New-Label {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Serial)
    if ([string]::IsNullOrWhiteSpace($script:PolyntLabelScript)) { throw 'No label script is configured. Set POLYNT_LABEL_SCRIPT to the shared label-script path.' }
    if (-not (Test-Path -LiteralPath $script:PolyntLabelScript)) { throw "Label script not found: $script:PolyntLabelScript. Set POLYNT_LABEL_SCRIPT to its location." }
    & $script:PolyntLabelScript -Serial $Serial
}

function Test-PolyntLocalComputer {
    param([Parameter(Mandatory)][string]$Computer)
    $localName = [string]$env:COMPUTERNAME
    $Computer -in @('.','localhost','127.0.0.1','::1') -or ($localName -and ($Computer.Split('.')[0] -ieq $localName))
}

function Get-PolyntComputerWmiObject {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Computer, [Parameter(Mandatory)][string]$Class, [string]$Namespace='root\cimv2', [string]$Domain='polynt')
    $parameters = @{Class=$Class;Namespace=$Namespace;ComputerName=$Computer;ErrorAction='Stop'}
    if (-not (Test-PolyntLocalComputer -Computer $Computer)) {
        $parameters.Credential = Get-PolyntCredential -Domain $Domain -PromptIfMissing
        $parameters.Impersonation = 'Impersonate'
    }
    Get-WmiObject @parameters
}

function Get-SN {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Name, [string]$Domain='polynt')
    try {
        $bios = Get-PolyntComputerWmiObject -Class Win32_BIOS -Computer $Name -Domain $Domain
        $system = Get-PolyntComputerWmiObject -Class Win32_ComputerSystem -Computer $Name -Domain $Domain
        [pscustomobject]@{ ComputerName=$Name; DeviceType='Computer'; SerialNumber=$bios.SerialNumber; Model=$system.Model }
        try {
            Get-PolyntComputerWmiObject -Class HP_DockAccessory -Namespace 'root/HP/InstrumentedServices/v1' -Computer $Name -Domain $Domain | ForEach-Object {
                [pscustomobject]@{ ComputerName=$Name; DeviceType='HP Dock'; SerialNumber=$_.SerialNumber; Model=if ($_.ProductName) {$_.ProductName} else {'HP Dock'} }
            }
        } catch { Write-Verbose "No HP dock information was available on $Name." }
    } catch { throw "Unable to inventory '$Name': $($_.Exception.Message)" }
}

function Get-PC {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Name, [string]$Domain)
    Assert-CommandAvailable Get-ADComputer
    $server = Resolve-PolyntDomain $Domain
    $properties = @('Name','Description','DistinguishedName','DNSHostName','Enabled')
    if ($server -eq 'rsn.chem.corp.local') { $properties += @('itserialnumber','itcontractnumber','itcontractdate') }
    try {
        $params = @{ Identity=$Name; Properties=$properties; ErrorAction='Stop' }
        if ($server) { $params.Server = $server }
        Get-ADComputer @params | Select-Object $properties
    } catch { throw "Unable to find computer '$Name' in $(if ($server) {$server} else {'the current AD domain'}). $($_.Exception.Message)" }
}

function Get-PC-Desc {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Description, [string]$Domain)
    Assert-CommandAvailable Get-ADComputer
    $server = Resolve-PolyntDomain $Domain
    $properties = @('Name','Description','DistinguishedName','DNSHostName','Enabled')
    if ($server -eq 'rsn.chem.corp.local') { $properties += @('itserialnumber','itcontractnumber','itcontractdate') }
    $escaped = $Description.Replace("'", "''")
    try {
        $params = @{ Filter="Description -like '*$escaped*'"; Properties=$properties; ErrorAction='Stop' }
        if ($server) { $params.Server = $server }
        Get-ADComputer @params | Select-Object $properties | Sort-Object Name
    } catch { throw "Unable to search descriptions in $(if ($server) {$server} else {'the current AD domain'}). $($_.Exception.Message)" }
}

function Start-PolyntProcessAsAdminUser {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$Domain = 'polynt',
        [switch]$Hidden
    )
    $credential = Get-PolyntCredential -Domain $Domain -PromptIfMissing
    $system32 = Join-Path $env:SystemRoot 'System32'
    $parameters = @{
        FilePath=$FilePath
        ArgumentList=$ArgumentList
        Credential=$credential
        LoadUserProfile=$true
        WorkingDirectory=$system32
    }
    if ($Hidden) { $parameters.WindowStyle = 'Hidden' }
    try {
        Start-Process @parameters
    } catch {
        throw "Unable to start $FilePath with the saved administrator credential. Verify the credential and that the Secondary Logon service is available. $($_.Exception.Message)"
    }
}

function Invoke-PolyntPsExec {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$Domain = 'polynt'
    )
    if (-not (Test-Path -LiteralPath $script:PsExecPath)) {
        throw "Bundled PsExec was not found at '$script:PsExecPath'."
    }
    $credential = Get-PolyntCredential -Domain $Domain -PromptIfMissing
    $arguments = @('-accepteula','-nobanner','-d','-i','-u',$credential.UserName,'-p',$credential.GetNetworkCredential().Password,$FilePath)
    if ($ArgumentList.Count) { $arguments += $ArgumentList }
    $process = Start-Process -FilePath $script:PsExecPath -ArgumentList $arguments -WindowStyle Hidden -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        throw "PsExec could not start $FilePath (exit code $($process.ExitCode)). Verify the saved administrator credential and local PsExec/UAC permissions."
    }
}

function Start-PolyntMmcAsAdminUser {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SnapIn, [string]$Domain='polynt')

    $credential = Get-PolyntCredential -Domain $Domain -PromptIfMissing
    $system32 = Join-Path $env:SystemRoot 'System32'
    $mmcPath = Join-Path $system32 'mmc.exe'
    $snapInPath = Join-Path $system32 $SnapIn
    if (-not (Test-Path -LiteralPath $snapInPath)) {
        throw "MMC console '$SnapIn' was not found. Install the corresponding Windows/RSAT feature first."
    }

    # MMC consoles need the administrator's domain identity for these tasks, but
    # not a locally elevated token. RunAsInvoker prevents MMC auto-elevation and
    # therefore avoids a UAC consent prompt; the process still uses the saved
    # administrator credential for AD and remote network access.
    $command = "`$env:__COMPAT_LAYER = 'RunAsInvoker'; Start-Process -FilePath '$mmcPath' -ArgumentList @('$snapInPath') -WorkingDirectory '$system32'"
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    try {
        Start-Process -FilePath (Join-Path $system32 'WindowsPowerShell\v1.0\powershell.exe') `
            -Credential $credential `
            -LoadUserProfile `
            -WorkingDirectory $system32 `
            -WindowStyle Hidden `
            -ArgumentList @('-NoProfile','-NonInteractive','-WindowStyle','Hidden','-EncodedCommand',$encodedCommand)
    } catch {
        throw "Unable to start $SnapIn with the saved administrator credential. Verify the credential and that the Secondary Logon service is available. $($_.Exception.Message)"
    }
}

function Get-PolyntAdmin {
    param([string]$Domain='polynt')
    $powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Start-PolyntProcessAsAdminUser -FilePath $powershellPath -ArgumentList @('-NoProfile','-NoExit') -Domain $Domain
}
function Start-PolyntRemoteCDrive {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Computer, [string]$Domain='polynt')
    $credential = Get-PolyntCredential -Domain $Domain -PromptIfMissing
    $system32 = Join-Path $env:SystemRoot 'System32'
    $cmdKeyPath = Join-Path $system32 'cmdkey.exe'
    $netPath = Join-Path $system32 'net.exe'
    $explorerPath = Join-Path $env:SystemRoot 'explorer.exe'
    $sharePath = "\\$Computer\c$"
    $password = $credential.GetNetworkCredential().Password
    & $cmdKeyPath "/add:$Computer" "/user:$($credential.UserName)" "/pass:$password" 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Windows could not prepare the administrator credential for '$Computer' (cmdkey exit code $LASTEXITCODE)." }
    if (-not (Test-Path -LiteralPath $sharePath -ErrorAction SilentlyContinue)) {
        $netOutput = @(& $netPath use $sharePath $password "/user:$($credential.UserName)" '/persistent:no' 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to authenticate to '$sharePath' with the saved administrator credential. $($netOutput -join ' ')"
        }
    }
    if (-not (Test-Path -LiteralPath $sharePath -ErrorAction SilentlyContinue)) { throw "The administrator credential was accepted, but '$sharePath' is still unavailable." }
    Start-Process -FilePath $explorerPath -ArgumentList $sharePath -ErrorAction Stop
    [pscustomobject]@{ComputerName=$Computer;Path=$sharePath;UserName=$credential.UserName;Status='Remote C drive opened'}
}
function Start-PolyntRemoteDesktop {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Computer, [string]$Domain='polynt')
    $credential = Get-PolyntCredential -Domain $Domain -PromptIfMissing
    $cmdKeyPath = Join-Path $env:SystemRoot 'System32\cmdkey.exe'
    $mstscPath = Join-Path $env:SystemRoot 'System32\mstsc.exe'
    if (-not (Test-Path -LiteralPath $cmdKeyPath)) { throw "Windows Credential Manager command was not found at '$cmdKeyPath'." }
    if (-not (Test-Path -LiteralPath $mstscPath)) { throw "Remote Desktop was not found at '$mstscPath'." }
    & $cmdKeyPath "/generic:TERMSRV/$Computer" "/user:$($credential.UserName)" "/pass:$($credential.GetNetworkCredential().Password)" 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Windows could not save the administrator credential for Remote Desktop to '$Computer' (cmdkey exit code $LASTEXITCODE)." }
    try {
        Start-Process -FilePath $mstscPath -ArgumentList "/v:$Computer" -ErrorAction Stop
    } catch {
        throw "The administrator credential was prepared, but Remote Desktop could not be started for '$Computer'. $($_.Exception.Message)"
    }
    [pscustomobject]@{ComputerName=$Computer;UserName=$credential.UserName;Status='Remote Desktop started with the saved administrator credential'}
}
function Start-Dsa { param([string]$Domain='polynt') Start-PolyntMmcAsAdminUser -SnapIn 'dsa.msc' -Domain $Domain }
function Start-Compmgmt { param([string]$Domain='polynt') Start-PolyntMmcAsAdminUser -SnapIn 'compmgmt.msc' -Domain $Domain }
function Start-Msra {
    param([string]$Computer, [string]$Domain='polynt')
    $msraArguments = @('/offerra')
    if ($Computer) { $msraArguments += $Computer }
    $quotedArguments = @($msraArguments | ForEach-Object { "'$(($_ -replace "'", "''"))'" }) -join ','
    $command = "Start-Process -FilePath 'msra.exe' -ArgumentList @($quotedArguments)"
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    Invoke-PolyntPsExec -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-NonInteractive','-WindowStyle','Hidden','-EncodedCommand',$encodedCommand) -Domain $Domain
    "Remote Assistance launch requested for $(if ($Computer) {$Computer} else {'computer selection'})."
}

function Get-PolyntLapsPwd {
    [CmdletBinding()] param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Computer, [string]$Domain)
    Assert-CommandAvailable Get-LapsADPassword
    $params = @{Identity=$Computer;Credential=(Get-PolyntCredential -Domain $Domain -PromptIfMissing);AsPlainText=$true;ErrorAction='Stop'}
    $resolvedDomain = Resolve-PolyntDomain $Domain
    if ($resolvedDomain) { $params.Domain = $resolvedDomain }
    Get-LapsADPassword @params |
        Select-Object ComputerName,DistinguishedName,Password,ExpirationTimeStamp
}

function Set-PC-Desc {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Computer, [Parameter(Mandatory)][AllowEmptyString()][string]$Description, [string]$Domain)
    Assert-CommandAvailable Set-ADComputer
    $server = Resolve-PolyntDomain $Domain
    $credential = Get-PolyntCredential -Domain $Domain -PromptIfMissing
    if ($PSCmdlet.ShouldProcess($Computer, "Set AD description to '$Description'")) {
        $params = @{ Identity=$Computer; Description=$Description; Credential=$credential; ErrorAction='Stop' }
        if ($server) { $params.Server = $server }
        Set-ADComputer @params
        Get-PC -Name $Computer -Domain $Domain
    }
}

function Get-BitLockerRecoveryKey {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Computer, [string]$Domain)
    Assert-CommandAvailable Get-ADComputer
    Assert-CommandAvailable Get-ADObject
    $server = Resolve-PolyntDomain $Domain
    $credential = Get-PolyntCredential -Domain $Domain -PromptIfMissing
    $computerParams = @{ Identity=$Computer; Properties='DistinguishedName'; Credential=$credential; ErrorAction='Stop' }
    if ($server) { $computerParams.Server = $server }
    $adComputer = Get-ADComputer @computerParams
    $keyParams = @{
        SearchBase=$adComputer.DistinguishedName
        SearchScope='OneLevel'
        LDAPFilter='(objectClass=msFVE-RecoveryInformation)'
        Properties=@('msFVE-RecoveryPassword','msFVE-RecoveryGuid','whenCreated')
        Credential=$credential
        ErrorAction='Stop'
    }
    if ($server) { $keyParams.Server = $server }
    $keys = @(Get-ADObject @keyParams | Sort-Object whenCreated -Descending | ForEach-Object {
        [pscustomobject]@{
            ComputerName=$Computer
            RecoveryPassword=$_.'msFVE-RecoveryPassword'
            RecoveryGuid=$_.'msFVE-RecoveryGuid'
            Created=$_.whenCreated
        }
    })
    if (-not $keys.Count) { throw "No BitLocker recovery information was found in AD for '$Computer'." }
    $keys
}

function Enable-PC {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Computer,
        [ValidateSet('Drocourt','Bordeaux')][string]$Site = 'Drocourt',
        [string]$Domain='polynt'
    )
    Assert-CommandAvailable Get-ADComputer
    Assert-CommandAvailable Set-ADComputer
    Assert-CommandAvailable Move-ADObject
    $server = Resolve-PolyntDomain $Domain
    if ($server -ne 'polynt.net') { throw 'Enable / move is currently available only for the Polynt domain.' }
    $credential = Get-PolyntCredential -Domain $server -PromptIfMissing
    try {
        $adComputer = Get-ADComputer -Identity $Computer -Server $server -Credential $credential -Properties Description,DistinguishedName,Enabled -ErrorAction Stop
    } catch { throw "Computer '$Computer' was not found in Polynt AD. $($_.Exception.Message)" }
    $newDescription = $adComputer.Description -replace '; Account disabled on .*$', ''
    if ([string]::IsNullOrWhiteSpace($newDescription)) { $newDescription = "$Site -" }
    $targetOU = "OU=Computers,OU=$Site,DC=polynt,DC=net"
    if ($PSCmdlet.ShouldProcess($Computer, "Enable, update description, and move to $targetOU")) {
        Set-ADComputer -Identity $adComputer.DistinguishedName -Server $server -Credential $credential -Description $newDescription -Enabled $true -ErrorAction Stop
        Move-ADObject -Identity $adComputer.DistinguishedName -TargetPath $targetOU -Server $server -Credential $credential -ErrorAction Stop
        Get-PC -Name $Computer -Domain 'polynt'
    }
}

function Find-PolyntADUser {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Identity, [string]$Domain)
    Assert-CommandAvailable Get-ADUser
    $server = Resolve-PolyntDomain $Domain
    $escaped = $Identity.Replace("'", "''")
    $params = @{
        Filter="SamAccountName -like '*$escaped*' -or Name -like '*$escaped*' -or UserPrincipalName -like '*$escaped*'"
        Properties=@('DisplayName','UserPrincipalName','LockedOut','Enabled','PasswordExpired','PasswordLastSet')
        ErrorAction='Stop'
    }
    if ($server) { $params.Server=$server }
    Get-ADUser @params | Select-Object SamAccountName,DisplayName,UserPrincipalName,Enabled,LockedOut,PasswordExpired,PasswordLastSet,DistinguishedName
}

function Get-PolyntADUserGroups {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Identity, [string]$Domain)
    Assert-CommandAvailable Get-ADPrincipalGroupMembership
    $server = Resolve-PolyntDomain $Domain
    $params = @{Identity=$Identity;ErrorAction='Stop'}
    if ($server) { $params.Server=$server }
    Get-ADPrincipalGroupMembership @params |
        Sort-Object Name |
        Select-Object Name,SamAccountName,GroupCategory,GroupScope,DistinguishedName
}

function Copy-PolyntADUserGroups {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SourceUser,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$TargetUser,
        [string]$Domain
    )
    Assert-CommandAvailable Get-ADUser
    Assert-CommandAvailable Add-ADGroupMember
    $server = Resolve-PolyntDomain $Domain
    $credential = Get-PolyntCredential -Domain $Domain -PromptIfMissing
    $sourceParams = @{Identity=$SourceUser;Properties='MemberOf';Credential=$credential;ErrorAction='Stop'}
    $targetParams = @{Identity=$TargetUser;Properties='MemberOf';Credential=$credential;ErrorAction='Stop'}
    if ($server) { $sourceParams.Server=$server;$targetParams.Server=$server }
    $source = Get-ADUser @sourceParams
    $target = Get-ADUser @targetParams
    $targetGroups = @($target.MemberOf)
    $missingGroups = @($source.MemberOf | Where-Object { $_ -notin $targetGroups } | Sort-Object)
    if (-not $missingGroups.Count) {
        return [pscustomobject]@{Group='';Status='No changes needed';TargetUser=$target.SamAccountName}
    }
    foreach ($groupDn in $missingGroups) {
        if ($PSCmdlet.ShouldProcess($target.SamAccountName,"Add membership in $groupDn")) {
            try {
                $params = @{Identity=$groupDn;Members=$target.DistinguishedName;Credential=$credential;ErrorAction='Stop'}
                if ($server) { $params.Server=$server }
                Add-ADGroupMember @params
                [pscustomobject]@{Group=$groupDn;Status='Added';TargetUser=$target.SamAccountName}
            } catch {
                [pscustomobject]@{Group=$groupDn;Status="Failed: $($_.Exception.Message)";TargetUser=$target.SamAccountName}
            }
        }
    }
}

function Add-PolyntADUserGroup {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$GroupIdentity,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$TargetUser,
        [string]$Domain
    )
    Assert-CommandAvailable Get-ADUser
    Assert-CommandAvailable Add-ADGroupMember
    $server = Resolve-PolyntDomain $Domain
    $credential = Get-PolyntCredential -Domain $Domain -PromptIfMissing
    $userParams = @{Identity=$TargetUser;Properties='MemberOf';Credential=$credential;ErrorAction='Stop'}
    if ($server) { $userParams.Server=$server }
    $user = Get-ADUser @userParams
    if ($GroupIdentity -in @($user.MemberOf)) { return [pscustomobject]@{Group=$GroupIdentity;Status='Already a member';TargetUser=$user.SamAccountName} }
    if ($PSCmdlet.ShouldProcess($user.SamAccountName,"Add membership in $GroupIdentity")) {
        $addParams = @{Identity=$GroupIdentity;Members=$user.DistinguishedName;Credential=$credential;ErrorAction='Stop'}
        if ($server) { $addParams.Server=$server }
        Add-ADGroupMember @addParams
        [pscustomobject]@{Group=$GroupIdentity;Status='Added';TargetUser=$user.SamAccountName}
    }
}

function Unlock-PolyntADUser {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Identity, [string]$Domain)
    Assert-CommandAvailable Unlock-ADAccount
    $server = Resolve-PolyntDomain $Domain
    $credential = Get-PolyntCredential -Domain $Domain -PromptIfMissing
    if ($PSCmdlet.ShouldProcess($Identity,'Unlock AD account')) {
        $params=@{Identity=$Identity;Credential=$credential;ErrorAction='Stop'};if($server){$params.Server=$server};Unlock-ADAccount @params
        Find-PolyntADUser -Identity $Identity -Domain $Domain
    }
}

function Reset-PolyntADUserPassword {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Identity,
        [Parameter(Mandatory)][securestring]$NewPassword,
        [bool]$RequireChangeAtLogin=$true,
        [string]$Domain
    )
    Assert-CommandAvailable Set-ADAccountPassword
    Assert-CommandAvailable Set-ADUser
    $server = Resolve-PolyntDomain $Domain
    $credential = Get-PolyntCredential -Domain $Domain -PromptIfMissing
    if ($PSCmdlet.ShouldProcess($Identity,'Reset AD password')) {
        $passwordParams=@{Identity=$Identity;Reset=$true;NewPassword=$NewPassword;Credential=$credential;ErrorAction='Stop'}
        if($server){$passwordParams.Server=$server}
        Set-ADAccountPassword @passwordParams
        $userParams=@{Identity=$Identity;ChangePasswordAtLogon=$RequireChangeAtLogin;Credential=$credential;ErrorAction='Stop'}
        if($server){$userParams.Server=$server}
        Set-ADUser @userParams
        Find-PolyntADUser -Identity $Identity -Domain $Domain
    }
}

function Get-PolyntTerminalSessions {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Computer, [string]$Domain='polynt')
    $credential = Get-PolyntCredential -Domain $Domain -PromptIfMissing
    $quserPath = Join-Path $env:SystemRoot 'System32\quser.exe'
    if (-not (Test-Path -LiteralPath $quserPath)) { throw "The Windows session-query tool was not found at '$quserPath'." }
    $temporaryFolder = if ($env:TEMP) { $env:TEMP } else { [IO.Path]::GetTempPath() }
    $token = [guid]::NewGuid().ToString('N')
    $outputPath = Join-Path $temporaryFolder "polynt-quser-$token.out"
    $errorPath = Join-Path $temporaryFolder "polynt-quser-$token.err"
    try {
        $process = Start-Process -FilePath $quserPath -ArgumentList "/server:$Computer" -Credential $credential -LoadUserProfile -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $outputPath -RedirectStandardError $errorPath -ErrorAction Stop
        $outputLines = if (Test-Path -LiteralPath $outputPath) { @(Get-Content -LiteralPath $outputPath -ErrorAction SilentlyContinue) } else { @() }
        $errorLines = if (Test-Path -LiteralPath $errorPath) { @(Get-Content -LiteralPath $errorPath -ErrorAction SilentlyContinue) } else { @() }
        if ($process.ExitCode -ne 0) {
            $message = (@($errorLines) + @($outputLines) | Where-Object { $_ }) -join ' '
            if ($message -match '(?i)no user|aucun utilisateur|keine benutzer|nessun utente|ning[uú]n usuario') { return @() }
            throw "Remote session query failed with exit code $($process.ExitCode). $message"
        }
        $dataLines = @($outputLines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Skip 1)
        foreach ($line in $dataLines) {
            $details = ([string]$line).Trim().TrimStart('>').Trim()
            if (-not $details) { continue }
            $userName = @($details -split '\s+')[0]
            [pscustomobject]@{ComputerName=$Computer;UserName=$userName;SessionType='Remote or disconnected session';State='Session found';SessionDetails=$details}
        }
    } finally {
        Remove-Item -LiteralPath $outputPath,$errorPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-RemoteSession {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Computer, [string]$Domain='polynt')
    try {
        $system = Get-PolyntComputerWmiObject -Class Win32_ComputerSystem -Computer $Computer -Domain $Domain
        if ($system.UserName) {
            [pscustomobject]@{ComputerName=$Computer;UserName=$system.UserName;SessionType='Interactive console';State='Active'}
            return
        }
        $terminalSessions = @(Get-PolyntTerminalSessions -Computer $Computer -Domain $Domain)
        if ($terminalSessions.Count) { $terminalSessions; return }
        [pscustomobject]@{ComputerName=$Computer;UserName=$null;SessionType='Interactive and remote sessions';State='No user session found'}
    } catch { throw "Unable to query local or remote user sessions on '$Computer'. $($_.Exception.Message)" }
}

function Get-RemoteSoftware {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Computer, [string]$Name='*', [string]$Domain='polynt')
    $hklm = 2147483650
    $paths = @('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall','SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')
    try {
        if (Test-PolyntLocalComputer -Computer $Computer) {
            $registry = [wmiclass]"\\$Computer\root\default:StdRegProv"
        } else {
            $credential = Get-PolyntCredential -Domain $Domain -PromptIfMissing
            $registry = Get-WmiObject -List -Class StdRegProv -Namespace 'root\default' -ComputerName $Computer -Credential $credential -Impersonation Impersonate -ErrorAction Stop
        }
        $results = foreach ($path in $paths) {
            $keysResult = $registry.EnumKey($hklm,$path)
            if ($keysResult.ReturnValue -eq 2) { continue }
            if ($keysResult.ReturnValue -ne 0) { throw "Registry enumeration failed for '$path' (error $($keysResult.ReturnValue))." }
            foreach ($key in @($keysResult.sNames)) {
                if (-not $key) { continue }
                $subKey = "$path\$key"
                $nameResult = $registry.GetStringValue($hklm,$subKey,'DisplayName')
                if ($nameResult.ReturnValue -ne 0) { continue }
                $displayName = $nameResult.sValue
                if ($displayName -and $displayName -like $Name) {
                    $version = $registry.GetStringValue($hklm,$subKey,'DisplayVersion')
                    $publisher = $registry.GetStringValue($hklm,$subKey,'Publisher')
                    $installDate = $registry.GetStringValue($hklm,$subKey,'InstallDate')
                    [pscustomobject]@{
                        ComputerName=$Computer
                        Name=$displayName
                        Version=$version.sValue
                        Publisher=$publisher.sValue
                        InstallDate=$installDate.sValue
                    }
                }
            }
        }
        return ($results | Sort-Object Name,Version -Unique)
    } catch {
        throw "Unable to inventory software on '$Computer' through WMI/DCOM. $($_.Exception.Message)"
    }
}

# Compatibility with commands from the original profile script.
function Set-Password {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$pw,
        [Parameter(Mandatory)][string]$UserName,
        [string]$Domain='polynt'
    )
    Set-PolyntCredential -UserName $UserName -Password (ConvertTo-SecureString $pw -AsPlainText -Force) -Domain $Domain
}
