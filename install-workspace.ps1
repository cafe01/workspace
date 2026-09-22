param(
  [string]$Release,
  [ValidateSet('','download','extraction','pre-activation','pointer-switch','post-activation-probe')]
  [string]$WorkspaceInstallFault = ''
)
$ErrorActionPreference = 'Stop'
function Receive-ReleaseFile([string]$Url, [string]$OutFile) {
  if ($env:WORKSPACE_TEST_CA_CERTIFICATE) {
    if (-not (Test-Path -LiteralPath $env:WORKSPACE_TEST_CA_CERTIFICATE -PathType Leaf)) {
      throw 'WORKSPACE_TEST_CA_CERTIFICATE does not name a certificate file'
    }
    & curl.exe --fail --silent --show-error --cacert $env:WORKSPACE_TEST_CA_CERTIFICATE --output $OutFile $Url
    if ($LASTEXITCODE -ne 0) { throw "test HTTPS download failed for $Url" }
    return
  }
  Invoke-WebRequest -UseBasicParsing $Url -OutFile $OutFile
}
# Inspect before running. This bootstrap never requests administrator access.
$origin = if ($env:WORKSPACE_PUBLIC_ORIGIN) { $env:WORKSPACE_PUBLIC_ORIGIN.TrimEnd('/') } else { 'https://cafe01.github.io/workspace' }
function Fail([string]$Message, [int]$Code = 1) { [Console]::Error.WriteLine("workspace install: $Message"); exit $Code }
function Assert-Properties($Object, [string[]]$Required, [string[]]$Optional = @()) {
  if ($null -eq $Object) { throw 'required object is absent' }
  $names = @($Object.PSObject.Properties.Name)
  foreach ($name in $Required) { if ($names -notcontains $name) { throw "missing field $name" } }
  foreach ($name in $names) { if (($Required + $Optional) -notcontains $name) { throw "unknown field $name" } }
}
function Assert-String($Value, [string]$Name) { if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) { throw "invalid $Name" } }
function Assert-Digest($Value, [string]$Name) { if ($Value -isnot [string] -or $Value -notmatch '^[0-9a-f]{64}$') { throw "invalid $Name" } }
function Assert-ImmutableUrl($Value, [string]$ReleaseId, [string]$Name) {
  Assert-String $Value $Name
  $uri = [Uri]$Value
  if ($uri.Scheme -ne 'https' -or -not $uri.Host -or $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -match '/latest/' -or $uri.AbsolutePath -notmatch [regex]::Escape($ReleaseId)) { throw "mutable or invalid $Name" }
}
function Get-Sha256([string]$Path) {
  $stream = [System.IO.File]::OpenRead($Path)
  $hasher = [System.Security.Cryptography.SHA256]::Create()
  try {
    return ([System.BitConverter]::ToString($hasher.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
  } finally {
    $hasher.Dispose()
    $stream.Dispose()
  }
}
function Assert-WorkspaceCatalog($Catalog, [string]$Requested) {
  Assert-Properties $Catalog @('schema','product','current_release_id','updated_at','releases')
  if ($Catalog.schema -ne 'product.delivery/release-catalog/v1') { throw 'unsupported catalog schema' }
  Assert-Properties $Catalog.product @('product_id','display_name','channel','public_url','support_url')
  if ($Catalog.product.product_id -ne 'workspace' -or $Catalog.product.display_name -ne 'Workspace' -or $Catalog.product.channel -ne 'preview') { throw 'catalog does not describe Workspace preview' }
  foreach ($url in @($Catalog.product.public_url,$Catalog.product.support_url)) { if (([Uri]$url).Scheme -ne 'https') { throw 'invalid product URL' } }
  $ids = @{}; $current = @()
  foreach ($entry in @($Catalog.releases)) {
    Assert-Properties $entry @('release_id','version','status','release_url','descriptor_url','descriptor_sha256','status_changed_at') @('withdrawal_reason')
    Assert-String $entry.release_id 'release_id'; Assert-String $entry.version 'version'; Assert-Digest $entry.descriptor_sha256 'descriptor_sha256'
    if ($ids.ContainsKey($entry.release_id)) { throw 'duplicate release id' }; $ids[$entry.release_id] = $true
    Assert-ImmutableUrl $entry.release_url $entry.release_id 'release_url'; Assert-ImmutableUrl $entry.descriptor_url $entry.release_id 'descriptor_url'
    if (@('current','superseded','withdrawn') -notcontains $entry.status) { throw 'invalid release status' }
    if ($entry.status -eq 'withdrawn') { Assert-String $entry.withdrawal_reason 'withdrawal_reason' } elseif ($entry.PSObject.Properties.Name -contains 'withdrawal_reason') { throw 'non-withdrawn release carries withdrawal reason' }
    if ($entry.status -eq 'current') { $current += $entry }
  }
  if ($null -eq $Catalog.current_release_id) { if ($current.Count -ne 0) { throw 'null current release disagrees with status' } }
  elseif ($current.Count -ne 1 -or $current[0].release_id -ne $Catalog.current_release_id) { throw 'current release disagrees with status' }
  $selectedId = if ($Requested) { $Requested } else { $Catalog.current_release_id }
  if (-not $selectedId) { throw 'no current Workspace release is available; check the public product page or support guidance' }
  $selected = @($Catalog.releases | Where-Object { $_.release_id -eq $selectedId })
  if ($selected.Count -ne 1 -or $selected[0].status -eq 'withdrawn') { throw "release $selectedId is absent, ambiguous, or withdrawn" }
  return $selected[0]
}
function Assert-WorkspaceDescriptor($Descriptor, $Entry) {
  Assert-Properties $Descriptor @('schema','product_id','display_name','channel','release_id','version','source_revision','created_at','release_url','evidence','artifacts')
  if ($Descriptor.schema -ne 'product.delivery/product-release/v1' -or $Descriptor.product_id -ne 'workspace' -or $Descriptor.display_name -ne 'Workspace' -or $Descriptor.channel -ne 'preview') { throw 'descriptor does not describe Workspace preview' }
  if ($Descriptor.release_id -ne $Entry.release_id -or $Descriptor.version -ne $Entry.version -or $Descriptor.release_url -ne $Entry.release_url -or $Descriptor.source_revision -notmatch '^[0-9a-f]{40}$') { throw 'descriptor identity disagrees with catalog' }
  Assert-ImmutableUrl $Descriptor.release_url $Descriptor.release_id 'release_url'
  Assert-Properties $Descriptor.evidence @('url','sha256'); Assert-ImmutableUrl $Descriptor.evidence.url $Descriptor.release_id 'evidence.url'; Assert-Digest $Descriptor.evidence.sha256 'evidence.sha256'
  $ids = @{}; $targets = @{}
  foreach ($artifact in @($Descriptor.artifacts)) {
    Assert-Properties $artifact @('artifact_id','platform','architecture','system_requirements','filename','url','sha256','size_bytes','archive_format','content_manifest_sha256','application_layout','runtime_compatibility_id')
    foreach ($name in @('artifact_id','platform','architecture','system_requirements','filename','archive_format','application_layout','runtime_compatibility_id')) { Assert-String $artifact.$name $name }
    Assert-Digest $artifact.sha256 'artifact.sha256'; Assert-Digest $artifact.content_manifest_sha256 'content_manifest_sha256'
    if ($artifact.size_bytes -isnot [long] -and $artifact.size_bytes -isnot [int]) { throw 'invalid artifact size' }; if ($artifact.size_bytes -lt 1) { throw 'invalid artifact size' }
    $target = "$($artifact.platform)-$($artifact.architecture)"
    if ($ids.ContainsKey($artifact.artifact_id) -or $targets.ContainsKey($target)) { throw 'duplicate artifact id or target' }; $ids[$artifact.artifact_id]=$true; $targets[$target]=$true
    if ([IO.Path]::GetFileName($artifact.filename) -ne $artifact.filename -or $artifact.filename -notmatch [regex]::Escape($Descriptor.release_id) -or $artifact.filename -notmatch [regex]::Escape($target)) { throw 'artifact filename is not identity bound' }
    Assert-ImmutableUrl $artifact.url $Descriptor.release_id 'artifact.url'; if (([Uri]$artifact.url).Segments[-1] -ne $artifact.filename) { throw 'artifact URL does not match filename' }
    if (($artifact.platform -eq 'windows') -ne ($artifact.archive_format -eq 'zip')) { throw 'artifact format disagrees with platform' }
    if ($artifact.application_layout -ne 'workspace/application-v1') { throw 'unsupported application layout' }
  }
  $selected = @($Descriptor.artifacts | Where-Object { $_.platform -eq 'windows' -and $_.architecture -eq 'x64' })
  if ($selected.Count -ne 1 -or $selected[0].archive_format -ne 'zip') { throw 'release has no unique Windows x64 zip artifact' }
  return $selected[0]
}

if (-not [Environment]::Is64BitOperatingSystem) { Fail 'unsupported platform (Windows x64 is required)' 2 }
if (-not $env:LOCALAPPDATA) { Fail 'LOCALAPPDATA must name a user-owned path' 2 }
$appHome = Join-Path $env:LOCALAPPDATA 'Workspace\application'
$releases = Join-Path $appHome 'releases'; $pointer = Join-Path $appHome 'active-release'; $previous = Join-Path $appHome 'previous-release'; $shimDir = Join-Path $env:LOCALAPPDATA 'Workspace\bin'; $shim = Join-Path $shimDir 'workspace.cmd'
New-Item -ItemType Directory -Force -Path $releases, $shimDir | Out-Null
$temp = Join-Path (Split-Path $appHome) ('.workspace-download-' + [guid]::NewGuid()); New-Item -ItemType Directory -Path $temp | Out-Null
$stage = $null
try {
  $catalogPath = Join-Path $temp 'catalog.json'; Receive-ReleaseFile "$origin/releases/catalog.json" $catalogPath
  try { $catalog = Get-Content -Raw $catalogPath | ConvertFrom-Json } catch { Fail "public release catalog is not canonical JSON: $_" }
  try { $entry = Assert-WorkspaceCatalog $catalog $Release } catch { Fail "public release catalog failed closed validation: $_" }
  $Release = $entry.release_id
  $descriptorPath = Join-Path $temp 'product-release.json'; Receive-ReleaseFile $entry.descriptor_url $descriptorPath
  if ((Get-Sha256 $descriptorPath) -ne $entry.descriptor_sha256) { Fail 'release descriptor SHA-256 verification failed' }
  try { $descriptor = Get-Content -Raw $descriptorPath | ConvertFrom-Json; $artifact = Assert-WorkspaceDescriptor $descriptor $entry } catch { Fail "release descriptor failed closed validation: $_" }
  $archive = Join-Path $temp $artifact.filename; Receive-ReleaseFile $artifact.url $archive
  if ($WorkspaceInstallFault -eq 'download') { Fail 'injected update fault at download' }
  if ((Get-Item -LiteralPath $archive).Length -ne $artifact.size_bytes) { Fail 'archive size verification failed; keep the previous host and retry' }
  if ((Get-Sha256 $archive) -ne $artifact.sha256) { Fail 'archive SHA-256 verification failed; keep the previous host and retry' }

  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zip = [IO.Compression.ZipFile]::OpenRead($archive)
  try {
    foreach ($zipEntry in $zip.Entries) {
      $name = $zipEntry.FullName.Replace('\','/')
      if ($name.StartsWith('/') -or $name -match '(^|/)\.\.($|/)' -or -not $name.StartsWith('workspace/application-v1/')) { Fail 'archive contains an unsafe or unexpected path' }
    }
  } finally { $zip.Dispose() }
  $stage = Join-Path $releases ('.stage-' + $Release + '-' + [guid]::NewGuid()); Expand-Archive -LiteralPath $archive -DestinationPath $stage
  if ($WorkspaceInstallFault -eq 'extraction') { Fail 'injected update fault at extraction' }
  $applicationHost = Join-Path $stage 'workspace\application-v1'; $exe = Join-Path $applicationHost 'cli\bundle\bin\workspace.exe'; $manifestPath = Join-Path $applicationHost 'content-manifest.json'
  if (-not (Test-Path -LiteralPath $exe -PathType Leaf) -or -not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { Fail 'archive layout verification failed' }
  $applicationHost = (Resolve-Path -LiteralPath $applicationHost).ProviderPath
  $manifestPath = (Resolve-Path -LiteralPath $manifestPath).ProviderPath
  $exe = (Resolve-Path -LiteralPath $exe).ProviderPath
  if (Get-ChildItem -LiteralPath $applicationHost -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }) { Fail 'archive layout contains a link or reparse point' }
  if ((Get-Sha256 $manifestPath) -ne $artifact.content_manifest_sha256) { Fail 'content manifest SHA-256 verification failed' }
  try {
    $manifest = Get-Content -Raw $manifestPath | ConvertFrom-Json
    Assert-Properties $manifest @('schema','application_layout','identity','files')
    if ($manifest.schema -ne 'workspace.application-content/v1' -or $manifest.application_layout -ne 'workspace/application-v1') { throw 'invalid manifest schema or layout' }
    Assert-Properties $manifest.identity @('product_id','version','release_id','source_revision','platform','architecture','runtime_compatibility_id')
    $expectedIdentity = @{ product_id='workspace'; version=$descriptor.version; release_id=$descriptor.release_id; source_revision=$descriptor.source_revision; platform='windows'; architecture='x64'; runtime_compatibility_id=$artifact.runtime_compatibility_id }
    foreach ($name in $expectedIdentity.Keys) { if ($manifest.identity.$name -ne $expectedIdentity[$name]) { throw "manifest identity mismatch: $name" } }
    $manifestPaths = @(); $seen = @{}
    foreach ($file in @($manifest.files)) {
      Assert-Properties $file @('path','sha256','size_bytes'); Assert-String $file.path 'manifest path'; Assert-Digest $file.sha256 'manifest digest'
      if ($file.path.StartsWith('/') -or $file.path -match '(^|/)\.\.($|/)' -or $seen.ContainsKey($file.path)) { throw 'unsafe or duplicate manifest path' }; $seen[$file.path]=$true
      $item = Join-Path $applicationHost ($file.path.Replace('/','\')); if (-not (Test-Path -LiteralPath $item -PathType Leaf)) { throw "manifest file is missing: $($file.path)" }
      if ((Get-Item -LiteralPath $item).Length -ne $file.size_bytes -or (Get-Sha256 $item) -ne $file.sha256) { throw "manifest verification failed: $($file.path)" }
      $manifestPaths += $file.path
    }
    if ($manifestPaths -notcontains 'cli/bundle/bin/workspace.exe') { throw 'manifest omits executable' }
    $hostPrefix = $applicationHost.TrimEnd('\') + '\'
    $actualPaths = @(Get-ChildItem -LiteralPath $applicationHost -Recurse -File -Force | ForEach-Object {
      $fullPath = (Resolve-Path -LiteralPath $_.FullName).ProviderPath
      if ($fullPath -eq $manifestPath) { return }
      if (-not $fullPath.StartsWith($hostPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'archive file escaped application host' }
      $fullPath.Substring($hostPrefix.Length).Replace('\','/')
    } | Sort-Object)
    $difference = @(Compare-Object ($manifestPaths | Sort-Object) $actualPaths)
    if ($difference.Count -ne 0) { throw "archive contains files outside the content manifest (expected=$($manifestPaths.Count), observed=$($actualPaths.Count), difference=$($difference.Count))" }
    $version = & $exe --json --version | ConvertFrom-Json; if ($LASTEXITCODE -ne 0) { throw 'staged version probe failed' }
    Assert-Properties $version @('schema_version','result'); Assert-Properties $version.result @('product_id','version','release_id','source_revision','platform','architecture','runtime_compatibility_id')
    if ($version.schema_version -ne 1) { throw 'staged version schema mismatch' }
    foreach ($name in $expectedIdentity.Keys) { if ($version.result.$name -ne $expectedIdentity[$name]) { throw "staged identity mismatch: $name" } }
  } catch { Fail "pre-activation layout or identity verification failed: $_" }

  $receipt = Join-Path $temp 'activation-receipt.json'
  @{ schema='workspace.application-activation/v1'; product_id='workspace'; version=$descriptor.version; release_id=$Release; source_revision=$descriptor.source_revision; platform='windows'; architecture='x64'; runtime_compatibility_id=$artifact.runtime_compatibility_id; archive_sha256=$artifact.sha256 } | ConvertTo-Json -Compress | Set-Content -NoNewline -Path $receipt
  $old = if (Test-Path -LiteralPath $pointer) { Get-Content -Raw $pointer } else { '' }; $oldPrevious = if (Test-Path -LiteralPath $previous) { Get-Content -Raw $previous } else { '' }
  $final = Join-Path $releases $Release
  if (Test-Path -LiteralPath $final) {
    if ($old.Trim() -ne $Release -or -not (Test-Path -LiteralPath (Join-Path $final 'activation-receipt.json')) -or -not (Compare-Object (Get-Content -Raw $receipt) (Get-Content -Raw (Join-Path $final 'activation-receipt.json')))) { Fail "release $Release is already present but not safely reusable" }
    Write-Output "Workspace release $Release is already active and verified."; exit 0
  }
  if ($WorkspaceInstallFault -eq 'pre-activation') { Fail 'injected update fault at pre-activation' }
  Move-Item -LiteralPath $applicationHost -Destination $final; Move-Item -LiteralPath $receipt -Destination (Join-Path $final 'activation-receipt.json'); Remove-Item -Recurse -Force $stage; $stage=$null
  if (Test-Path -LiteralPath $shim) { if (-not (Select-String -Quiet -Path $shim -Pattern 'workspace active-release shim')) { Fail "Refusing to replace unrelated command at $shim" } }
  Set-Content -NoNewline -Path $shim -Value "@echo off`r`nREM workspace active-release shim`r`nset /p id=<`"%LOCALAPPDATA%\Workspace\application\active-release`"`r`n`"%LOCALAPPDATA%\Workspace\application\releases\%id%\cli\bundle\bin\workspace.exe`" %*"
  function Restore-Pointers {
    if ($old) { Set-Content -NoNewline -Path "$pointer.restore" -Value $old; Move-Item -Force "$pointer.restore" $pointer } elseif (Test-Path $pointer) { Remove-Item -Force $pointer }
    if ($oldPrevious) { Set-Content -NoNewline -Path "$previous.restore" -Value $oldPrevious; Move-Item -Force "$previous.restore" $previous } elseif (Test-Path $previous) { Remove-Item -Force $previous }
  }
  if ($old) { Set-Content -NoNewline -Path "$previous.new" -Value $old; Move-Item -Force "$previous.new" $previous } elseif (Test-Path $previous) { Remove-Item -Force $previous }
  if ($WorkspaceInstallFault -eq 'pointer-switch') { Restore-Pointers; Fail 'injected update fault at pointer-switch' }
  Set-Content -NoNewline -Path "$pointer.new" -Value $Release; Move-Item -Force "$pointer.new" $pointer
  $activeExe = Join-Path $final 'cli\bundle\bin\workspace.exe'; if ($WorkspaceInstallFault -eq 'post-activation-probe') { Restore-Pointers; Fail 'injected update fault at post-activation-probe' }; & $activeExe --json --version | Out-Null; if ($LASTEXITCODE -ne 0) { Restore-Pointers; Fail 'activation probe failed; prior host remains active' }
  Write-Output "Installed Workspace host $Release at $final. No administrator access was requested."; Write-Output 'Host placement is incomplete: run workspace provision, then workspace provision --check.'
} finally {
  if ($stage -and (Test-Path -LiteralPath $stage)) { Remove-Item -Recurse -Force $stage }
  if (Test-Path -LiteralPath $temp) { Remove-Item -Recurse -Force $temp }
}
