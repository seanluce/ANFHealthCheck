<img src="./img/anficon.png" align="left" alt="" height="50" style="margin: 0 0 0 0; " />

# ANFHealthCheck

A PowerShell Runbook that will provide useful information about your Azure NetApp Files (ANF) resources. Schedule this to run every day for the most up-to-date info delivered straight to your inbox.

## What does it look like?

<https://seanluce.github.io/ANFHealthCheck/sample_output.html>

## Deploy from the Runbook Gallery

Deploy this script from the runbook Gallery. Edit the 'Send-Email' function with your SMTP server, credentials, email address, etc.

## Clone this repo and run locally

Clone this repo to run locally on your machine. Uncomment the last line to send the output to a local file.

## Current Modules

* NetApp Account Summary
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
