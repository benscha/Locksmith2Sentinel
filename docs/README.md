# Locksmith2 to Microsoft Sentinel (Log Analytics)

This project automates the ingestion of Locksmith2 JSON reports into a custom table in an existing Log Analytics workspace.

## Included Components

- `main.bicep`
  - Creates the following resources in a resource group:
    - Custom table `Locksmith2_CL`
    - Data Collection Endpoint (DCE)
    - Data Collection Rule (DCR)
    - DCR diagnostic setting that routes `LogErrors` to the Log Analytics workspace
    - Optional role assignment `Monitoring Metrics Publisher` on the DCR scope for a supplied managed identity principal ID
  - Routes the `Custom-Locksmith2Stream` stream into `Locksmith2_CL`.
- `main.bicepparam`
  - Supplies deployment parameters separately from the Windows installer. Edit its location, workspace name, and optional managed identity principal ID before deployment.
- `locksmith2Report.ps1`
  - Reads `*-locksmith2.json`
  - Validates records
  - Injects `TimeGenerated` in UTC (ISO 8601)
  - Authenticates via Managed Identity (native Azure VM IMDS at `169.254.169.254`, or the Azure Arc HIMDS endpoint at `localhost:40342` for Arc-connected servers)
  - Sends data through the Log Ingestion API to DCE/DCR
  - Archives successfully processed files
  - Writes local logs to `logs`
- `install.ps1`
  - Installs the Windows-side components only: validates `config.json`, downloads Locksmith2, and creates or updates the scheduled task.
  - Does not log into Azure or deploy infrastructure. Deploy `main.bicep` separately and populate `config.json` from the deployment outputs.

## Prerequisites

- Windows Server with access to Azure
- Azure CLI with Bicep support and permissions to deploy resources (for the separate infrastructure deployment)
- Existing Log Analytics workspace
- Managed Identity on the server

## Security Concept (PoLP)

- No secrets in scripts or config
- Authentication exclusively via Managed Identity
- Recommended: user-assigned Managed Identity (lifecycle decoupled from server)
- RBAC for ingestion: role `Monitoring Metrics Publisher` on DCR scope, assigned to the supplied managed identity principal ID

## Infrastructure Deployment

Infrastructure deployment is independent of the Windows installer. Sign in and select the subscription that contains the deployment resource group:

```powershell
az login
az account set --subscription "<subscription-id>"
```

Edit `main.bicepparam` before deployment:

- Set `location` and `logAnalyticsWorkspaceName`.
- Set `managedIdentityPrincipalId` to the principal (object) ID of the managed identity that will ingest data, or leave it empty to skip the RBAC assignment.

For a system-assigned identity on an Arc machine or Azure VM, retrieve its principal ID using its full Azure resource ID:

```powershell
az resource show --ids "<arc-machine-or-vm-resource-id>" --query identity.principalId --output tsv
```

For a user-assigned identity, use the identity's principal ID (not its client ID). The same Bicep parameter works regardless of identity type, machine type, or subscription.

Preview and deploy into the resource group containing the workspace:

```powershell
az deployment group what-if --resource-group "<resource-group>" --template-file main.bicep --parameters main.bicepparam
az deployment group create --resource-group "<resource-group>" --template-file main.bicep --parameters main.bicepparam
```

The deployment creates a DCR diagnostic setting that sends the `LogErrors` category to the workspace's `DCRLogErrors` table.

## Windows Installation

Copy `config.json.example` to `config.json` and fill in `DceUri`, `DcrImmutableId`, and `StreamName` from the deployment outputs. Retrieve those values with:

```powershell
$outputs = az deployment group show --resource-group "<resource-group>" --name "<deployment-name>" --query "properties.outputs" --output json | ConvertFrom-Json
$outputs.dataCollectionEndpointUri.value
$outputs.dataCollectionRuleImmutableId.value
$outputs.streamNameOut.value
```

Then run the installer on the target Windows Server. Azure deployment is not run by this script:

```powershell
.\install.ps1 -TaskSchedule DAILY -TaskModifier 1 -NonInteractive
```

Without `-NonInteractive`, the installer prompts for the scheduled task interval. To create the task yourself, select option 4. If a user-assigned identity is used at runtime, optionally pass its client ID with `-ManagedIdentityClientId` or set it in `config.json`.

## Runtime Behavior

The scheduled task starts `locksmith2Report.ps1` on a regular interval.

Each run processes only the newest file matching `SourcePattern` (default: `*-locksmith2.json`) in `SourceDirectory`.

Files in the `archive` directory are explicitly excluded from processing.

Successfully ingested files are moved to `archive`.

## Configuration

Create `config.json` by copying `config.json.example`, then add the DCE and DCR values from your deployment outputs. `install.ps1` validates and uses the existing file.

An example is available in `config.json.example`.

Important fields:

- `DceUri`
- `DcrImmutableId`
- `StreamName`
- `ManagedIdentityClientId` (optional; empty for system-assigned MI)

## Example KQL

```kusto
Locksmith2_CL
| where TimeGenerated > ago(24h)
| summarize count() by Technique
| order by count_ desc
```

### Detect new Issues

```kusto
let Lookback = 8d; // 1D+ than the Locksmith2 Report Generation
let Base = Locksmith2_CL
    | where TimeGenerated > ago(Lookback)
    | extend FindingKey = strcat(Technique, "|", Forest, "|", DistinguishedName, "|", IdentityReference, "|", ActiveDirectoryRights, "|", CAFullName);
// Everything that was already present before the current scan
let Known = Base
    | where TimeGenerated < ago(1d)
    | project FindingKey;
// Only rows from the latest scan that were not previously known
Base
| where TimeGenerated >= ago(1d)
| join kind=leftanti Known on FindingKey
| project TimeGenerated, Technique, Forest, Name, ObjectClass, IdentityReference, ActiveDirectoryRights, CAFullName, Issue, Fix, Revert
```



## AI-Assisted Development
🤖 Locksmith2Sentinel is developed with the assistance of AI. AI is used throughout the development and research process, with human review and validation of the resulting work.

## 👏 Shoutouts & Thanks

A special thanks to these fantastic supporters and Microsoft MVP Fellows:

* **Nicola Suter** ([@nicolonsky](https://github.com/nicolonsky)) – for optimizing and testing the script
* **Jake Hildreth** ([@jakehildreth](https://github.com/jakehildreth)) – for his awesome work on Locksmith2 and for backing my solution
