[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ConfirmToken,
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$SshAlias
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if($ConfirmToken -cne 'I_APPROVE_POINT_CLEAN_COMPLETED_MAIND_HTTP_ARTIFACTS'){
    throw 'Exact completed-artifact cleanup token required.'
}
$backupScript=Join-Path $PSScriptRoot 'backup_maind_http_temp_artifacts.ps1'
$backupOutput=& $backupScript -SshAlias $SshAlias
$backupText=($backupOutput|Out-String)
if($backupText -notmatch '(?m)^DIAGNOSTICS_BACKUP=PASS$'){
    throw 'Fresh checksum-verified backup did not complete; refusing cleanup.'
}
$ssh=Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
$remote=@'
set -eu
base=/tmp/maind-http-test
helper=/tmp/maind_http_runtime_test_remote.sh
patchdir=/data/quasar/quasar_patches
ps | grep -q '[m]aind --platformd'
! ( (ss -lnt 2>/dev/null || netstat -lnt 2>/dev/null || cat /proc/net/tcp) | grep -q ':223D' )
! iptables -S INPUT 2>/dev/null | grep -q '8765'
! ip6tables -S INPUT 2>/dev/null | grep -q '8765'
! grep -q 'quasar_patches' /proc/self/mountinfo
! ps | grep -E '[m]aind_http_runtime_test_remote.sh (watchdog|rollback)'
test ! -e "$patchdir/quasar.cfg.platformd.patch"
test -d "$base"
test ! -L "$base"
test "$(readlink -f "$base")" = "$base"
test -f "$base/completed"
test -f "$base/light.restore.verified"
test ! -e "$base/light.restore.armed"
test ! -e "$base/LIGHT_STATE_MAY_BE_CHANGED"
test -f "$helper"
test ! -L "$helper"
test "$(readlink -f "$helper")" = "$helper"
rm -f "$helper"
rm -rf "$base"
test ! -e "$helper"
test ! -e "$base"
if [ -d "$patchdir" ] && [ -z "$(ls -A "$patchdir")" ]; then rmdir "$patchdir"; fi
printf 'POINT_CLEANUP=PASS\n'
'@
$output=& $ssh -T -o BatchMode=yes -o ConnectTimeout=10 $SshAlias $remote
if($LASTEXITCODE-ne0-or$output -notcontains 'POINT_CLEANUP=PASS'){
    throw 'Remote point cleanup failed; inspect the fresh backup before any manual action.'
}
$backupOutput
$output
