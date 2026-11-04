<#
Deploys GreenXP to AWS. With no switches it does -Infra, -Api and -Web in that order.
  .\aws\deploy.ps1                 # everything
  .\aws\deploy.ps1 -Api            # just the API code
  .\aws\deploy.ps1 -Web            # just the site
  .\aws\deploy.ps1 -Migrate        # one-off copy from Supabase (see aws/README.md)
#>
param(
  [switch]$Infra, [switch]$Api, [switch]$Web, [switch]$Migrate,
  [string]$Stack = "greenxp", [string]$Region = "ap-south-1", [string]$Profile = "Mukesh",
  [string]$Domain = "greenxp.in",
  [string]$EipAllocationId = "eipalloc-044fc879cc73b5b99" # 13.206.152.233, the A record for greenxp.in
)
$ErrorActionPreference = "Stop"
if (-not ($Infra -or $Api -or $Web -or $Migrate)) { $Infra = $Api = $Web = $true }
$root = Split-Path $PSScriptRoot
$aws = (Get-Command aws -ErrorAction SilentlyContinue).Source
if (-not $aws) { $aws = "C:\Program Files\Amazon\AWSCLIV2\aws.exe" }
# Server output can contain non-ASCII characters (npm, dnf); without UTF-8 the CLI crashes printing them.
$env:PYTHONUTF8 = "1"; $env:PYTHONIOENCODING = "utf-8"
[Console]::OutputEncoding = [Text.Encoding]::UTF8

# The CLI writes progress to stderr; in Windows PowerShell that would count as an error, so only the exit code decides.
function Aws {
  $ErrorActionPreference = "Continue"
  & $aws @args --region $Region --profile $Profile 2>&1 | ForEach-Object { if ($_ -is [Management.Automation.ErrorRecord]) { Write-Host $_ } else { $_ } }
  if ($LASTEXITCODE) { throw "aws $($args[0]) $($args[1]) failed" }
}
function Outputs {
  $o = @{}
  (Aws cloudformation describe-stacks --stack-name $Stack --query "Stacks[0].Outputs" --output json | Out-String | ConvertFrom-Json) |
    ForEach-Object { $o[$_.OutputKey] = $_.OutputValue }
  $o
}
# Runs a shell command on the API server through SSM and prints its output; fails if the command fails.
function OnServer([string]$instance, [string]$command, [int]$timeout = 900) {
  $params = @{ commands = @($command); executionTimeout = @("$timeout") } | ConvertTo-Json -Compress
  $file = New-TemporaryFile; [IO.File]::WriteAllText($file, $params)
  $id = Aws ssm send-command --instance-ids $instance --document-name AWS-RunShellScript --parameters "file://$file" `
    --timeout-seconds 60 --query Command.CommandId --output text
  Remove-Item $file
  do {
    Start-Sleep 5
    $r = Aws ssm get-command-invocation --command-id $id --instance-id $instance --output json | Out-String | ConvertFrom-Json
    if (-not $r.Status) { throw "Couldn't read the status of command $id" }
  } while ($r.Status -in "Pending", "InProgress", "Delayed")
  Write-Host $r.StandardOutputContent
  if ($r.Status -ne "Success") { Write-Host $r.StandardErrorContent; throw "Command on the API server ended with $($r.Status)" }
}

if ($Infra) {
  Write-Host "== Infrastructure (stack $Stack in $Region; the first run takes 20-30 minutes)"
  Aws cloudformation deploy --template-file "$PSScriptRoot\greenxp.yaml" --stack-name $Stack `
    --capabilities CAPABILITY_IAM --no-fail-on-empty-changeset `
    --parameter-overrides "DomainName=$Domain" "ApiEipAllocationId=$EipAllocationId"
}
$out = Outputs

if ($Api) {
  Write-Host "== API"
  $bundle = Join-Path ([IO.Path]::GetTempPath()) "greenxp-api.tgz"
  tar -czf $bundle -C "$root\api" --exclude node_modules --exclude .env .
  $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
  Aws s3 cp $bundle "s3://$($out.ArtifactsBucket)/api/$stamp.tgz" --only-show-errors
  Aws s3 cp $bundle "s3://$($out.ArtifactsBucket)/api/current.tgz" --only-show-errors
  OnServer $out.ApiInstanceId "/usr/local/bin/greenxp-deploy"
}

if ($Migrate) {
  Write-Host "== Copy data from Supabase"
  Aws s3 cp "$PSScriptRoot\db" "s3://$($out.ArtifactsBucket)/migration/db" --recursive --only-show-errors
  OnServer $out.ApiInstanceId ("rm -rf /opt/greenxp/migration && aws s3 cp s3://$($out.ArtifactsBucket)/migration/db /opt/greenxp/migration " +
    "--recursive --quiet --region $Region && bash /opt/greenxp/migration/migrate-from-supabase.sh") 1800
}

if ($Web) {
  Write-Host "== Site"
  $dir = Join-Path ([IO.Path]::GetTempPath()) "greenxp-web"
  Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
  Copy-Item "$root\web" $dir -Recurse
  @"
// Written by aws/deploy.ps1 from the CloudFormation stack's outputs. Public values only.
window.GXP = {
  API_URL: "",
  COGNITO_REGION: "$Region",
  COGNITO_CLIENT_ID: "$($out.CognitoClientId)"
};
"@ | Set-Content "$dir\config.js" -Encoding utf8
  $bundle = Join-Path ([IO.Path]::GetTempPath()) "greenxp-site.tgz"
  tar -czf $bundle -C $dir .
  Aws s3 cp $bundle "s3://$($out.ArtifactsBucket)/site/current.tgz" --only-show-errors
  OnServer $out.ApiInstanceId "/usr/local/bin/greenxp-deploy-site"
}

Write-Host "Done. Site: $($out.SiteUrl)"
