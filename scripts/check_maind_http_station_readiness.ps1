[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$SshAlias,
    [string]$OutputPath
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path -Parent (Split-Path -Parent $PSCommandPath)
if([string]::IsNullOrWhiteSpace($OutputPath)){
    $OutputPath=Join-Path $root ('results\diagnostics\station-readiness-'+(Get-Date -Format yyyyMMdd-HHmmss)+'.json')
}
$remote=@'
set -u
expected_maind=7ff114e08d46d48394f9d794f89dc941f3b217bdcd3ff1ef46f1cd80fada6ec1
expected_launcher=e7af45d49ea9626c7bfc1d72c648663c82e024a8c9d538b0aa6f8317288f5054
port_hex=223D
emit() { printf '%s=%s\n' "$1" "$2"; }
exists() { if [ -e "$1" ]; then echo present; else echo absent; fi; }
listener_rows=$(awk -v p=":$port_hex" 'NR > 1 && substr($2,length($2)-4)==p {print FILENAME ":" $0}' /proc/net/tcp /proc/net/tcp6 2>/dev/null || true)
platform_rows=""
for p in /proc/[0-9]*; do
    [ -r "$p/cmdline" ] || continue
    c=$(tr '\000' ' ' < "$p/cmdline" 2>/dev/null || true)
    [ "$c" = "/system/vendor/quasar/maind --platformd " ] && platform_rows="$platform_rows ${p##*/}"
done
workers=""
for p in /proc/[0-9]*; do
    [ -r "$p/cmdline" ] || continue
    c=$(tr '\000' ' ' < "$p/cmdline" 2>/dev/null || true)
    case "$c" in *maind_http_runtime_test_remote*.sh\ watchdog*|*maind_http_runtime_test_remote*.sh\ rollback*) workers="$workers ${p##*/}:$c";; esac
done
guard4=no; iptables -C INPUT ! -i lo -p tcp --dport 8765 -j REJECT --reject-with tcp-reset >/dev/null 2>&1 && guard4=yes
guard6=no; ip6tables -C INPUT ! -i lo -p tcp --dport 8765 -j REJECT --reject-with tcp-reset >/dev/null 2>&1 && guard6=yes
patch_mount=no
awk '$5=="/data/quasar/quasar_patches" || $5=="/bkupgrade/data/quasar/quasar_patches" {found=1} END{exit !found}' /proc/self/mountinfo 2>/dev/null && patch_mount=yes
unresolved=""
if [ -d /tmp/maind-http-runs ]; then
    for d in /tmp/maind-http-runs/*; do
        [ -d "$d" ] || continue
        rid=$(cat "$d/run_id" 2>/dev/null || true)
        done_id=$(cat "$d/completed" 2>/dev/null || true)
        [ -n "$rid" ] && [ "$done_id" = "$rid" ] || unresolved="$unresolved $d"
    done
fi
missing=""
for x in awk cat date flock grep head id ip iptables ip6tables iptables-save ip6tables-save kill mkdir mount nohup ps readlink rmdir sed setsid sha256sum sleep tr umount wc; do
    command -v "$x" >/dev/null 2>&1 || missing="$missing $x"
done
[ -x /usr/bin/wget ] || missing="$missing /usr/bin/wget"
maind_hash=$(sha256sum /system/vendor/quasar/maind 2>/dev/null | awk '{print $1}')
launcher_hash=$(sha256sum /system/vendor/quasar/quasar_launcher2 2>/dev/null | awk '{print $1}')
emit timestamp_utc "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
emit platformd_pids "${platform_rows# }"
emit tcp_8765 "$([ -n "$listener_rows" ] && echo present || echo absent)"
emit listener_rows "$listener_rows"
emit guard_ipv4 "$guard4"
emit guard_ipv6 "$guard6"
emit patch_mount "$patch_mount"
emit patch_path "$(exists /data/quasar/quasar_patches)"
emit legacy_http_test "$(exists /tmp/maind-http-test)"
emit legacy_read_verify "$(exists /tmp/maind-http-read-verify)"
emit global_lock "$(exists /tmp/maind-http-runtime.lock)"
emit lock_run_id "$(cat /tmp/maind-http-runtime.lock/run_id 2>/dev/null || true)"
emit lock_owner_pid "$(cat /tmp/maind-http-runtime.lock/owner.pid 2>/dev/null || true)"
emit experiment_workers "${workers# }"
emit unresolved_runs "${unresolved# }"
emit missing_utilities "${missing# }"
emit maind_hash "$maind_hash"
emit maind_hash_matches "$([ "$maind_hash" = "$expected_maind" ] && echo yes || echo no)"
emit launcher_hash "$launcher_hash"
emit launcher_hash_matches "$([ "$launcher_hash" = "$expected_launcher" ] && echo yes || echo no)"
emit mem_available_kb "$(awk '/MemAvailable:/{print $2}' /proc/meminfo)"
emit lamp_neighbor "not_collected"
'@
# This command is deliberately data-only. It does not stage a helper and does
# not contain service, firewall, mount, file-removal, or file-creation actions.
$forbidden=@(
    '(?m)^\s*(rm|mkdir|rmdir|mount|umount|kill|reboot|poweroff)\b',
    '(?m)^\s*(iptables|ip6tables)\s+-(I|A|D|R|F|X|P|N)\b'
)
foreach($pattern in $forbidden){if($remote-match$pattern){throw "Read-only contract rejected remote script: $pattern"}}
$ssh=Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
$psi=[Diagnostics.ProcessStartInfo]::new()
$psi.FileName=$ssh
foreach($arg in @('-o','BatchMode=yes','-o','ConnectTimeout=10',$SshAlias,'sh -s')){[void]$psi.ArgumentList.Add($arg)}
$psi.UseShellExecute=$false;$psi.RedirectStandardInput=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
$process=[Diagnostics.Process]::new();$process.StartInfo=$psi
if(-not$process.Start()){throw 'Could not start SSH readiness process'}
$bytes=[Text.UTF8Encoding]::new($false).GetBytes($remote)
$process.StandardInput.BaseStream.Write($bytes,0,$bytes.Length);$process.StandardInput.BaseStream.Close()
$stdout=$process.StandardOutput.ReadToEnd();$stderr=$process.StandardError.ReadToEnd();$process.WaitForExit()
if($process.ExitCode-ne0){throw "Read-only station readiness failed exit=$($process.ExitCode): $stderr"}
$values=[ordered]@{}
foreach($line in @($stdout-split"\r?\n")){
    if($line-match'^([^=]+)=(.*)$'){$values[$matches[1]]=$matches[2]}
}
$reasons=[Collections.Generic.List[string]]::new()
if(@($values.platformd_pids-split' '|Where-Object{$_}).Count-ne1){$reasons.Add('platformd_identity')}
foreach($name in @('tcp_8765','guard_ipv4','guard_ipv6','patch_mount','global_lock')){if($values[$name]-notin@('absent','no')){$reasons.Add($name)}}
foreach($name in @('legacy_http_test','legacy_read_verify')){if($values[$name]-ne'absent'){$reasons.Add($name)}}
foreach($name in @('experiment_workers','unresolved_runs','missing_utilities')){if(-not[string]::IsNullOrWhiteSpace($values[$name])){$reasons.Add($name)}}
if($values.maind_hash_matches-ne'yes'){$reasons.Add('maind_hash')}
if($values.launcher_hash_matches-ne'yes'){$reasons.Add('launcher_hash')}
$result=[ordered]@{
    generated_utc=[DateTime]::UtcNow.ToString('o'); mode='read_only'; station=$SshAlias
    ready=($reasons.Count-eq0); blocking_reasons=@($reasons); values=$values
    ssh_exit_code=$process.ExitCode; stderr=$stderr.Trim(); remote_script_sha256=''
}
$sha=[Security.Cryptography.SHA256]::Create()
$result.remote_script_sha256=[Convert]::ToHexString($sha.ComputeHash($bytes)).ToLowerInvariant()
$parent=Split-Path -Parent $OutputPath;if($parent){New-Item -ItemType Directory -Force $parent|Out-Null}
$result|ConvertTo-Json -Depth 6|Set-Content -Encoding utf8NoBOM $OutputPath
$result|ConvertTo-Json -Depth 6
