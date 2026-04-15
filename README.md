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

## Minimal Setup

If you are coming from the blog post and want the shortest path into the demo, start here.

> **Demo repository:** [github.com/hailugebru/azure-sre-agents-aks](https://github.com/hailugebru/azure-sre-agents-aks)

**Prerequisites**
- Azure subscription with AKS deployment permissions
- Azure CLI with `aks-preview`
- Access to Azure SRE Agent

```powershell
git clone https://github.com/hailugebru/azure-sre-agents-aks
cd azure-sre-agents-aks
notepad 00-variables.ps1
```

That is enough to get the environment variables in place and continue with the full setup steps below.

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

> **Advanced: ARM64 Node Pools**  
> Steps 5 and 6 bias NAP toward ARM64 Azure Linux nodes for cost-efficient scale-out. NAP and Azure SRE Agent are complementary but separate — NAP manages infrastructure capacity, the agent investigates and remediates incidents. To apply:
> ```powershell
> .\05-arm-nodepool.ps1    # apply ARM64 NodePool preference
> .\06-arm-nodepool-v2.ps1 # add Azure Linux AKSNodeClass
> kubectl get nodepool
> kubectl describe nodepool default
> ```

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

### Step 8 — Configure Azure SRE Agent (Portal)

This step is performed in the Azure portal at **[sre.azure.com](https://sre.azure.com)**.

Azure SRE Agent configuration for this demo came down to four things: **scope**, **permissions**, **incident intake**, and **response mode**.

**A — Create the agent and scope it correctly**

1. Create an Azure SRE Agent resource and scope it to the demo resource group.
2. During deployment, Azure SRE Agent creates two managed identities:
    - a **user-assigned managed identity (UAMI)** used for RBAC and connector access
    - a system-assigned identity used internally by the service
3. Use the **UAMI** for the role assignments and connector setup below.
4. Add the demo resource group as a **managed resource** so the agent can investigate resources within that scope.

**B — Grant scenario-specific AKS access**

Core monitoring roles are assigned during setup. For this demo, I added AKS-specific rights so the agent could complete remediation end to end. Treat these as **scenario-specific**, not a default production baseline.

```bash
az role assignment create \
   --assignee "<uami-client-id>" \
   --role "Azure Kubernetes Service Cluster Admin Role" \
   --scope "/subscriptions/<sub-id>/resourcegroups/Azure-SRE-Agent-Demo_RG"

az role assignment create \
   --assignee "<uami-client-id>" \
   --role "Azure Kubernetes Service Contributor Role" \
   --scope "/subscriptions/<sub-id>/resourcegroups/Azure-SRE-Agent-Demo_RG"
```

**C — Connect Azure Monitor as the incident platform**

1. In Azure SRE Agent, configure **Azure Monitor** as the incident platform.
2. Copy the generated webhook URL.
3. Route the AKS alert to that webhook through an Azure Monitor **Action Group**.

This distinction matters: Azure Monitor handles how incidents **enter** the workflow, while connectors such as GitHub and Teams extend the workflow **outward** for tracking and communication.

**D — Choose permission level and run mode deliberately**

Use the safest rollout path:

```text
Start:   Reader + Review
Then:    Privileged + Review
Finally: Privileged + Autonomous for narrow, trusted incident paths
```

For this demo, I used broader permissions and `Autonomous` mode on a dedicated lab resource group so the workflow could run end to end without manual approval gates.

**E — Add custom instructions for AKS pod-health incidents**

These instructions shape the workflow, but they do not replace RBAC, telemetry quality, or tool availability:

```text
For AKS pod health alerts in the pets namespace:
1. Scan all namespaces for unhealthy pods first.
2. Prioritise OOMKilled and CrashLoopBackOff.
3. For OOMKilled: correlate NODE_OPTIONS / JVM flags against container memory limits before adjusting.
4. After any patch, wait for rollout, then verify cluster-wide pod health.
5. After successful resolution, create a GitHub issue with the incident ID, root cause, patch applied, and a recommendation to update the source manifest in Git.
```

---

### Step 9 — Configure GitHub Post-Incident Issue Automation (Portal)

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

> **Optional handoff:** The generated GitHub issue can be assigned to a GitHub agent, which can use the issue body, comments, and an additional prompt to begin the engineering follow-up work.

**D — Optional: Continue from issue to pull request**

If you assign the generated GitHub issue to a GitHub agent, the workflow can continue beyond issue creation:

1. The GitHub agent reads the **issue description**, any **comments**, and any **additional prompt** you provide.
2. It analyzes the repository against the incident context and proposed remediation.
3. It can then open a **draft pull request** for your review so the source manifests reflect the approved hotfix.

In this demo, that handoff produced a draft PR to align the `order-service` manifests with the memory remediation identified during the incident, so the repo would not drift from the in-cluster fix.

That is the end-to-end loop this setup enables: Azure SRE Agent handles live-site detection and mitigation, GitHub captures the engineering artifact, and the GitHub agent can carry the work forward into a reviewable code change.

---

### Step 10 — Configure Teams Notifications (Portal)

Use the Teams connector when you want real-time visibility during an autonomous run.

1. Go to **Builder > Connectors > + Add connector**.
2. Select **Microsoft Teams** and complete the sign-in flow.
3. Choose the target team and channel for incident updates.
4. Enable the connector for the Azure SRE Agent workflow.

In this demo, Teams carried three milestone updates during the incident:

1. investigation started
2. root cause and remediation identified
3. incident resolved

Teams provided real-time coordination for the on-call team, while GitHub captured the durable engineering follow-up.

---

## Try It Yourself

If you are coming from the blog post, this README is the full setup appendix.

1. Access Azure SRE Agent.
2. Clone the demo repo and run the setup scripts against your own subscription.
3. Start with `Reader + Review` on a non-production resource group.
4. Expand to `Privileged + Autonomous` only after validating the agent's reasoning and remediation quality in your environment.

## Full Setup Details

This README contains the complete AKS deployment steps, connector configuration, and post-incident artifact setup used in the blog demo:

- AKS cluster + NAP setup
- KEDA scaler setup
- Azure SRE Agent role assignments
- GitHub connector and issue automation
- Teams connector configuration

### Resources

| Resource | Link |
|---|---|
| Demo repository | [github.com/hailugebru/azure-sre-agents-aks](https://github.com/hailugebru/azure-sre-agents-aks) |
| Azure SRE Agent docs | [learn.microsoft.com/azure/sre-agent](https://learn.microsoft.com/azure/sre-agent/) |
| AKS Store Demo | [github.com/Azure-Samples/aks-store-demo](https://github.com/Azure-Samples/aks-store-demo) |
| Node Auto-Provisioning | [learn.microsoft.com/azure/aks/node-autoprovision](https://learn.microsoft.com/azure/aks/node-autoprovision) |
| KEDA on AKS | [learn.microsoft.com/azure/aks/keda-about](https://learn.microsoft.com/azure/aks/keda-about) |

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
