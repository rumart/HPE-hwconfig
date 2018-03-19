<#
    .SYNOPSIS
        The script will set inital iLO config for a HPE server and add it to OneView
    .DESCRIPTION
        The script creates a new iLO admin user, sets the correct name and DNS server
        in iLO and adds the server to OneView and creates and assigns a Server Profile to it
    .NOTES
        Author: Rudi Martinsen / Intility AS
        Date : 06/02-2018
        Version : 1.0.0
        Revised : 
        Changelog:
    .LINK        
        https://github.com/HewlettPackard/POSH-HPOneView
    .LINK        
        https://www.hpe.com/us/en/product-catalog/detail/pip.scripting-tools-for-windows-powershell.5440657.html
    .LINK        
        https://support.hpe.com/hpsc/swd/public/detail?swItemId=MTX_d7e7146b56324eb0879f0a98e2
    .LINK        
        https://github.com/rumart/HPE-hwconfig
    .PARAMETER ILOIp
        ILO Address of the server to configure
    .PARAMETER UserName
        Current default administrator
    .PARAMETER Password
        Password of the default administrator
    .PARAMETER Servername
        The name the server should be given
    .PARAMETER NewAdmin
        Username of the new administrator account to be created
    .PARAMETER NewAdminPass
        Password of the new administrator
    .PARAMETER Location
        Location parameter to decide which DNS server should be primary/secondary
    .PARAMETER AddOneView
        Switch parameter to control the Add to OneView option
    .PARAMETER OVServer
        The OneView instance to add the server to
    .PARAMETER HostType
        Parameter to control which profile template to use
    .PARAMETER AddOneView
        Switch parameter to control if the default admin should be removed    
#>
[cmdletbinding()]
param(
    $ILOIp,
    $UserName = "Administrator",
    [securestring]
    $Password = (Read-Host -Prompt "Specify iLO Password" -AsSecureString),
    $Servername,
    $NewAdmin = "newadmin",
    [securestring]
    $NewAdminPass = (Read-Host -Prompt "Specify new RMADMIN Password" -AsSecureString),
    [validateset("A","B")]
    $Location = "B",
    [switch]
    $AddOneView = $true,
    [ValidateSet("ovserver-001","ovserver-002","ovserver-003")]
    $OVServer = "ovserver-003",
    [string]
    [ValidateSet("Compute","VDI","SQL","DC")]
    $HostType,
    [switch]
    $RemoveDefaultAdmin = $true
)

if($AddOneView){
    $ovconn = Connect-HPOVMgmt -Credential (Get-Credential -Message "Add credentials for OneView") -Hostname $OVServer -AuthLoginDomain "domain.name"
}

if($location -eq "B"){
    $prim_dnsserver = "1.1.1.1"
    $sec_dnsserver = "2.2.2.2"
}
else{
    $prim_dnsserver = "2.2.2.2"
    $sec_dnsserver = "1.1.1.1"
}

$iloName = $Servername

#We need to have the passwords in clear text for some of the cmdlets to work....
$adminPass = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password))
$pass = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($NewAdminPass))

#Add new admin
Write-Verbose "Adding new admin user"
Add-HPiLOUser -Server $ILOIp -Username $UserName -Password $adminPass -NewUsername $newadmin -NewUserLogin $newadmin -NewPassword $pass -AdminPriv Y -ConfigILOPriv Y -RemoteConsPriv Y -ResetServerPriv Y -VirtualMediaPriv Y -DisableCertificateAuthentication

#Set Hostname, add dns settings
Write-Verbose "Setting iLO hostname and DNS settings"
Set-HPiLONetworkSetting -Server $ILOIp -Username $UserName -Password $adminPass -DisableCertificateAuthentication -DHCPEnable Disable -RegDDNSServer Disable -RegWINSServer Disable -DNSName $iloName -PrimDNSServer $prim_dnsserver -SecDNSServer $sec_dnsserver -DHCPDNSServer Disable

Write-Output "[$(get-date)] Sleeping for 2 minutes due to change in iLO network"
Start-Sleep -Seconds 120

#Add directory config & groups
Write-Verbose "Configuring Active Directory Integration"
$command = @"
HPQLOCFG.exe -s $ILOIp -f D:\Scripts\rib\ldap_config.xml -u $newadmin -p "$pass"
"@

Invoke-Expression -Command:$command

#Connect to bios
Write-Verbose "Gathering information from BIOS"
$conn = Connect-HPEBIOS -IP $ILOIp -Username $newadmin -Password $Pass -DisableCertificateAuthentication
if(!$conn){
    Write-Error "Couldn't get BIOS connection, the script cannot continue"
    break
}
$serial = (Get-HPEBIOSSystemInfo -Connection $conn | Select-Object serialnumber).serialnumber
$productName = $conn.ProductName
Write-Verbose "Server serial : $serial"
Write-Verbose "Server model : $productname"

if($removeDefaultAdmin){
    Remove-HPiLOUser -Server $ILOIp -RemoveUserLogin Administrator -DisableCertificateAuthentication -Username $newadmin -Password $pass
}

#Add/refresh in OneView
Write-Verbose "Adding / verifying in OneView"
if($AddOneView -and $ovconn){
    $ovhw = Get-HPOVServer -Name $iloName -ErrorAction SilentlyContinue
    if($ovhw){
        Write-Verbose "Server found in OneView, refreshing"
        Update-HPOVServer $ovhw -Async
    }
    else{
        $ovhwservers = Get-HPOVServer
        if($serial -in $ovhwservers.serialnumber){
            $ovhw = $ovhwservers | Where-Object {$_.serialnumber -eq $serial}
            Write-Verbose "Server found in OneView based on serialnumber, refreshing"
            Update-HPOVServer $ovhw -Async
        }
        else{
            Write-Verbose "Server not found in OneView, adding"
            New-HPOVServer -Hostname $ILOIP -Username $newadmin -Password $pass -LicensingIntent OneView #| Wait-HPOVTaskComplete
            
            $ovhw = Get-HPOVServer -Name $iloName
            if($ovhw){
                
                Write-Verbose "Server added"
            }
        }
    }

    if(!$ovhw.serverProfileUri){
        Write-Verbose "No Server Profile found, creating"
        #Choose template based on model (ok), and what it will be used for (missing)
        $hwtype = Get-HPOVServerHardwareType -Model $productName
        Write-Verbose "Hardware type found : $($hwtype.name)"

        $template = Get-HPOVServerProfileTemplate -ServerHardwareType $hwtype

        if($template.count -gt 1){
            Write-Warning "Multiple templates found, please specify"
            Write-Output $template.name
            $templatename = Read-Host "Specify template name"
            $template = Get-HPOVServerProfileTemplate -Name $templatename
        }
        
        if($template){
            Write-Verbose "Proceeding with template $($template.name)"
            if((Get-HPOVServer -Name $iloName).Powerstate -eq "On"){
                Write-Warning "Server power is on"
                $answer = Read-Host "Do you want to power off server to continue? y/n"
                if($answer -eq "y"){
                    $ovhw | Stop-HPOVServer -Confirm:$true | Wait-HPOVTaskComplete
                    New-HPOVServerProfile -Name $Servername -Server $ovhw -ServerProfileTemplate $template -AssignmentType Server -Async
                }
                else{
                    Write-Warning "Cannot assign profile to server"
                    New-HPOVServerProfile -Name $Servername -ServerProfileTemplate $template -AssignmentType Server -Async
                }
            }
            else{
                New-HPOVServerProfile -Name $Servername -Server $ovhw -ServerProfileTemplate $template -AssignmentType Server -Async
            }
            
        }
        else{
            Write-Warning "No templates found, exiting"
        }
    }

}


#Disconnect from OV and BIOS
Disconnect-HPOVMgmt $ovconn -ErrorAction SilentlyContinue
Disconnect-HPEBIOS $conn -ErrorAction SilentlyContinue
