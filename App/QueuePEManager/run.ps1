# Input bindings are passed in via param block.
param($QueueItem, $TriggerMetadata)

# Import PrivateEndpoint.Manager module
$moduleName = 'PrivateEndpoint.Manager'
$modulePath = Join-Path $PSScriptRoot '..\Modules\PrivateEndpoint.Manager'

# Add module path if not already present
if ($modulePath -notin $env:PSModulePath.Split(';')) {
    $env:PSModulePath = "$modulePath;$env:PSModulePath"
}

Import-Module -Name $moduleName -Force

# Constants
$configPath = Join-Path $PSScriptRoot '..\config.json'

try {
    # Verify config file exists
    if (-not (Test-Path $configPath)) {
        throw "Config file not found at $configPath"
    }
    
    # Load configuration and parse event message
    $config = Get-Content -Path $configPath -Raw | ConvertFrom-Json
    
    $message = $QueueItem
    Write-Host "Received message: $message"
    
    # Parse event - handle both string and object formats
    $queueEvent = if ($message -is [string]) {
        $message | ConvertFrom-Json -ErrorAction Stop
    } else {
        $message
    }
    
    Write-Host "Processing event: $($queueEvent.eventType)"
    
    # Extract resource information
    $resourceInfo = $queueEvent.data.resourceInfo
    $privateEndpointId = $resourceInfo.id
    $privateEndpointName = $resourceInfo.name
    
    # Parse subscription ID and resource group from PE ID using module function
    $parsedId = Parse-AzureResourceId -ResourceId $privateEndpointId
    $subscriptionId = $parsedId.SubscriptionId
    $resourceGroup = $parsedId.ResourceGroup
    $peName = $parsedId.ResourceName
    
    Set-AzContext -SubscriptionId $subscriptionId | Out-Null
    
    # Update tag on private endpoint using module function
    Set-PrivateEndpointProvisionedTag -ResourceGroup $resourceGroup -PrivateEndpointName $peName
    
    # Extract group IDs from private link service connections using module function
    $groupIds = Get-PrivateLinkGroupIds -ResourceInfo $resourceInfo
    
    Write-Host "Private Endpoint: $privateEndpointName"
    Write-Host "Group IDs: $($groupIds -join ', ')"
    
    # Configure DNS zones for each group ID
    $dnsMappings = $config.privateDnsZoneMappings
    
    foreach ($groupId in $groupIds) {
        if (-not $dnsMappings.$groupId) {
            Write-Host "✗ GroupId '$groupId' not found in config"
            continue
        }
        
        $dnsConfig = $dnsMappings.$groupId
        $zoneResourceId = $dnsConfig.resourceId
        
        Write-Host "✓ GroupId '$groupId' found in config (Zone: $($dnsConfig.zoneName))"
        
        try {
            # Wait for private endpoint to be ready for DNS configuration using module function
            Wait-PrivateEndpointProvisioning -ResourceGroup $resourceGroup -PrivateEndpointName $peName
            
            # Create DNS zone group using module function
            New-PrivateEndpointDnsZoneGroup -ResourceGroup $resourceGroup `
                -PrivateEndpointName $peName `
                -GroupId $groupId `
                -ZoneResourceId $zoneResourceId
            
        } catch {
            Write-Error "Error configuring DNS zone: $($_.Exception.Message)"
        }
    }
    
} catch {
    Write-Error "Error processing private endpoint event: $($_.Exception.Message)"
    throw
}
