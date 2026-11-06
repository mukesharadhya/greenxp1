<#
Fills in the GreenXP app secret (Secrets Manager "greenxp/app") without the values showing on screen or in history.
Press Enter to keep a value as it is; type "-" to remove it.
  .\aws\set-secrets.ps1              # Anthropic and Resend keys
  .\aws\set-secrets.ps1 -Supabase    # also the one-off Supabase migration settings
#>
param([switch]$Supabase, [string]$Region = "ap-south-1", [string]$Profile = "Mukesh", [string]$SecretId = "greenxp/app")
$ErrorActionPreference = "Stop"
$aws = (Get-Command aws -ErrorAction SilentlyContinue).Source
if (-not $aws) { $aws = "C:\Program Files\Amazon\AWSCLIV2\aws.exe" }

$current = & $aws secretsmanager get-secret-value --secret-id $SecretId --region $Region --profile $Profile --query SecretString --output text
if ($LASTEXITCODE) { throw "Couldn't read $SecretId" }
$values = @{}
($current | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $values[$_.Name] = $_.Value }

$keys = @("ANTHROPIC_API_KEY", "RESEND_API_KEY")
if ($Supabase) { $keys += "SUPABASE_DB_URL", "SUPABASE_SERVICE_ROLE_KEY" }
foreach ($k in $keys) {
  $state = if ($values[$k]) { "set" } else { "empty" }
  $s = Read-Host "$k (now $state)" -AsSecureString
  $v = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s))
  if ($v -eq "-") { $values.Remove($k) } elseif ($v) { $values[$k] = $v.Trim() }
}
if ($Supabase -and -not $values.SUPABASE_URL) { $values.SUPABASE_URL = "https://eloslvxejendunwoaydm.supabase.co" }

# Through a file, not the command line, so the values don't appear in the process list.
$file = New-TemporaryFile
try {
  [IO.File]::WriteAllText($file, ($values | ConvertTo-Json -Compress))
  & $aws secretsmanager put-secret-value --secret-id $SecretId --secret-string "file://$file" --region $Region --profile $Profile --query VersionId --output text | Out-Null
  if ($LASTEXITCODE) { throw "Couldn't save $SecretId" }
} finally { Remove-Item $file -Force }
Write-Host "Saved. Keys set: $(($values.Keys | Where-Object { $values[$_] } | Sort-Object) -join ', ')"
Write-Host "Restart the API to use them: .\aws\deploy.ps1 -Api"
