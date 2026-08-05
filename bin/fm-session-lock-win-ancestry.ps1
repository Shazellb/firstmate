# fm-session-lock-win-ancestry.ps1 - print the Win32 ancestry of -StartPid, one
# process per line, as pid<TAB>ppid<TAB>image<TAB>commandline, up to 16 hops,
# stopping at pid 0/1 or the first unresolvable pid.
#
# A dedicated .ps1 file, not an inline `powershell.exe -Command "..."` string:
# the loop body needs both single- and double-quoted PowerShell literals plus
# `$`-prefixed variables, and bin/fm-session-lock-lib.sh's caller is itself
# reached through nested `bash -c '...'` wrapping (the harness's own hook/tool
# invocation layer) - escaping all three quoting layers correctly at once is
# fragile and was empirically observed to silently truncate the walk to one
# hop with no error. A script file sidesteps the whole problem: PowerShell
# reads its own quoting untouched, and bash only ever passes one plain integer
# argument across the boundary.
#
# Called only from fm_harness_win_ancestry_chain (bin/fm-session-lock-lib.sh),
# which is itself called only when fm_harness_platform_is_windows is true.
param([long]$StartPid)

$p = $StartPid
for ($i = 0; $i -lt 16; $i++) {
  $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$p" -ErrorAction SilentlyContinue
  if (-not $proc) { break }
  $image = $proc.ExecutablePath
  if (-not $image) { $image = $proc.Name }
  $line = $proc.CommandLine
  if (-not $line) { $line = "" }
  $img = $image -replace "[\r\n\t]", " "
  $ln = $line -replace "[\r\n\t]", " "
  Write-Output ("{0}`t{1}`t{2}`t{3}" -f $proc.ProcessId, $proc.ParentProcessId, $img, $ln)
  $p = $proc.ParentProcessId
  if ($p -le 1) { break }
}
