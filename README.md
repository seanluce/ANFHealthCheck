<img src="./img/anficon.png" alt="" height="50" style="margin: 0 0 0 0; " />

# ANFHealthCheck

A PowerShell Runbook that will provide useful information about the health of your Azure NetApp Files (ANF) resources and optionally remediate various issues. Schedule this to run every day for the most up-to-date info delivered straight to your inbox.


**Note** - This update requires the following updated modules:
* Az.Accounts, v2.13.1
* Az.NetAppFiles, v0.13.1
* Az.VMware, v0.5.0

## Change Log
* October 31, 2023 - updated backup status module to use API until PowerShell modules are updated (Thank you, Erik!)
* October 5, 2023 - updated tested version of Az.Accounts, Az.NetAppFiles, and Az.VMware
* February 16, 2023 - script now disallows a null/empty value for the subscription Id ($subId), use 'ALL' to run against all subscriptions
* February 16, 2023 - added paramters to control actions/behavior related to reporting, remediation, and remediation dry run
* February 16, 2023 - added variables to control if the report is sent via Email and/or to Blob independently
* August 8, 2022 - added functionality to remediate volume capacity based on desired headroom, more info can be found under the 'Remediation' heading below
* August 8, 2022 - create new module to report on IP addresses used within each VNet that contains an ANF delegated subnet
* August 8, 2022 - created new module to show ANF/AVS datastores attached to AVS
* June 21, 2022 - added 'Volume Backup Status' module to show Azure NetApp Files backup status
* June 21, 2022 - added Capacity Pool column to all volume related modules
* June 21, 2022 - fixed Regional Quota module to use new powershell cmdlet, Get-AzNetAppFilesQuotaLimit
* Jan 14, 2022 - added parameter to set a custom subject line and report heading via -Subject parameter flag
* Jan 14, 2022 - fixed regional quota API call
* Sept 13, 2021 - added columns to CSV output, pool name, account, etc.
* Sept 01, 2021 - added CSV attachments to email for volume and pool details
* Sept 01, 2021 - added field 'active directory domain' to NetApp account module
* Sept 01, 2021 - created new module to show under-utilized pools only
* Sept 01, 2021 - created new module to show under-utilized volumes only, optionally only above a certain size
* Sept 01, 2021 - fixed display for 'manual' qos type in pool detail display
* Sept 01, 2021 - regional quota module now retrieves actual regional quota from API
* July 27, 2021 - added hash table to store hard coded regional quotas until API is available. Default is 25TiB unless another value is specified for a given region.

## Disclaimer

ANFHealthcheck is provided as is and is not supported by NetApp or Microsoft. You are encouraged to modify to fit your specific environment and/or requirements. It is strongly recommended to test the functionality before deploying to any business critical or production environments.

## Control the scope

The '-subId' parameter must be used to specify the scope of ANFCapacityManager

Specify a single SubId: 
```-SubId 'subscriptionIDhere'```

Specify a comma-delimited list of SubIds:
```-SubId 'sub-Id-one,sub-Id-two,sub-Id-three'```

Specify all SubIds:
```-SubId 'ALL'```

## What does it look like?

<https://seanluce.github.io/ANFHealthCheck/sample_output.html>

## Deploy from the Runbook Gallery

Deploy this script from the Runbook Gallery. Edit the 'Send-Email' function with your SMTP server, credentials, email address, etc.

## Clone this repo and run locally

Clone this repo to run locally on your machine. Use the parameter '-OutFile myfile.html' to write the output locally instead of sending via Email.

## Current Modules

* NetApp Account Summary
* Capacity Provisioned Against Regional Quota ([more info](https://azure.microsoft.com/en-us/updates/azure-netapp-files-regional-capacity-quota/#:~:text=StartingJuly%2026%2C%202021%20Azure%20NetApp%20Files%20%E2%80%93%20likesome,25%20TiB%2C%20per%20region%2C%20across%20all%20service%20levels.))
* Capacity Pool Utilization
* Volume Utilization Above x%
* Volume Utilization
* Volume Utilization Growth (x days)
* Volume Snapshot Status
* Volume Backup Status
* Volume Replication Status

## Remediation

ANFHealthCheck can remediate some health issues that it finds.

### ANFVolumeCapacityRemediation

This function will reduce the volume quotas if the headroom is above a desired threshold. Headroom is defined as the percent free space in the volume. To specify a volume's desired headroom, apply the tag titled 'anfhealthcheck_desired_headroom' to the volume resource and give it an integer value of the headroom percentage desired for that volume. For example, if 20% free space is desired, set the tag to an integer value of 20.

To enable volume capacity remediation, set the parameter '-volumeRemediation' to $true.

To enable volume capacity remediation 'dry run' mode, set the parameter '-volumeRemediation' to $true and the parameter '-remediationDryRun' to $true. This will provide a report of the remediation actions required, but will not modify any resources.

### ANFPoolCapacityRemediation

This function will reduce the capacity pool sizes if the headroom is above a desired threshold. Headroom is defined as the percent free space in the capacity pool that is not allocated to volumes. To specify a capacity pool's desired headroom, apply the tag titled 'anfhealthcheck_desired_headroom' to the capacity pool and give it an integer value of the headroom percentage desired for that capacity pool. For example, if 20% free space is desired, set the tag to an integer value of 20.

To enable pool capacity remediation, set the parameter '-poolRemediation' to $true.

To enable pool capacity remediation 'dry run' mode, set the parameter '-poolRemediation' to $true and the parameter '-remediationDryRun' to $true. This will provide a report of the remediation actions required, but will not modify any resources.

## Planned Modules

* ??? - Please open an issue if you have ideas for new modules!

## Requirements

* An SMTP server to send the emails. You can use SendGrid or any other SMTP server of your choice.
* Azure NetApp Files - of course! :D

## Need help?

Please open an issue here on GitHub and I will try to assist as my schedule permits.

## Disclaimer

This script is not supported by NetApp or Microsoft.

## Is this useful?

If you find this useful, please share and/or say hello on social media.
