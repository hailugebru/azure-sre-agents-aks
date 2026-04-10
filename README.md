# AKS NAP (Node Auto-Provisioning) Demo — PowerShell Scripts

This folder contains PowerShell scripts to deploy an AKS cluster with **Node Auto-Provisioning (NAP/Karpenter)**, run the [AKS Store Demo](https://github.com/Azure-Samples/aks-store-demo) application, and simulate an **OOMKilled** scenario for Azure SRE Agent troubleshooting.

## Prerequisites

- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) installed
- [kubectl](https://kubernetes.io/docs/tasks/tools/) installed
- An Azure subscription with permissions to create AKS clusters
- PowerShell 7+ (recommended)

## Before You Start

1. Open `00-variables.ps1` and update the `$SUBSCRIPTION_ID` variable with your Azure subscription ID.
2. Make sure you are logged in to Azure:
   ```powershell
   az login
   ```

## Step-by-Step Instructions

Run each script **in order** from this folder. Each step depends on the previous one.

---

### Step 0 — Load Variables

```powershell
. .\00-variables.ps1
```

Loads shared environment variables (`$SUBSCRIPTION_ID`, `$RESOURCE_GROUP`, `$LOCATION`, `$CLUSTER_NAME`) into your session. **Dot-source this first** — other scripts do it automatically.

---

### Step 1 — Prerequisites

```powershell
.\01-prerequisites.ps1
```

- Sets the active Azure subscription
- Registers the `NodeAutoProvisioningPreview` feature flag (waits until registered)
- Refreshes the `Microsoft.ContainerService` provider
- Installs/updates the `aks-preview` CLI extension

> **Note:** Feature registration can take 5-15 minutes.

---

### Step 2 — Create AKS Cluster

```powershell
.\02-create-cluster.ps1
```

- Creates the resource group
- Creates an AKS cluster with:
  - **NAP enabled** (`--node-provisioning-mode Auto`)
  - Azure CNI Overlay networking
  - Cilium dataplane
  - **Managed Prometheus** (`--enable-azure-monitor-metrics`)
- Downloads cluster credentials to your kubeconfig

> **Note:** Cluster creation takes ~5-10 minutes.

---

### Step 3 — Deploy the AKS Store Demo App

```powershell
.\03-deploy-app.ps1
```

- Creates the `pets` namespace
- Deploys the local manifests in `./manifests/aks-store` (MongoDB, RabbitMQ, order-service, product-service, makeline-service, store-front, store-admin, virtual-customer, virtual-worker)
- Waits for all pods to be Ready
- Prints the Store Front URL

---

### Step 4 — Enable NAP (Taint System Pool)

```powershell
.\04-setup-nap.ps1
```

- Discovers the default system nodepool
- Applies `CriticalAddonsOnly=true:NoExecute` taint to the system pool
- This evicts app pods → NAP/Karpenter provisions new user nodes automatically

**Monitor NAP activity:**
```powershell
kubectl get events -A --field-selector source=karpenter -w
kubectl get nodes,pods -n pets -o wide -w
```

**Inspect NAP nodepools:**
```powershell
kubectl get nodepool
kubectl describe nodepool default
```

---

### Step 5 — ARM64 NodePool Profile

```powershell
.\05-arm-nodepool.ps1
```

- Applies a Karpenter `NodePool` that prioritises **ARM64 D-family** VMs
- NAP will prefer ARM nodes for new workloads (cost-efficient)

---

### Step 6 — ARM64 NodePool v2 (Azure Linux)

```powershell
.\06-arm-nodepool-v2.ps1
```

- Applies an `AKSNodeClass` for **Azure Linux** (CBL-Mariner)
- Updates the ARM NodePool to use the Azure Linux node class

---

### Step 7 — Setup KEDA Scaler

```powershell
.\07-setup-keda-scaler.ps1
```

- Deploys a Secret, TriggerAuthentication, and ScaledObject for `virtual-worker`
- KEDA scales virtual-worker replicas based on RabbitMQ queue length

**Test scaling:**
```powershell
kubectl scale deployment virtual-customer -n pets --replicas=4
kubectl get deploy -n pets -w
kubectl exec rabbitmq-0 -n pets -- rabbitmqctl list_queues
```

---

### Step 8 — Configure GitHub Post-Incident Issue Automation (Portal)

This step is performed in the Azure portal at **[sre.azure.com](https://sre.azure.com)**.  
Run the helper script first to print the configuration checklist:

```powershell
.\08-setup-github-issues.ps1
```

**A — Add the GitHub MCP connector**

1. Go to **Builder > Connectors > + Add connector**
2. Select the **MCP** tab → **GitHub MCP server**
3. The portal pre-fills `https://api.githubcopilot.com/mcp/` and locks **Authentication method** to **Bearer token** — this is expected. MCP connectors use PAT/Bearer token, not OAuth.
   Generate a PAT at `github.com/settings/tokens` and paste it into the **PAT or API key** field.

   | PAT type | Required scope |
   |---|---|
   | Classic | `repo` |
   | Fine-grained *(recommended)* | `Issues: Read and write` scoped to `hailugebru/azure-sre-agents-aks` |

   > **Note:** The GitHub OAuth connector (Code Repository tab) is read-only. It cannot create issues — use the MCP connector here.

4. Select **Edit** on the new connector → **MCP Tools** → enable `create_issue` (and optionally `list_issues`)
5. Select **Save**

**B — Create the `github-issue-tracker` subagent**

1. Go to **Builder > Subagent builder > + Create subagent**
2. Name: `github-issue-tracker` | Autonomy: **Autonomous**
3. Add tool: `create_issue` from the `github-mcp` connection
4. Select **Save**

**C — Update the Incident Response Plan custom instructions**

Replace instruction 5 with:

```
5. After successful resolution, invoke the github-issue-tracker subagent to create
   a GitHub issue in hailugebru/azure-sre-agents-aks with the incident ID, root
   cause, patch applied, and a recommendation to update the source manifest in Git.
```

> **Verify:** After running the OOMKilled demo (Step 3 → Step 4), check  
> `https://github.com/hailugebru/azure-sre-agents-aks/issues` for the auto-created issue.

---

## Cleanup

To delete all Azure resources when done:

```powershell
. .\00-variables.ps1
az group delete -n $RESOURCE_GROUP --yes --no-wait
```

## Folder Structure

```
nap/
├── pwsh/               ← You are here (PowerShell scripts)
│   ├── 00-variables.ps1
│   ├── 01-prerequisites.ps1
│   ├── 02-create-cluster.ps1
│   ├── 03-deploy-app.ps1
│   ├── 04-setup-nap.ps1
│   ├── 05-arm-nodepool.ps1
│   ├── 06-arm-nodepool-v2.ps1
│   ├── 07-setup-keda-scaler.ps1
│   ├── 08-setup-github-issues.ps1
│   ├── README.md
│   └── manifests/
│       ├── aks-store/
│       │   ├── 00-mongodb.yaml
│       │   ├── 01-rabbitmq.yaml
│       │   ├── 02-order-service.yaml
│       │   ├── 03-makeline-service.yaml
│       │   ├── 04-product-service.yaml
│       │   ├── 05-store-front.yaml
│       │   ├── 06-store-admin.yaml
│       │   ├── 07-virtual-customer.yaml
│       │   └── 08-virtual-worker.yaml
│       ├── arm-nodepool-profile.yaml
│       ├── arm-nodepool-profile-v2.yaml
│       └── virtual-worker-scaler.yaml
├── cli/
├── README.md
└── workshop/
```
