param (
    [string]$subId,
    [string]$OutFile,
    [string]$Subject = "Azure NetApp Files Health Report"
 )

$sendMethod = "email" # choose blob or email

Import-Module Az.Accounts
Import-Module Az.NetAppFiles
Import-Module Az.Resources
Import-Module Az.Monitor
Import-Module Az.Storage

#User Modifiable Parameters
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

$volumeTagName = 'purpose' #name of tag to filter
$volumeTagValue = 'restore' #value of tag to filter

### TODO ###
# time offset?
# add module for detailed CRR view
# SMB share report
# NFS export report
# Dual-Protocol Report

# Connects as AzureRunAsConnection from Automation to ARM
try {
    $connection = Get-AutomationConnection -Name AzureRunAsConnection -ErrorAction SilentlyContinue
    Connect-AzAccount -ServicePrincipal -Tenant $connection.TenantID -ApplicationId $connection.ApplicationID -CertificateThumbprint $connection.CertificateThumbprint -ErrorAction SilentlyContinue
}
catch {
    "Unable to Connect-AzAccount using these parameters. Using locally cached credentials instead."
}

# Connects using custom credentials if AzureRunAsConnection can't be used
# $credentials = Get-AutomationPSCredential -Name "YOURCREDS"
# Connect-AzAccount -ServicePrincipal -Credential $credentials -Tenant "YOURTENANT"

function Send-Email() {
    #####
    ## Send finalResult as email
    #####
    $Username ="YOURUSERNAME" # Your user name - found in SendGrid portal
    $Password = ConvertTo-SecureString "YOURSECRET" -AsPlainText -Force # SendGrid password
    $credential = New-Object System.Management.Automation.PSCredential $Username, $Password
    $SMTPServer = "smtp.sendgrid.net"
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
        $volumeDetail = Get-AzNetAppFilesVolume -ResourceId $volume.ResourceId
        $volumePercentConsumed = [Math]::Round(($volumeConsumedSizes[$volume.ResourceId]/$volumeDetail.UsageThreshold)*100,2)
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
        $poolDetail = Get-AzNetAppFilesPool -ResourceId $pool.ResourceId
        $poolPercentAllocated = [Math]::Round(($poolAllocatedSizes[$pool.ResourceId]/$poolDetail.Size)*100,2)
        $poolCustomObject = [PSCustomObject]@{
            capacityPool = $poolDetail.name.split('/')[1]
            netappAccount = $poolDetail.name.split('/')[0]
            ServiceLevel = $poolDetail.ServiceLevel
            QosType = $poolDetail.QosType
            URL = 'https://portal.azure.com/#@' + $Subscription.TenantId + '/resource' + $pool.ResourceId
            Location = $poolDetail.Location
            Provisioned = $poolDetail.Size/1024/1024/1024
            Allocated = [Math]::Round($poolAllocatedSizes[$pool.ResourceId]/1024/1024/1024,2)
            AllocatedPercent = $poolPercentAllocated
            ResourceID = $pool.ResourceID
        }
        Export-Csv -InputObject $poolCustomObject -Append -Path poolDetails.csv 
        $poolObjects += $poolCustomObject
    }
    return $poolObjects
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
                $finalResult += '<td class="center">' + [Math]::Round($previousVolumeConsumedSizes[$volume.ResourceId]/1024/1024/1024,3) + '</td>'
                $finalResult += '<td class="center">' + $volume.Consumed + '</td>'
                $finalResult += '<td class="center">' + $percentChange + '%</td></tr>'
            } else {
                $finalResult += '<tr><td><a href="' + $volume.URL + '">' + $volume.Volume + '</a></td><td>' + $volume.Location + '</td><td>' + $volume.capacityPool + '</td>'
                $finalResult += '<td class="center">' + [Math]::Round($previousVolumeConsumedSizes[$volume.ResourceId]/1024/1024/1024,3) + '</td>'
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
    $finalResult += Show-ANFNetAppAccountSummary
    $finalResult += Show-ANFRegionalProvisioned
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

## Close our body and html tags
$finalResult += '<br><p>Created by <a href="https://github.com/seanluce">Sean Luce</a>, Technical Marketing Engineer <a href="https://cloud.netapp.com">@NetApp</a></p></body></html>'

## If you want to run this script locally use parameter -OutFile myoutput.html
if($OutFile) {
    $finalResult | out-file -filepath $OutFile
} elseif($sendMethod -eq "email") {
    Send-Email
} else {
    Save-Blob
}


