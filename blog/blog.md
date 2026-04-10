# Autonomous AKS Incident Response with Azure SRE Agent

**Tags:** AKS, Azure SRE Agent, AI Ops, Node Auto-Provisioning, KEDA, Incident Response

> **Demo scope:** This walkthrough configures Azure SRE Agent with **Privileged** permissions and **Autonomous** run mode against a dedicated demo resource group. Validate these patterns against your organization's RBAC, networking, and change-control requirements before production adoption.

---

## In This Article

1. [Introduction](#introduction)
2. [Solution Architecture](#solution-architecture)
3. [Prerequisites & Demo Repo](#prerequisites--demo-repo)
4. [Step 1 — Deploy an AKS Cluster with NAP](#step-1--deploy-an-aks-cluster-with-nap)
5. [Step 2 — Deploy the AKS Store Demo App](#step-2--deploy-the-aks-store-demo-app)
6. [Step 3 — Configure Azure SRE Agent](#step-3--configure-azure-sre-agent)
7. [Step 4 — See It in Action: Two Real Incidents, Zero Escalations](#step-4--see-it-in-action-two-real-incidents-zero-escalations)
8. [Bonus: Node Auto-Provisioning in Action](#bonus-node-auto-provisioning-in-action)
9. [Key Takeaways & Next Steps](#key-takeaways--next-steps)

---

## Introduction

It's 2 AM. Azure Monitor fires a Sev1 alert: pods are crashing in your production AKS cluster. The traditional playbook kicks in — an on-call engineer is paged, logs in, runs a series of diagnostic commands, figures out the root cause, applies a fix, and verifies recovery. By the time that's done, **30 to 60 minutes have passed**.

For teams running containerized workloads on Azure Kubernetes Service (AKS), this manual response cycle is a source of alert fatigue, slow recovery times, and inconsistent remediation quality. **Azure SRE Agent** addresses this head-on: it is an AI-powered operations agent that connects to your Azure resources, receives alerts from Azure Monitor, and executes a structured investigate-diagnose-remediate-verify loop — fully autonomously.

In this post, I'll walk through that end-to-end flow — covering cluster setup, agent configuration, and two real incidents resolved without human intervention.

| Metric | Result |
|---|---|
| Alert to Full Recovery (Incident 1) | **~8 minutes** |
| Human Interventions Required | **0** |
| Namespaces Scanned Automatically | **6 (40+ pods)** |
| Patches Applied Across Both Incidents | **5** |
| GitHub Issue Auto-Created | **Yes — [#1](https://github.com/hailugebru/azure-sre-agents-aks/issues/1)** |

> _Outcomes above reflect a single controlled lab run on April 10, 2026. MTTR will vary based on cluster size, telemetry latency, and failure type._

---

## Solution Architecture

The demo environment brings together three layers: an AKS cluster configured for modern scaling and networking patterns, the AKS Store reference application, and Azure SRE Agent integrated with Azure Monitor for incident-triggered investigation and remediation.

In Azure SRE Agent terminology, Azure Monitor acts as the **incident platform**, while access to Azure telemetry and AKS diagnostics comes from the agent's built-in Azure capabilities and RBAC permissions. External systems such as GitHub are added through **connectors**.

```
Azure Monitor  →  Action Group  →  Azure SRE Agent  →  AKS Cluster
(Metric alert)    (Webhook)        (Investigate +       (NAP + Cilium
                                    Fix + Verify)         + KEDA)
```

| Component | Technology | Purpose |
|---|---|---|
| Cluster networking | Azure CNI Overlay + Cilium dataplane | eBPF-based networking; no kube-proxy |
| Node provisioning | NAP / Karpenter | Automatically provisions right-sized nodes |
| Autoscaling | KEDA | Scales `virtual-worker` on RabbitMQ queue depth |
| Monitoring trigger | Azure Monitor metric alert | Detects pod phase failures; combine with container waiting signals for broader coverage |
| AI agent | Azure SRE Agent | Autonomous incident investigation and remediation |

> **Azure SRE Agent in one minute**
>
> | Concept | What it means |
> |---|---|
> | **Incident platform** | Where alerts originate — Azure Monitor in this demo |
> | **Built-in Azure capabilities** | Azure Monitor, Log Analytics, Resource Graph, AKS diagnostics — no connector needed |
> | **Connectors** | External systems the agent can use: GitHub, Teams, Kusto, MCP servers |
> | **Permission level** | `Reader` (investigate only) or `Privileged` (investigate and remediate) |
> | **Run mode** | `Review` (agent proposes, human approves) or `Autonomous` (agent acts without approval) |

---

## Prerequisites & Demo Repo

> **📦 Demo Repository:** [github.com/hailugebru/azure-sre-agents-aks](https://github.com/hailugebru/azure-sre-agents-aks)  
> PowerShell scripts, Kubernetes manifests, and KEDA ScaledObject configurations.

**You will need:**

- An Azure subscription with permission to create AKS clusters
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) (v2.56+) with the `aks-preview` extension
- [kubectl](https://kubernetes.io/docs/tasks/tools/) and PowerShell 7+
- Azure SRE Agent access (currently in preview — see the [docs](https://learn.microsoft.com/azure/sre-agent/) to request access)

```powershell
git clone https://github.com/hailugebru/azure-sre-agents-aks
cd azure-sre-agents-aks

# Edit your subscription ID before running any scripts
notepad 00-variables.ps1
```

> **Enterprise note:** If your environment uses outbound filtering or a browser proxy, allow access to `*.azuresre.ai` during agent setup. You also need sufficient Azure RBAC permissions to create role assignments for the agent's managed identity (Owner, User Access Administrator, or RBAC Administrator on the target scope).

---

## Step 1 — Deploy an AKS Cluster with NAP

The demo cluster uses **Node Auto-Provisioning (NAP)** (built on Karpenter) for demand-driven node selection, Azure CNI Overlay with Cilium for eBPF networking, and managed Prometheus for metrics — a configuration that creates the kind of CPU and memory pressure Azure SRE Agent can investigate and remediate.

> **Note:** NAP manages infrastructure capacity. Azure SRE Agent investigates and remediates incidents. The agent does not interact with NAP directly.

```powershell
. .\00-variables.ps1
.\01-prerequisites.ps1   # register preview features (~5-15 min)
.\02-create-cluster.ps1  # create the cluster (~5-10 min)
```

---

## Step 2 — Deploy the AKS Store Demo App

The [AKS Store Demo](https://github.com/Azure-Samples/aks-store-demo) is a reference microservices application with nine components running in the `pets` namespace — covering stateless services, stateful dependencies (MongoDB, RabbitMQ), and event-driven workers.

Manifests are vendored locally in `manifests/aks-store/` for easy customization:

```powershell
.\03-deploy-app.ps1

# Verify all pods are Running
kubectl get pods -n pets
```

### Enable KEDA autoscaling for virtual-worker

KEDA scales `virtual-worker` on RabbitMQ queue depth — creating workload activity for the agent to observe during incident response.

```powershell
.\07-setup-keda-scaler.ps1
```

---

## Step 3 — Configure Azure SRE Agent

With the cluster and application running, the next step is to wire up the Azure SRE Agent. There are four configuration actions:

1. **Create the Azure SRE Agent resource**  
   In the Azure portal, search for *SRE Agent* → **+ Create**. Scope it to `Azure-SRE-Agent-Demo_RG` and name it `aks-sre-agent`. Azure SRE Agent creates two managed identities during deployment: a **user-assigned managed identity (UAMI)** — which you work with for RBAC and connector scenarios — and a system-assigned identity used internally by the service.

   > _Portal screenshot: Create Azure SRE Agent — Basics tab showing subscription, resource group, agent name, region, and managed identity toggle set to On._  
   > _(See Figure 1 in the [HTML version](./index.html))_

2. **Grant RBAC to the agent's managed identity**

   Azure SRE Agent uses the UAMI for Azure resource access. During setup, Azure assigns core monitoring roles including Reader, Log Analytics Reader, Monitoring Reader, and Monitoring Contributor (note that Monitoring Contributor is assigned at subscription scope, not just resource group scope). The exact additional roles depend on your **permission level** (Reader vs Privileged) and the resource types in your managed resource groups.

   For this demo, I granted additional AKS-specific rights to allow cluster remediation. Treat these as scenario-specific additions, not a universal production baseline:

   ```bash
   # AKS Cluster Admin Role — full kubectl access via managed identity
   az role assignment create \
       --assignee "<uami-client-id>" \
       --role "Azure Kubernetes Service Cluster Admin Role" \
       --scope "/subscriptions/<sub-id>/resourcegroups/Azure-SRE-Agent-Demo_RG"

   # AKS Contributor — ARM-level read/write on the AKS resource
   az role assignment create \
       --assignee "<uami-client-id>" \
       --role "Azure Kubernetes Service Contributor Role" \
       --scope "/subscriptions/<sub-id>/resourcegroups/Azure-SRE-Agent-Demo_RG"
   ```

   > **Privileged vs. Reader**: Choose **Privileged** when adding the resource group in step 3 — required for the agent to apply patches. Reader permission level gives read-only access suitable for Review run mode.

3. **Add your resource group as a Managed Resource**  
   In the agent's *Managed Resources* blade, click **+ Add resource** and add `Azure-SRE-Agent-Demo_RG`. Managed resource groups define the Azure scope the agent can investigate. Within that scope, the quality of diagnosis and actions available still depend on the agent's RBAC permissions and the telemetry your environment emits.

   > _Portal screenshot: Managed Resources blade showing `Azure-SRE-Agent-Demo_RG` with status **Connected**._  
   > _(See Figure 2 in the [HTML version](./index.html))_

4. **Add an Azure Monitor trigger**

   **Part A — Connect Azure Monitor in the SRE Agent portal:**
   1. Go to **Builder → Incident platform**.
   2. Select **Azure Monitor** and turn **off** the *Quickstart response plan* toggle (you will create a custom one in the next step).
   3. Click **Save**. The portal generates a **webhook URL** — copy it.

   **Part B — Route the alert to the agent via Azure portal:**
   1. Open **Azure Portal → Monitor → Alerts → Action groups → + Create**.
   2. Under **Actions**, set Action type to **Webhook** and paste the webhook URL from Part A.
   3. Save the Action Group.
   4. Open the `pod-not-healthy` metric alert rule (scoped to the AKS cluster), attach the Action Group, and save.

   When the metric fires, the webhook delivers the alert payload to the agent, which matches it against your response plans and begins autonomous investigation within seconds.

   > **Alert coverage note:** `kube_pod_status_phase{phase="Failed"}` catches pods in the Failed phase, but `CrashLoopBackOff` is a container waiting reason — not a pod phase — and may not trigger this rule alone. For broader AKS production coverage, combine phase-based alerts with container waiting/termination signals and node-health rules.

   > _Portal screenshot: Builder → Incident platform blade showing Azure Monitor connected with the webhook URL and active response plan count._  
   > _(See Figure 3 in the [HTML version](./index.html))_

### Incident Response Plan: operating patterns

Azure SRE Agent uses two distinct control layers:
- **Permission level** (`Reader` or `Privileged`) — determines what Azure resources the agent can access and modify
- **Run mode** (`Review` or `Autonomous`) — determines whether the agent waits for approval before executing Azure infrastructure actions

In practice, most teams adopt the service in three patterns:

| Pattern | Permission | Run mode | Behavior | Recommended For |
|---|---|---|---|---|
| **Read-only investigation** | Reader | Review | Investigates and reports root cause. Makes **no changes**. | Initial rollout, compliance-sensitive environments |
| **Guided remediation** | Privileged | Review | Proposes exact actions. **Waits for human approval** before execution. | Building team confidence, moderate-severity alerts |
| **Autonomous remediation** | Privileged | Autonomous | Full loop: investigate → diagnose → remediate → verify → report. **No approval required.** | Production Sev0/Sev1 where MTTR is the priority |

> **⚡ Recommended ramp-up approach**  
> Start in the **Guided remediation** pattern for 1–2 weeks. Review and approve proposed actions to build operational confidence, then promote to **Autonomous** for Sev0/Sev1 alerts. Keep allowed actions narrowly scoped and validate behavior in Review mode before expanding autonomy.

> _Portal screenshot: Incident Response Plan blade — Autonomous mode selected, allowed actions checklist, notification integrations._  
> _(See Figure 4 in the [HTML version](./index.html))_

### Custom instructions for your environment

The Incident Response Plan supports free-text instructions that give the agent domain-specific context:

```
For AKS pod health alerts in the pets namespace:
1. Scan all namespaces for unhealthy pods first.
2. Prioritise OOMKilled and CrashLoopBackOff.
3. For OOMKilled: correlate NODE_OPTIONS / JVM flags against container memory limits
   before adjusting. Apply the minimum necessary increase.
4. After any patch, wait for rollout, then verify cluster-wide pod health.
5. After successful resolution, invoke the github-issue-tracker subagent to create
   a GitHub issue in hailugebru/azure-sre-agents-aks with the incident ID, root
   cause, patch applied, and a recommendation to update the source manifest in Git.
```

> These instructions shape the agent's workflow, but do not replace RBAC, telemetry quality, or the actual tool capabilities available to the agent.

---

### Post-Incident GitHub Issue Automation

After every successful remediation, the agent creates a GitHub issue — capturing the incident ID, root cause, patches applied, and follow-up recommendations. This closes the loop from runtime fix to tracked manifest change.

**GitHub MCP Connector Setup:**

1. Go to **Builder > Connectors > + Add connector > MCP tab > GitHub MCP server**. The portal pre-fills `https://api.githubcopilot.com/mcp/` and locks auth to **Bearer token**.
2. Generate a fine-grained PAT at `github.com/settings/tokens` with `Issues: Read and write` scoped to your repo. Paste it into the PAT field and select **Next**.
3. Once connected, enable the `create_issue` and `list_issues` MCP tools under **Edit → MCP Tools**, then **Save**.

> **Least-privilege:** Scope the PAT to a single repo with `Issues: Read and write` only — limits the agent's blast radius to issue management.

A dedicated `github-issue-tracker` subagent (**Builder > Subagent builder > + Create subagent**) keeps GitHub write access auditable — the main agent invokes it only after a confirmed resolution.

#### What the auto-created issue looks like

After Incident 1 resolved, the agent automatically filed [Issue #1](https://github.com/hailugebru/azure-sre-agents-aks/issues/1) at `16:01:26 UTC` — no human action. The issue contained:

- **Title:** `[AKS Alert] Pod Health Failures - pets namespace - 69e4dbba-6f33-5bc7-1700-c7d5e5b4000b`
- **Labels:** `aks`, `memory-management`, `pod-health`
- **Body:** Full incident summary with alert ID and timestamps, all unhealthy pods with failure states, root cause for each failure type, before/after tables for all 5 patches, post-patch `kubectl top` verification for all 9 pods, 7 actionable recommendations (including *"Update source manifests in Git"* and *"Add resource limit validation to the CI/CD pipeline to prevent sub-10m CPU limits from being deployed"*), and a deep link back to the SRE Agent investigation thread for a full audit trail.

---

## Step 4 — See It in Action: Two Real Incidents, Zero Escalations

These two incidents occurred on the same cluster in a single session on April 10, 2026, demonstrating both alert-driven and chat-driven investigation workflows — and two of the most common Kubernetes failure modes.

### Incident 1: CPU Starvation and Startup Probe Failures — Alert-Driven (MTTR: ~8 minutes)

**Trigger the incident.** Apply a misconfigured deployment with a 5 millicore CPU limit:

```powershell
kubectl patch deployment makeline-service -n pets --type='json' `
    -p='[
      {"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/cpu","value":"5m"},
      {"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/memory","value":"20Mi"}
    ]'

kubectl get pods -n pets -w
```

```
NAME                                  READY   STATUS             RESTARTS   AGE
makeline-service-59bcdc58fb-845wj     0/1     Error              1          32s
makeline-service-59bcdc58fb-845wj     0/1     CrashLoopBackOff   1          45s
```

Within five minutes, Azure Monitor fires the `pod-not-healthy` Sev1 alert (Alert ID `69e4dbba`, fired `15:36:15 UTC`) and the agent begins working immediately.

#### What the agent did

| Phase | Action |
|---|---|
| **Discover** | Scanned 40+ pods across 6 namespaces; isolated `makeline-service` (1 restart, exit code `1`) |
| **Root cause** | CPU limit `5m` caused 6× startup probe failures (`connection refused`) — port bind timeout. Exit code `1` (not `137`) ruled out OOMKill. |
| **Expand** | `kubectl top` found 3 more pods CPU-throttled at 112–200% of limit |
| **Remediate → Verify** | 4 patches applied sequentially; all 9 pods Running/0 restarts cluster-wide |

> _Portal screenshot: Incident History blade showing alert ID `69e4dbba`, Status: Resolved, 4 patches applied, cluster-wide sweep: 0 unhealthy pods._  
> _(See Figure 5 in the [HTML version](./index.html))_

---

### Incident 2: OOMKilled — Chat-Driven (MTTR: ~4 minutes)

Shortly after Incident 1, an engineer noticed `order-service` was unhealthy. **No alert needed** — the agent handles ad-hoc investigations from the chat window too.

**Trigger the incident.** Deploy `order-service-changed.yaml`, which has a 20Mi memory limit — far too low for Node.js/Fastify:

```powershell
kubectl apply -f .\manifests\aks-store\order-service-changed.yaml -n pets

kubectl get pods -n pets -w
```

```
NAME                               READY   STATUS             RESTARTS   AGE
order-service-75b944dd4b-m8td6     0/1     OOMKilled          1          18s
order-service-75b944dd4b-m8td6     0/1     CrashLoopBackOff   4          72s
```

**Chat prompt to the agent:**

```
The order-service pod in the pets namespace is not healthy.
Please investigate, identify the root cause, and fix it.
```

#### What the agent did

| Phase | Action |
|---|---|
| **Identify** | `kubectl describe` confirmed `OOMKilled`, exit code `137`, memory limit `20Mi` |
| **Root cause** | Empty container logs (killed before first write) + no `NODE_OPTIONS` in ConfigMap ruled out V8 heap misconfiguration — the `20Mi` limit was 12.8× below the pod's observed 50Mi runtime baseline |
| **Remediate → Verify** | Memory limit patched `20Mi → 128Mi`; new pod Running at 74Mi/128Mi (58% utilization), 0 restarts |

---

### Automated GitHub issue — [#1](https://github.com/hailugebru/azure-sre-agents-aks/issues/1)

After verifying Incident 1, the agent automatically created [GitHub Issue #1](https://github.com/hailugebru/azure-sre-agents-aks/issues/1) at `16:01:26 UTC` with no human action. The issue includes before/after tables for all 5 patches, post-patch `kubectl top` output for all 9 pods, 7 actionable recommendations, and a deep link to the investigation thread — giving the team everything they need to update the source manifests permanently.

### Traditional response vs. Azure SRE Agent

| | Traditional On-Call | Azure SRE Agent |
|---|---|---|
| Alert → response begins | 5–15 min (page and wake up) | Instant (webhook) |
| Connect to cluster | 3–10 min (VPN, kubeconfig) | Near-immediate once permissions, incident routing, and AKS API access are already configured |
| Scan 40+ pods across 6 namespaces | 10–20 min (sequential `kubectl`) | ~1 min (automated, parallel) |
| Correlate CPU limits, events, logs | 10–15 min (domain knowledge required) | ~2 min (structured checklist, rules out wrong hypotheses) |
| Apply 4 patches + monitor each rollout | 10–20 min | ~3 min (auto-generated, sequential rollouts) |
| Cluster-wide verification sweep | 5–10 min | ~1 min |
| Incident report + GitHub issue | 15–30 min next morning | Automatic, complete in minutes |
| **Total MTTR** | **60–120 minutes** | **~8 minutes (7–15× faster)** |

---

## Bonus: Node Auto-Provisioning in Action

While Azure SRE Agent handles incident response, NAP manages infrastructure elasticity underneath. Scripts `05-arm-nodepool.ps1` and `06-arm-nodepool-v2.ps1` apply Karpenter `NodePool` manifests that bias node selection toward **ARM64 D-family** VMs on **Azure Linux** — Microsoft's AKS guidance describes Arm64 VMs as delivering up to 50% better price-performance than comparable x86 VMs for scale-out workloads. If targeting Azure Linux 3 (the current stable release), update the `AKSNodeClass` OS SKU accordingly.

```powershell
.\05-arm-nodepool.ps1    # apply ARM64 NodePool preference
.\06-arm-nodepool-v2.ps1 # add Azure Linux AKSNodeClass

# Inspect NAP-provisioned nodes
kubectl get nodepool
kubectl describe nodepool default
```

---

## Key Takeaways & Next Steps

Azure SRE Agent detected and resolved two real AKS incidents — CPU starvation (~8 min MTTR) and OOMKilled (~4 min MTTR) — applying 5 patches with zero human interventions, then automatically filed a GitHub issue as a post-incident audit trail.

The key insight isn't just speed — it's **consistency**. The agent runs the same investigate → diagnose → remediate → verify → report loop every time, at 3 AM or 3 PM.

**Three things to carry forward:**

1. **Azure SRE Agent is a governed incident-response system**, not just an AI chatbot. The real levers are **permission levels** (Reader vs Privileged) and **run modes** (Review vs Autonomous) — not prompt quality.
2. **Built-in Azure diagnostics cover most of what you need.** Connectors extend the agent to external systems like GitHub and Teams when you're ready.
3. **Start narrow and expand deliberately.** One resource group, one incident type, Review run mode first. Validate that telemetry flows, RBAC is scoped correctly, and your incident trigger covers the failure modes you care about (`kube_pod_status_phase{phase="Failed"}` alone misses most `CrashLoopBackOff` scenarios) before enabling Autonomous.

### Extend the demo

- **Broader alert coverage**: add rules for `CrashLoopBackOff`, `ImagePullBackOff`, and node resource pressure
- **Multi-cluster**: add a second AKS cluster to Managed Resources and watch the agent correlate cross-cluster signals
- **Teams notifications**: add the **Send notification (Teams)** connector and a `teams-notifier` subagent to ping your on-call channel alongside the GitHub issue

### Resources

| Resource | Link |
|---|---|
| Demo repository | [github.com/hailugebru/azure-sre-agents-aks](https://github.com/hailugebru/azure-sre-agents-aks) |
| Azure SRE Agent docs | [learn.microsoft.com/azure/sre-agent](https://learn.microsoft.com/azure/sre-agent/) |
| AKS Store Demo | [github.com/Azure-Samples/aks-store-demo](https://github.com/Azure-Samples/aks-store-demo) |
| Node Auto-Provisioning | [learn.microsoft.com/azure/aks/node-autoprovision](https://learn.microsoft.com/azure/aks/node-autoprovision) |
| KEDA on AKS | [learn.microsoft.com/azure/aks/keda-about](https://learn.microsoft.com/azure/aks/keda-about) |
