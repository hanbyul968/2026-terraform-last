param([string]$Region, [string]$Name)
$ErrorActionPreference = "Continue"
$ts = aws kinesisanalyticsv2 describe-application --region $Region --application-name $Name --query 'ApplicationDetail.CreateTimestamp' --output text 2>$null
if ($ts -and $ts -ne "None") {
  aws kinesisanalyticsv2 delete-application --region $Region --application-name $Name --create-timestamp $ts
}
