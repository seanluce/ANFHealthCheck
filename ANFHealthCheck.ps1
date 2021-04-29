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
# add module for capacity pools allocated
# add module for accounts and regions
# add module for detailed snapshot view
# add module for detailed CRR view

# Connects as AzureRunAsConnection from Automation to ARM
$connection = Get-AutomationConnection -Name AzureRunAsConnection
Connect-AzAccount -ServicePrincipal -Tenant $connection.TenantID -ApplicationId $connection.ApplicationID -CertificateThumbprint $connection.CertificateThumbprint

function Send-Email() {
    $Username ="YOURSENDGRIDUSERNAME@azure.com" # Your user name - found in SendGrid portal
    $Password = ConvertTo-SecureString "SECRETPASSWORD" -AsPlainText -Force # SendGrid password
    $credential = New-Object System.Management.Automation.PSCredential $Username, $Password
    $SMTPServer = "smtp.sendgrid.net"
    $EmailFrom = "anf@xyz.com" # Can be anything - aaa@xyz.com
    $EmailTo = "you@xyz.com" # Valid recepient email address
    $Subject = "Azure NetApp Files Health Report"
    $Body = $finalResult
    # Send-MailMessage -smtpServer $SMTPServer -Credential $credential -Usessl -Port 587 -from $EmailFrom -to $EmailTo -subject $Subject -Body $Body -Attachments $file_path_for_nsg, $file_path_for_running_VM, $file_path_for_deallocated_VM, $file_path_for_stopped_VM, $file_path_for_vm_with_no_backup
    Send-MailMessage -smtpServer $SMTPServer -Credential $credential -Usessl -Port 587 -from $EmailFrom -to $EmailTo -subject $Subject -Body $Body -BodyAsHtml
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
            $finalResult += '<tr><td>' + $volumeDetail.name.split('/')[2] + '</td><td>' + $volumeDetail.Location + '</td><td class="center">' + $volumeDetail.UsageThreshold/1024/1024/1024 + '</td><td class="center">' + [Math]::Round($volumeConsumedSizes[$volume.ResourceId]/1024/1024/1024,0) + '</td>'
            if($volumePercentConsumed -ge $volumePercentFullWarning) {
                $finalResult += '<td class="warning">' + $volumePercentConsumed + '%</td></tr>'
            } else {
                $finalResult += '<td class="center">' + $volumePercentConsumed + '%</td></tr>'
            }
        
    }
    $finalResult += '</table><br>'
    return $finalResult
    ## Display ANF Volumes with Used Percentages
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
            $finalResult += '<tr>' + "<td>" + $volumeDetail.name.split('/')[2] + '</td>'
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
    ## Display ANF Volumes and Snapshot Policy and CRR Status 
    return $finalResult
}

$volumeCapacities = @{}
$volumeConsumedSizes = @{}
$poolCapacities = @{}
$netAppRegions = @()

#$cred = Get-AutomationPSCredential -Name "YOURCREDS"

#Connect-AzAccount -ServicePrincipal -Credential $cred -Tenant "YOURTENANT"

$Subscriptions = Get-AzSubscription

$finalResult = @'
                <html>
                <head>
                <style>
                    * {
                        font-family: arial, helvetica, sans-serif;
                        color: #4D4D4D;
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
    
    #####
    ## Collect all Volume Consumed Sizes ##
    #####
    $startTime = [datetime]::Now.AddMinutes(-30)
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
    ## Collect all Volume Consumed Sizes ##

    ## Get List of Unique Regions ##
    foreach($netAppAccount in $netAppAccounts) {
        write-output $netAppAccount
        $netAppRegions += $netAppAccount.Location
    }
    $netAppRegions = $netAppRegions | Sort-Object -Unique
    ## Get List of Unique Regions

    $finalResult += Show-ANFVolumeUtilization
    $finalResult += Show-ANFVolumeProtectionStatus    
}

$finalResult += '</body></html>'

Send-Email

#$finalResult | out-file -filepath 'output.html'
