$credPath = "C:\D\XML\credential.xml"
$cred = Import-CliXml $credPath
$username = $cred.UserName
$password = $cred.GetNetworkCredential().Password

$currentpath = "$(Get-Location)\tables\"
$otherFiles = Get-ChildItem -Path $currentpath -Filter "*.sql"

foreach ($file in $otherFiles) {
    Write-Host "Executing $($file.Name)"

    try {
        $sqlcmdOutput = & sqlcmd /S 124.123.64.36\SQLEXPRMG -U $username -P $password -b /d LIS_DEVTEST_RMG -I -i $file.FullName -b 2>&1

        if ($LASTEXITCODE -eq 0) {
            Write-Host "$($file.Name) Executed Successfully"
        } else {
            Write-Host "Error occurred while executing $($file.Name):"
            Write-Host $sqlcmdOutput
        }
    } catch {
        Write-Error "Error: $_"
    } finally {
        $ErrorActionPreference = 'Continue'
    }
}