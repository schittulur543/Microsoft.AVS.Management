<# Private Function Import #>
. $PSScriptRoot\AVSGenericUtils.ps1
. $PSScriptRoot\AVSvSANUtils.ps1

<# Download certificate from SAS token url #>
function Get-Certificates {
    Param
    (
        [Parameter(
            Mandatory = $true)]
        [System.Security.SecureString]
        $SSLCertificatesSasUrl
    )

    [string] $CertificatesSASPlainString = ConvertFrom-SecureString -SecureString $SSLCertificatesSasUrl -AsPlainText
    [System.StringSplitOptions] $options = [System.StringSplitOptions]::RemoveEmptyEntries -bor [System.StringSplitOptions]::TrimEntries
    [string[]] $CertificatesSASList = $CertificatesSASPlainString.Split(",", $options)
    Write-Host "Number of Certs passed $($CertificatesSASList.count)"
    if ($CertificatesSASList.count -eq 0) {
        throw "If adding an LDAPS identity source, please ensure you pass in at least one certificate"
    }
    if ($PSBoundParameters.ContainsKey('SecondaryUrl') -and $CertificatesSASList.count -lt 2) {
        throw "If passing in a secondary/fallback URL, ensure that at least two certificates are passed."
    }
    $DestinationFileArray = @()
    $Index = 1
    foreach ($CertSas in $CertificatesSASList) {
        Write-Host "Downloading Cert $Index..."
        $CertDir = $pwd.Path
        $CertLocation = "$CertDir/cert$Index.cer"
        try {
            $Response = Invoke-WebRequest -Uri $CertSas -OutFile $CertLocation
            $StatusCode = $Response.StatusCode
            Write-Host("Certificate downloaded. $StatusCode")
            $DestinationFileArray += $CertLocation
        }
        catch {
            throw "Failed to download certificate #$($Index): $($PSItem.Exception.Message). Ensure the SAS string is still valid"
        }
        $Index = $Index + 1
    }
    Write-Host "Number of certificates downloaded: $($DestinationFileArray.count)"
    return $DestinationFileArray
}

function Get-StoragePolicyInternal {
    Param
    (
        [Parameter(
            Mandatory = $true)]
        $StoragePolicyName
    )
    Write-Host "Getting Storage Policy $StoragePolicyName"
    $VSANStoragePolicies = Get-SpbmStoragePolicy -Namespace "VSAN" -ErrorAction Stop
    $StoragePolicy = Get-SpbmStoragePolicy $StoragePolicyName -ErrorAction Stop
    if ($null -eq $StoragePolicy) {
        Write-Error "Could not find Storage Policy with the name $StoragePolicyName." -ErrorAction Continue
        Write-Error "Available storage policies: $(Get-SpbmStoragePolicy -Namespace "VSAN")" -ErrorAction Stop
    }
    elseif (-not ($StoragePolicy -in $VSANStoragePolicies)) {
        Write-Error "Storage policy $StoragePolicyName is not supported. Storage policies must be in the VSAN namespace" -ErrorAction Continue
        Write-Error "Available storage policies: $(Get-SpbmStoragePolicy -Namespace "VSAN")" -ErrorAction Stop
    }
    return $StoragePolicy, $VSANStoragePolicies
}

function Set-StoragePolicyOnVM {
    Param
    (
        [Parameter(
            Mandatory = $true)]
        $VM,
        [Parameter(
            Mandatory = $true)]
        $VSANStoragePolicies,
        [Parameter(
            Mandatory = $true)]
        $StoragePolicy
    )
    if (-not $(Get-SpbmEntityConfiguration $VM).StoragePolicy -in $VSANStoragePolicies) {
        Write-Error "Modifying storage policy on $($VM.Name) is not supported"
    }
    Write-Host "Setting VM $($VM.Name) storage policy to $($StoragePolicy.Name)..."
    try {
        Set-VM -VM $VM -StoragePolicy $StoragePolicy -ErrorAction Stop -Confirm:$false
        Write-Output "Successfully set the storage policy on VM $($VM.Name) to $($StoragePolicy.Name)"
    }
    catch [VMware.VimAutomation.ViCore.Types.V1.ErrorHandling.InvalidVmConfig] {
        Write-Error "The selected storage policy $($StoragePolicy.Name) is not compatible with $($VM.Name). You may need more hosts: $($PSItem.Exception.Message)"
    }
    catch {
        Write-Error "Was not able to set the storage policy on $($VM.Name): $($PSItem.Exception.Message)"
    }
}

function Get-UnassociatedVsanObjectsWithPolicy {
    <#
    .SYNOPSIS
        Lists all unassociated vSAN objects with a specified storage policy across all clusters.
    
    .DESCRIPTION
        Scans all clusters for vSAN objects that are not associated with any VM and have the specified storage policy.
    
    .PARAMETER PolicyName
        The name of the storage policy to filter unassociated objects.
    
    .PARAMETER ClusterName
        The name of the vSphere cluster to scan for unassociated objects.
    
    .EXAMPLE
        Get-UnassociatedVsanObjectsWithPolicy -PolicyName 'vSAN Default Storage Policy' -ClusterName 'Cluster1'
    #>

    [CmdletBinding()]
    [AVSAttribute(10, UpdatesSDDC = $false)]										
    Param (
        [Parameter(Mandatory = $true, HelpMessage = 'The storage policy name to filter unassociated objects')]
        [ValidateNotNullOrEmpty()]
        [string]$PolicyName,
        
        [Parameter(Mandatory = $true, HelpMessage = 'The name of the vSphere cluster to scan for unassociated objects')]
        [ValidateNotNullOrEmpty()]
        [string]$ClusterName
    )
    
    $totalObjects = 0
    $matchedObjects = 0
    
    try {
        $cluster = Get-Cluster $ClusterName -ErrorAction Stop

        $clusterMoRef = $cluster.ExtensionData.MoRef
        $vmHost = ($cluster | Get-VMHost | Where-Object { $_.ConnectionState -eq 'Connected' -and $_.PowerState -eq 'PoweredOn' } | Select-Object -First 1)
        if ($null -eq $vmHost) {
            throw "No connected and powered-on hosts found."
        }
        $vsanIntSys = Get-View $vmHost.ExtensionData.ConfigManager.VsanInternalSystem
        $vsanClusterObjectSys = Get-VsanView -Id VsanObjectSystem-vsan-cluster-object-system
    }
    catch {
        Write-Error "Failed to initialize vSAN objects or connect to cluster: $_"
        return
    }

    try {
        $unassociatedObjects = ($vsanClusterObjectSys.VsanQueryObjectIdentities($clusterMoRef, $null, $null, $false, $true, $false)).Identities | Where-Object { $null -eq $_.Vm }
    }
    catch {
        Write-Error "Failed to query unassociated vSAN objects: $_"
        return
    }

    foreach ($obj in $unassociatedObjects) {
        $totalObjects++
        if ($obj.SpbmProfileName -eq $PolicyName) {
            $matchedObjects++
            try {
                $jsonResult = ($vsanIntSys.GetVsanObjExtAttrs($obj.Uuid)) | ConvertFrom-Json
                Write-Output $jsonResult
            }
            catch {
                Write-Warning "Failed to retrieve or parse attributes for object $($obj.Uuid): $_"
            }
        }
    }

    Write-Output "Total unassociated objects found: $totalObjects"
    Write-Output "Unassociated objects with policy '$PolicyName': $matchedObjects"
    
    if ($matchedObjects -eq 0) {
        Write-Output "No unassociated objects with policy '$PolicyName' found."
    }
}

function Update-StoragePolicyOfUnassociatedVsanObjects {
    <#
    .SYNOPSIS
        Updates the storage policy of unassociated vSAN objects from a current policy to a new target policy.
    
    .DESCRIPTION
        This function scans all clusters for unassociated vSAN objects with a specified current policy and updates their storage policy to a new target policy.
    
    .PARAMETER CurrentPolicyName
        The name of the current policy that unassociated objects currently have.
    
    .PARAMETER TargetPolicyName
        The name of the new storage policy to apply to the unassociated objects.
    
    .PARAMETER ClusterName
        The name of the vSphere cluster containing the unassociated objects to update.
    
    .EXAMPLE
        Update-StoragePolicyOfUnassociatedVsanObjects -CurrentPolicyName 'vSAN Default Storage Policy' -TargetPolicyName 'New Policy' -ClusterName 'Cluster1'													 
    #>

    [CmdletBinding()]
	[AVSAttribute(30, UpdatesSDDC = $false)]										
    Param (
        [Parameter(Mandatory = $true, HelpMessage = 'Specify the name of the current storage policy assigned to the unassociated objects.')]
        [ValidateNotNullOrEmpty()]
        [string]$CurrentPolicyName,
        
        [Parameter(Mandatory = $true, HelpMessage = 'Specify the name of the target storage policy to assign to the unassociated objects.')]
        [ValidateNotNullOrEmpty()]
        [string]$TargetPolicyName,
        
        [Parameter(Mandatory = $true, HelpMessage = 'Specify the name of the vSphere cluster containing the unassociated objects to update.')]
        [ValidateNotNullOrEmpty()]
        [string]$ClusterName
    )
    
    try {								
        $newPolicy = Get-SpbmStoragePolicy -Name $TargetPolicyName -ErrorAction Stop
    }
    catch {
        Write-Error "Failed to retrieve target storage policy '$TargetPolicyName': $($_.Exception.Message)"
        return
    }
					 
    $totalUnassociatedObjects = 0
    $updatedObjects = 0
    
    try {
        $cluster = Get-Cluster $ClusterName -ErrorAction Stop
	    $clusterMoRef = $cluster.ExtensionData.MoRef
        $vmHost = ($cluster | Get-VMHost | Where-Object { $_.ConnectionState -eq 'Connected' -and $_.PowerState -eq 'PoweredOn' } | Select-Object -First 1)
        if ($null -eq $vmHost) {
            throw "No connected and powered-on hosts found."
        }
        $vsanIntSys = Get-View $vmHost.ExtensionData.ConfigManager.VsanInternalSystem
        $vsanClusterObjectSys = Get-VsanView -Id VsanObjectSystem-vsan-cluster-object-system
    }
    catch {
        Write-Error "Failed to retrieve vSAN system views: $($_.Exception.Message)"
        return
    }

    try {												
        $unassociatedObjects = ($vsanClusterObjectSys.VsanQueryObjectIdentities($clusterMoRef, $null, $null, $false, $true, $false)).Identities | Where-Object { $null -eq $_.Vm }
    }
    catch {
        Write-Error "Failed to query unassociated vSAN objects: $($_.Exception.Message)"
        return
    }

    if (-not $unassociatedObjects) {
        Write-Output "No unassociated objects found."
        return
    }

    foreach ($obj in $unassociatedObjects) {
        $totalUnassociatedObjects++
        try {
            $jsonResult = ($vsanIntSys.GetVsanObjExtAttrs($obj.Uuid)) | ConvertFrom-Json																	   
            $objectID = ($jsonResult.PSObject.Properties.Name | Select-Object -First 1)
            $objectInfo = $jsonResult.$objectID
        }
        catch {
            Write-Warning "Failed to retrieve or parse attributes for object $($obj.Uuid): $($_.Exception.Message)"
            continue
        }
						  
        if ($null -eq $objectInfo.'User friendly name') {
            Write-Warning "No user friendly name for object UUID: $($obj.Uuid). Skipping Test-AVSProtectedObjectName check."
            $friendlyName = 'NO USER FRIENDLY NAME'
        } 
        else {
            $friendlyName = $objectInfo.'User friendly name'
            try {								   
                if (Test-AVSProtectedObjectName -Name $friendlyName) {
                    Write-Error "The object '$friendlyName' is protected. Skipping policy update for UUID: $($obj.Uuid)."
                    continue
                }
            }
            catch {
                Write-Warning "Failed to check if object name '$friendlyName' is protected: $($_.Exception.Message)"
                continue
            }
        }
												   
        if ($obj.SpbmProfileName -eq $CurrentPolicyName) {
            Write-Output "Unassociated object $($obj.Uuid) with policy '$CurrentPolicyName' is being updated to '$TargetPolicyName'..."
            try {
                $profileSpec = New-Object VMware.Vim.VirtualMachineDefinedProfileSpec
                $profileSpec.ProfileId = $newPolicy.Id

                $vsanClusterObjectSys.VosSetVsanObjectPolicy($clusterMoRef, $obj.Uuid, $profileSpec)
                Write-Output "Successfully updated storage policy for UUID: $($obj.Uuid)"
                $updatedObjects++
                Write-Output $jsonResult
            }
            catch {
                Write-Error "Failed to update storage policy for object '$($obj.Uuid)': $($_.Exception.Message)"
            }
        }
    }
    Write-Output "Total unassociated objects: $totalUnassociatedObjects"
    Write-Output "Unassociated objects with policy '$CurrentPolicyName' updated to '$TargetPolicyName': $updatedObjects"
    if ($updatedObjects -eq 0) {
        Write-Output "No unassociated objects with policy '$CurrentPolicyName' found."
    }
}

<#
    .Synopsis
     Not Recommended (use New-LDAPSIdentitySource): Add a not secure external identity source (Active Directory over LDAP) for use with vCenter Server Single Sign-On.

    .Parameter Name
     The user-friendly name the external AD will be given in vCenter

    .Parameter DomainName
     Domain name of the external active directory, e.g. myactivedirectory.local

    .Parameter DomainAlias
     Domain alias of the external active directory, e.g. myactivedirectory

    .Parameter PrimaryUrl
     Url of the primary ldap server to attempt to connect to, e.g. ldap://myadserver.local:389

    .Parameter SecondaryUrl
     Optional: Url of the fallback ldap server to attempt to connect to, e.g. ldap://myadserver.local:389

    .Parameter BaseDNUsers
     Base Distinguished Name for users, e.g. "dc=myadserver,dc=local"

    .Parameter BaseDNGroups
     Base Distinguished Name for groups, e.g. "dc=myadserver,dc=local"

    .Parameter Credential
     Credential to login to the LDAP server (NOT cloudadmin) in the form of a username/password credential. Usernames often look like prodAdmins@domainname.com or if the AD is a Microsoft Active Directory server, usernames may need to be prefixed with the NetBIOS domain name, such as prod\AD_Admin

    .Parameter GroupName
     Optional: A group in the customer external identity source to be added to CloudAdmins. Users in this group will have CloudAdmin access. Group name should be formatted without the domain name, e.g. group-to-give-access

    .Example
    # Add the domain server named "myserver.local" to vCenter
    Add-LDAPIdentitySource -Name 'myserver' -DomainName 'myserver.local' -DomainAlias 'myserver' -PrimaryUrl 'ldap://10.40.0.5:389' -BaseDNUsers 'dc=myserver, dc=local' -BaseDNGroups 'dc=myserver, dc=local'
#>
function New-LDAPIdentitySource {
    [CmdletBinding(PositionalBinding = $false)]
    [AVSAttribute(10, UpdatesSDDC = $false)]
    Param
    (
        [Parameter(
            Mandatory = $true,
            HelpMessage = 'User-Friendly name to store in vCenter')]
        [ValidateNotNull()]
        [string]
        $Name,

        [Parameter(
            Mandatory = $true,
            HelpMessage = 'Full DomainName: adserver.local')]
        [ValidateNotNull()]
        [string]
        $DomainName,

        [Parameter(
            Mandatory = $true,
            HelpMessage = 'DomainAlias: adserver')]
        [string]
        $DomainAlias,

        [Parameter(
            Mandatory = $true,
            HelpMessage = 'URL of your AD Server: ldaps://yourserver:636')]
        [ValidateNotNullOrEmpty()]
        [string]
        $PrimaryUrl,

        [Parameter(
            Mandatory = $false,
            HelpMessage = 'Optional: URL of a backup server')]
        [string]
        $SecondaryUrl,

        [Parameter(
            Mandatory = $true,
            HelpMessage = 'BaseDNGroups, "DC=name, DC=name"')]
        [ValidateNotNull()]
        [string]
        $BaseDNUsers,

        [Parameter(
            Mandatory = $true,
            HelpMessage = 'BaseDNGroups, "DC=name, DC=name"')]
        [ValidateNotNull()]
        [string]
        $BaseDNGroups,

        [Parameter(
            Mandatory = $true,
            HelpMessage = "Credential for the LDAP server")]
        [ValidateNotNull()]
        [System.Management.Automation.PSCredential]
        [System.Management.Automation.Credential()]
        $Credential,

        [Parameter (
            Mandatory = $false,
            HelpMessage = 'A group in the external identity source to give CloudAdmins access')]
        [string]
        $GroupName
    )

    try {
        Assert-ADServerURL $PrimaryUrl
        if ($PSBoundParameters.ContainsKey('SecondaryUrl')) {
            Assert-ADServerURL $SecondaryUrl
        }
    }
    catch {
        throw "Incorrect Primary/Secondary URL format: $_"
    }

    $ExternalIdentitySources = Get-IdentitySource -External -ErrorAction Continue
    if ($null -ne $ExternalIdentitySources) {
        Write-Host "Checking to see if identity source already exists..."
        if ($DomainName.trim() -eq $($ExternalIdentitySources.Name.trim())) {
            Write-Error $($ExternalIdentitySources | Format-List | Out-String) -ErrorAction Continue
            Write-Error "Already have an external identity source with the same name: $($ExternalIdentitySources.Name). If only trying to add a group to this Identity Source, use Add-GroupToCloudAdmins" -ErrorAction Stop
        }
        else {
            Write-Information "$($ExternalIdentitySources | Format-List | Out-String)"
            Write-Information "An identity source already exists, but not for this domain. Continuing to add this one..."
        }
    }
    else {
        Write-Host "No existing external identity sources found."
    }

    $Password = $Credential.GetNetworkCredential().Password
    Write-Host "Adding $DomainName..."
    Add-LDAPIdentitySource `
        -Name $Name `
        -DomainName $DomainName `
        -DomainAlias $DomainAlias `
        -PrimaryUrl $PrimaryUrl `
        -SecondaryUrl $SecondaryUrl `
        -BaseDNUsers $BaseDNUsers `
        -BaseDNGroups $BaseDNGroups `
        -Username $Credential.UserName `
        -Password $Password `
        -ServerType 'ActiveDirectory' -ErrorAction Stop
    $ExternalIdentitySources = Get-IdentitySource -External -ErrorAction Continue
    $ExternalIdentitySources | Format-List | Out-String

    if ($PSBoundParameters.ContainsKey('GroupName')) {
        Write-Host "GroupName passed in: $GroupName"
        Write-Host "Attempting to add group $GroupName to CloudAdmins..."
        Add-GroupToCloudAdmins -GroupName $GroupName -Domain $DomainName -ErrorAction Stop
    }
}

<#
    .SYNOPSIS
    Validate an URL of Active Directory Server.
#>
function Assert-ADServerURL {
    param (
        [Parameter(
            Mandatory = $true)]
        [ValidateNotNull()]
        [string]
        $Url
    )
    if (![uri]::IsWellFormedUriString($Url, 'Absolute')) {
        throw "Incorrect Url format entered from: $Url"
    }
    $ParsedUrl = [System.Uri]$Url
    if ($ParsedUrl.Port -lt 0 -OR $ParsedUrl.Host -eq "" -OR $ParsedUrl.Scheme -eq "") {
        throw "Incorrect Url format entered from: $Url. The correct Url format is protocol://host:port (Example: ldaps://yourserver.com:636)."
    }
    if ($ParsedUrl.Scheme -ne "ldap" -and $ParsedUrl.Scheme -ne "ldaps") {
        throw "Incorrect Url scheme: $ParsedUrl. The correct scheme must be either: LDAP or LDAPS."
    }
    if ($ParsedUrl.Port -notin 389, 636, 3268, 3269) {
        throw "Incorrect Url port: $ParsedUrl. The correct port number must be: 389, 636, 3268, or 3269."
    }
    if ($ParsedUrl.Scheme -eq "ldap" -and $ParsedUrl.Port -in 636, 3269) {
        Write-Warning "$ParsedUrl is nonstandard. Are you sure you meant to use the 636/3269 port and not the standard ports for LDAP, 389 or 3268? Continuing anyway.."
    }
    if ($ParsedUrl.Scheme -eq "ldaps" -and $ParsedUrl.Port -in 389, 3268) {
        Write-Warning "$ParsedUrl is nonstandard. Are you sure you meant to use the 389/3268 port and not the standard ports for LDAPS, 636 or 3269? Continuing anyway.."
    }
    if ($ParsedUrl.Scheme -eq "ldaps" -and [bool]($ParsedUrl.Host -as [ipaddress])) {
        throw "Incorrect Url format: $ParsedUrl. It should not be an IP address. Please use the hostname exactly as specified on the issued certificate."
    }
    $ResultUrlString = $ParsedUrl.GetLeftPart([UriPartial]::Authority)
    $ResultUrl = [System.Uri]$ResultUrlString
    return $ResultUrl
}

<#
    .Synopsis
     Download certificates from domain controllers and save them to local files
#>
function Get-CertificateFromServerToLocalFile {
    param (
        [Parameter(
            Mandatory = $true)]
        [ValidateNotNull()]
        [string[]]
        $remoteComputers
    )

    $DestinationFileArray = @()
    $exportFolder = $pwd.Path + "/"
    foreach ($computerUrl in $remoteComputers) {
        $ParsedUrl = [System.Uri]$computerUrl
        $ResultUrlString = $ParsedUrl.GetLeftPart([UriPartial]::Authority)
        $ResultUrl = [System.Uri]$ResultUrlString
        try {
            Write-Host ("Starting to Download Cert from " + $computerUrl)
            $Command = 'echo "1" | openssl s_client -connect ' + $ResultUrl.Host + ':' + $ResultUrl.Port + ' -showcerts'
            $SSHRes = Invoke-SSHCommand -Command $Command -SSHSession $SSH_Sessions['VC'].Value
            $SSHOutput = $SSHRes.Output | out-string
        }
        catch {
            throw "Failure to download the certificate from $computerUrl. $_"
        }

        if ($SSHOutput -notmatch '(?s)(?<cert>-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----)') {
            throw "The certificate from $computerUrl has an incorrect format"
        }
        else {
            $certs = select-string -inputobject $SSHOutput -pattern "(?s)(?<cert>-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----)" -allmatches
            $cert = $certs.matches[0]
            $exportPath = $exportFolder + ($ResultUrl.Host.split(".")[0]) + ".cer"
            $cert.Value | Out-File $exportPath -Encoding ascii
            $DestinationFileArray += $exportPath
        }
    }
    Write-Host "Number of certificates downloaded: $($DestinationFileArray.count)"
    return $DestinationFileArray
}

<#
    .Synopsis
     Recommended: Debug functionality of all OpenLDAP and Active Directory Identity Sources for use with vCenter Server Single Sign-On.

    .Example
    # Debug the OpenLDAP and Active Directory Identity Sources configured in vCenter
    Debug-LDAPSIdentitySources
#>
function Debug-LDAPSIdentitySources {
    [AVSAttribute(2, UpdatesSDDC = $false)]
    Param()
    Write-Host "*"
    Write-Host "* LDAP Identity Source Diagnostic Test Tool (ldapcheck)"
    Write-Host "* Executed at $((Get-Date).ToUniversalTime())"
    Write-Host "*"

    $sources = Get-IdentitySource -External -ErrorAction Stop
    $sources | ForEach-Object {
        if(($_.Type -eq "OpenLdap") -or ($_.Type -eq "ActiveDirectory")) {

            Write-Host "* -------------------------------------------------------------"
            Write-Host "* OpenLDAP Identity Source $($_.Name) detected."

            $urls = @()
            if(-not ($null -eq $_.PrimaryUrl)) {
                $urls += $_.PrimaryUrl
                Write-Host "* The Primary URL is  $($_.PrimaryUrl)."
            }
            if(-not ($null -eq $_.FailoverUrl)) {
                $urls += $_.FailoverUrl
                Write-Host "* The Failover URL is $($_.FailoverUrl)."
            }

            foreach($url in $urls) {
                Write-Host "* Checking LDAP URL: $url"

                # Check URL looks okay:
                # i.e. ldaps://ldap1.ldap.avs.azure.com
                try {
                    $ResultUrl = Assert-ADServerURL $url
                    $ldap_protocol = $ResultUrl.Scheme
                    $ldap_hostname = $ResultUrl.Host
                    $ldap_portspec = $ResultUrl.Port
                    Write-Host "  LDAP Protocol:        $ldap_protocol"
                    Write-Host "  LDAP Server Hostname: $ldap_hostname"
                    Write-Host "  LDAP Port Specified:  $ldap_portspec"

                    # Check if the LDAP hostname is in /etc/hosts
                    try {
                        $Command = "grep $ldap_hostname /etc/hosts"
                        $SSHRes = Invoke-SSHCommand -Command $Command -SSHSession $SSH_Sessions['VC'].Value
                    }
                    catch {
                        throw "ERROR: Unable to execute grep command on vCenter."
                    }
                    $SSHOutput = $SSHRes.Output | out-string
                    Write-Host "* vCenter /etc/hosts hostname resolution check returned: $SSHOutput"

                    # Call Host to check DNS resolution of LDAP server from vCenter"
                    try {
                        $Command = "host $ldap_hostname"
                        $SSHRes = Invoke-SSHCommand -Command $Command -SSHSession $SSH_Sessions['VC'].Value
                    }
                    catch {throw "ERROR: Unable to execute host command on vCenter."}
                    Write-Host "* vCenter DNS hostname resolution check returned: $($SSHRes.Output)"

                    # Now let's look at the port numbers
                    if($ldap_portspec -ne "") {
                        $ldap_port = $ldap_portspec -match ":([0-9]+)"
                        Write-Host "  LDAP Port number:      $ldap_port"
                    } else {
                        switch($ldap_protocol) {
                            "ldap"  {$ldap_port = 389}
                            "ldaps" {$ldap_port = 636}
                            "default" {$ldap_port = -1}
                        }
                        Write-Host "* LDAP Port to test:    $ldap_port"
                    }

                    # Call NetCat to test if the LDAP port is open
                    try {
                        $Command = "nc -vz $ldap_hostname $ldap_port"
                        $SSHRes = Invoke-SSHCommand -Command $Command -SSHSession $SSH_Sessions['VC'].Value
                    }
                    catch {throw "ERROR: Unable to execute nc command on vCenter."}

                    if($SSHRes.ExitStatus -eq 1) {
                        Write-Error "* vCenter-to-LDAP TCP test FAILED."

                        # Netcat failed to access the TCP port.
                        # Let's have vCenter ping the LDAP server (even though ICMP isn't required)"
                        try {
                            $Command = "ping -c 3 $ldap_hostname"
                            $SSHRes = Invoke-SSHCommand -Command $Command -SSHSession $SSH_Sessions['VC'].Value
                        }
                        catch {throw "ERROR: Unable to execute ping command on vCenter."}
                        Write-Host "* vCenter-to-LDAP Ping test returned:"
                        Write-Host "$($SSHRes.Output | out-string)"

                        if($($SSHRes.Output | Out-String) -match " (?<percentage>[0-9]+)% packet loss") {
                            $ping_loss = $Matches.percentage
                            if($ping_loss -eq "0") {
                                Write-Host "* vCenter was able to ping the LDAP server without a problem."
                            } elseif($ping_loss -eq "100") {
                                Write-Error "* vCenter was unable to ping LDAP server."

                                # Okay, this is bad. vCenter can't contact the LDAP server with TCP
                                # nor ping, so let's do a traceroute for the network folks to look at:
                                try {
                                    $Command = "traceroute $ldap_hostname"
                                    $SSHRes = Invoke-SSHCommand -Command $Command -SSHSession $SSH_Sessions['VC'].Value
                                }
                                catch {throw "ERROR: Unable to execute traceroute command on vCenter."}
                                Write-Host "* vCenter-to-LDAP Traceroute test returned:"
                                Write-Host "$($SSHRes.Output | out-string)"
                            } else {
                                Write-Warning "* Partial packet loss pinging LDAP server."
                            }
                        } else {
                            Write-Error "* Unable to interpret ping results."
                        }
                    } elseif($SSHRes.ExitStatus -eq 0) {
                        Write-Host "* vCenter-to-LDAP TCP test successful. Port is open."

                        if($ldap_protocol -eq "ldaps") {
                            Write-Host "* Attempting SSL Connect test."
                            # Netcat says the TCP port is open, so let's attempt an SSL connection:
                            try {
                                $Command = "openssl s_client -connect $($ldap_hostname):$($ldap_port) -showcerts < /dev/null"
                                $SSHRes = Invoke-SSHCommand -Command $Command -SSHSession $SSH_Sessions['VC'].Value
                            }
                            catch {throw "ERROR: Unable to execute openssl command on vCenter."}
                            Write-Host "* SSL connect test returned:"
                            Write-Host "$($SSHRes.Output | out-string)"
                        }
                    } else {
                        Write-Error "* vCenter-to-LDAP TCP test failed with result code $($SSHRes.ExitStatus)."
                    }
                } catch {
                    Write-Error "URL $url does not look like an LDAP URL. $_"
                }
            }
        }
    }
    Write-Host "* Script terminated at $((Get-Date).ToUniversalTime())"
}

<#
    .Synopsis
     Recommended: Add a secure external identity source (Active Directory over LDAPS) for use with vCenter Server Single Sign-On.

    .Parameter Name
     The user-friendly name the external AD will be given in vCenter

    .Parameter DomainName
     Domain name of the external active directory, e.g. myactivedirectory.local

    .Parameter DomainAlias
     Domain alias of the external active directory, e.g. myactivedirectory

    .Parameter PrimaryUrl
     Url of the primary ldaps server to attempt to connect to, e.g. ldaps://myadserver.local:636

    .Parameter SecondaryUrl
     Optional: Url of the fallback ldaps server to attempt to connect to, e.g. ldaps://myadserver.local:636

    .Parameter BaseDNUsers
     Base Distinguished Name for users, e.g. "dc=myadserver,dc=local"

    .Parameter BaseDNGroups
     Base Distinguished Name for groups, e.g. "dc=myadserver,dc=local"

    .Parameter Credential
     Credential to login to the LDAP server (NOT cloudadmin) in the form of a username/password credential. Usernames often look like prodAdmins@domainname.com or if the AD is a Microsoft Active Directory server, usernames may need to be prefixed with the NetBIOS domain name, such as prod\AD_Admin

    .Parameter SSLCertificatesSasUrl
     An comma-delimeted list of Blob Shared Access Signature strings to the certificates required to connect to the external active directory

    .Parameter GroupName
     Optional: A group in the customer external identity source to be added to CloudAdmins. Users in this group will have CloudAdmin access. Group name should be formatted without the domain name, e.g. group-to-give-access

    .Example
    # Add the domain server named "myserver.local" to vCenter
    Add-LDAPSIdentitySource -Name 'myserver' -DomainName 'myserver.local' -DomainAlias 'myserver' -PrimaryUrl 'ldaps://10.40.0.5:636' -BaseDNUsers 'dc=myserver, dc=local' -BaseDNGroups 'dc=myserver, dc=local' -Username 'myserver@myserver.local' -Password 'PlaceholderPassword' -CertificatesSAS 'https://sharedaccessstring.path/accesskey' -Protocol LDAPS
#>
function New-LDAPSIdentitySource {
    [CmdletBinding(PositionalBinding = $false)]
    [AVSAttribute(10, UpdatesSDDC = $false)]
    Param
    (
        [Parameter(
            Mandatory = $true,
            HelpMessage = 'User-Friendly name to store in vCenter')]
        [ValidateNotNull()]
        [string]
        $Name,

        [Parameter(
            Mandatory = $true,
            HelpMessage = 'Full DomainName: adserver.local')]
        [ValidateNotNull()]
        [string]
        $DomainName,

        [Parameter(
            Mandatory = $true,
            HelpMessage = 'DomainAlias: adserver')]
        [string]
        $DomainAlias,

        [Parameter(
            Mandatory = $true,
            HelpMessage = 'URL of your AD Server: ldaps://yourserver:636')]
        [ValidateNotNullOrEmpty()]
        [string]
        $PrimaryUrl,

        [Parameter(
            Mandatory = $false,
            HelpMessage = 'Optional: URL of a backup server')]
        [string]
        $SecondaryUrl,

        [Parameter(
            Mandatory = $true,
            HelpMessage = 'BaseDNGroups, "DC=name, DC=name"')]
        [ValidateNotNull()]
        [string]
        $BaseDNUsers,

        [Parameter(
            Mandatory = $true,
            HelpMessage = 'BaseDNGroups, "DC=name, DC=name"')]
        [ValidateNotNull()]
        [string]
        $BaseDNGroups,

        [Parameter(Mandatory = $true,
            HelpMessage = "Credential for the LDAP server")]
        [ValidateNotNull()]
        [System.Management.Automation.PSCredential]
        [System.Management.Automation.Credential()]
        $Credential,

        [Parameter(
            Mandatory = $false,
            HelpMessage = 'Optional: The certs will be installed from domain controllers if not specified. A comma-delimited list of SAS path URI to Certificates for authentication. Ensure permissions to read included. To generate, place the certificates in any storage account blob and then right click the cert and generate SAS')]
        [System.Security.SecureString]
        $SSLCertificatesSasUrl,

        [Parameter (
            Mandatory = $false,
            HelpMessage = 'A group in the external identity source to give CloudAdmins access')]
        [string]
        $GroupName
    )

    $ExternalIdentitySources = Get-IdentitySource -External -ErrorAction Continue
    if ($null -ne $ExternalIdentitySources) {
        Write-Host "Checking to see if identity source already exists..."
        if ($DomainName.trim() -eq $($ExternalIdentitySources.Name.trim())) {
            Write-Error $($ExternalIdentitySources | Format-List | Out-String) -ErrorAction Continue
            Write-Error "Already have an external identity source with the same name: $($ExternalIdentitySources.Name). If only trying to add a group to this Identity Source, use Add-GroupToCloudAdmins" -ErrorAction Stop
        }
        else {
            Write-Information "$($ExternalIdentitySources | Format-List | Out-String)"
            Write-Information "An identity source already exists, but not for this domain. Continuing to add this one..."
        }
    }
    else {
        Write-Host "No existing external identity sources found."
    }

    $Password = $Credential.GetNetworkCredential().Password
    $DestinationFileArray = @()
    $remoteComputers = , $PrimaryUrl
    if ($PSBoundParameters.ContainsKey('SecondaryUrl')) {
        $remoteComputers += $SecondaryUrl
    }

    # check the connection between domain servers and the vcenter
    foreach ($computerUrl in $remoteComputers) {
        $ResultUrl = Assert-ADServerURL $computerUrl
        # dns lookup
        try {
            $Command = 'nslookup ' + $ResultUrl.Host + ' -type=soa'
            $SSHRes = Invoke-SSHCommand -Command $Command -SSHSession $SSH_Sessions['VC'].Value
            if ($SSHRes.ExitStatus -ne 0) { throw "$($SSHRes.Output)" }
            $IPAddress = $SSHRes.Output | Select-String "Address:" | Where-Object { $_ -notmatch "#" } | ForEach-Object { $_.ToString().Split()[1] } | Select-Object -First 1
            if (-Not ($IPAddress -as [ipaddress])) { throw "The FQDN $($ResultUrl.Host) failed to resolved to an IP address or incorrect IP format. Make sure DNS is configured correctly." }
        }
        catch {
            throw "The FQDN $($ResultUrl.Host) cannot be resolved to an IP address. Make sure DNS is configured. $_"
        }
        Write-Host "The FQDN $($ResultUrl.Host) is resolved successfully."
        # reverse dns lookup
        try {
            $Command = 'nslookup ' + $IPAddress
            $SSHRes = Invoke-SSHCommand -Command $Command -SSHSession $SSH_Sessions['VC'].Value
            if ($SSHRes.ExitStatus -ne 0) { throw "The FQDN $($ResultUrl.Host) is resolved successfully but the IP address $($IPAddress) does not have a corresponding DNS PTR (pointer) record, which is used for reverse DNS lookups. Make sure DNS is configured. $($SSHRes.Output)" }
        }
        catch {
            Write-Warning "The FQDN $($ResultUrl.Host) failed to do a reverse DNS lookup. $_"
	    Write-Warning "For reverse lookup to work, DEFAULT zone in NSX-T DNS forwarder must be set to query a DNS server that can resolve reverse DNS lookup of $($ResultUrl.Host)"
            Write-Warning "Reverse lookup may not be required for LDAPS configuration."
        }
        # check whether a specific port (or range of ports) on a target ip address is open or closed
        try {
            $Command = 'nc -nvz ' + $IPAddress + ' ' + $ResultUrl.Port
            $SSHRes = Invoke-SSHCommand -Command $Command -SSHSession $SSH_Sessions['VC'].Value
            if ($SSHRes.ExitStatus -ne 0) { throw "$($SSHRes.Output)" }
        }
        catch {
            throw "The connection cannot be established. Please check the address, routing and/or firewall and make sure port $($ResultUrl.Port) is open. $_"
        }
        Write-Host "Connectivity to $($ResultUrl.Host):$($ResultUrl.Port) is verified."
    }

    if ($PSBoundParameters.ContainsKey('SSLCertificatesSasUrl')) {
        $DestinationFileArray = Get-Certificates -SSLCertificatesSasUrl $SSLCertificatesSasUrl -ErrorAction Stop
    }
    else {
        $DestinationFileArray = Get-CertificateFromServerToLocalFile $remoteComputers
    }

    [System.Array]$Certificates =
    foreach ($certFile in $DestinationFileArray) {
        try {
            New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($certfile)
        }
        catch {
            Write-Error "Failure to convert file $certfile to a certificate $($PSItem.Exception.Message)"
            throw "File to certificate conversion failed. See error message for more details"
        }
    }
    # check if the certicates expire or not
    foreach ($cert in $Certificates) {
        $currentDate = Get-Date
        Write-Host "Verifying certificate: $($cert.Subject)"
        if (($cert.NotBefore -lt $currentDate) -and ($cert.NotAfter -gt $currentDate)) {
            Write-Host "The certificate is current."
        } else {
            Write-Error "The certificate is not current. It's only valid between $($cert.NotBefore) and $($cert.NotAfter)." -ErrorAction Stop
        }
    }

    Write-Host "Adding the LDAPS Identity Source..."
    try {
        Add-LDAPIdentitySource `
        -Name $Name `
        -DomainName $DomainName `
        -DomainAlias $DomainAlias `
        -PrimaryUrl $PrimaryUrl `
        -SecondaryUrl $SecondaryUrl `
        -BaseDNUsers $BaseDNUsers `
        -BaseDNGroups $BaseDNGroups `
        -Username $Credential.UserName `
        -Password $Password `
        -ServerType 'ActiveDirectory' `
        -Certificates $Certificates -ErrorAction Stop
    }
    catch {
        Write-Error "VCenter wasn't able to add this identity source: $_" -ErrorAction Stop
    }
    $ExternalIdentitySources = Get-IdentitySource -External -ErrorAction Continue
    $ExternalIdentitySources | Format-List | Out-String

    if ($PSBoundParameters.ContainsKey('GroupName')) {
        Write-Host "GroupName passed in: $GroupName"
        Write-Host "Attempting to add group $GroupName to CloudAdmins..."
        Add-GroupToCloudAdmins -GroupName $GroupName -Domain $DomainName -ErrorAction Stop
    }
}

<#
    .Synopsis
     Update the SSL Certificates used for authenticating to an Active Directory over LDAPS

    .Parameter DomainName
     Domain name of the external active directory, e.g. myactivedirectory.local

    .Parameter SSLCertificatesSasUrl
     A comma-delimeted string of the shared access signature (SAS) URLs linking to the certificates required to connect to the external active directory. If more than one, separate each SAS URL by a comma `,`.
#>
function Update-IdentitySourceCertificates {
    [CmdletBinding(PositionalBinding = $false)]
    [AVSAttribute(10, UpdatesSDDC = $false)]
    Param
    (
        [Parameter(
            Mandatory = $true,
            HelpMessage = 'Name of the Identity source')]
        [ValidateNotNull()]
        [string]
        $DomainName,

        [Parameter(
            Mandatory = $false,
            HelpMessage = 'Optional: The certs will be downloaded from domain controllers if not specified. A comma-delimited list of SAS path URI to Certificates for authentication. Ensure permissions to read included. To generate, place the certificates in any storage account blob and then right click the cert and generate SAS')]
        [System.Security.SecureString]
        $SSLCertificatesSasUrl
    )

    $ExternalIdentitySources = Get-IdentitySource -External -ErrorAction Stop
    if ($null -ne $ExternalIdentitySources) {
        $IdentitySource = $ExternalIdentitySources | Where-Object { $_.Name -eq $DomainName }
        if ($null -ne $IdentitySource) {
            if ($PSBoundParameters.ContainsKey('SSLCertificatesSasUrl')) {
                $DestinationFileArray = Get-Certificates $SSLCertificatesSasUrl -ErrorAction Stop
            }
            else {
                $remoteComputers = @()
                if ($null -ne $IdentitySource.PrimaryUrl) {
                    $remoteComputers += $IdentitySource.PrimaryUrl
                    Write-Host "* The Primary URL is  $($IdentitySource.PrimaryUrl)."
                }
                else {
                    Write-Error "Internal Error: The primary url of identity source is null." -ErrorAction Stop
                }

                if ($null -ne $IdentitySource.FailoverUrl) {
                    $remoteComputers += $IdentitySource.FailoverUrl
                    Write-Host "* The Failover URL is $($IdentitySource.FailoverUrl)."
                }
                $DestinationFileArray = Get-CertificateFromServerToLocalFile $remoteComputers
            }
            [System.Array]$Certificates =
            foreach ($CertFile in $DestinationFileArray) {
                try {
                    [System.Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromCertFile($certfile)
                }
                catch {
                    Write-Error "Failure to convert file $certfile to a certificate $($PSItem.Exception.Message)"
                    throw "File to certificate conversion failed. See error message for more details"
                }
            }
            Write-Host "Updating the LDAPS Identity Source..."
            Set-LDAPIdentitySource -IdentitySource $IdentitySource -Certificates $Certificates -ErrorAction Stop
            $ExternalIdentitySources = Get-IdentitySource -External -ErrorAction Continue
            $ExternalIdentitySources | Format-List | Out-String
        }
        else {
            Write-Error "Could not find Identity Source with name: $DomainName." -ErrorAction Stop
        }
    }
    else {
        Write-Host "No existing external identity sources found."
    }
}

<#
    .Synopsis
     Update the password used in the credential to authenticate an LDAP server
    .Parameter Credential
     Credential to login to the LDAP server (NOT cloudadmin) in the form of a username/password credential. Usernames often look like prodAdmins@domainname.com or if the AD is a Microsoft Active Directory server, usernames may need to be prefixed with the NetBIOS domain name, such as prod\AD_Admin

     .Parameter DomainName
     Domain name of the external LDAP server, e.g. myactivedirectory.local
#>
function Update-IdentitySourceCredential {
    [CmdletBinding(PositionalBinding = $false)]
    [AVSAttribute(10, UpdatesSDDC = $false)]
    Param
    (
        [Parameter(
            Mandatory = $true,
            HelpMessage = 'Name of the Identity source')]
        [ValidateNotNull()]
        [string]
        $DomainName,

        [Parameter(Mandatory = $true,
            HelpMessage = "Credential for the LDAP server")]
        [ValidateNotNull()]
        [System.Management.Automation.PSCredential]
        [System.Management.Automation.Credential()]
        $Credential
    )

    $ExternalIdentitySources = Get-IdentitySource -External -ErrorAction Stop
    if ($null -ne $ExternalIdentitySources) {
        $IdentitySource = $ExternalIdentitySources | Where-Object { $_.Name -eq $DomainName }
        if ($null -ne $IdentitySource) {
            Write-Host "Updating the LDAP Identity Source..."
            Set-LDAPIdentitySource -IdentitySource $IdentitySource -Credential $Credential -ErrorAction Stop
            $ExternalIdentitySources = Get-IdentitySource -External -ErrorAction Continue
            $ExternalIdentitySources | Format-List | Out-String
        }
        else {
            throw "Could not find Identity Source with name: $DomainName."
        }
    }
    else {
        throw "No existing external identity sources found."
    }
}

<#
    .Synopsis
     Gets all external identity sources
#>
function Get-ExternalIdentitySources {
    [AVSAttribute(3, UpdatesSDDC = $false)]
    Param()

    $ExternalSource = Get-IdentitySource -External
    if ($null -eq $ExternalSource) {
        Write-Output "No external identity sources found."
        return
    }
    else {
        Write-Output "LDAPs Certificate(s) valid until the [Not After] parameter"
        $ExternalSource | Format-List | Out-String
    }
}

<#
    .Synopsis
     Removes supplied identity source, or, if no specific identity source is provided, will remove all identity sources.

    .Parameter DomainName
     The domain name of the external identity source to remove i.e. `mydomain.com`. If none provided, will attempt to remove all external identity sources.
#>
function Remove-ExternalIdentitySources {
    [AVSAttribute(5, UpdatesSDDC = $false)]
    Param
    (
        [Parameter(Mandatory = $false)]
        [string]
        $DomainName
    )

    $ExternalSource = Get-IdentitySource -External
    if ($null -eq $ExternalSource) {
        Write-Output "No external identity sources found to remove. Nothing done"
        return
    }
    else {
        if (-Not ($PSBoundParameters.ContainsKey('DomainName'))) {
            foreach ($AD in $ExternalSource) {
                Remove-IdentitySource -IdentitySource $AD -ErrorAction Stop
                Write-Output "Identity source $($AD.Name) removed."
            }
        }
        else {
            $FoundMatch = $false
            foreach ($AD in $ExternalSource) {
                if ($AD.Name -eq $DomainName) {
                    Remove-IdentitySource -IdentitySource $AD -ErrorAction Stop
                    Write-Output "Identity source $($AD.Name) removed."
                    $FoundMatch = $true
                }
            }
            if (-Not $FoundMatch) { Write-Output "No external identity source found that matches $DomainName. Nothing done." }
        }
    }
}

<#
    .Synopsis
     Add a group from the external identity to the CloudAdmins group

    .Parameter GroupName
     The group in the customer external identity source to be added to CloudAdmins. Users in this group will have CloudAdmin access. Group name should be formatted without the domain name, e.g. group-to-give-access

    .Parameter Domain
     Name of the external domain that GroupName is in. If not provided, will attempt to locate the group in all the configured active directories. For example, MyActiveDirectory.Com

    .Example
    # Add the group named vsphere-admins to CloudAdmins
     Add-GroupToCloudAdmins -GroupName 'vsphere-admins'
#>
function Add-GroupToCloudAdmins {
    [CmdletBinding(PositionalBinding = $false)]
    [AVSAttribute(10, UpdatesSDDC = $false)]
    Param
    (
        [Parameter(
            Mandatory = $true,
            HelpMessage = 'Name of the group to add to CloudAdmin')]
        [ValidateNotNull()]
        [string]
        $GroupName,

        [Parameter(Mandatory = $false)]
        [string]
        $Domain
    )

    $ExternalSources
    $GroupToAdd
    $Domain

    try {
        $ExternalSources = Get-IdentitySource -External -ErrorAction Stop
    }
    catch {
        Write-Error $PSItem.Exception.Message -ErrorAction Continue
        Write-Error "Unable to get external identity source" -ErrorAction Stop
    }

    # Searching the external identities for the domain
    if ($null -eq $ExternalSources -or 0 -eq $ExternalSources.count) {
        Write-Error "No external identity source found. Please run New-LDAPSIdentitySource first" -ErrorAction Stop
    }
    elseif ($ExternalSources.count -eq 1) {
        if ($PSBoundParameters.ContainsKey('Domain')) {
            if ($Domain -ne $ExternalSources.Name) {
                Write-Error "The Domain passed in ($Domain) does not match the external directory: $($ExternalSources.Name). Try again with -Domain $($ExternalSources.Name)" -ErrorAction Stop
            }
        }
    }
    elseif ($ExternalSources.count -gt 1) {
        if (-Not ($PSBoundParameters.ContainsKey('Domain'))) {
            Write-Host "Multiple external identites exist and domain not suplied. Will attempt to search all ADs attached for $GroupName"
        }
        else {
            $FoundDomainMatch = $false
            foreach ($AD in $ExternalSources) {
                if ($AD.Name -eq $Domain) {
                    $FoundDomainMatch = $true
                    break
                }
            }
            if (-Not $FoundDomainMatch) {
                Write-Warning "Searched the External Directories: $($ExternalSources | Format-List | Out-String) for $Domain and did not find a match"
                Write-Error "Was not able to find $Domain in any of the External Directories" -ErrorAction Stop
            }
        }
    }

    # Searching for the group in the specified domain, if provided, or all domains, if none provided
    if ($null -eq $Domain -or -Not ($PSBoundParameters.ContainsKey('Domain'))) {
        $FoundMatch = $false
        foreach ($AD in $ExternalSources) {
            Write-Host "Searching $($AD.Name) for $GroupName"
            try {
                $GroupFound = Get-SsoGroup -Name $GroupName -Domain $AD.Name -ErrorAction Stop
            }
            catch {
                Write-Host "Could not find $GroupName in $($AD.Name). Continuing.."
            }
            if ($null -ne $GroupFound -and -Not $FoundMatch) {
                Write-Host "Found $GroupName in $($AD.Name)."
                $Domain = $AD.Name
                $GroupToAdd = $GroupFound
                $FoundMatch = $true
            }
            elseif ($null -ne $GroupFound -and $FoundMatch) {
                Write-Host "Found $GroupName in $($AD.Name) as well."
                Write-Error "Group $GroupName exists in multiple domains . Please re-run and specify domain" -ErrorAction Stop
                return
            }
            elseif ($null -eq $GroupFound) {
                Write-Host "$GroupName not found in $($AD.Name)"
            }
        }
        if ($null -eq $GroupToAdd) {
            Write-Error "$GroupName was not found in any external identity that has been configured. Please ensure that the group name is typed correctly." -ErrorAction Stop
        }
    }
    else {
        try {
            Write-Host "Searching $Domain for $GroupName..."
            $GroupToAdd = Get-SsoGroup -Name $GroupName -Domain $Domain -ErrorAction Stop
        }
        catch {
            Write-Error "Exception $($PSItem.Exception.Message): Unable to get group $GroupName from $Domain" -ErrorAction Stop
        }
    }

    if ($null -eq $GroupToAdd) {
        Write-Error "$GroupName was not found in the domain. Please ensure that the group is spelled correctly" -ErrorAction Stop
    }
    else {
        Write-Host "Adding $GroupToAdd to CloudAdmins...."
    }

    $CloudAdmins = Get-SsoGroup -Name 'CloudAdmins' -Domain 'vsphere.local'
    if ($null -eq $CloudAdmins) {
        Write-Error "Internal Error fetching CloudAdmins group. Contact support" -ErrorAction Stop
    }

    $GroupToAddTuple = [System.Tuple]::Create("$($GroupToAdd.Name)", "$($GroupToAdd.Domain)")
    $CloudAdminMembers = @()
    foreach ($a in $(Get-SsoGroup -Group $CloudAdmins)) { $tuple = [System.Tuple]::Create("$($a.Name)", "$($a.Domain)"); $CloudAdminMembers += $tuple }
    if ($GroupToAddTuple -in $CloudAdminMembers) {
        Write-Host "Group $($GroupToAddTuple.Item1)@$($($GroupToAddTuple.Item2)) has already been added to CloudAdmins."
        return
    }

    try {
        Write-Host "Adding group $GroupName to CloudAdmins..."
        Add-GroupToSsoGroup -Group $GroupToAdd -TargetGroup $CloudAdmins -ErrorAction Stop
    }
    catch {
        $CloudAdminMembers = Get-SsoGroup -Group $CloudAdmins -ErrorAction Continue
        Write-Warning "Cloud Admin Members: $CloudAdminMembers" -ErrorAction Continue
        Write-Error "Unable to add group to CloudAdmins. Error: $($PSItem.Exception.Message)" -ErrorAction Stop
    }

    Write-Host "Successfully added $GroupName to CloudAdmins."
    $CloudAdminMembers = Get-SsoGroup -Group $CloudAdmins -ErrorAction Continue
    Write-Output "Cloud Admin Members: $CloudAdminMembers"
}

<#
    .Synopsis
     Remove a previously added group from an external identity from the CloudAdmins group

    .Parameter GroupName
     The group in the customer external identity source to be removed from CloudAdmins. Group name should be formatted without the domain name, e.g. group-to-give-access

    .Parameter Domain
     Name of the external domain that GroupName is in. If not provided, will attempt to locate the group in all the configured active directories. For example, MyActiveDirectory.Com

    .Example
    # Remove the group named vsphere-admins from CloudAdmins
     Remove-GroupFromCloudAdmins -GroupName 'vsphere-admins'
#>
function Remove-GroupFromCloudAdmins {
    [CmdletBinding(PositionalBinding = $false)]
    [AVSAttribute(10, UpdatesSDDC = $false)]
    Param
    (
        [Parameter(
            Mandatory = $true,
            HelpMessage = 'Name of the group to remove from CloudAdmin')]
        [ValidateNotNull()]
        [string]
        $GroupName,

        [Parameter(Mandatory = $false)]
        [string]
        $Domain
    )

    $ExternalSources
    $GroupToRemove
    $Domain

    try {
        $ExternalSources = Get-IdentitySource -External -ErrorAction Stop
    }
    catch {
        Write-Error $PSItem.Exception.Message -ErrorAction Continue
        Write-Error "Unable to get external identity source" -ErrorAction Stop
    }

    # Searching the external identities for the domain
    if ($null -eq $ExternalSources -or 0 -eq $ExternalSources.count) {
        Write-Error "No external identity source found. Please run New-LDAPSIdentitySource first" -ErrorAction Stop
    }
    elseif ($ExternalSources.count -eq 1) {
        if ($PSBoundParameters.ContainsKey('Domain')) {
            if ($Domain -ne $ExternalSources.Name) {
                Write-Error "The Domain passed in ($Domain) does not match the external directory: $($ExternalSources.Name)" -ErrorAction Stop
            }
        }
    }
    elseif ($ExternalSources.count -gt 1) {
        if (-Not ($PSBoundParameters.ContainsKey('Domain'))) {
            Write-Host "Multiple external identites exist and domain not suplied. Will attempt to search all ADs attached for $GroupName"
        }
        else {
            $FoundDomainMatch = $false
            foreach ($AD in $ExternalSources) {
                if ($AD.Name -eq $Domain) {
                    $FoundDomainMatch = $true
                    break
                }
            }
            if (-Not $FoundDomainMatch) {
                Write-Warning "Searched the External Directories: $($ExternalSources | Format-List | Out-String) for $Domain and did not find a match"
                Write-Error "Was not able to find $Domain in any of the External Directories" -ErrorAction Stop
            }
        }
    }

    # Searching for the group in the specified domain, if provided, or all domains, if none provided
    if ($null -eq $Domain -or -Not ($PSBoundParameters.ContainsKey('Domain'))) {
        $FoundMatch = $false
        foreach ($AD in $ExternalSources) {
            Write-Host "Searching $($AD.Name) for $GroupName"
            try {
                $GroupFound = Get-SsoGroup -Name $GroupName -Domain $AD.Name -ErrorAction Stop
            }
            catch {
                Write-Host "Could not find $GroupName in $($AD.Name). Continuing.."
            }
            if ($null -ne $GroupFound -and -Not $FoundMatch) {
                Write-Host "Found $GroupName in $($AD.Name)."
                $Domain = $AD.Name
                $GroupToRemove = $GroupFound
                $FoundMatch = $true
            }
            elseif ($null -ne $GroupFound -and $FoundMatch) {
                Write-Host "Found $GroupName in $($AD.Name) as well."
                Write-Error "Group $GroupName exists in multiple domains . Please re-run and specify domain" -ErrorAction Stop
                return
            }
            elseif ($null -eq $GroupFound) {
                Write-Host "$GroupName not found in $($AD.Name)"
            }
        }
        if ($null -eq $GroupToRemove) {
            Write-Error "$GroupName was not found in any external identity that has been configured. Please ensure that the group name is typed correctly." -ErrorAction Stop
        }
    }
    else {
        try {
            Write-Host "Searching $Domain for $GroupName..."
            $GroupToRemove = Get-SsoGroup -Name $GroupName -Domain $Domain -ErrorAction Stop
        }
        catch {
            Write-Error "Exception $($PSItem.Exception.Message): Unable to get group $GroupName from $Domain" -ErrorAction Stop
        }
    }

    if ($null -eq $GroupToRemove) {
        Write-Error "$GroupName was not found in $Domain. Please ensure that the group is spelled correctly" -ErrorAction Stop
    }
    else {
        Write-Host "Removing $GroupToRemove from CloudAdmins...."
    }

    $CloudAdmins = Get-SsoGroup -Name 'CloudAdmins' -Domain 'vsphere.local'
    if ($null -eq $CloudAdmins) {
        Write-Error "Internal Error fetching CloudAdmins group. Contact support" -ErrorAction Stop
    }

    try {
        Remove-GroupFromSsoGroup -Group $GroupToRemove -TargetGroup $CloudAdmins -ErrorAction Stop
    }
    catch {
        $CloudAdminMembers = Get-SsoGroup -Group $CloudAdmins -ErrorAction Continue
        Write-Error "Current Cloud Admin Members: $CloudAdminMembers" -ErrorAction Continue
        Write-Error "Unable to remove group from CloudAdmins. Is it there at all? Error: $($PSItem.Exception.Message)" -ErrorAction Stop
    }

    Write-Information "Group $GroupName successfully removed from CloudAdmins."
    $CloudAdminMembers = Get-SsoGroup -Group $CloudAdmins -ErrorAction Continue
    Write-Output "Current Cloud Admin Members: $CloudAdminMembers"
}

<#
    .Synopsis
     Get all groups that have been added to the cloud admin group
    .Example
    # Get all users in CloudAdmins
     Get-CloudAdminGroups
#>
function Get-CloudAdminGroups {
    [CmdletBinding(PositionalBinding = $false)]
    [AVSAttribute(3, UpdatesSDDC = $false)]
    Param()

    $CloudAdmins = Get-SsoGroup -Name 'CloudAdmins' -Domain 'vsphere.local'
    if ($null -eq $CloudAdmins) {
        Write-Error "Internal Error fetching CloudAdmins group. Contact support" -ErrorAction Stop
    }

    $CloudAdminMembers = Get-SsoGroup -Group $CloudAdmins -ErrorAction Stop
    if ($null -eq $CloudAdminMembers) {
        Write-Output "No groups yet added to CloudAdmin."
    }
    else {
        $CloudAdminMembers | Format-List | Out-String
    }
}

<#
    .Synopsis
     Gets all the vSAN based storage policies available to set on a VM.
#>
function Get-StoragePolicies {
    [AVSAttribute(3, UpdatesSDDC = $False)]
    Param()

    $StoragePolicies
    try {
        $StoragePolicies = Get-SpbmStoragePolicy -Namespace "VSAN" -ErrorAction Stop | Select-Object Name, AnyOfRuleSets
    }
    catch {
        Write-Error $PSItem.Exception.Message -ErrorAction Continue
        Write-Error "Unable to get storage policies" -ErrorAction Stop
    }
    if ($null -eq $StoragePolicies) {
        Write-Host "Could not find any storage policies."
    }
    else {
        Write-Output "Available Storage Policies:"
        $StoragePolicies | Format-List | Out-String
    }
}

<#
    .Synopsis
     Modify vSAN based storage policies on a VM(s)

    .Parameter StoragePolicyName
     Name of a vSAN based storage policy to set on the specified VM. Options can be seen in vCenter or using the Get-StoragePolicies command.

    .Parameter VMName
     Name of the VM to set the vSAN based storage policy on. This supports wildcards for bulk operations. For example, MyVM* would attempt to change the storage policy on MyVM1, MyVM2, MyVM3, etc.

    .Example
    # Set the vSAN based storage policy on MyVM to RAID-1 FTT-1
    Set-VMStoragePolicy -StoragePolicyName "RAID-1 FTT-1" -VMName "MyVM"
#>
function Set-VMStoragePolicy {
    [CmdletBinding(PositionalBinding = $false)]
    [AVSAttribute(10, UpdatesSDDC = $True)]
    Param
    (
        [Parameter(
            Mandatory = $true,
            HelpMessage = 'Name of the storage policy to set')]
        [ValidateNotNullOrEmpty()]
        [string]
        $StoragePolicyName,

        [Parameter(
            Mandatory = $true,
            HelpMessage = 'Name of the VM to set the storage policy on')]
        [ValidateNotNullOrEmpty()]
        [string]
        $VMName
    )
    $StoragePolicy, $VSANStoragePolicies = Get-StoragePolicyInternal $StoragePolicyName -ErrorAction Stop
    $VMList = Get-VM $VMName

    if ($null -eq $VMList) {
        Write-Error "Was not able to set the storage policy on the VM. Could not find VM(s) with the name: $VMName" -ErrorAction Stop
    }
    elseif ($VMList.count -eq 1) {
        $VM = $VMList[0]
        Set-StoragePolicyOnVM -VM $VM -VSANStoragePolicies $VSANStoragePolicies -StoragePolicy $StoragePolicy -ErrorAction Stop
    }
    else {
        foreach ($VM in $VMList) {
            Set-StoragePolicyOnVM -VM $VM -VSANStoragePolicies $VSANStoragePolicies -StoragePolicy $StoragePolicy -ErrorAction Continue
        }
    }
}

<#
    .Synopsis
     Modify vSAN based storage policies on all VMs in a Container

    .Parameter StoragePolicyName
     Name of a vSAN based storage policy to set on the specified VM. Options can be seen in vCenter or using the Get-StoragePolicies command.

    .Parameter Location
     Name of the Folder, ResourcePool, or Cluster containing the VMs to set the storage policy on.
     For example, if you would like to change the storage policy of all the VMs in the cluster "Cluster-2", then supply "Cluster-2".
     Similarly, if you would like to change the storage policy of all the VMs in a folder called "MyFolder", supply "MyFolder"

    .Example
    # Set the vSAN based storage policy on all VMs in MyVMs to RAID-1 FTT-1
    Set-LocationStoragePolicy -StoragePolicyName "RAID-1 FTT-1" -Location "MyVMs"
#>
function Set-LocationStoragePolicy {
    [CmdletBinding(PositionalBinding = $false)]
    [AVSAttribute(10, UpdatesSDDC = $True)]
    Param
    (
        [Parameter(
            Mandatory = $true,
            HelpMessage = 'Name of the storage policy to set')]
        [ValidateNotNullOrEmpty()]
        [string]
        $StoragePolicyName,

        [Parameter(
            Mandatory = $true,
            HelpMessage = 'Name of the Folder, ResourcePool, or Cluster containing the VMs to set the storage policy on.')]
        [ValidateNotNullOrEmpty()]
        [string]
        $Location
    )
    $StoragePolicy, $VSANStoragePolicies = Get-StoragePolicyInternal $StoragePolicyName -ErrorAction Stop
    $VMList = Get-VM -Location $Location

    if ($null -eq $VMList) {
        Write-Error "Was not able to set storage policies. Could not find VM(s) in the container: $Location" -ErrorAction Stop
    }
    else {
        foreach ($VM in $VMList) {
            Set-StoragePolicyOnVM -VM $VM -VSANStoragePolicies $VSANStoragePolicies -StoragePolicy $StoragePolicy -ErrorAction Continue
        }
    }
}

<#
    .Synopsis
     Specify default storage policy for a cluster(s)

    .Parameter StoragePolicyName
     Name of a vSAN based storage policy to set to be the default for VMs on this cluster. Options can be seen in vCenter or using the Get-StoragePolicies command.

    .Parameter ClusterName
     Name of the cluster to set the default on. This supports wildcards for bulk operations. For example, MyCluster* would attempt to change the storage policy on MyCluster1, MyCluster2, etc.

    .Example
    # Set the default vSAN based storage policy on MyCluster to RAID-1 FTT-1
    Set-ClusterDefaultStoragePolicy -StoragePolicyName "RAID-1 FTT-1" -ClusterName "MyCluster"
#>
function Set-ClusterDefaultStoragePolicy {
    [CmdletBinding(PositionalBinding = $false)]
    [AVSAttribute(10, UpdatesSDDC = $True)]
    Param
    (
        [Parameter(
            Mandatory = $true,
            HelpMessage = 'Name of the storage policy to set')]
        [ValidateNotNullOrEmpty()]
        [string]
        $StoragePolicyName,

        [Parameter(
            Mandatory = $true,
            HelpMessage = 'Name of the Cluster to set the storage policy on')]
        [ValidateNotNullOrEmpty()]
        [string]
        $ClusterName
    )
    $StoragePolicy, $VSANStoragePolicies = Get-StoragePolicyInternal $StoragePolicyName
    $CompatibleDatastores = Get-SpbmCompatibleStorage -StoragePolicy $StoragePolicy
    $ClusterList = Get-Cluster $ClusterName
    if ($null -eq $ClusterList) {
        Write-Error "Could not find Cluster with the name $ClusterName." -ErrorAction Stop
    }

    $ClusterDatastores = $ClusterList | Get-VMHost | Get-Datastore

    if ($null -eq $ClusterDatastores) {
        $hosts = $ClusterList | Get-VMHost
        if ($null -eq $hosts) {
            Write-Error "Was not able to set the Storage policy on $ClusterList. The Cluster does not appear to have VM Hosts. Please add VM Hosts before setting storage policy" -ErrorAction Stop
        }
        else {
            Write-Error "Setting the Storage Policy on this Cluster is not supported." -ErrorAction Stop
        }
    }
    elseif ($ClusterDatastores.count -eq 1) {
        if ($ClusterDatastores[0] -in $CompatibleDatastores) {
            try {
                Write-Host "Setting Storage Policy on $ClusterList to $StoragePolicyName..."
                Set-SpbmEntityConfiguration -Configuration (Get-SpbmEntityConfiguration $ClusterDatastores[0]) -storagePolicy $StoragePolicy -ErrorAction Stop -Confirm:$false
                Write-Output "Successfully set the Storage Policy on $ClusterList to $StoragePolicyName"
            }
            catch {
                Write-Error "Was not able to set the Storage Policy on the Cluster Datastore: $($PSItem.Exception.Message)" -ErrorAction Stop
            }
        }
        else {
            Write-Error "Modifying the default storage policy on this cluster: $($ClusterDatastores[0]) is not supported" -ErrorAction Stop
        }
    }
    else {
        foreach ($Datastore in $ClusterDatastores) {
            if ($Datastore -in $CompatibleDatastores) {
                try {
                    Write-Host "Setting Storage Policy on $Datastore to $StoragePolicyName..."
                    Set-SpbmEntityConfiguration -Configuration (Get-SpbmEntityConfiguration $Datastore) -storagePolicy $StoragePolicy -ErrorAction Stop -Confirm:$false
                    Write-Output "Successfully set the storage policy on $Datastore to $StoragePolicyName"
                }
                catch {
                    Write-Error "Was not able to set the storage policy on the Cluster Datastore: $($PSItem.Exception.Message)" -ErrorAction Stop
                }
            }
            else {
                Write-Error "Modifying the default storage policy on $Datastore is not supported" -ErrorAction Continue
                continue
            }
        }
    }
}

<#
    .Synopsis
     This will create a folder on each cluster's vSAN datastore -- GuestStore and set each cluster to pull tools from their respective vsan datastore. The 'gueststore-vmtools' file is required.
     The Tools zip file must be in a publicly available HTTP(S) downloadable location.

     .EXAMPLE
     Once the function is imported, you simply need to run Set-ToolsRepo -ToolsURL <url to tools zip file>
#>
function Set-ToolsRepo {
    [AVSAttribute(30, UpdatesSDDC = $false)]
    param(
        [Parameter(Mandatory = $true,
            HelpMessage = 'A publicly available HTTP(S) URL to download the Tools zip file.')]
        [String]
        $Tools_URL
    )

    # Tools repo folder
    $new_folder = 'GuestStore'
    # To check for existing tools versions
    $archive_path = '/vmware/apps/vmtools/windows64/'

    # Make new directory to store and expand the zip file
    $tmp_dir = New-Item -Path "./newtools" -ItemType Directory
    $tools_file = "$tmp_dir/tools.zip"
    # Download the new tools files
    Invoke-WebRequest -Uri $tools_url -OutFile $tools_file -ErrorAction Stop
    Expand-Archive -Path $tools_file -DestinationPath $tmp_dir -ErrorAction Stop

    $tools_path_new = "${tmp_dir}${archive_path}vmtools-*"
    $tools_version = (Get-ChildItem -Path $tools_path_new -Directory).name
    if ( $nill -eq $tools_version ) {
        Write-Error -Message 'Unable to find new tools files. Is this a GuestStore bundle?'
        throw 'Unable to find new tools files'
    }

    $tools_short_version = $tools_version -replace 'vmtools-', ''

    # Get all vSAN datastores
    $datastores = Get-Datastore -ErrorAction Stop | Where-Object { $_.extensionData.Summary.Type -eq 'vsan' }

    if ( $nill -eq $datastores ) {
        Write-Error -Message 'No VSAN datastores found'
        throw 'No VSAN datastores found'
    }

    foreach ($datastore in $datastores) {
        # In case one is left over
        Remove-PSDrive -Name DS -Confirm:$false -ErrorAction SilentlyContinue | Out-Null

        # Get datastore name
        $ds_name = $datastore.Name

        # Get ID of the vsanDatastore requested
        $ds_id = Get-Datastore -Name $ds_name | Select-Object -Property Id

        # Create the PS drive
        New-PSDrive -Location $datastore -Name DS -PSProvider VimDatastore -Root '\' | Out-Null

        # Does repo folder exist?
        $Dsbrowser = Get-View -Id $Datastore.Extensiondata.Browser
        $spec = New-Object VMware.Vim.HostDatastoreBrowserSearchSpec
        $spec.Query += New-Object VMware.Vim.FolderFileQuery
        $folderObj = ($dsBrowser.SearchDatastore("[$ds_name] \", $spec)).File | Where-Object { $_.FriendlyName -eq $new_folder }

        # If not, create it
        If ($nil -eq $folderObj) {
            New-Item -ItemType Directory -Path "DS:/$new_folder"
            # Recheck
            $folderObj = ($dsBrowser.SearchDatastore("[$ds_name] \", $spec)).File | Where-Object { $_.FriendlyName -eq $new_folder }
            If ($nil -eq $folderObj) {
                Write-Error -Message "Folder creation failed on $ds_name"
                throw "Folder creation failed on $ds_name"
            }
            else {
                Write-Information "Folder creation successful on $ds_name"
            }
        }

        # See what Tools versions are already present
        $existing_dirs = Get-ChildItem "DS:/$new_folder/$archive_path"
        $do_not_copy = $false
        foreach ($existing_dir in $existing_dirs) {
            if ( $existing_dir.GetType() -match 'folder') {
                $ver = $existing_dir.Name -replace 'vmtools-', ''
                $tools_older_version = ($ver -ge $tools_short_version) ? $ver : $nil
                if ($nil -ne $tools_older_version) {
                    $do_not_copy = $true
                }
            }
        }

        # If there is a newer version already present, skip the copy
        if ($do_not_copy) {
            Write-Information "Skipping copy of $tools_version to $ds_name as there is a newer version already present" -InformationAction Continue
        }
        else {
            Write-Information "Copying $tools_version to $ds_name"
            Copy-DatastoreItem -Item "./${tools_version}/*" "DS:/$new_folder" -Recurse -Force
        }

        # Reset the do_not_copy flag
        $do_not_copy = $false

        # Remove the PS drive
        Remove-PSDrive -Name DS -Confirm:$false

        $url = ($datastore.ExtensionData.Summary.Url) + "$new_folder"

        # Get all hosts that have this vSAN datastore mounted
        $vmhosts = Get-VMHost | Where-Object { $_.ExtensionData.Datastore.value -eq ($ds_id.Id).Split('-', 2)[1] }
        if ($nil -eq $vmhosts) {
            Write-Error -Message "No hosts found for datastore $ds_name"
            throw "No hosts found for datastore $ds_name"
        }

        foreach ( $vmhost in $vmhosts ) {
            $esxcli = Get-EsxCli -V2 -VMHost $vmhost
            Write-Information "Setting the GuestStore repository setting for host: $vmhost"
            $arguments = $esxcli.system.settings.gueststore.repository.set.CreateArgs()
            $arguments.url = $Url
            $esxcli.system.settings.gueststore.repository.set.invoke($arguments)
        }
    }
}

<#
.Synopsis
    Set vSAN compression and deduplication on a cluster or clusters. If deduplication is enabled then compression is required.
    The default cluster configuration is deduplication and compression but the customer can change that.
    Choosing neither compression nor deduplication will disable both.
    This requires action on every physical disk and will take time to complete.
.EXAMPLE
    Set-vSANCompressDedupe -ClustersToChange "cluster-1,cluster-2" -Compression $true
    Set-vSANCompressDedupe -ClustersToChange "cluster-1,cluster-2" -Deduplication $true
    Set-vSANCompressDedupe -ClustersToChange "cluster-1,cluster-2"
    Set-vSANCompressDedupe -ClustersToChange "*"
#>
function Set-vSANCompressDedupe {
    [AVSAttribute(60, UpdatesSDDC = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [String]$ClustersToChange,
        [Parameter(Mandatory = $false,
            HelpMessage = "Enable compression and deduplication.")]
        [bool]$Deduplication,
        [Parameter(Mandatory = $false,
            HelpMessage = "Enable compression only.")]
        [bool]$Compression
    )

    # $cluster is an array of cluster names or "*""
    foreach ($cluster_each in ($ClustersToChange.split(",", [System.StringSplitOptions]::RemoveEmptyEntries)).Trim()) {
        $Clusters += Get-Cluster -Name $cluster_each
    }

    foreach ($Cluster in $Clusters) {
        $cluster_name = $Cluster.Name

        If ($Deduplication) {
            # Deduplication requires compression
            Write-Host "Enabling deduplication and compression on $cluster_name"
            Set-VsanClusterConfiguration -Configuration $cluster_name -SpaceEfficiencyEnabled $true
        }
        elseif ($Compression) {
            # Compression only
            Write-Host "Enabling compression on $cluster_name"
            Set-VsanClusterConfiguration -Configuration $cluster_name -SpaceCompressionEnabled $true
        }
        else {
            # Disable both
            Write-Host "Disabling deduplication and compression on $cluster_name"
            Set-VsanClusterConfiguration -Configuration $cluster_name -SpaceEfficiencyEnabled $false
        }
    }
}

Function Remove-AVSStoragePolicy {
    <#
    .DESCRIPTION
        This function removes a storage policy.
    .PARAMETER Name
        Name of Storage Policy. Wildcards are not supported and will be stripped.
    .EXAMPLE
        Remove-AVSStoragePolicy -Name "Encryption"
    #>

    [CmdletBinding()]
    [AVSAttribute(10, UpdatesSDDC = $false)]
    param (
        [Parameter(Mandatory = $true)]
        [string]
        $Name
    )
    Begin {
        #Remove Wildcards characters from Name
        $Name = Limit-WildcardsandCodeInjectionCharacters $Name
        #Protected Policy Object Name Validation Check
        If (Test-AVSProtectedObjectName -Name $Name) {
            Write-Error "$Name is a protected policy name.  Please choose a different policy name."
            return
        }

    }
    Process {
        #Get Storage Policy
        $StoragePolicy = Get-SpbmStoragePolicy -Name $Name -ErrorAction SilentlyContinue
        #Remove Storage Policy
        If ([string]::IsNullOrEmpty($StoragePolicy)) {
            Write-Error "Storage Policy $Name does not exist."
            return
        }
        Else { Remove-SpbmStoragePolicy -StoragePolicy $StoragePolicy -Confirm:$false }

    }
}

Function New-AVSStoragePolicy {
    <#
	.DESCRIPTION
		This function creates a new or overwrites an existing vSphere Storage Policy.
        Non vSAN-Based, vSAN Only, VMEncryption Only, Tag Only based and/or any combination of these policy types are supported.
    .PARAMETER Name
        Name of Storage Policy - Wildcards are not allowed and will be stripped.
    .PARAMETER Description
        Description of Storage Policy you are creating, free form text.
    .PARAMETER vSANSiteDisasterTolerance
        Default is "None"
        Valid Values are "None", "Dual", "Preferred", "Secondary", "NoneStretch"
        None = No Site Redundancy (Recommended Option for Non-Stretch Clusters, NOT recommended for Stretch Clusters)
        Dual = Dual Site Redundancy (Recommended Option for Stretch Clusters)
        Preferred = No site redundancy - keep data on Preferred (stretched cluster)
        Secondary = No site redundancy -  Keep data on Secondary Site (stretched cluster)
        NoneStretch = No site redundancy - Not Recommended (https://kb.vmware.com/s/article/88358)
        Only valid for stretch clusters.
    .PARAMETER vSANFailuresToTolerate
        Default is "R1FTT1"
        Valid values are "None", "R1FTT1", "R1FTT2", "R1FTT3", "R5FTT1", "R6FTT2", "R1FTT3"
        None = No Data Redundancy
        R1FTT1 = 1 failure - RAID-1 (Mirroring)
        R1FTT2 = 2 failures - RAID-1 (Mirroring)
        R1FTT3 = 3 failures - RAID-1 (Mirroring)
        R5FTT1 = 1 failure - RAID-5 (Erasure Coding)
        R6FTT2 = 2 failures - RAID-6 (Erasure Coding)
        No Data Redundancy options are not covered under Microsoft SLA.
    .PARAMETER VMEncryption
        Default is None.  Valid values are None, PreIO, PostIO.
        PreIO allows VAIO filtering solutions to capture data prior to VM encryption.
        PostIO allows VAIO filtering solutions to capture data after VM encryption.
    .PARAMETER vSANObjectSpaceReservation
        Default is 0.  Valid values are 0..100
        Object Reservation.  0=Thin Provision, 100=Thick Provision
    .PARAMETER vSANDiskStripesPerObject
        Default is 1.  Valid values are 1..12.
        The number of HDDs across which each replica of a storage object is striped.
        A value higher than 1 may result in better performance (for e.g. when flash read cache misses need to get serviced from HDD), but also results in higher use of system resources.
    .PARAMETER vSANIOLimit
        Default is unset. Valid values are 0..2147483647
        IOPS limit for the policy.
    .PARAMETER vSANCacheReservation
        Default is 0. Valid values are 0..100
        Percentage of cache reservation for the policy.
	.PARAMETER vSANChecksumDisabled
        Default is $false. Enable or disable checksum for the policy. Valid values are $true or $false.
        WARNING - Disabling checksum may lead to data LOSS and/or corruption.
        Recommended value is $false.
    .PARAMETER vSANForceProvisioning
        Default is $false. Force provisioning for the policy. Valid values are $true or $false.
        WARNING - vSAN Force Provisioned Objects are not covered under Microsoft SLA.  Data LOSS and vSAN instability may occur.
        Recommended value is $false.
    .PARAMETER Tags
        Match to datastores that do have these tags.  Tags are case sensitive.
        Comma seperate multiple tags. Example: Tag1,Tag 2,Tag_3
    .PARAMETER NotTags
        Match to datastores that do NOT have these tags. Tags are case sensitive.
        Comma seperate multiple tags. Example: Tag1,Tag 2,Tag_3
    .PARAMETER Overwrite
        Overwrite existing Storage Policy.  Default is $false.
        Passing overwrite true provided will overwrite an existing policy exactly as defined.
        Those values not passed will be removed or set to default values.
    .EXAMPLE
        Creates a new storage policy named Encryption with that enables Pre-IO filter VM encryption
        New-AVSStoragePolicy -Name "Encryption" -VMEncryption "PreIO"
    .EXAMPLE
        Creates a new storage policy named "RAID-1 FTT-1 with Pre-IO VM Encryption" with a description enabled for Pre-IO VM Encryption
        New-AVSStoragePolicy -Name "RAID-1 FTT-1 with Pre-IO VM Encryption" -Description "My super secure and performant storage policy" -VMEncryption "PreIO" -vSANFailuresToTolerate "1 failure - RAID-1 (Mirroring)"
    .EXAMPLE
        Creates a new storage policy named "Tagged Datastores" to use datastores tagged with "SSD" and "NVMe" and not datastores tagged "Slow"
        New-AVSStoragePolicy -Name "Tagged Datastores" -Tags "SSD","NVMe" -NotTags "Slow"
    .EXAMPLE
        Creates a new storage policy named "Production Only" to use datastore tagged w/ Production and not tagged w/ Test or Dev.  Set with RAID-1, 100% read cache, and Thick Provisioning of Disk.
        New-AVSStoragePolicy -Name "Production Only" -Tags "Production" -NotTags "Test","Dev" -vSANFailuresToTolerate "1 failure - RAID-1 (Mirroring)" -vSANObjectSpaceReservation 100 -vSANCacheReservation 100
    .EXAMPLE
        Passing -Overwrite:$true to any examples provided will overwrite an existing policy exactly as defined.  Those values not passed will be removed or set to default values.
        #>
    [CmdletBinding()]
    [AVSAttribute(10, UpdatesSDDC = $false)]
    param(
        #Add parameterSetNames to allow for vSAN, Tags, VMEncryption, StorageIOControl, vSANDirect to be optional.
        [Parameter(Mandatory = $true)]
        [string]
        $Name,
        [Parameter(Mandatory = $false)]
        [string]
        $Description,
        [Parameter(Mandatory = $false)]
        [ValidateSet("None", "Dual", "Preferred", "Secondary", "NoneStretch")]
        [string]
        $vSANSiteDisasterTolerance,
        [Parameter(Mandatory = $false)]
        [ValidateSet("None", "R1FTT1", "R5FTT1", "R1FTT2", "R6FTT2", "R1FTT3")]
        [string]
        $vSANFailuresToTolerate,
        [Parameter(Mandatory = $false)]
        [ValidateSet("None", "PreIO", "PostIO")]
        [string]
        $VMEncryption = "None",
        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 100)]
        [int]
        $vSANObjectSpaceReservation,
        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 12)]
        [int]
        $vSANDiskStripesPerObject,
        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 2147483647)]
        [int]
        $vSANIOLimit,
        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 100)]
        [int]
        $vSANCacheReservation,
        [Parameter(Mandatory = $false)]
        [boolean]
        $vSANChecksumDisabled,
        [Parameter(Mandatory = $false)]
        [boolean]
        $vSANForceProvisioning,
        [Parameter(Mandatory = $false)]
        [string]
        $Tags,
        [Parameter(Mandatory = $false)]
        [string]
        $NotTags,
        [Parameter(Mandatory = $false)]
        [Boolean]
        $Overwrite

    )



    Begin {
        #Cleanup Wildcard and Code Injection Characters
        Write-Information "Cleaning up Wildcard and Code Injection Characters from Name value: $Name"
        $Name = Limit-WildcardsandCodeInjectionCharacters -String $Name
        Write-Information "Name value after cleanup: $Name"
        Write-Information "Cleaning up Wildcard and Code Injection Characters from Description value: $Description"
        If (![string]::IsNullOrEmpty($Description)) { $Description = Limit-WildcardsandCodeInjectionCharacters -String $Description }
        Write-Information "Description value after cleanup: $Description"

        #Protected Policy Object Name Validation Check
        If (Test-AVSProtectedObjectName -Name $Name) {
            Write-Error "$Name is a protected policy name.  Please choose a different policy name."
            break
        }

        #Check for existing policy
        $ExistingPolicy = Get-AVSStoragePolicy -Name $Name
        Write-Information ("Existing Policy: " + $ExistingPolicy.name)
        if ($ExistingPolicy -and !$Overwrite) {
            Write-Error "Storage Policy $Name already exists.  Set -Overwrite to $true to overwrite existing policy."
            break
        }
        if (!$ExistingPolicy -and $Overwrite) {
            Write-Error "Storage Policy $Name does not exist.  Set -Overwrite to $false to create new policy."
            break
        }
        Write-Information "Overwrite value set to: $Overwrite"
        Switch ($Overwrite) {
            $true {
                $pbmprofileresourcetype = new-object vmware.spbm.views.PbmProfileResourceType
                $pbmprofileresourcetype.ResourceType = "STORAGE" # No other known valid value.
                $profilespec = new-object VMware.Spbm.Views.PbmCapabilityProfileUpdateSpec
                $profilespec.Name = $Name
                $profilespec.Constraints = new-object vmware.spbm.views.PbmCapabilitySubProfileConstraints
                If (![string]::IsNullOrEmpty($Description)) { $profilespec.Description = $Description }
            }
            $false {
                $pbmprofileresourcetype = new-object vmware.spbm.views.PbmProfileResourceType
                $pbmprofileresourcetype.ResourceType = "STORAGE" # No other known valid value.
                $profilespec = new-object VMware.Spbm.Views.PbmCapabilityProfileCreateSpec
                $profilespec.ResourceType = $pbmprofileresourcetype
                $profilespec.Name = $Name
                $profilespec.Constraints = new-object vmware.spbm.views.PbmCapabilitySubProfileConstraints
                If (![string]::IsNullOrEmpty($Description)) { $profilespec.Description = $Description }
                $profilespec.Category = "REQUIREMENT" #Valid options are REQUIREMENT = vSAN Storage Policies or RESOURCE = ?? or DATA_SERVICE_POLICY = Common Storage Policies such encryption and storage IO.
                Write-Information "Profile Name set to: $($profilespec.Name)"
                Write-Information "Profile Category set to: $($profilespec.Category)"
            }
        }
        Write-Information "Getting SPBM Capabilities"
        $SPBMCapabilities = Get-AVSSPBMCapabilities
        Foreach ($Capability in $SPBMCapabilities) {
            Write-Information "SPBM Capability: NameSpace: $($Capability.NameSpace), SubCategory: $($Capability.SubCategory), CapabilityMetaData Count: $($Capability.CapabilityMetadata.Count)"
        }

        #vSAN Site Disaster Tolerance / Stretch Cluster specific configuration
        Write-Information "vSANSiteDisasterTolerance value set to: $vSANSiteDisasterTolerance"
        Switch ($vSANSiteDisasterTolerance) {
            "None" {
                #Left blank on purpose.  No additional configuration required.
            }
            "Dual" {
                $Subprofile = new-object VMware.Spbm.Views.PbmCapabilityInstance
                $Subprofile.Id = New-Object VMware.Spbm.Views.PbmCapabilityMetadataUniqueId
                $Subprofile.Id.Namespace = "VSAN"
                $Subprofile.Id.Id = "subFailuresToTolerate"
                $Subprofile.Constraint = New-Object VMware.Spbm.Views.PbmCapabilityConstraintInstance
                $Subprofile.Constraint[0].PropertyInstance = New-Object VMware.Spbm.Views.PbmCapabilityPropertyInstance
                $Subprofile.Constraint[0].PropertyInstance[0].id = $Subprofile.Id.Id
                $Subprofile.Constraint[0].PropertyInstance[0].value = 1
                If (($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "VSAN" }).count -eq 0) {
                    $profilespec.Constraints.SubProfiles += new-object VMware.Spbm.Views.PbmCapabilitySubProfile -Property @{"Name" = "VSAN" }
                    Write-Information "Added VSAN Subprofile to ProfileSpec"
                    ($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "VSAN" }).Capability += $subprofile
                }
                Else { ($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "VSAN" }).Capability += $subprofile }

                $Subprofile = new-object VMware.Spbm.Views.PbmCapabilityInstance
                $Subprofile.Id = New-Object VMware.Spbm.Views.PbmCapabilityMetadataUniqueId
                $Subprofile.Id.Namespace = "VSAN"
                $Subprofile.Id.Id = "locality"
                $Subprofile.Constraint = New-Object VMware.Spbm.Views.PbmCapabilityConstraintInstance
                $Subprofile.Constraint[0].PropertyInstance = New-Object VMware.Spbm.Views.PbmCapabilityPropertyInstance
                $Subprofile.Constraint[0].PropertyInstance[0].id = $Subprofile.Id.Id
                $Subprofile.Constraint[0].PropertyInstance[0].value = "None"
                ($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "VSAN" }).Capability += $subprofile
            }
            "Preferred" {
                $Subprofile = new-object VMware.Spbm.Views.PbmCapabilityInstance
                $Subprofile.Id = New-Object VMware.Spbm.Views.PbmCapabilityMetadataUniqueId
                $Subprofile.Id.Namespace = "VSAN"
                $Subprofile.Id.Id = "subFailuresToTolerate"
                $Subprofile.Constraint = New-Object VMware.Spbm.Views.PbmCapabilityConstraintInstance
                $Subprofile.Constraint[0].PropertyInstance = New-Object VMware.Spbm.Views.PbmCapabilityPropertyInstance
                $Subprofile.Constraint[0].PropertyInstance[0].id = $Subprofile.Id.Id
                $Subprofile.Constraint[0].PropertyInstance[0].value = 1
                If (($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "VSAN" }).count -eq 0) {
                    $profilespec.Constraints.SubProfiles += new-object VMware.Spbm.Views.PbmCapabilitySubProfile -Property @{"Name" = "VSAN" }
                    Write-Information "Added VSAN Subprofile to ProfileSpec"
                    ($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "VSAN" }).Capability += $subprofile
                }
                Else { ($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "VSAN" }).Capability += $subprofile }

                $Subprofile = new-object VMware.Spbm.Views.PbmCapabilityInstance
                $Subprofile.Id = New-Object VMware.Spbm.Views.PbmCapabilityMetadataUniqueId
                $Subprofile.Id.Namespace = "VSAN"
                $Subprofile.Id.Id = "locality"
                $Subprofile.Constraint = New-Object VMware.Spbm.Views.PbmCapabilityConstraintInstance
                $Subprofile.Constraint[0].PropertyInstance = New-Object VMware.Spbm.Views.PbmCapabilityPropertyInstance
                $Subprofile.Constraint[0].PropertyInstance[0].id = $Subprofile.Id.Id
                $Subprofile.Constraint[0].PropertyInstance[0].value = "Preferred Fault Domain"
                If (($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "VSAN" }).count -eq 0) {
                    $profilespec.Constraints.SubProfiles += new-object VMware.Spbm.Views.PbmCapabilitySubProfile -Property @{"Name" = "VSAN" }
                    Write-Information "Added VSAN Subprofile to ProfileSpec"
                    ($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "VSAN" }).Capability += $subprofile
                }
                Else { ($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "VSAN" }).Capability += $subprofile }
                $Description = $Description + " - Unreplicated objects in a stretch cluster are unprotected by Microsoft SLA and data loss/corruption may occur."
                Write-Warning "$Name policy setting unreplicated objects in a stretch cluster are unprotected by Microsoft SLA and data loss/corruption may occur."
            }
            "Secondary" {
                $Subprofile = new-object VMware.Spbm.Views.PbmCapabilityInstance
                $Subprofile.Id = New-Object VMware.Spbm.Views.PbmCapabilityMetadataUniqueId
                $Subprofile.Id.Namespace = "VSAN"
                $Subprofile.Id.Id = "subFailuresToTolerate"
                $Subprofile.Constraint = New-Object VMware.Spbm.Views.PbmCapabilityConstraintInstance
                $Subprofile.Constraint[0].PropertyInstance = New-Object VMware.Spbm.Views.PbmCapabilityPropertyInstance
                $Subprofile.Constraint[0].PropertyInstance[0].id = $Subprofile.Id.Id
                $Subprofile.Constraint[0].PropertyInstance[0].value = 1
                If (($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "VSAN" }).count -eq 0) {
                    $profilespec.Constraints.SubProfiles += new-object VMware.Spbm.Views.PbmCapabilitySubProfile -Property @{"Name" = "VSAN" }
                    Write-Information "Added VSAN Subprofile to ProfileSpec"
                    ($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "VSAN" }).Capability += $subprofile
                }
                Else { ($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "VSAN" }).Capability += $subprofile }

                $Subprofile = new-object VMware.Spbm.Views.PbmCapabilityInstance
                $Subprofile.Id = New-Object VMware.Spbm.Views.PbmCapabilityMetadataUniqueId
                $Subprofile.Id.Namespace = "VSAN"
                $Subprofile.Id.Id = "locality"
                $Subprofile.Constraint = New-Object VMware.Spbm.Views.PbmCapabilityConstraintInstance
                $Subprofile.Constraint[0].PropertyInstance = New-Object VMware.Spbm.Views.PbmCapabilityPropertyInstance
                $Subprofile.Constraint[0].PropertyInstance[0].id = $Subprofile.Id.Id
                $Subprofile.Constraint[0].PropertyInstance[0].value = "Secondary Fault Domain"
                If (($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "VSAN" }).count -eq 0) {
                    $profilespec.Constraints.SubProfiles += new-object VMware.Spbm.Views.PbmCapabilitySubProfile -Property @{"Name" = "VSAN" }
                    Write-Information "Added VSAN Subprofile to ProfileSpec"
                }
                Else { ($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "VSAN" }).Capability += $subprofile }
                $Description = $Description + " - Unreplicated objects in a stretch cluster are unprotected by Microsoft SLA and data loss/corruption may occur."
                Write-Warning "$Name policy setting unreplicated objects in a stretch cluster are unprotected by Microsoft SLA and data loss/corruption may occur."
            }
            "NoneStretch" {
                $Subprofile = new-object VMware.Spbm.Views.PbmCapabilityInstance
                $Subprofile.Id = New-Object VMware.Spbm.Views.PbmCapabilityMetadataUniqueId
                $Subprofile.Id.Namespace = "VSAN"
                $Subprofile.Id.Id = "subFailuresToTolerate"
                $Subprofile.Constraint = New-Object VMware.Spbm.Views.PbmCapabilityConstraintInstance
                $Subprofile.Constraint[0].PropertyInstance = New-Object VMware.Spbm.Views.PbmCapabilityPropertyInstance
                $Subprofile.Constraint[0].PropertyInstance[0].id = $Subprofile.Id.Id
                $Subprofile.Constraint[0].PropertyInstance[0].value = 1
                If (($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "VSAN" }).count -eq 0) {
                    $profilespec.Constraints.SubProfiles += new-object VMware.Spbm.Views.PbmCapabilitySubProfile -Property @{"Name" = "VSAN" }
                    Write-Information "Added VSAN Subprofile to ProfileSpec"
                }
                Else { ($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "VSAN" }).Capability += $subprofile }

                $Subprofile = new-object VMware.Spbm.Views.PbmCapabilityInstance
                $Subprofile.Id = New-Object VMware.Spbm.Views.PbmCapabilityMetadataUniqueId
                $Subprofile.Id.Namespace = "VSAN"
                $Subprofile.Id.Id = "locality"
                $Subprofile.Constraint = New-Object VMware.Spbm.Views.PbmCapabilityConstraintInstance
                $Subprofile.Constraint[0].PropertyInstance = New-Object VMware.Spbm.Views.PbmCapabilityPropertyInstance
                $Subprofile.Constraint[0].PropertyInstance[0].id = $Subprofile.Id.Id
                $Subprofile.Constraint[0].PropertyInstance[0].value = "None"
                If (($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "VSAN" }).count -eq 0) {
                    $profilespec.Constraints.SubProfiles += new-object VMware.Spbm.Views.PbmCapabilitySubProfile -Property @{"Name" = "VSAN" }
                    Write-Information "Added VSAN Subprofile to ProfileSpec"
                    ($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "VSAN" }).Capability += $subprofile
                }
                Else { ($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "VSAN" }).Capability += $subprofile }
                $Description = $Description + " - Unreplicated objects in a stretch cluster are unprotected by Microsoft SLA and data loss/corruption may occur."
                Write-Warning "$Name policy setting unreplicated objects in a stretch cluster are unprotected by Microsoft SLA and data loss/corruption may occur."
            }
            Default {}
        }
        #vSANFailurestoTolerate / FTT
        Write-Information "vSANFailurestoTolerate value set to: $vSANFailuresToTolerate"
        Switch ($vSANFailuresToTolerate) {
            "None" {
                $Subprofile = new-object VMware.Spbm.Views.PbmCapabilityInstance
                $Subprofile.Id = New-Object VMware.Spbm.Views.PbmCapabilityMetadataUniqueId
                $Subprofile.Id.Namespace = "VSAN"
                $Subprofile.Id.Id = "hostFailuresToTolerate"
                $Subprofile.Constraint = New-Object VMware.Spbm.Views.PbmCapabilityConstraintInstance
                $Subprofile.Constraint[0].PropertyInstance = New-Object VMware.Spbm.Views.PbmCapabilityPropertyInstance
                $Subprofile.Constraint[0].PropertyInstance[0].id = $Subprofile.Id.Id
                $Subprofile.Constraint[0].PropertyInstance[0].value = 0
                If (($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "VSAN" }).count -eq 0) {
                    $profilespec.Constraints.SubProfiles += new-object VMware.Spbm.Views.PbmCapabilitySubProfile -Property @{"Name" = "VSAN" }
                    Write-Information "Added VSAN Subprofile to ProfileSpec"
                    ($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "VSAN" }).Capability += $subprofile
                }
                Else { ($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "VSAN" }).Capability += $subprofile }
                $Description = $Description + " - FTT 0 based policy objects are unprotected by Microsoft SLA and data loss/corruption may occur."
                Write-Warning "$Name policy setting $vSANFailurestoTolerate based policy objects are unprotected by Microsoft SLA and data loss/corruption may occur."
            }
            #TODO: Support this?
            "No Data redundancy with host affinity" {  }
            "R1FTT1" {
                $Subprofile = new-object VMware.Spbm.Views.PbmCapabilityInstance
                $Subprofile.Id = New-Object VMware.Spbm.Views.PbmCapabilityMetadataUniqueId
                $Subprofile.Id.Namespace = "VSAN"
                $Subprofile.Id.Id = "hostFailuresToTolerate"
                $Subprofile.Constraint = New-Object VMware.Spbm.Views.PbmCapabilityConstraintInstance
                $Subprofile.Constraint[0].PropertyInstance = New-Object VMware.Spbm.Views.PbmCapabilityPropertyInstance
                $Subprofile.Constraint[0].PropertyInstance[0].id = $Subprofile.Id.Id
                $Subprofile.Constraint[0].PropertyInstance[0].value = 1
                If (($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "VSAN" }).count -eq 0) {
                    $profilespec.Constraints.SubProfiles += new-object VMware.Spbm.Views.PbmCapabilitySubProfile -Property @{"Name" = "VSAN" }
                    Write-Information "Added VSAN Subprofile to ProfileSpec"
                    ($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "VSAN" }).Capability += $subprofile
                }
                Else { ($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "VSAN" }).Capability += $subprofile }

                $Subprofile = new-object VMware.Spbm.Views.PbmCapabilityInstance
                $Subprofile.Id = New-Object VMware.Spbm.Views.PbmCapabilityMetadataUniqueId
                $Subprofile.Id.Namespace = "VSAN"
                $Subprofile.Id.Id = "replicaPreference"
                $Subprofile.Constraint = New-Object VMware.Spbm.Views.PbmCapabilityConstraintInstance
                $Subprofile.Constraint[0].PropertyInstance = New-Object VMware.Spbm.Views.PbmCapabilityPropertyInstance
                $Subprofile.Constraint[0].PropertyInstance[0].id = $Subprofile.Id.Id
                $Subprofile.Constraint[0].PropertyInstance[0].value = "RAID-1 (Mirroring) - Performance"
                ($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "VSAN" }).Capability += $subprofile
            }
            "R5FTT1" {
                $Subprofile = new-object VMware.Spbm.Views.PbmCapabilityInstance
                $Subprofile.Id = New-Object VMware.Spbm.Views.PbmCapabilityMetadataUniqueId
                $Subprofile.Id.Namespace = "VSAN"
                $Subprofile.Id.Id = "hostFailuresToTolerate"
                $Subprofile.Constraint = New-Object VMware.Spbm.Views.PbmCapabilityConstraintInstance
                $Subprofile.Constraint[0].PropertyInstance = New-Object VMware.Spbm.Views.PbmCapabilityPropertyInstance
                $Subprofile.Constraint[0].PropertyInstance[0].id = $Subprofile.Id.Id
                $Subprofile.Constraint[0].PropertyInstance[0].value = 1
                If (($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "VSAN" }).count -eq 0) {
                    $profilespec.Constraints.SubProfiles += new-object VMware.Spbm.Views.PbmCapabilitySubProfile -Property @{"Name" = "VSAN" }
                    Write-Information "Added VSAN Subprofile to ProfileSpec"
                    ($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "VSAN" }).Capability += $subprofile
                }
                Else { ($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "VSAN" }).Capability += $subprofile }

                Write-Information "Profilespec: $($profilespec | Out-String)"
                $Subprofile = new-object VMware.Spbm.Views.PbmCapabilityInstance
                $Subprofile.Id = New-Object VMware.Spbm.Views.PbmCapabilityMetadataUniqueId
                $Subprofile.Id.Namespace = "VSAN"
                $Subprofile.Id.Id = "replicaPreference"
                $Subprofile.Constraint = New-Object VMware.Spbm.Views.PbmCapabilityConstraintInstance
                $Subprofile.Constraint[0].PropertyInstance = New-Object VMware.Spbm.Views.PbmCapabilityPropertyInstance
                $Subprofile.Constraint[0].PropertyInstance[0].id = $Subprofile.Id.Id
                $Subprofile.Constraint[0].PropertyInstance[0].value = "RAID-5/6 (Erasure Coding) - Capacity"
                ($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "VSAN" }).Capability += $subprofile

                Write-Information "Profilespec: $($profilespec | Out-String)"
                $Subprofile = new-object VMware.Spbm.Views.PbmCapabilityInstance
                $Subprofile.Id = New-Object VMware.Spbm.Views.PbmCapabilityMetadataUniqueId
                $Subprofile.Id.Namespace = "VSAN"
                $Subprofile.Id.Id = "storageType"
                $Subprofile.Constraint = New-Object VMware.Spbm.Views.PbmCapabilityConstraintInstance
                $Subprofile.Constraint[0].PropertyInstance = New-Object VMware.Spbm.Views.PbmCapabilityPropertyInstance
                $Subprofile.Constraint[0].PropertyInstance[0].id = $Subprofile.Id.Id
                $Subprofile.Constraint[0].PropertyInstance[0].value = "Allflash"
                ($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "VSAN" }).Capability += $subprofile
                Write-Information "All Flash added to ProfileSpec as required for $vsanFailurestoTolerate"
            }
            "R1FTT2" {
                $Subprofile = new-object VMware.Spbm.Views.PbmCapabilityInstance
                $Subprofile.Id = New-Object VMware.Spbm.Views.PbmCapabilityMetadataUniqueId
                $Subprofile.Id.Namespace = "VSAN"
                $Subprofile.Id.Id = "hostFailuresToTolerate"
                $Subprofile.Constraint = New-Object VMware.Spbm.Views.PbmCapabilityConstraintInstance
                $Subprofile.Constraint[0].PropertyInstance = New-Object VMware.Spbm.Views.PbmCapabilityPropertyInstance
                $Subprofile.Constraint[0].PropertyInstance[0].id = $Subprofile.Id.Id
                $Subprofile.Constraint[0].PropertyInstance[0].value = 2
                If (($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "VSAN" }).count -eq 0) {
                    $profilespec.Constraints.SubProfiles += new-object VMware.Spbm.Views.PbmCapabilitySubProfile -Property @{"Name" = "VSAN" }
                    Write-Information "Added VSAN Subprofile to ProfileSpec"
                    ($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "VSAN" }).Capability += $subprofile
                }
                Else { ($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "VSAN" }).Capability += $subprofile }

                $Subprofile = new-object VMware.Spbm.Views.PbmCapabilityInstance
                $Subprofile.Id = New-Object VMware.Spbm.Views.PbmCapabilityMetadataUniqueId
                $Subprofile.Id.Namespace = "VSAN"
                $Subprofile.Id.Id = "replicaPreference"
                $Subprofile.Constraint = New-Object VMware.Spbm.Views.PbmCapabilityConstraintInstance
                $Subprofile.Constraint[0].PropertyInstance = New-Object VMware.Spbm.Views.PbmCapabilityPropertyInstance
                $Subprofile.Constraint[0].PropertyInstance[0].id = $Subprofile.Id.Id
                $Subprofile.Constraint[0].PropertyInstance[0].value = "RAID-1 (Mirroring) - Performance"
                ($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "VSAN" }).Capability += $subprofile
            }
            "R6FTT2" {
                $Subprofile = new-object VMware.Spbm.Views.PbmCapabilityInstance
                $Subprofile.Id = New-Object VMware.Spbm.Views.PbmCapabilityMetadataUniqueId
                $Subprofile.Id.Namespace = "VSAN"
                $Subprofile.Id.Id = "hostFailuresToTolerate"
                $Subprofile.Constraint = New-Object VMware.Spbm.Views.PbmCapabilityConstraintInstance
                $Subprofile.Constraint[0].PropertyInstance = New-Object VMware.Spbm.Views.PbmCapabilityPropertyInstance
                $Subprofile.Constraint[0].PropertyInstance[0].id = $Subprofile.Id.Id
                $Subprofile.Constraint[0].PropertyInstance[0].value = 2
                If (($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "VSAN" }).count -eq 0) {
                    $profilespec.Constraints.SubProfiles += new-object VMware.Spbm.Views.PbmCapabilitySubProfile -Property @{"Name" = "VSAN" }
                    Write-Information "Added VSAN Subprofile to ProfileSpec"
                    ($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "VSAN" }).Capability += $subprofile
                }
                Else { ($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "VSAN" }).Capability += $subprofile }

                $Subprofile = new-object VMware.Spbm.Views.PbmCapabilityInstance
                $Subprofile.Id = New-Object VMware.Spbm.Views.PbmCapabilityMetadataUniqueId
                $Subprofile.Id.Namespace = "VSAN"
                $Subprofile.Id.Id = "replicaPreference"
                $Subprofile.Constraint = New-Object VMware.Spbm.Views.PbmCapabilityConstraintInstance
                $Subprofile.Constraint[0].PropertyInstance = New-Object VMware.Spbm.Views.PbmCapabilityPropertyInstance
                $Subprofile.Constraint[0].PropertyInstance[0].id = $Subprofile.Id.Id
                $Subprofile.Constraint[0].PropertyInstance[0].value = "RAID-5/6 (Erasure Coding) - Capacity"
                ($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "VSAN" }).Capability += $subprofile

                $Subprofile = new-object VMware.Spbm.Views.PbmCapabilityInstance
                $Subprofile.Id = New-Object VMware.Spbm.Views.PbmCapabilityMetadataUniqueId
                $Subprofile.Id.Namespace = "VSAN"
                $Subprofile.Id.Id = "storageType"
                $Subprofile.Constraint = New-Object VMware.Spbm.Views.PbmCapabilityConstraintInstance
                $Subprofile.Constraint[0].PropertyInstance = New-Object VMware.Spbm.Views.PbmCapabilityPropertyInstance
                $Subprofile.Constraint[0].PropertyInstance[0].id = $Subprofile.Id.Id
                $Subprofile.Constraint[0].PropertyInstance[0].value = "Allflash"
                ($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "VSAN" }).Capability += $subprofile
                Write-Information "All Flash added to ProfileSpec as required for $vsanFailurestoTolerate"
            }
            "R1FTT3" {
                $Subprofile = new-object VMware.Spbm.Views.PbmCapabilityInstance
                $Subprofile.Id = New-Object VMware.Spbm.Views.PbmCapabilityMetadataUniqueId
                $Subprofile.Id.Namespace = "VSAN"
                $Subprofile.Id.Id = "hostFailuresToTolerate"
                $Subprofile.Constraint = New-Object VMware.Spbm.Views.PbmCapabilityConstraintInstance
                $Subprofile.Constraint[0].PropertyInstance = New-Object VMware.Spbm.Views.PbmCapabilityPropertyInstance
                $Subprofile.Constraint[0].PropertyInstance[0].id = $Subprofile.Id.Id
                $Subprofile.Constraint[0].PropertyInstance[0].value = 3
                If (($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "VSAN" }).count -eq 0) {
                    $profilespec.Constraints.SubProfiles += new-object VMware.Spbm.Views.PbmCapabilitySubProfile -Property @{"Name" = "VSAN" }
                    Write-Information "Added VSAN Subprofile to ProfileSpec"
                    ($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "VSAN" }).Capability += $subprofile
                }
                Else { ($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "VSAN" }).Capability += $subprofile }

                $Subprofile = new-object VMware.Spbm.Views.PbmCapabilityInstance
                $Subprofile.Id = New-Object VMware.Spbm.Views.PbmCapabilityMetadataUniqueId
                $Subprofile.Id.Namespace = "VSAN"
                $Subprofile.Id.Id = "replicaPreference"
                $Subprofile.Constraint = New-Object VMware.Spbm.Views.PbmCapabilityConstraintInstance
                $Subprofile.Constraint[0].PropertyInstance = New-Object VMware.Spbm.Views.PbmCapabilityPropertyInstance
                $Subprofile.Constraint[0].PropertyInstance[0].id = $Subprofile.Id.Id
                $Subprofile.Constraint[0].PropertyInstance[0].value = "RAID-1 (Mirroring) - Performance"
                ($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "VSAN" }).Capability += $subprofile
            }
            Default {}
        }
        #vSANChecksumDisabled
        Write-Information "vSANChecksumDisabled value is: $vSANChecksumDisabled"
        Switch ($vSANChecksumDisabled) {
            $true {
                $Subprofile = new-object VMware.Spbm.Views.PbmCapabilityInstance
                $Subprofile.Id = New-Object VMware.Spbm.Views.PbmCapabilityMetadataUniqueId
                $Subprofile.Id.Namespace = "VSAN"
                $Subprofile.Id.Id = "checksumDisabled"
                $Subprofile.Constraint = New-Object VMware.Spbm.Views.PbmCapabilityConstraintInstance
                $Subprofile.Constraint[0].PropertyInstance = New-Object VMware.Spbm.Views.PbmCapabilityPropertyInstance
                $Subprofile.Constraint[0].PropertyInstance[0].id = $Subprofile.Id.Id
                $Subprofile.Constraint[0].PropertyInstance[0].value = $true
                If (($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "VSAN" }).count -eq 0) {
                    $profilespec.Constraints.SubProfiles += new-object VMware.Spbm.Views.PbmCapabilitySubProfile -Property @{"Name" = "VSAN" }
                    Write-Information "Added VSAN Subprofile to ProfileSpec"
                }
                Else { ($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "VSAN" }).Capability += $subprofile }
                $Description = $Description + " - Disabling vSAN Checksum may invalidate Microsoft SLA terms and data loss/corruption may occur."
                Write-Warning "Disabling vSAN Checksum may invalidate Microsoft SLA terms and data loss/corruption may occur."
            }
            # Empty profile spec defaults to setting to false in overwrite case
            $false {}
        }
        #vSANForceProvisioning
        Write-Information "vSANForceProvisioning Value is: $vSANForceProvisioning"
        Switch ($vSANForceProvisioning) {
            $true {
                $Subprofile = new-object VMware.Spbm.Views.PbmCapabilityInstance
                $Subprofile.Id = New-Object VMware.Spbm.Views.PbmCapabilityMetadataUniqueId
                $Subprofile.Id.Namespace = "VSAN"
                $Subprofile.Id.Id = "forceProvisioning"
                $Subprofile.Constraint = New-Object VMware.Spbm.Views.PbmCapabilityConstraintInstance
                $Subprofile.Constraint[0].PropertyInstance = New-Object VMware.Spbm.Views.PbmCapabilityPropertyInstance
                $Subprofile.Constraint[0].PropertyInstance[0].id = $Subprofile.Id.Id
                $Subprofile.Constraint[0].PropertyInstance[0].value = $true
                If (($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "VSAN" }).count -eq 0) {
                    $profilespec.Constraints.SubProfiles += new-object VMware.Spbm.Views.PbmCapabilitySubProfile -Property @{"Name" = "VSAN" }
                    Write-Information "Added VSAN Subprofile to ProfileSpec"
                    ($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "VSAN" }).Capability += $subprofile
                }
                Else { ($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "VSAN" }).Capability += $subprofile }
                $Description = $Description + " - Force Provisioned objects are unprotected by Microsoft SLA and data loss/corruption may occur."
                Write-Warning "$Name policy setting Force Provisioned objects are unprotected by Microsoft SLA and data loss/corruption may occur."
            }
            # Empty profile spec defaults to setting to false in overwrite case
            $false {}
        }

        #vSANDiskStripesPerObject
        Write-Information "vSANDiskStripesPerObject value is: $vSANDiskStripesPerObject"
        If ($vSANDiskStripesPerObject -gt 0) {
            Write-Information "Creating vSAN Disk Stripes Subprofile"
            $Subprofile = new-object VMware.Spbm.Views.PbmCapabilityInstance
            $Subprofile.Id = New-Object VMware.Spbm.Views.PbmCapabilityMetadataUniqueId
            $Subprofile.Id.Namespace = "VSAN"
            $Subprofile.Id.Id = "stripeWidth"
            $Subprofile.Constraint = New-Object VMware.Spbm.Views.PbmCapabilityConstraintInstance
            $Subprofile.Constraint[0].PropertyInstance = New-Object VMware.Spbm.Views.PbmCapabilityPropertyInstance
            $Subprofile.Constraint[0].PropertyInstance[0].id = $Subprofile.Id.Id
            $Subprofile.Constraint[0].PropertyInstance[0].value = $vSANDiskStripesPerObject
            If (($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "VSAN" }).count -eq 0) {
                $profilespec.Constraints.SubProfiles += new-object VMware.Spbm.Views.PbmCapabilitySubProfile -Property @{"Name" = "VSAN" }
                Write-Information "Added VSAN Subprofile to ProfileSpec"
                ($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "VSAN" }).Capability += $subprofile
            }
            Else { ($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "VSAN" }).Capability += $subprofile }
        }

        #VSANIOLimit
        Write-Information "vSANIOLimit set to: $vSANIOLimit"
        If ($vSANIOLimit -gt 0) {
            Write-Information "Building vSAN IOLimit Subprofile"
            $Subprofile = new-object VMware.Spbm.Views.PbmCapabilityInstance
            $Subprofile.Id = New-Object VMware.Spbm.Views.PbmCapabilityMetadataUniqueId
            $Subprofile.Id.Namespace = "VSAN"
            $Subprofile.Id.Id = "iopsLimit"
            $Subprofile.Constraint = New-Object VMware.Spbm.Views.PbmCapabilityConstraintInstance
            $Subprofile.Constraint[0].PropertyInstance = New-Object VMware.Spbm.Views.PbmCapabilityPropertyInstance
            $Subprofile.Constraint[0].PropertyInstance[0].id = $Subprofile.Id.Id
            $Subprofile.Constraint[0].PropertyInstance[0].value = $vSANIOLimit
            If (($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "VSAN" }).count -eq 0) {
                $profilespec.Constraints.SubProfiles += new-object VMware.Spbm.Views.PbmCapabilitySubProfile -Property @{"Name" = "VSAN" }
                Write-Information "Added VSAN Subprofile to ProfileSpec"
                ($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "VSAN" }).Capability += $subprofile
            }
            Else { ($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "VSAN" }).Capability += $subprofile }
        }

        #VSANCacheReservation
        Write-Information "vSANCacheReservation set to: $vSANCacheReservation"
        If ($vSANCacheReservation -gt 0) {
            Write-Information "Creating vSANCacheReservation Subprofile"
            $Subprofile = new-object VMware.Spbm.Views.PbmCapabilityInstance
            $Subprofile.Id = New-Object VMware.Spbm.Views.PbmCapabilityMetadataUniqueId
            $Subprofile.Id.Namespace = "VSAN"
            $Subprofile.Id.Id = "cacheReservation"
            $Subprofile.Constraint = New-Object VMware.Spbm.Views.PbmCapabilityConstraintInstance
            $Subprofile.Constraint[0].PropertyInstance = New-Object VMware.Spbm.Views.PbmCapabilityPropertyInstance
            $Subprofile.Constraint[0].PropertyInstance[0].id = $Subprofile.Id.Id
            $Subprofile.Constraint[0].PropertyInstance[0].value = ([int]$vSANCacheReservation * 10000)
            If (($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "VSAN" }).count -eq 0) {
                $profilespec.Constraints.SubProfiles += new-object VMware.Spbm.Views.PbmCapabilitySubProfile -Property @{"Name" = "VSAN" }
                Write-Information "Added VSAN Subprofile to ProfileSpec"
                ($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "VSAN" }).Capability += $subprofile
            }
            Else { ($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "VSAN" }).Capability += $subprofile }
        }

        #VSANObjectReservation
        Write-Information "vSANObjectReservation set to: $vSANObjectSpaceReservation"
        If ($vSANObjectSpaceReservation -gt 0) {
            Write-Information "Creating vSANObjectReservation Subprofile"
            $Subprofile = new-object VMware.Spbm.Views.PbmCapabilityInstance
            $Subprofile.Id = New-Object VMware.Spbm.Views.PbmCapabilityMetadataUniqueId
            $Subprofile.Id.Namespace = "VSAN"
            $Subprofile.Id.Id = "proportionalCapacity"
            $Subprofile.Constraint = New-Object VMware.Spbm.Views.PbmCapabilityConstraintInstance
            $Subprofile.Constraint[0].PropertyInstance = New-Object VMware.Spbm.Views.PbmCapabilityPropertyInstance
            $Subprofile.Constraint[0].PropertyInstance[0].id = $Subprofile.Id.Id
            $Subprofile.Constraint[0].PropertyInstance[0].value = $vSANObjectSpaceReservation
            If (($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "VSAN" }).count -eq 0) {
                $profilespec.Constraints.SubProfiles += new-object VMware.Spbm.Views.PbmCapabilitySubProfile -Property @{"Name" = "VSAN" }
                Write-Information "Added VSAN Subprofile to ProfileSpec"
                ($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "VSAN" }).Capability += $subprofile
            }
            Else { ($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "VSAN" }).Capability += $subprofile }
        }

        # Tag Support for Storage Policies
        Write-Information ("Tags recorded as: " + $Tags)
        $TagData = $SPBMCapabilities | Where-Object { $_.subcategory -eq "Tag" }
        If (![string]::IsNullOrEmpty($Tags)) {
            # Needed as run command does not support string array types, cannot simply overwrite existing variable for some reason.
            $Array = Convert-StringToArray -String $Tags
            Foreach ($Tag in $Array) {
                Write-Information ("Tag: " + $Tag)
                $Tag = Limit-WildcardsandCodeInjectionCharacters -String $Tag
                $ObjectTag = Get-Tag -Name $Tag
                If (![string]::IsNullOrEmpty($ObjectTag)) {
                    If ($ObjectTag.count -gt 1) {
                        Write-Information "Multiple Tags found with the name $Tag. Filtering by Datastore category."
                        Foreach ($Entry in $ObjectTag) {
                            Write-Information ("Tag Name: " + $Entry.Name)
                            If ($Entry.Category.EntityType -eq "Datastore") {
                                $CatData = $TagData.CapabilityMetadata | Where-Object { $_.summary.Label -eq $Entry.Category.Name }
                                $Subprofile = new-object VMware.Spbm.Views.PbmCapabilityInstance
                                $Subprofile.Id = $Catdata.Id
                                $Subprofile.Constraint = New-Object VMware.Spbm.Views.PbmCapabilityConstraintInstance
                                $Subprofile.Constraint[0].PropertyInstance = New-Object VMware.Spbm.Views.PbmCapabilityPropertyInstance
                                $Subprofile.Constraint[0].PropertyInstance[0].id = $Catdata.propertymetadata.id
                                $Subprofile.Constraint[0].PropertyInstance[0].Operator = ""
                                $Subprofile.Constraint[0].PropertyInstance[0].value = New-object VMware.Spbm.Views.PbmCapabilityDiscreteSet
                                $Subprofile.Constraint[0].PropertyInstance[0].value.values = $Entry.Name
                                If (($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "Tag based placement" }).count -eq 0) {
                                    $profilespec.Constraints.SubProfiles += new-object VMware.Spbm.Views.PbmCapabilitySubProfile -Property @{"Name" = "Tag based placement" }
                                    Write-Information "Added Tag based placement subprofile to ProfileSpec"
                                    ($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "Tag based placement" }).Capability += $Subprofile
                                    Write-Information "Added $Tag to profilespec"
                                }
                                Else {
                                    ($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "Tag based placement" }).Capability += $Subprofile
                                }

                            }
                            If ($Entry.Category.EntityType -ne "Datastore") {
                                Write-Information "Tag $($Entry.Name) of category $($Entry.Category.Name) is not a Datastore Tag. Skipping."
                            }
                        }
                    }
                    If ($ObjectTag.count -eq 1) {
                        If ($ObjectTag.Category.EntityType -ne "Datastore") {
                            Write-Warning "Tag $Tag is not a Datastore Tag. Skipping."
                        }
                        Else {
                            $Entry = $ObjectTag
                            $CatData = $TagData.CapabilityMetadata | Where-Object { $_.summary.Label -eq $Entry.Category.Name }
                            $Subprofile = new-object VMware.Spbm.Views.PbmCapabilityInstance
                            $Subprofile.Id = $Catdata.Id
                            $Subprofile.Constraint = New-Object VMware.Spbm.Views.PbmCapabilityConstraintInstance
                            $Subprofile.Constraint[0].PropertyInstance = New-Object VMware.Spbm.Views.PbmCapabilityPropertyInstance
                            $Subprofile.Constraint[0].PropertyInstance[0].id = $Catdata.propertymetadata.id
                            $Subprofile.Constraint[0].PropertyInstance[0].Operator = ""
                            $Subprofile.Constraint[0].PropertyInstance[0].value = New-object VMware.Spbm.Views.PbmCapabilityDiscreteSet
                            $Subprofile.Constraint[0].PropertyInstance[0].value.values = $Entry.Name
                            If (($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "Tag based placement" }).count -eq 0) {
                                $profilespec.Constraints.SubProfiles += new-object VMware.Spbm.Views.PbmCapabilitySubProfile -Property @{"Name" = "Tag based placement" }
                                Write-Information "Added Tag based placement subprofile to ProfileSpec"
                                    ($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "Tag based placement" }).Capability += $Subprofile
                                Write-Information "Added $Tag to profilespec"
                            }
                            Else {
                                ($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "Tag based placement" }).Capability += $Subprofile
                            }
                        }


                    }


                }
                Else { Write-Error "Tag $Tag not found. Skipping. Tags are case-sensitive, please verify." }
            }


        }

        # Not Tag Support for Storage Policies
        Write-Information ("NotTags recorded as: " + $NotTags)
        If (![string]::IsNullOrEmpty($NotTags)) {
            # Needed as run command does not support string array types, cannot simply overwrite existing variable for some reason.
            $Array = Convert-StringToArray -String $NotTags
            Foreach ($Tag in $Array) {
                Write-Information ("Tag: " + $Tag)
                $Tag = Limit-WildcardsandCodeInjectionCharacters -String $Tag
                $ObjectTag = Get-Tag -Name $Tag
                If (![string]::IsNullOrEmpty($ObjectTag)) {
                    If ($ObjectTag.count -gt 1) {
                        Write-Information "Multiple Tags found with the name $Tag. Filtering by Datastore category."
                        Foreach ($Entry in $ObjectTag) {
                            Write-Information ("Tag Name: " + $Entry.Name)
                            If ($Entry.Category.EntityType -eq "Datastore") {
                                $CatData = $TagData.CapabilityMetadata | Where-Object { $_.summary.Label -eq $Entry.Category.Name }
                                $Subprofile = new-object VMware.Spbm.Views.PbmCapabilityInstance
                                $Subprofile.Id = $Catdata.Id
                                $Subprofile.Constraint = New-Object VMware.Spbm.Views.PbmCapabilityConstraintInstance
                                $Subprofile.Constraint[0].PropertyInstance = New-Object VMware.Spbm.Views.PbmCapabilityPropertyInstance
                                $Subprofile.Constraint[0].PropertyInstance[0].id = $Catdata.propertymetadata.id
                                $Subprofile.Constraint[0].PropertyInstance[0].Operator = "NOT"
                                $Subprofile.Constraint[0].PropertyInstance[0].value = New-object VMware.Spbm.Views.PbmCapabilityDiscreteSet
                                $Subprofile.Constraint[0].PropertyInstance[0].value.values = $Entry.Name
                                If (($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "Tag based placement" }).count -eq 0) {
                                    $profilespec.Constraints.SubProfiles += new-object VMware.Spbm.Views.PbmCapabilitySubProfile -Property @{"Name" = "Tag based placement" }
                                    Write-Information "Added Tag based placement subprofile to ProfileSpec"
                                    ($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "Tag based placement" }).Capability += $Subprofile
                                    Write-Information "Added $Tag to profilespec"
                                }
                                Else {
                                    ($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "Tag based placement" }).Capability += $Subprofile
                                }

                            }
                            If ($Entry.Category.EntityType -ne "Datastore") {
                                Write-Information "Tag $($Entry.Name) of category $($Entry.Category.Name) is not a Datastore Tag. Skipping."
                            }
                        }
                    }
                    If ($ObjectTag.count -eq 1) {
                        if ($ObjectTag.Category.EntityType -ne "Datastore") {
                            Write-Information "Tag $Tag is not a Datastore Tag. Skipping."
                        }
                        Else {
                            $Entry = $ObjectTag
                            $CatData = $TagData.CapabilityMetadata | Where-Object { $_.summary.Label -eq $Entry.Category.Name }
                            $Subprofile = new-object VMware.Spbm.Views.PbmCapabilityInstance
                            $Subprofile.Id = $Catdata.Id
                            $Subprofile.Constraint = New-Object VMware.Spbm.Views.PbmCapabilityConstraintInstance
                            $Subprofile.Constraint[0].PropertyInstance = New-Object VMware.Spbm.Views.PbmCapabilityPropertyInstance
                            $Subprofile.Constraint[0].PropertyInstance[0].id = $Catdata.propertymetadata.id
                            $Subprofile.Constraint[0].PropertyInstance[0].Operator = "NOT"
                            $Subprofile.Constraint[0].PropertyInstance[0].value = New-object VMware.Spbm.Views.PbmCapabilityDiscreteSet
                            $Subprofile.Constraint[0].PropertyInstance[0].value.values = $Entry.Name
                            If (($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "Tag based placement" }).count -eq 0) {
                                $profilespec.Constraints.SubProfiles += new-object VMware.Spbm.Views.PbmCapabilitySubProfile -Property @{"Name" = "Tag based placement" }
                                Write-Information "Added Tag based placement subprofile to ProfileSpec"
                                ($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "Tag based placement" }).Capability += $Subprofile
                                Write-Information "Added $Tag to profilespec"
                            }
                            Else {
                                    ($profilespec.Constraints.SubProfiles | Where-Object { $_.Name -eq "Tag based placement" }).Capability += $Subprofile
                            }
                        }


                    }


                }
                Else { Write-Error "Tag $Tag not found. Skipping. Tags are case-sensitive, please verify." }
            }


        }
        #IMPORTANT - Any additional functionality should be added before the VMEncryption Parameter.  The reason is that this subprofile must be added as a capability to all subprofile types for API to accept.
        Write-Information "VMEncryption set to: $VMEncryption"
        Switch ($VMEncryption) {
            "None" {}
            "PreIO" {
                #Check for AVS VM Encryption Policies, create if not present.
                $IOPolicy = Get-AVSStoragePolicy -Name "AVS PRE IO Encryption" -ResourceType "DATA_SERVICE_POLICY"
                If (!$IOPolicy) { $IOPolicy = New-AVSCommonStoragePolicy -Encryption -Name "AVS PRE IO Encryption" -Description "Encrypts VM before VAIO Filter" -PostIOEncryption $false }
                Write-Information ("VMEncryption uniqueID: " + $IOPolicy.ProfileId.UniqueId)
                $Subprofile = new-object VMware.Spbm.Views.PbmCapabilityInstance
                $Subprofile.Id = New-Object VMware.Spbm.Views.PbmCapabilityMetadataUniqueId
                $Subprofile.Id.Namespace = "com.vmware.storageprofile.dataservice"
                $Subprofile.Id.Id = $IOPolicy.ProfileId.UniqueId
                $Subprofile.Constraint = New-Object VMware.Spbm.Views.PbmCapabilityConstraintInstance
                $Subprofile.Constraint[0].PropertyInstance = New-Object VMware.Spbm.Views.PbmCapabilityPropertyInstance
                $Subprofile.Constraint[0].PropertyInstance[0].id = $Subprofile.Id.Id
                $Subprofile.Constraint[0].PropertyInstance[0].value = $Subprofile.Id.Id
                If ($profilespec.Constraints.SubProfiles.count -eq 0) {
                    $SubprofileName = "Host based services"
                    $profilespec.Constraints.SubProfiles += new-object VMware.Spbm.Views.PbmCapabilitySubProfile -Property @{"Name" = $SubprofileName }
                    Write-Information "Added $SubprofileName to ProfileSpec"
                    Foreach ($service in $profilespec.Constraints.SubProfiles) {
                        $service.Capability += $subprofile
                    }
                }
                ElseIf ($profilespec.Constraints.SubProfiles.count -ge 1) {
                    Foreach ($service in $profilespec.Constraints.SubProfiles) {
                        $service.Capability += $subprofile
                    }
                }
                Write-Information "Added $($IOPolicy.Name) to profilespec"

            }
            "PostIO" {
                $IOPolicy = Get-AVSStoragePolicy -Name "AVS POST IO Encryption" -ResourceType "DATA_SERVICE_POLICY"
                If (!$IOPolicy) { $IOPolicy = New-AVSCommonStoragePolicy -Encryption -Name "AVS POST IO Encryption" -Description "Encrypts VM after VAIO Filter" -PostIOEncryption $true }
                Write-Information ("VMEncryption uniqueID: " + $IOPolicy.ProfileId.UniqueId)
                $Subprofile = new-object VMware.Spbm.Views.PbmCapabilityInstance
                $Subprofile.Id = New-Object VMware.Spbm.Views.PbmCapabilityMetadataUniqueId
                $Subprofile.Id.Namespace = "com.vmware.storageprofile.dataservice"
                $Subprofile.Id.Id = $IOPolicy.profileid.UniqueId
                $Subprofile.Constraint = New-Object VMware.Spbm.Views.PbmCapabilityConstraintInstance
                $Subprofile.Constraint[0].PropertyInstance = New-Object VMware.Spbm.Views.PbmCapabilityPropertyInstance
                $Subprofile.Constraint[0].PropertyInstance[0].id = $Subprofile.Id.Id
                $Subprofile.Constraint[0].PropertyInstance[0].value = $Subprofile.Id.Id
                If ($profilespec.Constraints.SubProfiles.count -eq 0) {
                    $SubprofileName = "Host based services"
                    $profilespec.Constraints.SubProfiles += new-object VMware.Spbm.Views.PbmCapabilitySubProfile -Property @{"Name" = $SubprofileName }
                    Write-Information "Added $SubprofileName to ProfileSpec"
                    Write-Information $profilespec.Constraints.SubProfiles[0].Name
                    Foreach ($service in $profilespec.Constraints.SubProfiles) {
                        $service.Capability += $subprofile
                    }
                }
                ElseIf ($profilespec.Constraints.SubProfiles.count -ge 1) {
                    Foreach ($service in $profilespec.Constraints.SubProfiles) {
                        $service.Capability += $subprofile
                    }
                }
                Write-Information "Added $($IOPolicy.Name) to profilespec"

            }
            Default {}
        }

    }
    process {
        $profilespec.Description = $Description
        #return $profilespec #Uncomment to capture and debug profile spec.
        If ($profilespec.Constraints.SubProfiles.count -eq 0) {
            Write-Error "At least one parameter must be defined to create a storage policy."
            Return
        }
        $serviceInstanceView = Get-SpbmView -Id "PbmServiceInstance-ServiceInstance"
        $spbmServiceContent = $serviceInstanceView.PbmRetrieveServiceContent()
        $spbmProfMgr = Get-SpbmView -Id $spbmServiceContent.ProfileManager
        If ($Overwrite) {
            $spbmProfMgr.PbmUpdate($ExistingPolicy.ProfileId, $profilespec)
            if ($?) { return "$($ExistingPolicy.Name) Updated" }
            else { return "$($ExistingPolicy.Name) Update Failed" }

        }
        Else {
            $profileuniqueID = $spbmProfMgr.PbmCreate($profilespec)
            $existingpolicies = Get-AVSStoragePolicy
            $createdpolicy = $existingpolicies | where-object { $_.profileid.uniqueid -eq $profileuniqueID.UniqueId }
            Write-Information "Created $($createdpolicy.Name)"
            return ("Created " + $createdpolicy.Name + " " + $profileuniqueID.UniqueId)
        }

    }
}

<#
    .Synopsis
        This allows the customer to change DRS from the default setting to 1-4 with 4 being the least conservative.
    .PARAMETER Drs
        The DRS setting to apply to the cluster.  3 is the default setting, 2 is one step more conservative (meaning less agressive in moving VMs).
    .PARAMETER ClustersToChange
        The clusters to apply the DRS setting to.  This can be a single cluster or a comma separated list of clusters or a wildcard.
    .EXAMPLE
        Set-CustomDRS -ClustersToChange "Cluster-1, Cluster-2" -Drs 2
        Set-CustomDRS -ClustersToChange "*" -Drs 3  # This returns it to the default setting
#>
function Set-CustomDRS {

    [AVSAttribute(15, UpdatesSDDC = $false)]
    param(
        [Parameter(Mandatory = $true)]
        [String]$ClustersToChange,
        [Parameter(Mandatory = $true,
            HelpMessage = "The DRS setting. Default of 3 or more conservative of 2 or less conservative 4.")]
        [ValidateRange(1, 4)]
        [int] $Drs
    )

    switch ($Drs) {
        4 { $drsChange = 2 }
        3 { $drsChange = 3 }
        2 { $drsChange = 4 }
        1 { $drsChange = 5 }
        Default { $drsChange = 3 }
    }

    # Settings for DRS
    $spec = New-Object VMware.Vim.ClusterConfigSpecEx
    $spec.DrsConfig = New-Object VMware.Vim.ClusterDrsConfigInfo
    $spec.DrsConfig.VmotionRate = $drsChange
    $spec.DrsConfig.Enabled = $true
    $spec.DrsConfig.Option = New-Object VMware.Vim.OptionValue[] (2)
    $spec.DrsConfig.Option[0] = New-Object VMware.Vim.OptionValue
    $spec.DrsConfig.Option[0].Value = '0'
    $spec.DrsConfig.Option[0].Key = 'TryBalanceVmsPerHost'
    $spec.DrsConfig.Option[1] = New-Object VMware.Vim.OptionValue
    $spec.DrsConfig.Option[1].Value = '1'
    $spec.DrsConfig.Option[1].Key = 'IsClusterManaged'
    $modify = $true
    # End DRS settings

    # $cluster is an array of cluster names or "*""
    foreach ($cluster_each in ($ClustersToChange.split(",", [System.StringSplitOptions]::RemoveEmptyEntries)).Trim()) {
        $Clusters += Get-Cluster -Name $cluster_each
    }

    foreach ($cluster in $clusters) {
        try {
            $_this = Get-View -Id $cluster.Id
            $_this.ReconfigureComputeResource_Task($spec, $modify)
            Write-Host "Successfully set DRS for cluster $($cluster.Name)."
        }
        catch {
            Write-Error "Failed to set DRS for cluster $($cluster.Name)."
        }
    }
}

Function Set-AVSVSANClusterUNMAPTRIM {
    <#
    .DESCRIPTION
        This function enables vSAN UNMAP/TRIM on the cluster defined by the -Name parameter.
        Once enabled, supported Guest OS VM's must be powered off and powered back on.  A reboot will not suffice.
        See url for more information: https://core.vmware.com/resource/vsan-space-efficiency-technologies#sec19560-sub6
    .PARAMETER Name
        Name of Clusters as defined in vCenter.  Valid values are blank or a comma separated list of cluster names.
        Set-AVSVSANClusterUNMAPTRIM -Name Cluster-1,Cluster-2,Cluster-3
        Enables UNMAP/TRIM on Clusters-1,2,3
        Set-AVSVSANClusterUNMAPTRIM -Enable:True
        Enables UNMAP/TRIM on all Clusters
    .PARAMETER Enable
        Set to true to enable UNMAP/TRIM on target cluster(s). Default is false.
        WARNING - There is a performance impact when UNMAP/TRIM is enabled.
        See url for more information: https://core.vmware.com/resource/vsan-space-efficiency-technologies#sec19560-sub6
    .EXAMPLE
        Set-AVSVSANClusterUNMAPTRIM -Name 'Cluster-1,Cluster-2,Cluster-3'
        Enables UNMAP/TRIM on Clusters-1,2,3
    .EXAMPLE
        Set-AVSVSANClusterUNMAPTRIM -Enable:True
        Enables UNMAP/TRIM on all Clusters
    #>

    [CmdletBinding()]
    [AVSAttribute(10, UpdatesSDDC = $false)]
    param (
        [Parameter(Mandatory = $false)]
        [string]
        $Name,
        [Parameter(Mandatory = $true)]
        [bool]
        $Enable
    )
    begin {
        If ([string]::IsNullOrEmpty($Name)){}
        Else {
            $Name = Limit-WildcardsandCodeInjectionCharacters -String $Name
            $Array = Convert-StringToArray -String $Name
        }
        $TagName = "VSAN UNMAP/TRIM"
        $InfoMessage = "Info - There may be a performance impact when UNMAP/TRIM is enabled.
            See url for more information: https://core.vmware.com/resource/vsan-space-efficiency-technologies#sec19560-sub6"
    }
    process {
        If ([string]::IsNullOrEmpty($Array)) {
            $Clusters = Get-Cluster
            Foreach ($Cluster in $Clusters) {
                $Cluster | Set-VsanClusterConfiguration -GuestTrimUnmap:$Enable
                Add-AVSTag -Name $TagName -Description $InfoMessage -Entity $Cluster
                Write-Information "$($Cluster.Name) set to $Enabled for UNMAP/TRIM"
                If ($Enable) {
                    Write-Information $InfoMessage
                }
            }
            Get-Cluster | Set-VsanClusterConfiguration -GuestTrimUnmap:$Enable
        }
        Else {
            Foreach ($Entry in $Array) {
                If ($Cluster = Get-Cluster -name $Entry) {
                    $Cluster | Set-VsanClusterConfiguration -GuestTrimUnmap:$Enable
                    Write-Information "$($Cluster.Name) set to $Enabled for UNMAP/TRIM"
                    If ($Enable) {
                        Write-Information $InfoMessage
                        Add-AVSTag -Name $TagName -Description $InfoMessage -Entity $Cluster
                    }
                    If ($Enable -eq $false) {
                        $AssignedTag = Get-TagAssignment -Tag $Tagname -Entity $Cluster
                        Remove-TagAssignment -TagAssignment $AssignedTag -Confirm:$false
                    }
                }
            }
        }
    }
}

Function Get-AVSVSANClusterUNMAPTRIM {
    <#
    .DESCRIPTION
        This function gets vSAN UNMAP/TRIM configuration status on all clusters.
    #>

    [CmdletBinding()]
    [AVSAttribute(10, UpdatesSDDC = $false)]
    param ()
    begin {}
    process {
            Get-Cluster | Get-VsanClusterConfiguration | Select-Object Name, GuestTrimUnmap
        }
}

function Remove-CustomRole {
    <#
    .DESCRIPTION
        This function allows customer to remove a custom role from the SDDC.
        Useful in case of roles created with greater privileges than Cloudadmin that can no longer be removed from the UI.
    #>

    [CmdletBinding()]
    [AVSAttribute(10, UpdatesSDDC = $false)]
    param (
        [Parameter(Mandatory = $true,
            HelpMessage = "The name of the role to remove, as displayed in the vCenter UI (case insensitive). This must be a custom role.")]
        [string]
        $roleInput
    )
    # Check if the role exists before attempting removal
    $roleToRemove = Get-VIRole | Where-Object { $_.Description -eq $roleInput }

    # Check if the role is in the protected names list or is a System role
    if ($roleToRemove.Count -eq 1) {
        if ((Test-AVSProtectedObjectName -Name $roleToRemove.Name) -or $roleToRemove.IsSystem -eq $true) {
            Write-Error "'$roleInput' is either System or Built-in. Removal not allowed."
        }
        else {
            try {
                Remove-VIRole -Role $roleToRemove -Confirm:$false -Force:$false
                Write-Host "The role '$roleInput' has been removed."
            }
            catch {
                Write-Error "Failed to remove the role '$roleInput'."
                Write-Error $_.Exception.Message
            }
        }
    }
    else {
        Write-Host "The role '$roleInput' was not found or can refer to several roles. No removal performed. Below the list of roles found:"
        foreach ($roleItem in $roleToRemove) {
            Write-Host "Role Name: $($roleItem.Name)"
            Write-Host "Role Description: $($roleItem.Description)"
        }
    }
}

Function Get-vSANDataInTransitEncryptionStatus {
    <#
    .DESCRIPTION
        Gets status of vSAN Data-In-Transit Encryption for all clusters in a SDDC
    #>
    [CmdletBinding()]
    [AVSAttribute(10, UpdatesSDDC = $false)]
    param()
    begin{}
    process {
        $clusters = Get-Cluster
        $diteConfig = @()
        $vSANConigView = Get-VsanView -Id VsanVcClusterConfigSystem-vsan-cluster-config-system
        foreach ($cluster in $clusters) {
            $diteConfig += [PSCustomObject]@{
                Name = $cluster.Name
                DataEncryptionInTransit = $vSANConigView.VsanClusterGetConfig($cluster.ExtensionData.MoRef).DataInTransitEncryptionConfig.Enabled
            }
        }
        $diteConfig | Format-Table | Out-String | Write-Host
    }

}

Function Set-vSANDataInTransitEncryption {
  <#
    .DESCRIPTION
        Enable/Disable vSAN Data-In-Transit Encryption for clusters of a SDDC.
        There may be a performance impact when vSAN Data-In-Transit Encryption is enabled. Refer :  https://blogs.vmware.com/virtualblocks/2021/08/12/storageminute-vsan-data-encryption-performance/
    .PARAMETER ClusterName
        Name of the cluster. Leave blank if required to enable for whole SDDC else enter comma separated list of names.
    .PARAMETER Enable
        Specify True/False to Enable/Disable the feature.
    #>
    [CmdletBinding()]
    [AVSAttribute(10, UpdatesSDDC = $false)]
    param (
     [Parameter(Mandatory = $false)]
     [string]
     $ClusterName,
     [Parameter(Mandatory = $true)]
     [bool]
     $Enable
    )
    begin {
        If (-not ([string]::IsNullOrEmpty($ClusterName))) {
            $ClusterNamesParsed = Limit-WildcardsandCodeInjectionCharacters -String $ClusterName
            $ClusterNamesArray = Convert-StringToArray -String $ClusterNamesParsed
        }
        Write-Host "Enable value is $Enable"
        $TagName = "vSAN Data-In-Transit Encryption" 
            $InfoMessage = "Info - There may be a performance impact when vSAN Data-In-Transit Encryption is enabled. Refer :  https://blogs.vmware.com/virtualblocks/2021/08/12/storageminute-vsan-data-encryption-performance/"
    }
    process {
        If ([string]::IsNullOrEmpty($ClusterNamesArray)) {
            $ClustersToOperateUpon = Get-Cluster
        }
        Else {
            $ClustersToOperateUpon = $ClusterNamesArray | ForEach-Object { Get-Cluster -Name $_ }
        }
        Foreach ($cluster in $ClustersToOperateUpon) {
                $vSANConfigView = Get-VsanView -Id VsanVcClusterConfigSystem-vsan-cluster-config-system
                $vSANReconfigSpec = New-Object -type VMware.Vsan.Views.VimVsanReconfigSpec
                $vSANReconfigSpec.Modify = $true
                $vSANDataInTransitConfig= New-Object -type VMware.Vsan.Views.VsanDataInTransitEncryptionConfig
                $vSANDataInTransitConfig.Enabled = $Enable
                $vSANDataInTransitConfig.RekeyInterval = 1440
                $vSANReconfigSpec.DataInTransitEncryptionConfig = $vSANDataInTransitConfig
                $task = $vSANConfigView.VsanClusterReconfig($Cluster.ExtensionData.MoRef,$vSANReconfigSpec)
                Wait-Task -Task (Get-Task -Id $task)
                If ((Get-Task -Id $task).State -eq "Success"){
                    Write-Host "$($Cluster.Name) set to $Enable"
                    If ($Enable) {
                        Add-AVSTag -Name $TagName -Description $InfoMessage -Entity $Cluster
                        Write-Information $InfoMessage
                    }
                    else {
                        $AssignedTag = Get-TagAssignment -Tag $Tagname -Entity $Cluster
                        Remove-TagAssignment -TagAssignment $AssignedTag -Confirm:$false
                    }
                }else {
                    Write-Error "Failed to set $($Cluster.Name) to $Enable"
                }
            }

        }
}
