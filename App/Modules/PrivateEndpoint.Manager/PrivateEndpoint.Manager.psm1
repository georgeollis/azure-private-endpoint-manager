#
# PrivateEndpoint.Manager Module
# Provides functions for managing Azure Private Endpoints and DNS zone configurations
#

# Module constants
$script:DefaultRetries = 10
$script:DefaultInitialWait = 2
$script:DefaultMaxWait = 15

<#
.SYNOPSIS
    Invokes a command with exponential backoff retry logic.

.PARAMETER ScriptBlock
    The script block to execute.

.PARAMETER MaxRetries
    Maximum number of retry attempts.

.PARAMETER InitialWaitSeconds
    Initial wait time between retries in seconds.

.PARAMETER MaxWaitSeconds
    Maximum wait time between retries in seconds.

.PARAMETER RetryableErrorPattern
    Regex pattern to match retryable error messages.
#>
function Invoke-RetryableOperation {
    param(
        [scriptblock] $ScriptBlock,
        [int] $MaxRetries = $script:DefaultRetries,
        [int] $InitialWaitSeconds = $script:DefaultInitialWait,
        [int] $MaxWaitSeconds = $script:DefaultMaxWait,
        [string] $RetryableErrorPattern = 'RetryableError|ReferencedResourceNotProvisioned'
    )
    
    $retryCount = 0
    $waitTime = $InitialWaitSeconds
    $success = $false
    
    while ($retryCount -lt $MaxRetries -and -not $success) {
        try {
            & $ScriptBlock
            $success = $true
        } catch {
            if ($retryCount -lt ($MaxRetries - 1) -and ($_.Exception.Message -match $RetryableErrorPattern)) {
                Write-Host "Retryable error, waiting ${waitTime}s before retry ($($retryCount + 1)/$MaxRetries)..."
                Start-Sleep -Seconds $waitTime
                $waitTime = [Math]::Min($waitTime * 2, $MaxWaitSeconds)
                $retryCount++
            } else {
                throw
            }
        }
    }
    
    if (-not $success) {
        Write-Warning "Max retries reached, operation may have failed"
    }
}

<#
.SYNOPSIS
    Parses Azure resource ID to extract subscription ID and resource group.

.PARAMETER ResourceId
    The full Azure resource ID.

.OUTPUTS
    PSObject with properties: SubscriptionId, ResourceGroup, ResourceName
#>
function Parse-AzureResourceId {
    param([string] $ResourceId)
    
    $parts = $ResourceId -split '/'
    
    [PSCustomObject]@{
        SubscriptionId = $parts[2]
        ResourceGroup  = $parts[4]
        ResourceName   = $parts[-1]
    }
}

<#
.SYNOPSIS
    Extracts group IDs from private link service connections.

.PARAMETER ResourceInfo
    The resource info object from the event.

.OUTPUTS
    Array of group ID strings.
#>
function Get-PrivateLinkGroupIds {
    param([PSObject] $ResourceInfo)
    
    $groupIds = @()
    foreach ($connection in $ResourceInfo.properties.privateLinkServiceConnections) {
        $groupIds += $connection.properties.groupIds
    }
    
    return $groupIds
}

<#
.SYNOPSIS
    Updates the 'hidden-pe-state' tag on a private endpoint to 'provisioned'.

.PARAMETER ResourceGroup
    The resource group name.

.PARAMETER PrivateEndpointName
    The private endpoint name.

.PARAMETER MaxRetries
    Maximum number of retry attempts.

.PARAMETER InitialWaitSeconds
    Initial wait time between retries in seconds.

.PARAMETER MaxWaitSeconds
    Maximum wait time between retries in seconds.

.OUTPUTS
    Boolean indicating success.
#>
function Set-PrivateEndpointProvisionedTag {
    param(
        [string] $ResourceGroup,
        [string] $PrivateEndpointName,
        [int] $MaxRetries = $script:DefaultRetries,
        [int] $InitialWaitSeconds = $script:DefaultInitialWait,
        [int] $MaxWaitSeconds = $script:DefaultMaxWait
    )
    
    Write-Host "Updating tag 'hidden-pe-state' to 'provisioned' for PE: $PrivateEndpointName"
    
    Invoke-RetryableOperation -MaxRetries $MaxRetries -InitialWaitSeconds $InitialWaitSeconds -MaxWaitSeconds $MaxWaitSeconds -ScriptBlock {
        $privateEndpoint = Get-AzPrivateEndpoint -ResourceGroupName $ResourceGroup -Name $PrivateEndpointName
        $privateEndpoint.Tag = $privateEndpoint.Tag ?? @{}
        $privateEndpoint.Tag['hidden-pe-state'] = 'provisioned'
        $privateEndpoint | Set-AzPrivateEndpoint | Out-Null
        Write-Host "✓ Tag 'hidden-pe-state' set to 'provisioned'"
    }
}

<#
.SYNOPSIS
    Waits for a private endpoint to reach 'Succeeded' provisioning state.

.PARAMETER ResourceGroup
    The resource group name.

.PARAMETER PrivateEndpointName
    The private endpoint name.

.PARAMETER MaxRetries
    Maximum number of retry attempts.

.PARAMETER InitialWaitSeconds
    Initial wait time between retries in seconds.

.PARAMETER MaxWaitSeconds
    Maximum wait time between retries in seconds.

.OUTPUTS
    Boolean indicating if endpoint reached Succeeded state.
#>
function Wait-PrivateEndpointProvisioning {
    param(
        [string] $ResourceGroup,
        [string] $PrivateEndpointName,
        [int] $MaxRetries = $script:DefaultRetries,
        [int] $InitialWaitSeconds = $script:DefaultInitialWait,
        [int] $MaxWaitSeconds = $script:DefaultMaxWait
    )
    
    $provisioningReady = $false
    $retryCount = 0
    $waitTime = $InitialWaitSeconds
    
    while ($retryCount -lt $MaxRetries -and -not $provisioningReady) {
        try {
            $privateEndpoint = Get-AzPrivateEndpoint -ResourceGroupName $ResourceGroup -Name $PrivateEndpointName
            
            if ($privateEndpoint.ProvisioningState -eq 'Succeeded') {
                Write-Host "Private endpoint ready (state: $($privateEndpoint.ProvisioningState))"
                $provisioningReady = $true
            } elseif ($privateEndpoint.ProvisioningState -in @('Failed', 'Canceled')) {
                throw "Private endpoint in failed state: $($privateEndpoint.ProvisioningState)"
            } else {
                Write-Host "PE provisioning state: $($privateEndpoint.ProvisioningState), waiting ${waitTime}s..."
                Start-Sleep -Seconds $waitTime
                $waitTime = [Math]::Min($waitTime * 2, $MaxWaitSeconds)
                $retryCount++
            }
        } catch {
            if ($retryCount -lt ($MaxRetries - 1) -and ($_.Exception.Message -match 'RetryableError')) {
                Start-Sleep -Seconds $waitTime
                $waitTime = [Math]::Min($waitTime * 2, $MaxWaitSeconds)
                $retryCount++
            } else {
                throw
            }
        }
    }
    
    if (-not $provisioningReady) {
        Write-Warning "Max retries reached for PE provisioning, proceeding anyway"
    }
    
    return $provisioningReady
}

<#
.SYNOPSIS
    Creates a DNS zone group for a private endpoint.

.PARAMETER ResourceGroup
    The resource group name.

.PARAMETER PrivateEndpointName
    The private endpoint name.

.PARAMETER GroupId
    The private link service group ID.

.PARAMETER ZoneResourceId
    The private DNS zone resource ID.

.PARAMETER ZoneGroupName
    The name of the DNS zone group to create.
#>
function New-PrivateEndpointDnsZoneGroup {
    param(
        [string] $ResourceGroup,
        [string] $PrivateEndpointName,
        [string] $GroupId,
        [string] $ZoneResourceId,
        [string] $ZoneGroupName = 'private-endpoint-manager'
    )
    
    try {
        $zoneGroupConfig = @{
            Name = $GroupId
            PrivateDnsZoneId = $ZoneResourceId
        }
        
        Write-Host "Creating private DNS zone group '$ZoneGroupName' for $GroupId"
        
        New-AzPrivateDnsZoneGroup -ResourceGroupName $ResourceGroup `
            -PrivateEndpointName $PrivateEndpointName `
            -Name $ZoneGroupName `
            -PrivateDnsZoneConfig $zoneGroupConfig -ErrorAction Stop | Out-Null
        
        Write-Host "✓ Successfully created DNS zone group"
    } catch {
        Write-Warning "Could not create DNS zone group: $($_.Exception.Message)"
    }
}

# Export public functions
Export-ModuleMember -Function @(
    'Invoke-RetryableOperation',
    'Parse-AzureResourceId',
    'Get-PrivateLinkGroupIds',
    'Set-PrivateEndpointProvisionedTag',
    'Wait-PrivateEndpointProvisioning',
    'New-PrivateEndpointDnsZoneGroup'
)
