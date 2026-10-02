param(
    [int]$MemoryMB = 4096,
    [int]$Cpus = 4,
    [switch]$Start
)
$ErrorActionPreference = 'Stop'
$repoPath = Split-Path $PSScriptRoot -Parent
$localPath = Join-Path $repoPath '.local'
$vbox = 'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe'
$vmName = 'mts-devops-ubuntu'
$iso = Join-Path $localPath 'ubuntu-24.04.4-live-server-amd64.iso'
$expectedHash = 'e907d92eeec9df64163a7e454cbc8d7755e8ddc7ed42f99dbc80c40f1a138433'
function Invoke-VBox([string[]]$Arguments) {
    $vboxOutput = & $vbox @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "VBoxManage failed: $($Arguments[0])" }
    if ($Arguments[0] -eq 'unattended') {
        Write-Output 'Unattended installation prepared; credential output suppressed.'
    } else { $vboxOutput | Write-Output }
}
if (!(Test-Path -LiteralPath $vbox)) { throw 'VirtualBox is not installed.' }
if (!(Test-Path -LiteralPath $iso)) { throw "Download Ubuntu Server ISO into $iso (see docs/virtualbox.md)." }
if ((Get-FileHash -LiteralPath $iso -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expectedHash) {
    throw 'ISO checksum mismatch or download incomplete.'
}
$registered = & $vbox list vms
if ($registered -match ('^"' + [regex]::Escape($vmName) + '"')) {
    Write-Output 'VM already exists; configuration and disks are preserved.'
    Invoke-VBox @('showvminfo', $vmName, '--machinereadable')
    exit 0
}
New-Item -ItemType Directory -Force -Path $localPath | Out-Null
$keyPath = Join-Path $localPath 'vm_ed25519'
if (!(Test-Path -LiteralPath $keyPath)) {
    & ssh-keygen -t ed25519 -N '' -C 'mts-devops-local' -f $keyPath | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'SSH key generation failed.' }
}
$publicKey = (Get-Content -LiteralPath ($keyPath + '.pub') -Raw).Trim()
$template = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'ubuntu-autoinstall.yaml.template') -Raw).Replace('@@PUBLIC_KEY@@', $publicKey)
$templatePath = Join-Path $localPath 'autoinstall.template'
[IO.File]::WriteAllText($templatePath, $template, [Text.UTF8Encoding]::new($false))
$passwordPath = Join-Path $localPath 'vm-password.txt'
[IO.File]::WriteAllText($passwordPath, ([guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N')))
$vmsPath = Join-Path $localPath 'vms'
Invoke-VBox @('createvm', '--name', $vmName, '--ostype', 'Ubuntu_64', '--basefolder', $vmsPath, '--register')
Invoke-VBox @('modifyvm', $vmName, '--memory', "$MemoryMB", '--cpus', "$Cpus", '--graphicscontroller', 'vmsvga', '--vram', '16', '--nic1', 'nat', '--natpf1', 'ssh,tcp,127.0.0.1,2222,,22', '--natpf1', 'web,tcp,127.0.0.1,8080,,30080', '--boot1', 'dvd', '--boot2', 'disk')
$disk = Join-Path (Join-Path $vmsPath $vmName) 'ubuntu.vdi'
Invoke-VBox @('createmedium', 'disk', '--filename', $disk, '--size', '30720', '--format', 'VDI')
Invoke-VBox @('storagectl', $vmName, '--name', 'SATA', '--add', 'sata', '--controller', 'IntelAhci')
Invoke-VBox @('storageattach', $vmName, '--storagectl', 'SATA', '--port', '0', '--device', '0', '--type', 'hdd', '--medium', $disk)
Invoke-VBox @('storagectl', $vmName, '--name', 'IDE', '--add', 'ide')
Invoke-VBox @('storageattach', $vmName, '--storagectl', 'IDE', '--port', '0', '--device', '0', '--type', 'dvddrive', '--medium', $iso)
Invoke-VBox @('unattended', 'install', $vmName, "--iso=$iso", '--user=mts', "--user-password-file=$passwordPath", '--hostname=mts-devops.local', '--locale=en_US', '--time-zone=Asia/Irkutsk', '--no-install-additions', "--script-template=$templatePath", '--start-vm=none')
if ($Start) { Invoke-VBox @('startvm', $vmName, '--type', 'headless') }
Write-Output 'VM prepared. Local private key and password are in .local and must not be published.'
