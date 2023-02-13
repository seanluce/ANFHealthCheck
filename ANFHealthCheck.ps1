param (
    [string]$subId,
    [string]$OutFile,
    [string]$Subject = "Azure NetApp Files Health Report",
    [boolean]$remediateOnly = $false #set to true if you do not want the HTML report to be generated
)

Import-Module Az.Accounts
Import-Module Az.NetAppFiles
Import-Module Az.Resources
Import-Module Az.Monitor
Import-Module Az.Storage
Import-Module Az.VMware

#User Modifiable Parameters
$sendMethod = "email" # choose blob or email
$volumePercentFullWarning = 20 #highlight volume if consumed % is greater than or equal to
$volumePercentUnderWarning = 10 #highlight volume if consumed % is less than or equal to
$volumePercentUnderWarningMinSize = 0 #used with above variable to only show volumes larger than this size
$poolPercentAllocatedWarning = 90 #highlight pool if allocated % is less than or equal to
$poolPercentAllocatedWarningMinSize = 0 #used with above variable to only show pool larger than this size
$volumeSpaceGiBTooLow = 25 #highlight volume if available space is below or equal to
$oldestSnapTooOldThreshold = 30 #days, highlight snapshot date if oldest snap is older than or equal to
$mostRecentSnapTooOldThreshold = 48 #hours, highlight snapshot date if newest snap is older than or equal to 
$oldestBackupTooOldThreshold = 360 #days, highlight snapshot date if oldest snap is older than or equal to
$mostRecentBackupTooOldThreshold = 48 #hours, highlight snapshot date if newest snap is older than or equal to
$volumeConsumedDaysAgo = 7 #days ago to display for volume utilization growth over time
$regionProvisionedPercentWarning = 90 #highlight region if provisioned against quota higher than this value

#Used to filter volume list for a certain tag and value
$volumeTagName = 'purpose' #name of tag to filter
$volumeTagValue = 'restore' #value of tag to filter

#Remediation Volume Headroom
$enableVolumeCapacityRemediation = $true #true will enable remediation and show remediation report in HTML output
$enableVolumeCapacityRemediationDryRun = $true #false will resize volumes down to desired headroom
$volumePercentDesiredHeadroomGlobal = 0 #Use with care as this has the potential to reduce volume sizes that are over-provisioned for performance. Consider using individual volume tags instead.

#Remediation Pool Headroom
$enablePoolCapacityRemediation = $true #true will enable remediation and show remediation report in HTML output
$enablePoolCapacityRemediationDryRun = $true #false will resize capacity pools down to desired headroom
$poolPercentDesiredHeadroomGlobal = -1 #set to -1 to disable for all capacity pools unless they have the tag: anfhealthcheck_desired_headroom set to 0 or greater
$minPoolSizeGiB = 4096 # use this to set the minimum pool size

# Connect using a Managed Service Identity
try {
        (Connect-AzAccount -Identity).context
    }
catch{
        Write-Output "There is no managed service identity. Aborting."; 
        exit
    }

# Connects using custom credentials if AzureRunAsConnection can't be used
# $credentials = Get-AutomationPSCredential -Name "YOURCREDS"
# Connect-AzAccount -ServicePrincipal -Credential $credentials -Tenant "YOURTENANT"

function Send-Email() {
    #####
    ## Send finalResult as email
    #####
    $Username ="YOURUSERNAME"
    $Password = ConvertTo-SecureString "YOURSECRET" -AsPlainText -Force # SendGrid password
    $credential = New-Object System.Management.Automation.PSCredential $Username, $Password
    $SMTPServer = "smtp.myserver.net"
    $EmailFrom = "aaa@xyz.com" # Can be anything - aaa@xyz.com
    $EmailTo = "aaa@xyz.com" # Valid recepient email address
    $Body = $finalResult
    Send-MailMessage -smtpServer $SMTPServer -Credential $credential -Usessl -Port 587 -from $EmailFrom -to $EmailTo -subject $Subject -Body $Body -BodyAsHtml -Attachments poolDetails.csv, volumeDetails.csv
}
Function Save-Blob() {
    $dateStamp = get-date -format "yyyyMMddHHmm"
    $blobName = "ANFHealthCheck_" + $dateStamp + ".html"
    $storageAccountRg = "sluce.rg"
    $storageAccountName =  "seanshowback"
    $containerName = 'anfhealthcheck' # to use Azure Static Sites, set to $web
    $finalResult | out-file -filepath $blobName
    $storageAccount = Set-AzStorageAccount -ResourceGroupName $storageAccountRg -Name $storageAccountName
    $context = $storageAccount.context
    try {
        New-AzStorageContainer -name $containerName -context $context -Permission off -ErrorAction Stop # change permissions to 'blob' for read access to blob
    }
    catch {
        "Container already exists."
    }
    Set-AzStorageBlobContent $blobName -Container $containername -blob $blobName -context $context -Properties @{"ContentType" = 'text/html'} -Force
    Set-AzStorageBlobContent $blobName -Container $containername -blob "index.html" -context $context -Properties @{"ContentType" = 'text/html'} -Force
    Remove-Item $blobName
}
function Get-ANFAccounts() {
    return Get-AzResource | Where-Object {$_.ResourceType -eq "Microsoft.NetApp/netAppAccounts"}
}
function Get-ANFPools() {
    return Get-AzResource | Where-Object {$_.ResourceType -eq "Microsoft.NetApp/netAppAccounts/capacityPools"}
}
function Get-ANFVolumes() {
    ## Use this function to limit the scope to a specific resource group
    return Get-AzResource | Where-Object {$_.ResourceType -eq "Microsoft.NetApp/netAppAccounts/capacityPools/volumes"}
}
function Get-ANFVolumeDetails($volumeConsumedSizes) {
    $volumeObjects = @()
    foreach($volume in $volumes) {
        $desiredHeadroomPercent = $null
        $volumeDetail = Get-AzNetAppFilesVolume -ResourceId $volume.ResourceId
        $volumePercentConsumed = [Math]::Round(($volumeConsumedSizes[$volume.ResourceId]/$volumeDetail.UsageThreshold)*100,2)
        $tagDesiredHeadroom = $volumeDetail.Tags.anfhealthcheck_desired_headroom #remediation
        if($tagDesiredHeadroom){
            $desiredHeadroomPercent = [int]$tagDesiredHeadroom
        }elseif($volumePercentDesiredHeadroomGlobal -gt 0){
            $desiredHeadroomPercent = $volumePercentDesiredHeadroomGlobal
        }else {
            $desiredHeadroomPercent = 0
        }
        $volumeCustomObject = [PSCustomObject]@{
            Volume = $volumeDetail.name.split('/')[2]
            capacityPool = $volumeDetail.name.split('/')[1]
            netappAccount = $volumeDetail.name.split('/')[0]
            URL = 'https://portal.azure.com/#@' + $Subscription.TenantId + '/resource' + $volume.ResourceId
            Location = $volumeDetail.Location
            Provisioned = $volumeDetail.UsageThreshold/1024/1024/1024
            Consumed = [Math]::Round($volumeConsumedSizes[$volume.ResourceId]/1024/1024/1024,2)
            Available = [Math]::Round(($volumeDetail.UsageThreshold - $volumeConsumedSizes[$volume.ResourceId])/1024/1024/1024,2)
            ConsumedPercent = $volumePercentConsumed
            capacityPercentHeadroom = 100 - $volumePercentConsumed #remediation
            desiredHeadroom = $desiredHeadroomPercent
            ResourceID = $volume.ResourceId
            SnapshotPolicyId = $volumeDetail.DataProtection.Snapshot.SnapshotPolicyId
            BackupPolicyId = $volumeDetail.DataProtection.Backup.BackupPolicyId
            BackupVaultId = $volumeDetail.DataProtection.Backup.VaultId
            BackupEnabled = $volumeDetail.DataProtection.Backup.BackupEnabled
            BackupPolicyEnforced = $volumeDetail.DataProtection.Backup.PolicyEnforced #this is GUI setting 'Policy Suspended'
            EndpointType = $volumeDetail.DataProtection.Replication.endPointType
            RemoteVolumeResourceId = $volumeDetail.DataProtection.Replication.RemoteVolumeResourceId
            ReplicationSchedule = $volumeDetail.DataProtection.Replication.ReplicationSchedule
            SubnetId = $volumeDetail.SubnetId
            Tags = $volumeDetail.Tags
            AvsDataStore = $volumeDetail.AvsDataStore
        }
        Export-Csv -InputObject $volumeCustomObject -Append -Path volumeDetails.csv 
        $volumeObjects += $volumeCustomObject
    }
    return $volumeObjects
}
function ANFVolumeCapacityRemediation {
    if($enableVolumeCapacityRemediationDryRun -eq $true) {
        $title = '<h3>Volume Capacity Remediation (dry run only)</h3>'
    }else {
        $title = '<h3>Volume Capacity Remediation</h3>'
    }
    $finalResult += $title
    $finalResult += '<table>'
    $finalResult += '<th>Volume</th><th>Capacity Pool</th><th>Location</th><th>Desired Headroom</th><th>Consumed (GiB)</th><th>Previous Quota (GiB)</th><th>New Quota (GiB)</th>'
    foreach($volume in $volumeDetails) {
        if($volume.desiredHeadroom -gt 0 -and $volume.capacityPercentHeadroom -gt $volume.desiredHeadroom -and $volume.Provisioned -gt 100) {
            $newQuota = $volume.consumed * (1 + ($volume.desiredHeadroom / 100))
            if($newQuota -le 100) {
                $newQuotaWholeGiB = 100
            } elseif($newQuota -gt 100) {
                $newQuotaWholeGiB = [Math]::Round($newQuota,0)
            }
            $finalResult += '<tr><td><a href="' + $volume.URL + '">' + $volume.Volume + '</a></td><td>' + $volume.capacityPool + '</td><td>' + $volume.Location + '</td><td>' + $volume.desiredHeadroom + '%</td><td>' + $volume.consumed + '</td><td>' + $volume.Provisioned + '</td><td>' + $newQuotaWholeGiB + '</td></tr>'
            if($enableVolumeCapacityRemediationDryRun -eq $false) {
                $newQuotaBytes = $newQuotaWholeGiB * 1024 * 1024 * 1024
                $null = Update-AzNetAppFilesVolume -ResourceId $volume.ResourceID -UsageThreshold $newQuotaBytes
            }
        }
    }
    $finalResult += '</table><br>'
    return $finalResult
}
function Get-ANFVolumeConsumedSizes($days) {
    #####
    ## Collect all Volume Consumed Sizes ##
    #####
    $volumeConsumedSizes = @{}
    $endTime = [datetime]::Now.AddDays(-$days)
    $startTime = $endTime.AddMinutes(-30)
    foreach($volume in $volumes) {
        $consumedSize = 0
        $volumeConsumedDataPoints = Get-AzMetric -ResourceId $volume.ResourceId -MetricName "VolumeLogicalSize" -StartTime $startTime -EndTime $endTime -TimeGrain 00:5:00 -WarningAction:SilentlyContinue -EA SilentlyContinue
        foreach($dataPoint in $volumeConsumedDataPoints.data) {
            if($dataPoint.Average -gt $consumedSize) {
                $consumedSize = $dataPoint.Average
            }
        }
        $volumeConsumedSizes.add($volume.ResourceId, $consumedSize)
    }
    return $volumeConsumedSizes
    ## Collect all Volume Consumed Sizes ##
}
function Get-ANFCapacityPoolAllocatedSizes() {
    #####
    ## Collect all Capacity Pool Allocated Sizes ##
    #####
    $capacityPoolAllocatedSizes = @{}
    $startTime = [datetime]::Now.AddMinutes(-15)
    $endTime = [datetime]::Now
    foreach($capacityPool in $capacityPools) {
        $metricValue = 0
        $dataPoints = Get-AzMetric -ResourceId $capacityPool.ResourceId -MetricName "VolumePoolAllocatedUsed" -StartTime $startTime -EndTime $endTime -TimeGrain 00:5:00 -WarningAction:SilentlyContinue -EA SilentlyContinue
        foreach($dataPoint in $dataPoints.data) {
            if($dataPoint.Average -gt $metricValue) {
                $metricValue = $dataPoint.Average
            }
        }
        $capacityPoolAllocatedSizes.add($capacityPool.ResourceId, $metricValue)
    }
    return $capacityPoolAllocatedSizes
    ## Collect all Volume Consumed Sizes ##
}
function Get-ANFPoolDetails($poolAllocatedSizes) {
    $poolObjects = @()
    foreach($pool in $capacityPools) {
        $desiredHeadroomPercent = $null
        $poolDetail = Get-AzNetAppFilesPool -ResourceId $pool.ResourceId
        $poolPercentAllocated = [Math]::Round(($poolAllocatedSizes[$pool.ResourceId]/$poolDetail.Size)*100,2)
        $tagDesiredHeadroom = $poolDetail.Tags.anfhealthcheck_desired_headroom #remediation
        if($tagDesiredHeadroom){
            $desiredHeadroomPercent = [int]$tagDesiredHeadroom
        }
        if(!($desiredHeadroomPercent) -and $poolPercentDesiredHeadroomGlobal -ge 0){
            $desiredHeadroomPercent = $poolPercentDesiredHeadroomGlobal
        }
        $poolCustomObject = [PSCustomObject]@{
            capacityPool = $poolDetail.name.split('/')[1]
            netappAccount = $poolDetail.name.split('/')[0]
            ServiceLevel = $poolDetail.ServiceLevel
            desiredHeadroom = $desiredHeadroomPercent
            QosType = $poolDetail.QosType
            URL = 'https://portal.azure.com/#@' + $Subscription.TenantId + '/resource' + $pool.ResourceId
            Location = $poolDetail.Location
            Provisioned = $poolDetail.Size/1024/1024/1024
            Allocated = [Math]::Round($poolAllocatedSizes[$pool.ResourceId]/1024/1024/1024,2)
            AllocatedPercent = $poolPercentAllocated
            capacityPercentHeadroom = 100 - $poolPercentAllocated
            ResourceID = $pool.ResourceID
        }
        Export-Csv -InputObject $poolCustomObject -Append -Path poolDetails.csv 
        $poolObjects += $poolCustomObject
    }
    return $poolObjects
}
function ANFPoolCapacityRemediation {
    if($enablePoolCapacityRemediationDryRun -eq $true) {
        $title = '<h3>Capacity Pool Capacity Remediation (dry run only)</h3>'
    }else {
        $title = '<h3>Capacity Pool Capacity Remediation</h3>'
    }
    $finalResult += $title
    $finalResult += '<table>'
    $finalResult += '<th>Pool Name</th><th>Location</th><th>Desired Headroom</th><th>Allocated (GiB)</th><th>Previous Size (GiB)</th><th>New Size (GiB)</th>'
    foreach($pool in $poolDetails) {
        $newSize = $null
        if($pool.desiredHeadroom -ge 0 -and $pool.capacityPercentHeadroom -gt $pool.desiredHeadroom -and $pool.Provisioned -gt 0) {
            $newSize = $pool.Allocated * (1 + ($pool.desiredHeadroom / 100))
            if($newSize -le $minPoolSizeGiB) {
                $newSizeWholeGiB = $minPoolSizeGiB
            } elseif($newSize -gt $minPoolSizeGiB) {
                $newSizeWholeGiB = [Math]::Round($newSize,0)
                if($newSizeWholeGiB % 1024 -gt 0){
                    $newSizeWholeGiB = ([int][Math]::Floor($newSizeWholeGiB / 1024) + 1) * 1024
                }
            }
            if($newSizeWholeGiB -lt $pool.Provisioned){
                $finalResult += '<tr><td><a href="' + $pool.URL + '">' + $pool.capacityPool + '</a></td><td>' + $pool.Location + '</td><td>' + $pool.desiredHeadroom + '%</td><td>' + $pool.Allocated + '</td><td>' + $pool.Provisioned + '</td><td>' + $newSizeWholeGiB + '</td></tr>'
                if($enablePoolCapacityRemediationDryRun -eq $false) {
                    Start-Sleep 180
                    $null = Update-AzNetAppFilesPool -ResourceId $pool.ResourceID -PoolSize ($newSizeWholeGiB*1024*1024*1024)
                }
            }
        }
    }
    $finalResult += '</table><br>'
    return $finalResult
}
function Get-ANFAVSdatastoreVolumeDetails() {
    $privateClouds = Get-AzVMwarePrivateCloud
    $datastoreObjects = @()
    foreach($privateCloud in $privateClouds){
        $dataStoreURI = '/subscriptions/' + $Subscription.Id + '/resourceGroups/' + $privateCloud.ResourceGroupName + '/providers/Microsoft.AVS/privateClouds/' + $privateCloud.Name + '/clusters/Cluster-1/datastores?api-version=2021-12-01'
        $listParams = @{
            Path = $dataStoreURI
            Method = 'GET'
        }
        $rawData = (Invoke-AzRestMethod @listParams).Content
        $objectData = ConvertFrom-Json $rawData
        foreach($datastore in $objectData.value) {
            $datastoreDetail = Get-AzNetAppFilesVolume -ResourceId $datastore.properties.netAppVolume.Id -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
            if($datastoreDetail){
                $datastoreCustomObject = [PSCustomObject]@{
                    URL = 'https://portal.azure.com/#@' + $Subscription.TenantId + '/resource' + $datastore.Id
                    datastoreId = $datastore.Id
                    privateCloud = $datastore.Id.split('/')[8]
                    cluster = $datastore.Id.split('/')[10]
                    datastore = $datastore.Id.split('/')[12]
                    volume = $datastoreDetail.name.split('/')[2]
                    capacityPool = $datastoreDetail.name.split('/')[1]
                    netappAccount = $datastoreDetail.name.split('/')[0]
                    Location = $datastoreDetail.Location
                    provisionedSize = $datastoreDetail.UsageThreshold/1024/1024/1024
                    ResourceID = $datastoreDetail.Id
                    SubnetId = $datastoreDetail.SubnetId
                    Tags = $datastoreDetail.Tags
                    AvsDataStore = $datastoreDetail.AvsDataStore
                }
                $datastoreObjects += $datastoreCustomObject
            }
        }
    }
    return $datastoreObjects   
}
function Show-ANFVNetsIPUsage() {
    $finalResult += '<h3>Virtual Network IP Report</h3>'
    $finalResult += '<table>'
    $finalResult += '<th>VNet Name</th><th>Location</th><th>Resource Group</th><th class="center">VNet IPs</th><th class="center">Peered IPs</th><th class="center">Total IPs</th>'
    $vnets = Get-AzVirtualNetwork
    foreach($vnet in $vnets | Where-Object {$_.subnets.delegations.serviceName -eq "Microsoft.NetApp/volumes"}) {
        $finalResult += '<tr><td>' + $vnet.Name + '</td><td>' + $vnet.Location + '</td><td>' + $vnet.ResourceGroupName + '</td>'
        $anfvnetURI = $vnet.Id.tolower().Split("/")
        $RG_Index = [array]::indexof($anfvneturi,"resourcegroups")
        $SubID = $anfvneturi[$RG_Index -1]
        $ResourceGroup = $anfvneturi[$RG_Index + 1]
        #$ResourceProvider = $anfvneturi[$RG_Index + 3]
        #$RP_sub_catagory = $anfvneturi[$RG_Index + 4]
        $Resource = $anfvneturi[$RG_Index + 5]
        #Region Variable to check for global peering
        $region = ""
        #Set last sub value to keep from running set-context on the first loop if they're equal
        $lastsub = $SubID
        #Reset/Initiate Main Vnet Variables
        $mainVnetTotal = 0
        $subnet = ""
        $subnets = ""
        $templist = ""
        $x = 0
        #Set Subscription Context
        Set-AzContext -subscription $SubID *>$null
        #Get the original VNET that was sent in via parameters
        $ANFVNET = Get-AzVirtualNetwork -Name $Resource -ResourceGroupName $ResourceGroup
        if ($ANFVNET.id.Length -gt 0) {
            #Set the value to check for global peering
            #Global peering is not supported so shouldn't count against the total.
            $region = $ANFVNET.Location
            #Get All Subnets IP usage
            $subnets = Get-AzVirtualNetworkUsageList -ResourceGroupName $ResourceGroup -Name $Resource
            foreach ($subnet in $subnets) {
                $templist = $subnet | Select-object -Property CurrentValue
                foreach($x in $templist) {
                    $mainVnetTotal = $mainVnetTotal + $x.CurrentValue
                }
            }
            #write-host "ANF VNet Total: " $mainVnetTotal
            #Reset/initiate Variables for Peers
            $subnet = ""
            $subnets= ""
            $peerstotal = 0
            $templist = ""
            $x=0
            $peers = Get-AzVirtualNetworkPeering -VirtualNetworkName $Resource -ResourceGroupName $ResourceGroup | Sort-Object -Property RemoteVirtualNetwork
            #ensure we have peers to work with.
            if ($peers.count -gt 0) {
                #Using the $peers list, loop through and perform get on the virtual network and all associated IPs.
                foreach($peer in $peers) {
                    $RG_Index = ""
                    $SubID = ""
                    $ResourceGroup = ""
                    #$ResourceProvider = ""
                    #$RP_sub_catagory = ""
                    $Resource = ""
                    #This gets the URI of the current Peer
                    $peerVnet = $peer.RemoteVirtualNetwork.id.ToString()
                    $peervnetURI = $peerVnet.tolower().Split("/")
                    #this parses the current uri
                    $RG_Index = [array]::indexof($peervnetURI,"resourcegroups")
                    $SubID = $peervnetURI[$RG_Index -1]
                    $ResourceGroup = $peervnetURI[$RG_Index + 1]
                    $ResourceProvider = $peervnetURI[$RG_Index + 3]
                    $RP_sub_catagory = $peervnetURI[$RG_Index + 4]
                    $Resource = $peervnetURI[$RG_Index + 5]
                    #add logic to switch subscription if it's not the same from the last run.
                    if($lastsub -ne $SubID){
                        Set-AzContext -subscription $SubID *>$null
                    }
                    #Get peered vnet
                    try {
                        $peeredVNet = Get-AzVirtualNetwork -Name $Resource -ResourceGroupName $ResourceGroup -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
                    }
                    catch {
                    }
                    #check for global peering which is not routed, so this wouldn't go against the total.
                    if ($region -eq $peeredVNet.Location) {
                        #Get All Subnets IP usage from the peered vnet
                        $subnets = Get-AzVirtualNetworkUsageList -ResourceGroupName $ResourceGroup -Name $Resource
                        foreach ($subnet in $subnets) {
                            $templist = $subnet | Select-object -Property CurrentValue
                            foreach($x in $templist) {
                                $peerstotal = $peerstotal + $x.CurrentValue
                            }
                        }#foreach subnet end
                    } #end global peering check if
                    #Set Last subscription that was used.
                    $lastsub = $SubID
                }
                #write-host "Peered Vnet Total: " $peerstotal
                $GrandTotal = $mainVnetTotal + $peerstotal
                $finalResult += '<td class="center">' + $mainVnetTotal + '</td><td class="center">' + $peerstotal +'</td><td class="center">' + $GrandTotal + '</td></tr>'
            }
            else{
            #write-host "Peered Vnet Total: No peers"
            $GrandTotal = $mainVnetTotal
            $finalResult += '<td class="center">' + $mainVnetTotal + '</td><td class="center">0</td><td class="center">' + $GrandTotal + '</td></tr>'
            }
            #Write-Host "Total: " $GrandTotal
        }
    }
    $finalResult += '</table><br>'
    return $finalResult
}
function Show-ANFNetAppAccountSummary() {
    #####
    ## Display ANF NetApp Account Summary
    #####
    $finalResult += '<h3>NetApp Account Summary</h3>'
    $finalResult += '<table>'
    $finalResult += '<th>Account Name</th><th>Location</th><th>Resource Group</th><th>Active Directory Domain</th>'
    foreach($netAppAccount in $netAppAccounts) {
        $accountDetail = Get-AzNetAppFilesAccount -ResourceId $netAppAccount.ResourceId | Select-Object Name, Location, ResourceGroupName, ActiveDirectories
        $finalResult += '<tr>'
        $finalResult += '<td><a href="https://portal.azure.com/#@' + $Subscription.TenantId + '/resource' + $netAppAccount.ResourceId + '">' + $accountDetail.Name + '</a></td><td>' + $accountDetail.Location + '</td><td>' + $accountDetail.ResourceGroupName + '</td><td>' + $accountDetail.ActiveDirectories.Domain + '</td>'
        $finalResult += '</tr>'
    }
    $finalResult += '</table><br>'
    return $finalResult
}
function Show-ANFRegionalProvisioned() {
    #####
    ## Display provisioned capacity per region
    #####
    $allANFRegions = Get-AzLocation | Where-Object {$_.Providers -contains "Microsoft.NetApp"}
    $regionCapacityQuota = @{}
    foreach($netappAccount in $netAppAccounts) {
        try {
            $currentQuota = Get-AzNetAppFilesQuotaLimit -Location $netappAccount.Location | where-object {$_.Name -like "*totalTiBsPerSubscription*"} -WarningAction:Ignore -EA Ignore
            $regionCapacityQuota.add($netappAccount.Location, $currentQuota.Current)
        }
        catch {
            $regionCapacityQuota.add($netappAccount.Location, 25)
        }
    }
    $finalResult += '<h3>Capacity Provisioned Against Regional Quota</h3>'
    $finalResult += '<table>'
    $finalResult += '<th>Region</th><th class="center">Quota (TiB)</th><th class="center">Provisioned (TiB)</th><th class="center">Provisioned (%)</th>'
    $regionAllocated = @{}
    foreach($capacityPool in $capacityPools) {
        $poolDetail = Get-AzNetAppFilesPool -ResourceId $capacityPool.ResourceId
        $regionAllocated[$poolDetail.Location] += $poolDetail.Size 
    }
    foreach($region in $regionAllocated.Keys) {
        if($regionCapacityQuota[$region]) {
            $thisRegionQuota = $regionCapacityQuota[$region] 
        } else {
            $thisRegionQuota = 25
        }
        $percentofQuota = [Math]::Round((($regionAllocated[$region]/1024/1024/1024/1024 / $thisRegionQuota) * 100),2)
        $finalResult += '<tr>' + '<td>' + $region + '</td><td class="center">' + $thisRegionQuota + '</td><td class="center">' + $regionAllocated[$region]/1024/1024/1024/1024  + '</td>'
        if($percentofQuota -ge $regionProvisionedPercentWarning) {
            $finalResult += '<td class="warning">' + $percentofQuota + '%</td></tr>'
        } else {
            $finalResult += '<td class="center">' + $percentofQuota + '%</td></tr>'
        }
    }
    $finalResult += '</table><br>'
    return $finalResult
}
function Show-ANFCapacityPoolUnderUtilized() {
    #####
    ## Display ANF Capacity Pools that are under-utilized
    #####
    $finalResult += '<h3>Capacity Pool Utilization below ' + $poolPercentAllocatedWarning + '% (pool >= ' + $poolPercentAllocatedWarningMinSize + ' GiB)</h3>'
    $finalResult += '<table>'
    $finalResult += '<th>Pool Name</th><th>Location</th><th>Service Level</th><th>QoS Type</th><th class="center">Provisioned (GiB)</th><th class="center">Allocated (GiB)</th><th class ="center">Allocated (%)</th>'
    foreach($poolDetail in $poolDetails | Sort-Object -Property AllocatedPercent -Descending) {
        if($poolDetail.AllocatedPercent -le $poolPercentAllocatedWarning -and $poolDetail.Provisioned -gt $poolPercentAllocatedWarningMinSize) {
            $finalResult += '<tr>'
            $finalResult += '<td><a href="' + $poolDetail.URL + '">' + $poolDetail.capacityPool + '</a></td><td>' + $poolDetail.Location + '</td><td>' + $poolDetail.ServiceLevel + '</td><td>' + $poolDetail.QosType + '</td><td class = "center">' + $poolDetail.Provisioned + '</td>'
            $finalResult += '<td class="center">' + $poolDetail.Allocated + '</td>'
            $finalResult += '<td class="warning">' + $poolDetail.AllocatedPercent + '%</td></tr>'
        } 
    }
    $finalResult += '</table><br>'
    return $finalResult
}
function Show-ANFCapacityPoolUtilization() {
    #####
    ## Display ANF Capacity Pools with Used Percentages
    #####
    $finalResult += '<h3>Capacity Pool Utilization</h3>'
    $finalResult += '<table>'
    $finalResult += '<th>Pool Name</th><th>Location</th><th>Service Level</th><th>QoS Type</th><th class="center">Provisioned (GiB)</th><th class="center">Allocated (GiB)</th><th class ="center">Allocated (%)</th>'
    foreach($poolDetail in $poolDetails | Sort-Object -Property AllocatedPercent -Descending) {
        $finalResult += '<tr>'
        $finalResult += '<td><a href="' + $poolDetail.URL + '">' + $poolDetail.capacityPool + '</a></td><td>' + $poolDetail.Location + '</td><td>' + $poolDetail.ServiceLevel + '</td><td>' + $poolDetail.QosType + '</td><td class = "center">' + $poolDetail.Provisioned + '</td>'
        $finalResult += '<td class="center">' + $poolDetail.Allocated + '</td>'
        if($poolDetail.AllocatedPercent -le $poolPercentAllocatedWarning) {
            $finalResult += '<td class="warning">' + $poolDetail.AllocatedPercent + '%</td>'
        } else {
            $finalResult += '<td class="center">' + $poolDetail.AllocatedPercent + '%</td>'
        }
        $finalResult += '</tr>'
    }
    $finalResult += '</table><br>'
    return $finalResult
}
function Show-ANFVolumeUtilizationAboveThreshold() {
    #####
    ## Display ANF Volumes with Used Percentages above Threshold
    #####
    $finalResult += '<h3>Volume Utilization above ' + $volumePercentFullWarning + '%</h3>'
    $finalResult += '<table>'
    $finalResult += '<th>Volume Name</th><th>Location</th><th>Capacity Pool</th><th class="center">Provisioned (GiB)</th><th class="center">Available (GiB)</th><th class="center">Consumed (GiB)</th><th class="center">Consumed (%)</th>'
        foreach($volume in $volumeDetails | Sort-Object -Property ConsumedPercent -Descending) {  
            if($volume.ConsumedPercent -ge $volumePercentFullWarning) {
                $finalResult += '<tr><td><a href="' + $volume.URL + '">' + $volume.Volume + '</a></td><td>' + $volume.Location + '</td><td>' + $volume.capacityPool + '</td><td class="center">' + $volume.Provisioned + '</td>'
                if ($volume.Available -le $volumeSpaceGiBTooLow) {
                    $finalResult += '<td class="warning">' + $volume.Available + '</td>'
                } else {
                    $finalResult += '<td class="center">' + $volume.Available + '</td>'
                }
                $finalResult += '<td class="center">' + $volume.Consumed + '</td><td class="warning">' + $volume.ConsumedPercent + '%</td></tr>'
            } 
    }
    $finalResult += '</table><br>'
    return $finalResult
}
function Show-ANFVolumeUtilizationBelowThreshold() {
    #####
    ## Display ANF Volumes with Used Percentages above Threshold
    #####
    $finalResult += '<h3>Volume Utilization below ' + $volumePercentUnderWarning + '% (volumes >= ' + $volumePercentUnderWarningMinSize + ' GiB)</h3>'
    $finalResult += '<table>'
    $finalResult += '<th>Volume Name</th><th>Location</th><th>Capacity Pool</th><th class="center">Provisioned (GiB)</th><th class="center">Available (GiB)</th><th class="center">Consumed (GiB)</th><th class="center">Consumed (%)</th>'
        foreach($volume in $volumeDetails | Sort-Object -Property ConsumedPercent -Descending) {  
            if($volume.ConsumedPercent -le $volumePercentUnderWarning -and $volume.Provisioned -ge $volumePercentUnderWarningMinSize) {
                $finalResult += '<tr><td><a href="' + $volume.URL + '">' + $volume.Volume + '</a></td><td>' + $volume.Location + '</td><td>' + $volume.capacityPool + '</td><td class="center">' + $volume.Provisioned + '</td>'
                if ($volume.Available -le $volumeSpaceGiBTooLow) {
                    $finalResult += '<td class="warning">' + $volume.Available + '</td>'
                } else {
                    $finalResult += '<td class="center">' + $volume.Available + '</td>'
                }
                $finalResult += '<td class="center">' + $volume.Consumed + '</td><td class="warning">' + $volume.ConsumedPercent + '%</td></tr>'
            } 
    }
    $finalResult += '</table><br>'
    return $finalResult
}
function Show-ANFVolumeUtilization() {
    #####
    ## Display ANF Volumes with Used Percentages
    #####
    $finalResult += '<h3>Volume Utilization</h3>'
    $finalResult += '<table>'
    $finalResult += '<th>Volume Name</th><th>Location</th><th>Capacity Pool</th><th class="center">Provisioned (GiB)</th><th class="center">Available (GiB)</th><th class="center">Consumed (GiB)</th><th class="center">Consumed (%)</th>'
        foreach($volume in $volumeDetails | Sort-Object -Property ConsumedPercent -Descending) {  
            $finalResult += '<tr><td><a href="' + $volume.URL + '">' + $volume.Volume + '</a></td><td>' + $volume.Location + '</td><td>' + $volume.capacityPool + '</td><td class="center">' + $volume.Provisioned + '</td>'
            if ($volume.Available -le $volumeSpaceGiBTooLow) {
                $finalResult += '<td class="warning">' + $volume.Available + '</td>'
            } else {
                $finalResult += '<td class="center">' + $volume.Available + '</td>'
            }
            $finalResult += '<td class="center">' + $volume.Consumed + '</td>'
            if($volume.ConsumedPercent -ge $volumePercentFullWarning -or $volume.ConsumedPercent -le $volumePercentUnderWarning) {
                $finalResult += '<td class="warning">' + $volume.ConsumedPercent + '%</td></tr>'
            } else {
                $finalResult += '<td class="center">' + $volume.ConsumedPercent + '%</td></tr>'
            }
    }
    $finalResult += '</table><br>'
    return $finalResult
}
function Show-ANFVolumeUtilizationFilterTag() {
    #####
    ## Display ANF Volumes with Used Percentages filtered by tag
    #####
    $finalResult += '<h3>Volume Utilization (tag: ' + $volumeTagName + ' = ' + $volumeTagValue + ')</h3>'
    $finalResult += '<table>'
    $finalResult += '<th>Volume Name</th><th>Location</th><th>Capacity Pool</th><th class="center">Provisioned (GiB)</th><th class="center">Available (GiB)</th><th class="center">Consumed (GiB)</th><th class="center">Consumed (%)</th>'
        $volumesMatchingTag = $volumeDetails | where-object {$_.Tags.$volumeTagName -eq $volumeTagValue}
        foreach($volume in $volumesMatchingTag | Sort-Object -Property ConsumedPercent -Descending) {  
            $finalResult += '<tr><td><a href="' + $volume.URL + '">' + $volume.Volume + '</a></td><td>' + $volume.Location + '</td><td>' + $volume.capacityPool + '</td><td class="center">' + $volume.Provisioned + '</td>'
            if ($volume.Available -le $volumeSpaceGiBTooLow) {
                $finalResult += '<td class="warning">' + $volume.Available + '</td>' 
            } else {
                $finalResult += '<td class="center">' + $volume.Available + '</td>'
            }
            $finalResult += '<td class="center">' + $volume.Consumed + '</td>'
            if($volume.ConsumedPercent -ge $volumePercentFullWarning -or $volume.ConsumedPercent -le $volumePercentUnderWarning) {
                $finalResult += '<td class="warning">' + $volume.ConsumedPercent + '%</td></tr>'
            } else {
                $finalResult += '<td class="center">' + $volume.ConsumedPercent + '%</td></tr>'
            }
    }
    $finalResult += '</table><br>'
    return $finalResult
}
function Show-ANFVolumeUtilizationGrowth() {
    #####
    ## Display ANF Volumes with consumption today and previous
    #####
    $finalResult += '<h3>Volume Utilization Growth (' + $volumeConsumedDaysAgo + ' days)</h3>'
    $finalResult += '<table>'
    $finalResult += '<th>Volume Name</th><th>Location</th><th>Capacity Pool</th><th class="center">Previous Consumed (GiB)</th><th class="center">Today Consumed (GiB)</th><th class="center">Change (%)</th>'
        foreach($volume in $volumeDetails | Sort-Object -Property ConsumedPercent -Descending) {
            if($previousVolumeConsumedSizes[$volume.ResourceId] -gt 0 -and $volume.Consumed -gt 0) {
                try {
                    $percentChange = ([Math]::Round((($volume.Consumed - [Math]::Round($previousVolumeConsumedSizes[$volume.ResourceId]/1024/1024/1024,2)) / [Math]::Round($previousVolumeConsumedSizes[$volume.ResourceId]/1024/1024/1024,2)),2)) * 100
                }
                catch {
                    $percentChange = 0
                }
                $finalResult += '<tr><td><a href="' + $volume.URL + '">' + $volume.Volume + '</a></td><td>' + $volume.Location + '</td><td>' + $volume.capacityPool + '</td>'
                $finalResult += '<td class="center">' + [Math]::Round($previousVolumeConsumedSizes[$volume.ResourceId]/1024/1024/1024,2) + '</td>'
                $finalResult += '<td class="center">' + $volume.Consumed + '</td>'
                $finalResult += '<td class="center">' + $percentChange + '%</td></tr>'
            } else {
                $finalResult += '<tr><td><a href="' + $volume.URL + '">' + $volume.Volume + '</a></td><td>' + $volume.Location + '</td><td>' + $volume.capacityPool + '</td>'
                $finalResult += '<td class="center">' + [Math]::Round($previousVolumeConsumedSizes[$volume.ResourceId]/1024/1024/1024,2) + '</td>'
                $finalResult += '<td class="center">' + $volume.Consumed + '</td>'
                $finalResult += '<td class="center">' + '0' + '%</td></tr>'
            }
    }
    $finalResult += '</table><br>'
    return $finalResult
}
function Show-ANFVolumeAVSDatastore() {
    #####
    ## Display ANF Volumes which are enabled for AVS datastore
    #####
    $finalResult += '<h3>Azure NetApp Files datastore for AVS</h3>'
    $finalResult += '<table>'
    $finalResult += '<th>Volume Name</th><th>Location</th><th>Capacity Pool</th><th>AVS datastore</th><th>Private Cloud</th><th>Cluster</th><th class="center">Provisioned (GiB)</th>'
        foreach($datastore in $datastoreDetails) {
            if($datastore.AvsDataStore -eq "Enabled"){
                $finalResult += '<tr><td><a href="' + $datastore.URL + '">' + $datastore.Volume + '</a></td><td>' + $datastore.Location + '</td><td>' + $datastore.capacityPool + '</td><td>' + $datastore.AvsDataStore + '</td><td>' + $datastore.privateCloud + '</td><td>' + $datastore.cluster + '</td><td class="center">' + $datastore.ProvisionedSize + '</td>'
            }
    }
    $finalResult += '</table><br>'
    return $finalResult
}
function Show-ANFVolumeSnapshotStatus() {
    #####
    ## Display ANF Volumes and Snapshot Policy and CRR Status 
    #####
    $finalResult += '<h3>Volume Snapshot Status</h3>'
    $finalResult += '<table>'
    $finalResult += '<th>Volume Name</th><th>Location</th><th>Capacity Pool</th><th class="center">Snapshot Policy</th><th>Policy Name</th><th class="center">Oldest Snap</th><th class="center">Newest Snap</th><th class="center">No. Snaps</th>'
        foreach($volume in $volumeDetails) {
            $volumeSnaps = @()
            $snapCount = 0
            $mostRecentSnapDisplay = $null
            $oldestSnapDisplay = $null
            $volumeSnaps = Get-AzNetAppFilesSnapshot -ResourceGroupName $volume.ResourceId.split('/')[4] -AccountName $volume.ResourceId.split('/')[8] -PoolName $volume.ResourceId.split('/')[10] -VolumeName $volume.ResourceId.split('/')[12]
            if($volumeSnaps) {
                $mostRecentSnapDate = $volumeSnaps[0].Created
                $oldestSnapDate = $volumeSnaps[0].Created
                foreach($volumeSnap in $volumeSnaps){
                    $snapCount += 1
                    if($volumeSnap.Created -gt $mostRecentSnapDate) {
                        $mostRecentSnapDate = $volumeSnap.Created
                    }
                    if($volumeSnap.Created -lt $oldestSnapDate) {
                        $oldestSnapDate = $volumeSnap.Created
                    }
                }
                if($mostRecentSnapDate -le (Get-Date).AddHours(-($mostRecentSnapTooOldThreshold))) {
                    $mostRecentSnapDisplay = '<td class="warning">' + $mostRecentSnapDate.ToString("MM-dd-yy hh:mm tt") + '</td>'
                } else {
                    $mostRecentSnapDisplay = '<td class="center">' + $mostRecentSnapDate.ToString("MM-dd-yy hh:mm tt") + '</td>'
                }
                if($oldestSnapDate -le (Get-Date).AddDays(-($oldestSnapTooOldThreshold))) {
                    $oldestSnapDisplay = '<td class="warning">' + $oldestSnapDate.ToString("MM-dd-yy hh:mm tt") + '</td>'
                } else {
                    $oldestSnapDisplay = '<td class="center">' + $oldestSnapDate.ToString("MM-dd-yy hh:mm tt") + '</td>'
                }
            } else {
                $mostRecentSnapDisplay = '<td class="warning">None</td>'
                $oldestSnapDisplay = '<td class="warning">None</td>'
            }
            $finalResult += '<tr>' + '<td><a href="https://portal.azure.com/#@' + $Subscription.TenantId + '/resource' + $volume.ResourceId + '">' + $volume.Volume + '</a></td><td>' + $volume.Location + '</td><td>' + $volume.capacityPool + '</td>'
            if($volume.SnapshotPolicyId) {
                $snapshotPolicyDisplay = 'Yes'
                $finalResult += '<td class="center">' + $snapshotPolicyDisplay + '</td>'
                $finalResult += '<td>' + $volume.SnapshotPolicyId.split('/')[10] + '</td>'
            } else {
                $snapshotPolicyDisplay = 'No'
                $finalResult += '<td class="warning center">' + $snapshotPolicyDisplay + '</td><td></td>'
            }
            $finalResult += $oldestSnapDisplay
            $finalResult += $mostRecentSnapDisplay
            $finalResult += '<td class="center">' + $snapCount + '</td>'
            $finalResult += '</tr>'
        }
    $finalResult += '</table><br>'
    return $finalResult 
}
function Show-ANFVolumeBackupStatus() {
    #####
    ## Display ANF Volumes and Backup Policy 
    #####
    $finalResult += '<h3>Volume Backup Status</h3>'
    $finalResult += '<table>'
    $finalResult += '<th>Volume Name</th><th>Location</th><th>Capacity Pool</th><th class="center">Policy Name</th><th class="center">Oldest Backup</th><th class="center">Newest Backup</th><th class="center">No. Backups</th>'
        foreach($volume in $volumeDetails) {
            $volumeBackups = @()
            $backupCount = 0
            $mostRecentBackupDisplay = $null
            $oldestBackupDisplay = $null
            $volumeBackups = Get-AzNetAppFilesBackup -ResourceGroupName $volume.ResourceId.split('/')[4] -AccountName $volume.ResourceId.split('/')[8] -PoolName $volume.ResourceId.split('/')[10] -VolumeName $volume.ResourceId.split('/')[12]
            if($volumeBackups) {
                $mostRecentBackupDate = $volumeBackups[0].CreationDate
                $oldestBackupDate = $volumeBackups[0].CreationDate
                foreach($volumeBackup in $volumeBackups){
                    $BackupCount += 1
                    if($volumeBackup.CreationDate) {
                        if($volumeBackup.CreationDate -gt $mostRecentBackupDate) {
                            $mostRecentBackupDate = $volumeBackup.CreationDate
                        }
                        if($volumeBackup.CreationDate -lt $oldestBackupDate) {
                            $oldestBackupDate = $volumeBackup.CreationDate
                        }
                    }
                }
                $mostRecentBackupDisplay = '<td class="warning center">None</td>' # remove once CreationDate property is valid
                $oldestBackupDisplay = '<td class="warning center">None</td>' # remove once CreationDate property is valid
                # remove comment block once CreationDate property is valid
                if($mostRecentBackupDate -le (Get-Date).AddHours(-($mostRecentBackupTooOldThreshold))) {
                    $mostRecentBackupDisplay = '<td class="warning">' + $mostRecentBackupDate.ToString("MM-dd-yy hh:mm tt") + '</td>'
                } else {
                    $mostRecentBackupDisplay = '<td class="center">' + $mostRecentBackupDate.ToString("MM-dd-yy hh:mm tt") + '</td>'
                }
                if($oldestBackupDate -le (Get-Date).AddDays(-($oldestBackupTooOldThreshold))) {
                    $oldestBackupDisplay = '<td class="warning">' + $oldestBackupDate.ToString("MM-dd-yy hh:mm tt") + '</td>'
                } else {
                    $oldestBackupDisplay = '<td class="center">' + $oldestBackupDate.ToString("MM-dd-yy hh:mm tt") + '</td>'
                }
                #
            } else {
                $mostRecentBackupDisplay = '<td class="warning center">None</td>'
                $oldestBackupDisplay = '<td class="warning center">None</td>'
            }
            
            $finalResult += '<tr>' + '<td><a href="https://portal.azure.com/#@' + $Subscription.TenantId + '/resource' + $volume.ResourceId + '">' + $volume.Volume + '</a></td><td>' + $volume.Location + '</td><td>' + $volume.capacityPool + '</td>'
            if($volume.BackupPolicyId) {
                $finalResult += '<td class="center">' + $volume.BackupPolicyId.split('/')[10] + '</td>'
            } else {
                $BackupPolicyDisplay = 'None'
                $finalResult += '<td class="warning center">' + $BackupPolicyDisplay + '</td>'
            }
            $finalResult += $oldestBackupDisplay
            $finalResult += $mostRecentBackupDisplay
            $finalResult += '<td class="center">' + $BackupCount + '</td>'
            $finalResult += '</tr>'
        }
    $finalResult += '</table><br>'
    return $finalResult 
}
function Show-ANFVolumeReplicationStatus() {
    #####
    ## Display ANF Volumes and Snapshot Policy and CRR Status 
    #####
    $finalResult += '<h3>Volume Replication Status</h3>'
    $finalResult += '<table>'
    $finalResult += '<th>Volume Name</th><th>Location</th><th>Capacity Pool</th><th class="center">Type</th><th>Schedule</th><th>Source Region</th><th>Target Region</th><th class="center">Healthy?</th>'
        foreach($volume in $volumeDetails | Sort-Object -Property EndpointType -Descending) {
            $finalResult += '<tr>' + '<td><a href="https://portal.azure.com/#@' + $Subscription.TenantId + '/resource' + $volume.ResourceId + '">' + $volume.Volume + '</a></td><td>' + $volume.Location + '</td><td>' + $volume.capacityPool + '</td>'
            if($volume.EndpointType -eq 'Src' -or $volume.EndpointType -eq 'Dst') {
                $remoteVolumeDetail = Get-AzNetAppFilesVolume -ResourceId $volume.RemoteVolumeResourceId
                $replicationStatus = Get-AzNetAppFilesReplicationStatus -ResourceId $volume.ResourceId
                if($volume.EndpointType -eq 'Src') {
                    $replicationDisplay = 'Source'
                    $finalResult += '<td class="center">' + $replicationDisplay + '</td>'
                    $finalResult += '<td>' + $remoteVolumeDetail.DataProtection.Replication.ReplicationSchedule + '</td>'
                    $finalResult += '<td>' + $volume.Location + '</td>'
                    $finalResult += '<td><a href="https://portal.azure.com/#@' + $Subscription.TenantId + '/resource' + $remoteVolumeDetail.Id + '">' + $remoteVolumeDetail.Location + '</td>'
                    $finalResult += '<td class="center">' + $replicationStatus.Healthy + '</td>'
                } elseif ($volume.EndpointType -eq 'Dst') {
                    $replicationDisplay = 'Destination'
                    $finalResult += '<td class="center">' + $replicationDisplay + '</td>'
                    $finalResult += '<td>' + $volume.ReplicationSchedule + '</td>'
                    $finalResult += '<td><a href="https://portal.azure.com/#@' + $Subscription.TenantId + '/resource' + $remoteVolumeDetail.Id + '">' + $remoteVolumeDetail.Location + '</td>'
                    $finalResult += '<td>' + $volume.Location + '</td>'
                    $finalResult += '<td class="center">' + $replicationStatus.Healthy + '</td>'
                }
            } else {
                $replicationDisplay = 'n/a'
                $finalResult += '<td class="warning center">' + $replicationDisplay + '</td><td></td><td></td><td></td><td></td>'
            }
            $finalResult += '</tr>'
        }
    $finalResult += '</table><br>'
    return $finalResult 
}

## Get an array of all Azure Subscriptions
if ($subId) {
    $subArray = $subId.Split(',')
    $subArray
    $Subscriptions = Get-AzSubscription | Where-Object {$_.SubscriptionId -in $subArray}
} else {
    $Subscriptions = Get-AzSubscription
}

## Add some CSS - feel free to customize to match your brand or corporate standards
$finalResult = @'
                <html>
                <head>
                <style>
                    * {
                        font-family: arial, helvetica, sans-serif;
                        color: #757575;
                    }
                    p {
                        font-size: 80%;
                    }
                    a:link {
                        color: #5278FF;
                        text-decoration: none;
                    }
                    a:visited {
                        color: #5278FF;
                        text-decoration: none;
                    }
                    a:hover {
                        color: #2958FF;
                        text-decoration: underline;
                    }
                    a:active {
                        color: #2958FF;
                        text-decoration: none;
                    }
                    tr:hover {
                        background-color: #F2F2F2;
                    }
                    h2 {
                        color: #757575;
                    }
                    h3 {
                        color: #757575;
                        margin: 4px;
                    }
                    table {
                        width: 100%;
                    }
                    table, th, td, tr {
                        border-collapse: collapse;
                        text-align: left;
                    }
                    tr:nth-child(odd) {
                        background-color: #F2F2F2;
                    }
                    th {
                        background-color: #5278ff;
                        color: #FFFFFF;
                        font-weight: normal;
                    }
                    th, td {
                        border-bottom: 1px solid #ddd;
                        font-size: 80%;
                        padding-top: 7px;
                        padding-bottom: 7px;
                        padding-left: 10px;
                        padding-right: 10px;
                    }
                    .warning {
                        color: #DB2841;
                        font-weight: normal;
                        text-align: center;
                    }
                    .center {
                        text-align: center;
                    }
                </style>
                </head>
                <body>
'@

$finalResult += '<h2>' + $Subject + '</h2>'

foreach ($Subscription in $Subscriptions) {
    
    Set-AzContext $Subscription 
    $finalResult += '<h6>Subscription: ' + $Subscription.Name + ', ' + $Subscription.Id + '</h6>'
    ## Collect Resources
    $netAppAccounts = Get-ANFAccounts
    $capacityPools = Get-ANFPools
    $volumes = Get-ANFVolumes

    ## Collect Azure Monitor Data
    $volumeConsumedSizes = Get-ANFVolumeConsumedSizes(0) ## get volume utilization from 0 days ago
    $previousVolumeConsumedSizes = Get-ANFVolumeConsumedSizes($volumeConsumedDaysAgo) # get volumes utilization from number of days ago
    $capacityPoolAllocatedSizes = Get-ANFCapacityPoolAllocatedSizes
    
    ## collect details for all resources
    $volumeDetails = Get-ANFVolumeDetails($volumeConsumedSizes)
    $poolDetails = Get-ANFPoolDetails($capacityPoolAllocatedSizes)    
    $datastoreDetails = Get-ANFAVSdatastoreVolumeDetails

    ## Generate Module Output
    
    if($enableVolumeCapacityRemediation -eq $true) {
        $finalResult += ANFVolumeCapacityRemediation
    }

    if($enablePoolCapacityRemediation -eq $true) {
        $finalResult += ANFPoolCapacityRemediation
    }

    if($remediateOnly -eq $false) {
        $finalResult += Show-ANFNetAppAccountSummary
        $finalResult += Show-ANFRegionalProvisioned
        #$finalResult += Show-ANFVNetsIPUsage
        $finalResult += Show-ANFCapacityPoolUnderUtilized
        $finalResult += Show-ANFCapacityPoolUtilization
        #$finalResult += Show-ANFVolumeUtilizationFilterTag
        $finalResult += Show-ANFVolumeUtilizationAboveThreshold
        $finalResult += Show-ANFVolumeUtilizationBelowThreshold
        $finalResult += Show-ANFVolumeUtilization
        $finalResult += Show-ANFVolumeUtilizationGrowth
        if($datastoreDetails){
            $finalResult += Show-ANFVolumeAVSDatastore
        }
        $finalResult += Show-ANFVolumeSnapshotStatus
        $finalResult += Show-ANFVolumeBackupStatus
        $finalResult += Show-ANFVolumeReplicationStatus
    }
}

## Close our body and html tags
$finalResult += '<br><p>Created by <a href="https://github.com/seanluce">Sean Luce</a>, Technical Marketing Engineer <a href="https://cloud.netapp.com">@NetApp</a></p></body></html>'

## If you want to run this script locally use parameter -OutFile myoutput.html
if($remediateOnly -eq $false) {
    if($OutFile) {
        $finalResult | out-file -filepath $OutFile
    } elseif($sendMethod -eq "email") {
        Send-Email
    } else {
        Save-Blob
    }
}


