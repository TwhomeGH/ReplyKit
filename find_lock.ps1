$targetFile = "liveAPPApp.swift"
$processes = Get-Process
foreach ($p in $processes) {
    try {
        $modules = $p.Modules
        foreach ($m in $modules) {
            if ($m.FileName -like "*$targetFile*") {
                Write-Output "$($p.ProcessName) ($($p.Id))"
            }
        }
    } catch {
        # skip
    }
}
Write-Output "Done scanning"
