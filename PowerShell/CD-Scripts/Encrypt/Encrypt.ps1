$credential = Get-Credential -Message "Please enter the server credentials"
$xmlPath = "R:\RMG_Auto\Script\Encrypt\Xml\credential.xml"

$cXmlPath = Read-Host -Message "$xmlPath if the default path and file name are acceptable, please respond with Y/y or N/n"
while ($cXmlPath -ne 'Y' -and $cXmlPath -ne 'y' -and $cXmlPath -ne 'N'-and $cXmlPath -ne 'n')
{
    $cXmlPath = Read-Host -Message "The last input is invalid. Please respond with Y/y or N/n."
}
if (!($cXmlPath -eq 'Y' -or $cXmlPath -eq 'y'))
{
    $xmlPath = Read-Host -Message "please enter where u want to store the xml path "
}

try 
{
    $credential | Export-CliXml -Path $xmlPath
    Write-Host "credentials is stored in $xmlPath please use this path in the main script"
}
catch 
{
    $errorMessage = $_.Exception.Message 
    Write-Host "error occured while creating the xml format $errorMessage"
}