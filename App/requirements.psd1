# This file enables modules to be automatically managed by the Functions service.
# See https://aka.ms/functionsmanageddependency for additional information.
#
@{
    # For latest supported version, go to 'https://www.powershellgallery.com/packages/Az'. 
    # To use the Az module in your function app, please uncomment the line below.
    'Az.Network' = '7.24.0'
    # Note: PrivateEndpoint.Manager is a local module located in the Modules directory
    # and is loaded dynamically by the function runtime. It requires PowerShell 7.0+
}
