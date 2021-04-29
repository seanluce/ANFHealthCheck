Import-Module Az.Accounts
Import-Module Az.NetAppFiles
Import-Module Az.Resources
Import-Module Az.Monitor

#User Modifiable Parameters
$volumePercentFullWarning = 80
$volumeSnapTooOldWarning = 1 #days? #todo

### TODO ###
# map locations to human readable
# link to resources inline
# time offset?
# add module for detailed snapshot view
# add module for detailed CRR view

# Connects as AzureRunAsConnection from Automation to ARM
# $connection = Get-AutomationConnection -Name AzureRunAsConnection
# Connect-AzAccount -ServicePrincipal -Tenant $connection.TenantID -ApplicationId $connection.ApplicationID -CertificateThumbprint $connection.CertificateThumbprint

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
function Show-ANFVolumeUtilization() {
    #####
    ## Display ANF Volumes with Used Percentages
    #####
    $finalResult += '<h3>Volume Utilization</h3>'
    $finalResult += '<table>'
    $finalResult += '<th>Volume Name</th><th>Location</th><th class="center">Provisioned (GiB)</th><th class="center">Consumed (GiB)</th><th class="center">Consumed (%)</th>'
        foreach($volume in $volumes) {   
            $volumeDetail = Get-AzNetAppFilesVolume -ResourceId $volume.ResourceId
            $volumePercentConsumed = [Math]::Round(($volumeConsumedSizes[$volume.ResourceId]/$volumeDetail.UsageThreshold)*100,2)
            $finalResult += '<tr><td><a href="https://portal.azure.com/#@' + $Subscription.TenantId + '/resource' + $volume.ResourceId + '">' + $volumeDetail.name.split('/')[2] + '</a></td><td>' + $volumeDetail.Location + '</td><td class="center">' + $volumeDetail.UsageThreshold/1024/1024/1024 + '</td><td class="center">' + [Math]::Round($volumeConsumedSizes[$volume.ResourceId]/1024/1024/1024,0) + '</td>'
            if($volumePercentConsumed -ge $volumePercentFullWarning) {
                $finalResult += '<td class="warning">' + $volumePercentConsumed + '%</td></tr>'
            } else {
                $finalResult += '<td class="center">' + $volumePercentConsumed + '%</td></tr>'
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
    $finalResult += '<th>Volume Name</th><th class="center">Snapshot Policy</th><th>Policy Name</th><th class="center">Recent Snapshot</th><th class="center">Replication</th><th class="center">Schedule</th>'
        foreach($volume in $volumes) {
            $volumeDetail = @()
            $volumeSnaps = @()
            $mostRecentSnapDisplay = $null
            $volumeDetail = Get-AzNetAppFilesVolume -ResourceId $volume.ResourceId
            $volumeSnaps = Get-AzNetAppFilesSnapshot -ResourceGroupName $volume.ResourceId.split('/')[4] -AccountName $volume.ResourceId.split('/')[8] -PoolName $volume.ResourceId.split('/')[10] -VolumeName $volume.ResourceId.split('/')[12]
            if($volumeSnaps) {
                $mostRecentSnapDate = $volumeSnaps[0].Created
                foreach($volumeSnap in $volumeSnaps){
                    if($volumeSnap.Created -gt $mostRecentSnapDate) {
                        $mostRecentSnapDate = $volumeSnap.Created
                    }
                }
                $mostRecentSnapDisplay = '<td>' + $mostRecentSnapDate.ToString("MM-dd-yy hh:mm tt") + '</td>'
            } else {
                $mostRecentSnapDisplay = '<td class="warning">None</td>'
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
            $finalResult += $mostRecentSnapDisplay
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
                        color: #4D4D4D;
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

                    
                    h3 {
                        color: #4D4D4D;
                        margin: 4px;
                    }
                    table, th, td, tr {
                        border-collapse: collapse;
                        text-align: left;
                    }
                    th {
                        background-color: #F2F2F2;
                        color: #4D4D4D;
                        font-weight: normal;
                    }
                    th, td {
                        border-bottom: 1px solid #ddd;
                        font-size: 90%;
                        padding: 5px;
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
    $finalResult += Show-ANFVolumeUtilization
    $finalResult += Show-ANFVolumeProtectionStatus

}

## Close our body and html tags
$finalResult += '</body></html>'

## Send the HTML via email
Send-Email

## If you want to run this script locally or for development purposes uncomment out this line below to have the ouput saved locally
#$finalResult | out-file -filepath 'output.html'
