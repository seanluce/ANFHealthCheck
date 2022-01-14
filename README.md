<img src="./img/anficon.png" alt="" height="50" style="margin: 0 0 0 0; " />

# ANFHealthCheck

A PowerShell Runbook that will provide useful information about your Azure NetApp Files (ANF) resources. Schedule this to run every day for the most up-to-date info delivered straight to your inbox.

## Change Log

* Jan 14, 2022 - added parameter to set a custom subject line and report heading via -Subject parameter flag
* Jan 14, 2022 - fixed regional quota API call
* Sept 13, 2021 - added additional columns to CSV output, pool name, account, etc.
* Sept 01, 2021 - added CSV attachments to email for volume and pool details
* Sept 01, 2021 - added field 'active directory domain' to NetApp account module
* Sept 01, 2021 - created new module to show under-utilized pools only
* Sept 01, 2021 - created new module to show under-utilized volumes only, optionally only above a certain size
* Sept 01, 2021 - fixed display for 'manual' qos type in pool detail display
* Sept 01, 2021 - regional quota module now retrieves actual regional quota from API
* July 27, 2021 - added hash table to store hard coded regional quotas until API is available. Default is 25TiB unless another value is specified for a given region.

## Limit the scope to a single Subscription

Use the -SubID parameter to limit the scope to a single subscription ID.

## What does it look like?

<https://seanluce.github.io/ANFHealthCheck/sample_output.html>

## Deploy from the Runbook Gallery

Deploy this script from the Runbook Gallery. Edit the 'Send-Email' function with your SMTP server, credentials, email address, etc.

## Clone this repo and run locally

Clone this repo to run locally on your machine. Use the parameter '-OutFile myfile.html' to write the output locally instead of sending via Email.

## Current Modules

* NetApp Account Summary
* NEW Capacity Provisioned Against Regional Quota ([more info](https://azure.microsoft.com/en-us/updates/azure-netapp-files-regional-capacity-quota/#:~:text=StartingJuly%2026%2C%202021%20Azure%20NetApp%20Files%20%E2%80%93%20likesome,25%20TiB%2C%20per%20region%2C%20across%20all%20service%20levels.))
* Capacity Pool Utilization
* Volume Utilization Above x%
* Volume Utilization
* Volume Utilization Growth (x days)
* Volume Snapshot Status
* Volume Replication Status

## Planned Modules

* ??? - Please open an issue if you have ideas for new modules!

## Requirements

* An SMTP server to send the emails. You can use Azure SendGrid or any other SMTP server of your choice.
* Azure NetApp Files - of course! :D

## Need help?

Please open an issue here on GitHub and I will try to assist as my schedule permits.

## Disclaimer

This script is not supported by NetApp or Microsoft.

## Is this useful?

If you find this useful, please share and/or say hello on social media.
