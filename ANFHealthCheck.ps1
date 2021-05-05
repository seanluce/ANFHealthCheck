Import-Module Az.Accounts
Import-Module Az.NetAppFiles
Import-Module Az.Resources
Import-Module Az.Monitor

#User Modifiable Parameters
$volumePercentFullWarning = 80
$oldestSnapTooOldThreshold = 30 #days
$mostRecentSnapTooOldThreshold = 48 #hours

### TODO ###
# map locations to human readable
# time offset?
# add module for detailed snapshot view
# add module for detailed CRR view

# Connects as AzureRunAsConnection from Automation to ARM
$connection = Get-AutomationConnection -Name AzureRunAsConnection
Connect-AzAccount -ServicePrincipal -Tenant $connection.TenantID -ApplicationId $connection.ApplicationID -CertificateThumbprint $connection.CertificateThumbprint

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
function Get-ANFVolumeConsumedSizes() {
    #####
    ## Collect all Volume Consumed Sizes ##
    #####
    $startTime = [datetime]::Now.AddMinutes(-15)
    $endTime = [datetime]::Now
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
function Show-ANFNetAppAccountSummary() {
    #####
    ## Display ANF NetApp Account Summary
    #####
    $finalResult += '<h3>NetApp Account Summary</h3>'
    $finalResult += '<table>'
    $finalResult += '<th>Account Name</th><th>Location</th><th>Resource Group</th>'
    foreach($netAppAccount in $netAppAccounts) {
        $accountDetail = Get-AzNetAppFilesAccount -ResourceId $netAppAccount.ResourceId
        $finalResult += '<tr>'
        $finalResult += '<td><a href="https://portal.azure.com/#@' + $Subscription.TenantId + '/resource' + $netAppAccount.ResourceId + '">' + $accountDetail.Name + '</a></td><td>' + $accountDetail.Location + '</td><td>' + $accountDetail.ResourceGroupName + '</td>'
        $finalResult += '</tr>'
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
    $finalResult += '<th>Pool Name</th><th>Location</th><th>Service Level</th><th>QoS Type</th><th>Provisioned (GiB)</th><th>Allocated (GiB)</th>'
    foreach($capacityPool in $capacityPools) {
        $poolDetail = Get-AzNetAppFilesPool -ResourceId $capacityPool.ResourceId
        $finalResult += '<tr>'
        
        $finalResult += '<td><a href="https://portal.azure.com/#@' + $Subscription.TenantId + '/resource' + $capacityPool.ResourceId + '">' + $poolDetail.Name.Split('/')[1] + '</a></td><td>' + $poolDetail.Location + '</td><td>' + $poolDetail.ServiceLevel + '</td><td>' + $poolDetail.QosType + '</td><td class = "center">' + $poolDetail.Size / 1024 / 1024 / 1024 + '</td>'
        $finalResult += '<td class="center">' + $capacityPoolAllocatedSizes[$capacityPool.ResourceId] / 1024 / 1024 / 1024 + '</td>' 
        $finalResult += '</tr>'
    }
    $finalResult += '</table><br>'
    return $finalResult
}
function Show-ANFVolumeUtilizationAboveThreshold() {
    #####
    ## Display ANF Volumes with Used Percentages above Threshold
    #####
    $volumeObjects = @()
    $finalResult += '<h3>Volume Utilization</h3>'
    $finalResult += '<table>'
    foreach($volume in $volumes) {
        $volumeDetail = Get-AzNetAppFilesVolume -ResourceId $volume.ResourceId
        $volumePercentConsumed = [Math]::Round(($volumeConsumedSizes[$volume.ResourceId]/$volumeDetail.UsageThreshold)*100,2)
        $volumeCustomObject = [PSCustomObject]@{
            Name = $volumeDetail.name.split('/')[2]
            URL = 'https://portal.azure.com/#@' + $Subscription.TenantId + '/resource' + $volume.ResourceId
            Location = $volumeDetail.Location
            Provisioned = $volumeDetail.name.split('/')[2]
            Consumed = [Math]::Round($volumeConsumedSizes[$volume.ResourceId]/1024/1024/1024,0)
            ConsumedPercent = $volumePercentConsumed
        }
        $volumeObjects += $volumeCustomObject
    }
    $finalResult += '<th>Volume Name</th><th>Location</th><th class="center">Provisioned (GiB)</th><th class="center">Consumed (GiB)</th><th class="center">Consumed (%)</th>'
        foreach($volume in $volumeObjects | Sort-Object -Property ConsumedPercent -Descending) {  
            if($volume.ConsumedPercent -ge $volumePercentFullWarning) {
                $finalResult += '<tr><td><a href="' + $volume.URL + '">' + $volume.Name + '</a></td><td>' + $volume.Location + '</td><td class="center">' + $volume.Provisioned + '</td><td class="center">' + $volume.Consumed + '</td>'
                $finalResult += '<td>' + $volume.ConsumedPercent + '%</td></tr>'
            } 
    }
    $finalResult += '</table><br>'
    return $finalResult
}
function Show-ANFVolumeUtilization() {
    #####
    ## Display ANF Volumes with Used Percentages
    #####
    $volumeObjects = @()
    $finalResult += '<h3>Volume Utilization</h3>'
    $finalResult += '<table>'
    foreach($volume in $volumes) {
        $volumeDetail = Get-AzNetAppFilesVolume -ResourceId $volume.ResourceId
        $volumePercentConsumed = [Math]::Round(($volumeConsumedSizes[$volume.ResourceId]/$volumeDetail.UsageThreshold)*100,2)
        $volumeCustomObject = [PSCustomObject]@{
            Name = $volumeDetail.name.split('/')[2]
            URL = 'https://portal.azure.com/#@' + $Subscription.TenantId + '/resource' + $volume.ResourceId
            Location = $volumeDetail.Location
            Provisioned = $volumeDetail.name.split('/')[2]
            Consumed = [Math]::Round($volumeConsumedSizes[$volume.ResourceId]/1024/1024/1024,0)
            ConsumedPercent = $volumePercentConsumed
        }
        $volumeObjects += $volumeCustomObject
    }
    $finalResult += '<th>Volume Name</th><th>Location</th><th class="center">Provisioned (GiB)</th><th class="center">Consumed (GiB)</th><th class="center">Consumed (%)</th>'
        foreach($volume in $volumeObjects | Sort-Object -Property ConsumedPercent -Descending) {  
            $finalResult += '<tr><td><a href="' + $volume.URL + '">' + $volume.Name + '</a></td><td>' + $volume.Location + '</td><td class="center">' + $volume.Provisioned + '</td><td class="center">' + $volume.Consumed + '</td>'
            if($volume.ConsumedPercent -ge $volumePercentFullWarning) {
                $finalResult += '<td class="warning">' + $volume.ConsumedPercent + '%</td></tr>'
            } else {
                $finalResult += '<td class="center">' + $volume.ConsumedPercent + '%</td></tr>'
            }
        
    }
    $finalResult += '</table><br>'
    return $finalResult
}
function Show-ANFVolumeProtectionStatus() {
    #####
    ## Display ANF Volumes and Snapshot Policy and CRR Status 
    #####
    $finalResult += '<h3>Volume Protection Status</h3>'
    $finalResult += '<table>'
    $finalResult += '<th>Volume Name</th><th class="center">Snapshot Policy</th><th>Policy Name</th><th class="center">Oldest Snap</th><th class="center">Newest Snap</th><th>No. Snaps</th><th class="center">Replication</th><th class="center">Schedule</th>'
        foreach($volume in $volumes) {
            $volumeDetail = @()
            $volumeSnaps = @()
            $snapCount = 0
            $mostRecentSnapDisplay = $null
            $oldestSnapDisplay = $null
            $volumeDetail = Get-AzNetAppFilesVolume -ResourceId $volume.ResourceId
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
                    $mostRecentSnapDisplay = '<td>' + $mostRecentSnapDate.ToString("MM-dd-yy hh:mm tt") + '</td>'
                }
                if($oldestSnapDate -le (Get-Date).AddDays(-($oldestSnapTooOldThreshold))) {
                    $oldestSnapDisplay = '<td class="warning">' + $oldestSnapDate.ToString("MM-dd-yy hh:mm tt") + '</td>'
                } else {
                    $oldestSnapDisplay = '<td>' + $oldestSnapDate.ToString("MM-dd-yy hh:mm tt") + '</td>'
                }
            } else {
                $mostRecentSnapDisplay = '<td class="warning">None</td>'
                $oldestSnapDisplay = '<td class="warning">None</td>'
            }
            $finalResult += '<tr>' + '<td><a href="https://portal.azure.com/#@' + $Subscription.TenantId + '/resource' + $volume.ResourceId + '">' + $volumeDetail.name.split('/')[2] + '</a></td>'
            if($volumeDetail.DataProtection.Snapshot.SnapshotPolicyId) {
                $snapshotPolicyDisplay = 'Yes'
                $finalResult += '<td class="center">' + $snapshotPolicyDisplay + '</td>'
                $finalResult += '<td>' + $volumeDetail.DataProtection.Snapshot.SnapshotPolicyId.split('/')[10] + '</td>'
            } else {
                $snapshotPolicyDisplay = 'No'
                $finalResult += '<td class="warning center">' + $snapshotPolicyDisplay + '</td><td></td>'
            }
            $finalResult += $oldestSnapDisplay
            $finalResult += $mostRecentSnapDisplay
            $finalResult += '<td class="center">' + $snapCount + '</td>'
            if($volumeDetail.DataProtection.Replication.endPointType) {
                if($volumeDetail.DataProtection.Replication.endPointType -eq 'Src') {
                    $replicationDisplay = 'Yes'
                    $finalResult += '<td class="center">' + $replicationDisplay + '</td>'
                    $remoteResourceDetail = Get-AzNetAppFilesVolume -ResourceId $volumeDetail.DataProtection.Replication.RemoteVolumeResourceId
                    $finalResult += '<td>' + $remoteResourceDetail.DataProtection.Replication.ReplicationSchedule + '</td>'
                } elseif ($volumeDetail.DataProtection.Replication.endPointType -eq 'Dst') {
                    $replicationDisplay = 'Dst'
                    $finalResult += '<td class="center">' + $replicationDisplay + '</td><td></td>'
                }
            } else {
                $replicationDisplay = 'No'
                $finalResult += '<td class="warning center">' + $replicationDisplay + '</td><td></td>'
            }
            $finalResult += '</tr>'
        }
    $finalResult += '</table><br>'
    return $finalResult 
}

## Declare Hash Tables to hold Metric Data
$volumeConsumedSizes = @{}
$capacityPoolAllocatedSizes = @{}

## Get an array of all Azure Subscriptions
$Subscriptions = Get-AzSubscription

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
                    table, th, td, tr {
                        border-collapse: collapse;
                        text-align: left;
                    }
                    tr:nth-child(odd) {
                        background-color: #F2F2F2;
                    }
                    th {
                        background-color: #2958FF;
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

    $netAppAccounts = Get-AzResource | Where-Object {$_.ResourceType -eq "Microsoft.NetApp/netAppAccounts"}
    $capacityPools = Get-AzResource | Where-Object {$_.ResourceType -eq "Microsoft.NetApp/netAppAccounts/capacityPools"}
    $volumes = Get-AzResource | Where-Object {$_.ResourceType -eq "Microsoft.NetApp/netAppAccounts/capacityPools/volumes"}
    
    $volumeConsumedSizes = Get-ANFVolumeConsumedSizes
    $capacityPoolAllocatedSizes = Get-ANFCapacityPoolAllocatedSizes

    $finalResult += Show-ANFNetAppAccountSummary
    $finalResult += Show-ANFCapacityPoolUtilization
    $finalResult += Show-ANFVolumeUtilizationAboveThreshold
    $finalResult += Show-ANFVolumeUtilization
    $finalResult += Show-ANFVolumeProtectionStatus

}

## Close our body and html tags
$finalResult += '<br><p>Created by <a href="https://github.com/seanluce">Sean Luce</a>, Cloud Solutions Architect @<a href="https://cloud.netapp.com">NetApp</a></p></body></html>'

## Send the HTML via email
Send-Email

## If you want to run this script locally or for development purposes uncomment out this line below to have the ouput saved locally
#$finalResult | out-file -filepath 'output.html'
