
# Define the list of snapshot & disk names to check
$snapshotNames = @(
"do_not_delete_kenemvda10p-snap-v5.1-29012026-5.0-and-install_fp",
"cat-ken-em-app-datastage-basedisk-mr60x"
)

$diskNames = @(
"nag01_disk0",
"kenemnag01p-datadisk-01"
)

# Set the time range for Activity Log lookup (last 90 days)
$end   = Get-Date
$start = $end.AddDays(-90)

# A single list of "targets" with Resource Type + Name
$targets = @()
$targets += $snapshotNames | ForEach-Object { [PSCustomObject]@{ Type="Snapshot"; Name=$_ } }
$targets += $diskNames     | ForEach-Object { [PSCustomObject]@{ Type="Disk";     Name=$_ } }

# Function to get createdBy from systemData of the resource.
function Get-CreatedByFromSystemData {
  param([Parameter(Mandatory)] [string] $ResourceId)

  $arm = Get-AzResource -ResourceId $ResourceId -ExpandProperties -ErrorAction SilentlyContinue
  if ($arm -and $arm.SystemData -and $arm.SystemData.CreatedBy) {
    return $arm.SystemData.CreatedBy
  }
  return $null
}

# Function to get createdBy from Activity Log.
function Get-CreatedByFromActivityLog {
  param(
    [Parameter(Mandatory)] [string]   $ResourceId,
    [Parameter(Mandatory)] [string[]] $ActionPrefixes,  # e.g. "Microsoft.Compute/disks/write"
    [Parameter(Mandatory)] [datetime] $StartTime,
    [Parameter(Mandatory)] [datetime] $EndTime
  )
    $logs = Get-AzLog -ResourceId $ResourceId -StartTime $StartTime -EndTime $EndTime -MaxRecord 2000 -ErrorAction SilentlyContinue
    
$evt = $logs |
    Where-Object {
      foreach ($p in $ActionPrefixes) {
        if ($_.Authorization.Action -like "$p*") { return $true }
        if ($_.OperationName.Value    -like "$p*") { return $true }
        if ($_.OperationName          -like "$p*") { return $true }
      }
      return $false
    } |
    Sort-Object EventTimestamp |
    Select-Object -First 1

  if ($evt -and $evt.Caller) { return $evt.Caller }
  return $null
}

# Initialize results array
# We will collect results in this array and then output at the end. This allows us to handle missing snapshots more easily.
$results = foreach ($sub in Get-AzSubscription) {
    # Switch to the subscription context to ensure we are querying the correct resources and logs
    # This is important because Get-AzResource and Get-AzLog will only return data for the current subscription context.
    Set-AzContext -SubscriptionId $sub.Id | Out-Null

    # Get all snapshots and disks in the current subscription. We will use these lists to find the target snapshots/disks by name. This is more efficient than calling Get-AzResource for each target, especially if we have many targets.
    $snapIndex = @{}
    foreach ($s in (Get-AzSnapshot -ErrorAction SilentlyContinue)) { $snapIndex[$s.Name] = $s }
    $diskIndex = @{}
    foreach ($d in (Get-AzDisk -ErrorAction SilentlyContinue)) { $diskIndex[$d.Name] = $d }


    
foreach ($t in $targets) {

    $resource = $null
    $resourceType = $t.Type

    if ($resourceType -eq "Snapshot") {
      if ($snapIndex.ContainsKey($t.Name)) { $resource = $snapIndex[$t.Name] }
    }
    elseif ($resourceType -eq "Disk") {
      if ($diskIndex.ContainsKey($t.Name)) { $resource = $diskIndex[$t.Name] }
    }

    if (-not $resource) { continue }

    # 1) BEST SOURCE: systemData.createdBy
    $createdBy = Get-CreatedByFromSystemData -ResourceId $resource.Id

    # 2) FALLBACK: Activity log (last 90 days) [1](https://docs.azure.cn/en-us/azure-monitor/platform/activity-log)
    if (-not $createdBy) {
      $actionPrefixes =
        if ($resourceType -eq "Snapshot") { @("Microsoft.Compute/snapshots/write") }
        else                              { @("Microsoft.Compute/disks/write") } # Create or Update Disk action [2](https://rbac-catalog.dev/operations/Microsoft.Compute/disks/write)

      $createdBy = Get-CreatedByFromActivityLog -ResourceId $resource.Id -ActionPrefixes $actionPrefixes -StartTime $start -EndTime $end
    }

    if (-not $createdBy) {
      $createdBy = "Unknown (no systemData + no matching activity log event/Caller)"
    }

    # Normalize time created field name (snapshots & disks both usually have TimeCreated)
    $timeCreated = $null
    if ($resource.PSObject.Properties.Name -contains "TimeCreated") { $timeCreated = $resource.TimeCreated }

    [PSCustomObject]@{
      Subscription   = $sub.Name
      ResourceType   = $resourceType
      Name           = $resource.Name
      ResourceGroup  = $resource.ResourceGroupName
      TimeCreated    = $timeCreated
      CreatedBy      = $createdBy
      ResourceId     = $resource.Id
    }
  }
}

# =========================
# MARK ITEMS NOT FOUND
# =========================
$foundKeys = $results | ForEach-Object { "$($_.ResourceType)|$($_.Name)" } | Select-Object -Unique
$missing = $targets |
  Where-Object { ("$($_.Type)|$($_.Name)") -notin $foundKeys } |
  ForEach-Object {
    [PSCustomObject]@{
      Subscription   = "-"
      ResourceType   = $_.Type
      Name           = $_.Name
      ResourceGroup  = "-"
      TimeCreated    = $null
      CreatedBy      = "Not Found (in accessible subscriptions)"
      ResourceId     = "-"
    }
  }

($results + $missing) | Sort-Object ResourceType, Name, Subscription | Format-Table -AutoSize
