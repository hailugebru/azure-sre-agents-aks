# ============================================================
# Step 7 - Setup KEDA ScaledObject for virtual-worker
# ============================================================
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\00-variables.ps1"
$manifestsDir = Join-Path $PSScriptRoot "manifests"

Write-Host "=== Setting up KEDA ScaledObject for virtual-worker ===" -ForegroundColor Yellow
Write-Host ""

# Enable the KEDA add-on on AKS (idempotent — no-op if already enabled)
Write-Host "Enabling AKS KEDA add-on..."
az aks update `
  --resource-group $RESOURCE_GROUP `
  --name $CLUSTER_NAME `
  --enable-keda

Write-Host "Waiting for KEDA CRDs to become available..."
$retries = 0
while ($retries -lt 30) {
    $crd = kubectl get crd scaledobjects.keda.sh --ignore-not-found -o name 2>$null
    if ($crd) { break }
    Start-Sleep -Seconds 10
    $retries++
}
if (-not $crd) {
    Write-Error "Timed out waiting for KEDA CRDs"
    exit 1
}
Write-Host "KEDA CRDs are ready." -ForegroundColor Green
Write-Host ""

# Apply the ScaledObject manifest
Write-Host "Applying virtual-worker scaler (Secret + TriggerAuthentication + ScaledObject)..."
kubectl apply -f (Join-Path $manifestsDir "virtual-worker-scaler.yaml")

Write-Host ""
Write-Host "Verifying ScaledObject..."
kubectl get scaledobject -n pets

Write-Host ""
Write-Host "Verifying HPA created by KEDA..."
kubectl get hpa -n pets

Write-Host ""
Write-Host "=== KEDA ScaledObject setup complete ===" -ForegroundColor Green
Write-Host ""
Write-Host "To test scaling, run:" -ForegroundColor Cyan
Write-Host "  kubectl scale deployment virtual-customer -n pets --replicas=42"
Write-Host ""
Write-Host "To monitor scaling:" -ForegroundColor Cyan
Write-Host "  kubectl get deploy -n pets -w"
Write-Host "  kubectl events -w -n pets --for hpa/keda-hpa-virtual-worker-rabbitmq-scaledobject"
Write-Host "  kubectl exec rabbitmq-0 -n pets -- rabbitmqctl list_queues"
