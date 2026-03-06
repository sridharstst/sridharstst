$file1 = Read-Host "Enter the path to the first file"
$file2 = Read-Host "Enter the path to the second file"

$content1 = Get-Content $file1
$content2 = Get-Content $file2

$diff = Compare-Object $content1 $content2 -IncludeEqual

$diff | ForEach-Object {
    if ($_.SideIndicator -eq "==") {
        Write-Host $_.InputObject -ForegroundColor Green
    } elseif ($_.SideIndicator -eq "<=") {
        Write-Host "$($_.InputObject) (only in $file1)" -ForegroundColor Red
    } else {
        Write-Host "$($_.InputObject) (only in $file2)" -ForegroundColor Red
    }
}