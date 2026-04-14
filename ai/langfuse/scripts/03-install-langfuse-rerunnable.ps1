$ErrorActionPreference = "Stop"

param(
  [string]$Namespace = "langfuse",
  [string]$ReleaseName = "langfuse",
  [string]$ChartRef = "langfuse/langfuse",
  [string]$SecretName = "langfuse-secrets"
)

helm repo add langfuse https://langfuse.github.io/langfuse-k8s 2>$null | Out-Null
helm repo update | Out-Null

kubectl get ns $Namespace *> $null 2>&1
if ($LASTEXITCODE -ne 0) { kubectl create ns $Namespace | Out-Null }

$getKey = {
  param($ns, $name, $key)
  $b64 = kubectl -n $ns get secret $name -o ("jsonpath={.data.$key}") 2>$null
  if ($b64) { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64)) } else { $null }
}
$randB64 = { [Convert]::ToBase64String([byte[]](1..32 | ForEach-Object { Get-Random -Maximum 256 })) }
$randTxt = { -join ((48..57 + 65..90 + 97..122) | Get-Random -Count 32 | ForEach-Object { [char]$_ }) }

$salt = & $getKey $Namespace $SecretName "LANGFUSE_SALT"; if (-not $salt) { $salt = & $randB64 }
$nextauth = & $getKey $Namespace $SecretName "NEXTAUTH_SECRET"; if (-not $nextauth) { $nextauth = & $randB64 }
$pg = & $getKey $Namespace $SecretName "POSTGRES_PASSWORD"; if (-not $pg) { $pg = & $randTxt }
$ch = & $getKey $Namespace $SecretName "CLICKHOUSE_PASSWORD"; if (-not $ch) { $ch = & $randTxt }
$redis = & $getKey $Namespace $SecretName "REDIS_PASSWORD"; if (-not $redis) { $redis = & $randTxt }

kubectl -n $Namespace create secret generic $SecretName `
  --from-literal=LANGFUSE_SALT=$salt `
  --from-literal=NEXTAUTH_SECRET=$nextauth `
  --from-literal=POSTGRES_PASSWORD=$pg `
  --from-literal=CLICKHOUSE_PASSWORD=$ch `
  --from-literal=REDIS_PASSWORD=$redis `
  --dry-run=client -o yaml | kubectl apply -f - | Out-Null

helm upgrade --install $ReleaseName $ChartRef -n $Namespace `
  --set langfuse.salt.secretKeyRef.name=$SecretName `
  --set langfuse.salt.secretKeyRef.key=LANGFUSE_SALT `
  --set langfuse.nextauth.secret.secretKeyRef.name=$SecretName `
  --set langfuse.nextauth.secret.secretKeyRef.key=NEXTAUTH_SECRET `
  --set postgresql.auth.password=$pg `
  --set clickhouse.auth.password=$ch `
  --set redis.auth.password=$redis `
  --set langfuse.redis.password=$redis

Write-Host "Langfuse deployed/updated."
