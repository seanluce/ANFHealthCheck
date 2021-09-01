param (
    [string]$subId,
    [string]$OutFile
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
$volumeSpaceGiBTooLow = 25 #highlight volume if available space is below or equal to
$oldestSnapTooOldThreshold = 30 #days, highlight snapshot date if oldest snap is older than or equal to
$mostRecentSnapTooOldThreshold = 48 #hours, highlight snapshot date if newest snap is older than or equal to 
$volumeConsumedDaysAgo = 7 # days ago to display for volume utilization growth over time
$regionProvisionedPercentWarning = 90

### TODO ###
# time offset?
# add module for detailed CRR view
# SMB share report
# NFS export report
# Dual-Protocol Report

# Connects as AzureRunAsConnection from Automation to ARM
try {
    $connection = Get-AutomationConnection -Name AzureRunAsConnection
    Connect-AzAccount -ServicePrincipal -Tenant $connection.TenantID -ApplicationId $connection.ApplicationID -CertificateThumbprint $connection.CertificateThumbprint
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
    $Username ="YOURSENDGRIDUSERNAME@azure.com" # Your user name - found in SendGrid portal
    $Password = ConvertTo-SecureString "SECRETPASSWORD" -AsPlainText -Force # SendGrid password
    $credential = New-Object System.Management.Automation.PSCredential $Username, $Password
    $SMTPServer = "smtp.sendgrid.net"
    $EmailFrom = "anf@xyz.com" # Can be anything - aaa@xyz.com
    $EmailTo = "you@xyz.com" # Valid recepient email address
    $Subject = "Azure NetApp Files Health Report"
    $Body = $finalResult
    Send-MailMessage -smtpServer $SMTPServer -Credential $credential -Usessl -Port 587 -from $EmailFrom -to $EmailTo -subject $Subject -Body $Body -BodyAsHtml
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
            Name = $volumeDetail.name.split('/')[2]
            URL = 'https://portal.azure.com/#@' + $Subscription.TenantId + '/resource' + $volume.ResourceId
            Location = $volumeDetail.Location
            Provisioned = $volumeDetail.UsageThreshold/1024/1024/1024
            Consumed = [Math]::Round($volumeConsumedSizes[$volume.ResourceId]/1024/1024/1024,2)
            Available = [Math]::Round(($volumeDetail.UsageThreshold - $volumeConsumedSizes[$volume.ResourceId])/1024/1024/1024,2)
            ConsumedPercent = $volumePercentConsumed
            ResourceID = $volume.ResourceID
            SnapshotPolicyId = $volumeDetail.DataProtection.Snapshot.SnapshotPolicyId
            EndpointType = $volumeDetail.DataProtection.Replication.endPointType
            RemoteVolumeResourceId = $volumeDetail.DataProtection.Replication.RemoteVolumeResourceId
            ReplicationSchedule = $volumeDetail.DataProtection.Replication.ReplicationSchedule
            SubnetId = $volumeDetail.SubnetId
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
            Name = $poolDetail.name.split('/')[1]
            ServiceLevel = $poolDetail.ServiceLevel
            QosType = $poolDetail.QosType
            URL = 'https://portal.azure.com/#@' + $Subscription.TenantId + '/resource' + $pool.ResourceId
            Location = $poolDetail.Location
            Provisioned = $poolDetail.Size/1024/1024/1024
            Allocated = [Math]::Round($poolAllocatedSizes[$pool.ResourceId]/1024/1024/1024,2)
            AllocatedPercent = $poolPercentAllocated
            ResourceID = $volume.ResourceID
        }
        Export-Csv -InputObject $poolCustomObject -Append -Path poolDetails.csv 
        $poolObjects += $poolCustomObject
    }
    return $poolObjects
}
function Show-ANFNetAppAccountSummary() {
    #####
    ## Display ANF NetApp Account Summary
    #####
    $finalResult += '<h3>NetApp Account Summary</h3>'
    $finalResult += '<table>'
    $finalResult += '<th>Account Name</th><th>Location</th><th>Resource Group</th><th>Domain</th>'
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
    foreach($region in $allANFRegions) {
        $restPath = '/subscriptions/' + $Subscription.Id + '/providers/Microsoft.NetApp/locations/' + $region.Location + '/quotaLimits?api-version=2021-06-01'
        $rawAPIResponse = Invoke-AzRestMethod -Path $restPath -Method GET
        $jsonResponse = ConvertFrom-Json $rawAPIResponse.Content
        $regionCapacityQuota.add($region.Location, $jsonResponse.totalTiBsPerSubscription.current)
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
    $finalResult += '<h3>Capacity Pool Utilization below ' + $poolPercentAllocatedWarning + '%</h3>'
    $finalResult += '<table>'
    $finalResult += '<th>Pool Name</th><th>Location</th><th>Service Level</th><th>QoS Type</th><th class="center">Provisioned (GiB)</th><th class="center">Allocated (GiB)</th><th class ="center">Allocated (%)</th>'
    foreach($poolDetail in $poolDetails) {
        if($poolDetail.AllocatedPercent -le $poolPercentAllocatedWarning) {
            $finalResult += '<tr>'
            $finalResult += '<td><a '+ $poolDetail.URL + '">' + $poolDetail.Name + '</a></td><td>' + $poolDetail.Location + '</td><td>' + $poolDetail.ServiceLevel + '</td><td>' + $poolDetail.QosType + '</td><td class = "center">' + $poolDetail.Provisioned + '</td>'
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
    foreach($poolDetail in $poolDetails) {
        $finalResult += '<tr>'
        $finalResult += '<td><a '+ $poolDetail.URL + '">' + $poolDetail.Name + '</a></td><td>' + $poolDetail.Location + '</td><td>' + $poolDetail.ServiceLevel + '</td><td>' + $poolDetail.QosType + '</td><td class = "center">' + $poolDetail.Provisioned + '</td>'
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
    $finalResult += '<th>Volume Name</th><th>Location</th><th class="center">Provisioned (GiB)</th><th class="center">Available (GiB)</th><th class="center">Consumed (GiB)</th><th class="center">Consumed (%)</th>'
        foreach($volume in $volumeDetails | Sort-Object -Property ConsumedPercent -Descending) {  
            if($volume.ConsumedPercent -ge $volumePercentFullWarning) {
                $finalResult += '<tr><td><a href="' + $volume.URL + '">' + $volume.Name + '</a></td><td>' + $volume.Location + '</td><td class="center">' + $volume.Provisioned + '</td>'
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
    $finalResult += '<th>Volume Name</th><th>Location</th><th class="center">Provisioned (GiB)</th><th class="center">Available (GiB)</th><th class="center">Consumed (GiB)</th><th class="center">Consumed (%)</th>'
        foreach($volume in $volumeDetails | Sort-Object -Property ConsumedPercent -Descending) {  
            if($volume.ConsumedPercent -le $volumePercentUnderWarning -and $volume.Provisioned -ge $volumePercentUnderWarningMinSize) {
                $finalResult += '<tr><td><a href="' + $volume.URL + '">' + $volume.Name + '</a></td><td>' + $volume.Location + '</td><td class="center">' + $volume.Provisioned + '</td>'
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
    $finalResult += '<th>Volume Name</th><th>Location</th><th class="center">Provisioned (GiB)</th><th class="center">Available (GiB)</th><th class="center">Consumed (GiB)</th><th class="center">Consumed (%)</th>'
        foreach($volume in $volumeDetails | Sort-Object -Property ConsumedPercent -Descending) {  
            $finalResult += '<tr><td><a href="' + $volume.URL + '">' + $volume.Name + '</a></td><td>' + $volume.Location + '</td><td class="center">' + $volume.Provisioned + '</td>'
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
    $finalResult += '<th>Volume Name</th><th>Location</th><th class="center">Previous Consumed (GiB)</th><th class="center">Today Consumed (GiB)</th><th class="center">Change (%)</th>'
        foreach($volume in $volumeDetails | Sort-Object -Property ConsumedPercent -Descending) {
            if($previousVolumeConsumedSizes[$volume.ResourceId] -gt 0) {
                try {
                    $percentChange = ([Math]::Round((($volume.Consumed - [Math]::Round($previousVolumeConsumedSizes[$volume.ResourceId]/1024/1024/1024,2)) / [Math]::Round($previousVolumeConsumedSizes[$volume.ResourceId]/1024/1024/1024,2)),2)) * 100
                }
                catch {
                    $percentChange = 0
                }
                $finalResult += '<tr><td><a href="' + $volume.URL + '">' + $volume.Name + '</a></td><td>' + $volume.Location + '</td>'
                $finalResult += '<td class="center">' + [Math]::Round($previousVolumeConsumedSizes[$volume.ResourceId]/1024/1024/1024,2) + '</td>'
                $finalResult += '<td class="center">' + $volume.Consumed + '</td>'
                $finalResult += '<td class="center">' + $percentChange + '%</td></tr>'
            } else {
                $finalResult += '<tr><td><a href="' + $volume.URL + '">' + $volume.Name + '</a></td><td>' + $volume.Location + '</td>'
                $finalResult += '<td class="center">' + [Math]::Round($previousVolumeConsumedSizes[$volume.ResourceId]/1024/1024/1024,2) + '</td>'
                $finalResult += '<td class="center">' + $volume.Consumed + '</td>'
                $finalResult += '<td class="center">' + 'n/a' + '%</td></tr>'
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
    $finalResult += '<th>Volume Name</th><th>Location</th><th class="center">Snapshot Policy</th><th>Policy Name</th><th class="center">Oldest Snap</th><th class="center">Newest Snap</th><th class="center">No. Snaps</th>'
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
            $finalResult += '<tr>' + '<td><a href="https://portal.azure.com/#@' + $Subscription.TenantId + '/resource' + $volume.ResourceId + '">' + $volume.Name + '</a></td><td>' + $volume.Location + '</td>'
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
function Show-ANFVolumeReplicationStatus() {
    #####
    ## Display ANF Volumes and Snapshot Policy and CRR Status 
    #####
    $finalResult += '<h3>Volume Replication (CRR) Status</h3>'
    $finalResult += '<table>'
    $finalResult += '<th>Volume Name</th><th class="center">Type</th><th>Schedule</th><th>Source Region</th><th>Target Region</th><th class="center">Healthy?</th>'
        foreach($volume in $volumeDetails | Sort-Object -Property EndpointType -Descending) {
            $finalResult += '<tr>' + '<td><a href="https://portal.azure.com/#@' + $Subscription.TenantId + '/resource' + $volume.ResourceId + '">' + $volume.name + '</a></td>'
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
    $Subscriptions = Get-AzSubscription | Where-Object {$_.SubscriptionId -eq $subId}
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
                <h2>Azure NetApp Files Health Report</h2>
'@

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

    ## Generate Module Output
    $finalResult += Show-ANFNetAppAccountSummary
    $finalResult += Show-ANFRegionalProvisioned
    $finalResult += Show-ANFCapacityPoolUnderUtilized
    $finalResult += Show-ANFCapacityPoolUtilization
    $finalResult += Show-ANFVolumeUtilizationAboveThreshold
    $finalResult += Show-ANFVolumeUtilizationBelowThreshold
    $finalResult += Show-ANFVolumeUtilization
    $finalResult += Show-ANFVolumeUtilizationGrowth
    $finalResult += Show-ANFVolumeSnapshotStatus
    $finalResult += Show-ANFVolumeReplicationStatus
}

## Close our body and html tags
$finalResult += '<br><p>Created by <a href="https://github.com/seanluce">Sean Luce</a>, Cloud Solutions Architect <a href="https://cloud.netapp.com">@NetApp</a></p></body></html>'

## If you want to run this script locally use parameter -OutFile myoutput.html
if($OutFile) {
    $finalResult | out-file -filepath $OutFile
} elseif($sendMethod -eq "email") {
    Send-Email
} else {
    Save-Blob
}


