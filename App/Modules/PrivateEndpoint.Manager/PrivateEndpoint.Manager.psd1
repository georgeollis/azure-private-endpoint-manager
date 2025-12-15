@{
    RootModule            = 'PrivateEndpoint.Manager.psm1'
    ModuleVersion         = '1.0.0'
    GUID                  = '12345678-1234-1234-1234-123456789012'
    Author                = 'George Ollis'
    CompanyName           = 'Private Endpoint Manager'
    Description           = 'PowerShell module for managing Azure Private Endpoints and DNS zone configurations'
    PowerShellVersion     = '7.0'
    RequiredModules       = @('Az.Network')
    FunctionsToExport     = @(
        'Invoke-RetryableOperation',
        'Parse-AzureResourceId',
        'Get-PrivateLinkGroupIds',
        'Set-PrivateEndpointProvisionedTag',
        'Wait-PrivateEndpointProvisioning',
        'New-PrivateEndpointDnsZoneGroup'
    )
    PrivateData           = @{
        PSData = @{
            Tags       = @('Azure', 'PrivateEndpoint', 'DNS', 'Management')
            ProjectUri = 'https://github.com/georgeollis/azure-private-endpoint-manager'
        }
    }
}
