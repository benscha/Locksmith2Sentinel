# Locksmith2 to Microsoft Sentinel (Log Analytics)

This project automates the ingestion of Locksmith2 JSON reports into a custom table in an existing Log Analytics workspace.

## Included Components

- `main.bicep`
  - Creates the following resources in a resource group:
    - Custom table `Locksmith2_CL`
    - Data Collection Endpoint (DCE)
    - Data Collection Rule (DCR)
    - Role assignment `Monitoring Metrics Publisher` on the DCR scope (from explicit principal ID, or auto-resolved from an Arc/VM identity source)
  - Routes the `Custom-Locksmith2Stream` stream into `Locksmith2_CL`.
- `locksmith2Report.ps1`
  - Reads `*-locksmith2.json`
  - Validates records
  - Injects `TimeGenerated` in UTC (ISO 8601)
  - Authenticates via Managed Identity (native Azure VM IMDS at `169.254.169.254`, or the Azure Arc HIMDS endpoint at `localhost:40342` for Arc-connected servers)
  - Sends data through the Log Ingestion API to DCE/DCR
  - Archives successfully processed files
  - Writes local logs to `logs`
- `install.ps1`
  - Complete installation including:
    - Azure CLI check/installation
    - Permission check before deployment
    - Bicep deployment
    - Automatic managed identity principal resolution (client ID / Arc token claim)
    - Automatic Arc/VM identity source detection (machine name + resource group) when principal ID is not provided
    - Bicep-driven RBAC assignment `Monitoring Metrics Publisher` on DCR scope
    - `config.json` creation
    - Download/extract Locksmith2
    - Create/update scheduled task
  - Can also run without deployment by using `-SkipDeployment` (uses existing `config.json`)

## Prerequisites

- Windows Server with access to Azure
- Permissions on the target resource group (for example `Owner` or `Contributor`)
- Existing Log Analytics workspace
- Managed Identity on the server

## Security Concept (PoLP)

- No secrets in scripts or config
- Authentication exclusively via Managed Identity
- Recommended: user-assigned Managed Identity (lifecycle decoupled from server)
- RBAC for ingestion: role `Monitoring Metrics Publisher` on DCR scope

## Installation

Example command:

```powershell
.\install.ps1 `
  -SubscriptionId "<sub-id>" `
  -ResourceGroupName "<rg-name>" `
  -WorkspaceName "<law-name>" `
  -Location "westeurope" `
  -ManagedIdentityClientId "<optional-uami-client-id>" `
  -ManagedIdentityPrincipalId "<optional-mi-object-id>" `
  -ManagedIdentityMachineName "<optional-arc-or-vm-name>" `
  -ManagedIdentityResourceGroupName "<optional-identity-rg>"
```

If `-ManagedIdentityPrincipalId` is omitted, the installer now falls back to machine-based auto-resolution:

- resolves machine name from `-ManagedIdentityMachineName` or local hostname
- detects Arc machine (`Microsoft.HybridCompute/machines`) or Azure VM (`Microsoft.Compute/virtualMachines`)
- passes that identity source into Bicep, which resolves `identity.principalId` and assigns `Monitoring Metrics Publisher` on the DCR

Notes:

- Without `-NonInteractive`, the script asks for the scheduled task interval interactively.
- With `-SkipDeployment`, Azure login, Bicep deployment, and RBAC assignment are skipped.
- When using `-SkipDeployment`, a valid `config.json` must already exist in the project directory.
- For unattended execution, you can optionally use:

Full installation one-liner (deployment + non-interactive task settings):

```powershell
.\install.ps1 -SubscriptionId "<sub-id>" -ResourceGroupName "<rg-name>" -WorkspaceName "<law-name>" -Location "westeurope" -TaskSchedule DAILY -TaskModifier 1 -NonInteractive
```

```powershell
.\install.ps1 `
  -SubscriptionId "<sub-id>" `
  -ResourceGroupName "<rg-name>" `
  -WorkspaceName "<law-name>" `
  -Location "westeurope" `
  -TaskSchedule DAILY `
  -TaskModifier 1 `
  -NonInteractive
```

Installation without deployment (for example, when Bicep was already deployed from another machine):

```powershell
.\install.ps1 `
  -SkipDeployment `
  -TaskSchedule DAILY `
  -TaskModifier 1 `
  -NonInteractive
```

## Runtime Behavior

The scheduled task starts `locksmith2Report.ps1` on a regular interval.

Each run processes only the newest file matching `SourcePattern` (default: `*-locksmith2.json`) in `SourceDirectory`.

Files in the `archive` directory are explicitly excluded from processing.

Successfully ingested files are moved to `archive`.

## Configuration

The `config.json` file is created by `install.ps1`.

An example is available in `config.json.example`.

Important fields:

- `DceUri`
- `DcrImmutableId`
- `StreamName`
- `ManagedIdentityClientId` (optional; empty for system-assigned MI)

## External Deployment (SkipDeployment)

If you deploy `main.bicep` from another machine, run `install.ps1` on the target server with `-SkipDeployment`.

In this mode, the installer skips Azure login, Bicep deployment, and RBAC assignment, and uses the existing `config.json`.

You can extract the required values from your deployment outputs:

```powershell
$outputs = az deployment group show `
  --resource-group "<rg-name>" `
  --name "<deployment-name>" `
  --query "properties.outputs" `
  --output json | ConvertFrom-Json

$outputs.dataCollectionEndpointUri.value
$outputs.dataCollectionRuleImmutableId.value
$outputs.streamNameOut.value
```

Map them to `config.json` as follows:

- `DceUri` -> `dataCollectionEndpointUri.value`
- `DcrImmutableId` -> `dataCollectionRuleImmutableId.value`
- `StreamName` -> `streamNameOut.value`

Then run:

```powershell
.\install.ps1 -SkipDeployment -TaskSchedule DAILY -TaskModifier 1 -NonInteractive
```

## Example KQL

```kusto
Locksmith2_CL
| where TimeGenerated > ago(24h)
| summarize count() by Technique
| order by count_ desc
```

## 👏 Shoutouts & Thanks

A special thanks to these fantastic supporters and Microsoft MVP Fellows:

* **Nicola Suter** ([@nicolonsky](https://github.com/nicolonsky)) – for optimizing and testing the script
* **Jake Hildreth** ([@jakehildreth](https://github.com/jakehildreth)) – for his awesome work on Locksmith2 and for backing my solution
