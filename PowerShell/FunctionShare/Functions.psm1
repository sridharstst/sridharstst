function Remove-OldLogs {
  param (
    $numRecentlogs
  )
  try {
      $logs = Get-ChildItem $logPath -Filter *.log
      $logs = $logs | Sort-Object -Property LastWriteTime -Descending
      $oldLogs = $logs | Select-Object -Skip $numRecentlogs
      $oldLogs | Remove-Item -Force  
      Write-Host "Old log files cleaned up"   
  }
  catch {
      $ErrorMessage = $_.Exception.Message
      Write-Error "error occured while trying to clean the oldlogs: $oldlogs error Details:$errorMessage"
  }
    
  }

function Backup-Data {
    param (
        $webSitePath,
        $folder,
        $backupPath,
        $numRecentBackups,
        $BackTimeFolder
    )
    
    $hasErrors = $false
    
    try {
        if (!(Test-Path $folder)) {
            # Check if backup parent path exists before listing
            if (!(Test-Path $backupPath)) {
                Write-Host "Backup path doesn't exist, creating: $backupPath"
                New-Item -ItemType Directory -Path $backupPath -Force -ErrorAction Stop | Out-Null
            }
            
            # Get existing backups with error handling
            try {
                $existingBackups = Get-ChildItem -Path $backupPath -Directory -ErrorAction Stop | 
                    Sort-Object CreationTime -Descending
            } catch {
                Write-Host "Warning: Could not list existing backups: $_" -ForegroundColor Yellow
                $existingBackups = @()
            }
                
            if ($existingBackups.Count -gt $numRecentBackups) {
                $foldersToDelete = $existingBackups | 
                    Select-Object -Skip $numRecentBackups
                
                foreach ($folderToDelete in $foldersToDelete) {
                    try {
                        Write-Host "Deleting old backup: $($folderToDelete.Name)"
                        Remove-Item -Path $folderToDelete.FullName -Recurse -Force -ErrorAction Stop
                    } catch {
                        Write-Host "Warning: Could not delete $($folderToDelete.Name): $_" -ForegroundColor Yellow
                    }
                }
            }
            
            # Verify source exists
            if (!(Test-Path $webSitePath)) {
                Write-Host "Error: Source path does not exist: $webSitePath" -ForegroundColor Red
                $hasErrors = $true
                return $hasErrors
            }
            
            # Create backup folder
            Write-Host "Creating destination folder: $folder"
            New-Item -ItemType Directory -Path $folder -ErrorAction Stop | Out-Null
            
            # Copy files
            Write-Host "Copying files from $webSitePath to $folder"
            Copy-Item -Path "$webSitePath\*" -Destination $folder -Recurse -Force -ErrorAction Stop
            
            Write-Host "Backup successful to $folder" -ForegroundColor Green
            
        } else {  
            Write-Warning "Backup folder already exists, skipping backup: $folder"
        }
        
    } catch {
        $backupError = $_.Exception.Message
        Write-Host "Error occurred during backup:" -ForegroundColor Red
        Write-Host $backupError -ForegroundColor Red
        $hasErrors = $true
    }
    
    return $hasErrors
}

function Copy-File {
        param(
            [string]$destPath,
            [string]$filename,
            $dmzSourcePath,
            $version,
            $buildNumber,
            $latestPath
        )
        $hasErrors = $false
    
        try {
            if (!(Test-Path $destPath)) {
                Write-Warning "destPath path doesn't exist, creating: $destPath"
                New-Item -ItemType Directory -Path $destPath -Force -ErrorAction Stop | Out-Null
            }
            $filenamePath = "$filename-$version-$buildNumber.7z"
            $filepath = Join-Path -Path $destPath -ChildPath $filenamePath
        
            # Clean destination directory
            Write-Host "Cleaning destination directory: $destPath"
            Remove-Item "$destPath\*" -Recurse -Force -ErrorAction Stop
            Write-Host "Successfully removed files in $destPath"
        
            # Copy the 7z file
            Write-Host "Copying $filenamePath from source to destination"
            Copy-Item "$dmzSourcePath\$filenamePath" $destPath -ErrorAction Stop
        
            # Extract the archive
            Write-Host "Extracting $filenamePath to $latestPath"
            & "C:\Program Files\7-Zip\7z.exe" x $filepath -aou -y -o"$latestPath"
        
            if ($LASTEXITCODE -ne 0) {
                throw "7-Zip extraction failed with exit code: $LASTEXITCODE"
            }
        
            # Clean up the archive file
            Remove-Item $filepath -Force -ErrorAction Stop
            Write-Host "Successfully copied and unzipped $filenamePath" -ForegroundColor Green
        }
        catch {
            $ErrorMessage = $_.Exception.Message
            Write-Warning "Error occurred while migrating and cleaning $destPath. Error Details: $ErrorMessage"
            $hasErrors = $true
        }
    
        return $hasErrors
    }

# HELPER FUNCTION FOR ALL IIS RELATED FUNCTIONS ------------
function Wait-IISObjectStableState {
    <#
    .SYNOPSIS
    Waits for IIS object (AppPool/Website) to reach a stable state
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ObjectName,
        [Parameter(Mandatory = $true)]
        [ValidateSet("AppPool", "Website")]
        [string]$ObjectType,
        [int]$TimeoutSeconds = 60,
        [int]$StableCheckCount = 3
    )
    
    Write-Verbose "Waiting for $ObjectType '$ObjectName' to reach stable state..."
    $timer = 0
    $lastState = $null
    $stableCount = 0
    
    do {
        Start-Sleep -Seconds 1
        $timer++
        
        try {
            $currentState = if ($ObjectType -eq "AppPool") {
                (Get-WebAppPoolState $ObjectName).Value
            } else {
                (Get-WebsiteState $ObjectName).Value
            }
            
            if ($currentState -eq $lastState) {
                $stableCount++
            } else {
                $stableCount = 0
                if ($lastState -ne $null) {
                    Write-Verbose "State changed: $lastState -> $currentState"
                }
            }
            
            $lastState = $currentState
        }
        catch {
            Write-Warning "Error checking state: $($_.Exception.Message)"
            $stableCount = 0
        }
        
    } while ($stableCount -lt $StableCheckCount -and $timer -lt $TimeoutSeconds)
    
    if ($timer -ge $TimeoutSeconds) {
        Write-Warning "$ObjectType '$ObjectName' did not stabilize within $TimeoutSeconds seconds"
    } else {
        Write-Verbose "$ObjectType '$ObjectName' stabilized in state: $lastState after $timer seconds"
    }
    
    return $lastState
}

function Stop-OrphanedWorkerProcesses {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AppPoolName,
        [int]$GracePeriodSeconds = 5
    )
    
    try {
        Write-Verbose "Checking for orphaned worker processes for app pool: $AppPoolName"
        
        # Use HashSet to track unique PIDs
        $processIds = New-Object System.Collections.Generic.HashSet[int]
        
        # Get worker processes - use SINGLE method to avoid duplicates
        try {
            $wmiProcesses = Get-WmiObject -Class Win32_Process -ErrorAction SilentlyContinue | 
                Where-Object { $_.Name -eq "w3wp.exe" -and $_.CommandLine -like "*-ap `"$AppPoolName`"*" }
            
            foreach ($proc in $wmiProcesses) {
                [void]$processIds.Add($proc.ProcessId)
            }
        }
        catch {
            Write-Verbose "WMI query failed: $($_.Exception.Message)"
        }
        
        if ($processIds.Count -gt 0) {
            Write-Output "Found $($processIds.Count) orphaned worker process(es) for '$AppPoolName'"
            
            foreach ($processId in $processIds) {
                try {
                    # Verify process still exists
                    $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
                    if (-not $process) {
                        Write-Verbose "Process $processId already terminated"
                        continue
                    }
                    
                    Write-Output "Terminating worker process ID: $processId"
                    
                    # Graceful termination first
                    Stop-Process -Id $processId -ErrorAction SilentlyContinue
                    Start-Sleep -Milliseconds 500
                    
                    # Check if still running
                    $stillRunning = Get-Process -Id $processId -ErrorAction SilentlyContinue
                    if ($stillRunning) {
                        Write-Verbose "Graceful stop failed, force terminating..."
                        Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
                        Write-Output "Force terminated process ID: $processId"
                    }
                    else {
                        Write-Verbose "Process $processId terminated gracefully"
                    }
                }
                catch {
                    Write-Verbose "Could not terminate process $processId : $($_.Exception.Message)"
                }
            }
            
            Start-Sleep -Seconds $GracePeriodSeconds
            Write-Verbose "Worker process cleanup completed"
        }
        else {
            Write-Verbose "No orphaned worker processes found for '$AppPoolName'"
        }
    }
    catch {
        Write-Warning "Error during worker process cleanup: $($_.Exception.Message)"
    }
}

function Test-IISSystemHealth {
    <#
    .SYNOPSIS
    Performs comprehensive IIS system health check
    #>
    [OutputType([bool])]
    param()
    
    try {
        Write-Verbose "Performing IIS system health check..."
        
        # Check critical services
        $services = @("WAS", "W3SVC")
        foreach ($serviceName in $services) {
            $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
            if (-not $service -or $service.Status -ne "Running") {
                Write-Error "Critical service '$serviceName' is not running"
                return $false
            }
        }
        
        # Check for high resource usage
        $w3wpProcesses = Get-Process -Name "w3wp" -ErrorAction SilentlyContinue
        $highCpuProcesses = $w3wpProcesses | Where-Object { $_.CPU -gt 80 }
        
        if ($highCpuProcesses) {
            Write-Warning "High CPU detected on $($highCpuProcesses.Count) IIS worker process(es)"
        }
        
        # Check available memory
        $availableMemory = (Get-Counter "\Memory\Available MBytes").CounterSamples.CookedValue
        if ($availableMemory -lt 512) {
            Write-Warning "Low available memory detected: $availableMemory MB"
        }
        
        Write-Verbose "IIS system health check passed"
        return $true
    }
    catch {
        Write-Error "IIS health check failed: $($_.Exception.Message)"
        return $false
    }
}

function Invoke-SafeIISDeployment {
    <#
    .SYNOPSIS
    Orchestrates a complete IIS deployment with proper sequencing and rollback capability
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$AppPoolName,
        [string]$WebSiteName = $null,
        [scriptblock]$DeploymentAction,
        [int]$MaxRetries = 2
    )
    
    $rollbackRequired = $false
    $originalAppPoolState = $null
    $originalWebSiteState = $null
    
    try {
        Write-Output "=== Starting Safe IIS Deployment ==="
        Write-Output "App Pool: $AppPoolName"
        if ($WebSiteName) { Write-Output "Website: $WebSiteName" }
        
        # Capture initial states for rollback
        try {
            $originalAppPoolState = (Get-WebAppPoolState $AppPoolName).Value
            Write-Output "Original App Pool state: $originalAppPoolState"
            
            if ($WebSiteName) {
                $originalWebSiteState = (Get-WebsiteState $WebSiteName).Value
                Write-Output "Original Website state: $originalWebSiteState"
            }
        }
        catch {
            Write-Warning "Could not capture original states: $($_.Exception.Message)"
        }
        
        # Stop services in correct order
        Write-Output "--- Stopping Services ---"
        if ($WebSiteName) {
            Stop-WebSites -WebSiteName $WebSiteName -MaxRetries $MaxRetries
        }
        Stop-ApplicationPool -AppPoolName $AppPoolName -MaxRetries $MaxRetries
        
        # Execute deployment
        if ($DeploymentAction) {
            Write-Output "--- Executing Deployment ---"
            & $DeploymentAction
        }
        
        # Start services in correct order
        Write-Output "--- Starting Services ---"
        Start-ApplicationPool -AppPoolName $AppPoolName -MaxRetries $MaxRetries
        if ($WebSiteName) {
            Start-WebSites -WebSiteName $WebSiteName -MaxRetries $MaxRetries
        }
        
        Write-Output "=== Safe IIS Deployment Completed Successfully ==="
    }
    catch {
        $rollbackRequired = $true
        Write-Error "Deployment failed: $($_.Exception.Message)"
        
        Write-Output "--- Attempting Service Recovery ---"
        try {
            # Try to restore original states
            if ($originalAppPoolState -eq "Started") {
                Start-ApplicationPool -AppPoolName $AppPoolName -MaxRetries 2
            }
            if ($WebSiteName -and $originalWebSiteState -eq "Started") {
                Start-WebSites -WebSiteName $WebSiteName -MaxRetries 2
            }
        }
        catch {
            Write-Error "Service recovery also failed: $($_.Exception.Message)"
        }
        
        throw "Deployment failed and rollback attempted"
    }
}

#END of helper functions______________________

function Restart-ApplicationPool {
    <#
    .SYNOPSIS
    Restarts an IIS Application Pool with comprehensive error handling and retry logic
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$AppPoolName,
        [int]$MaxRetries = 3,
        [int]$RetryDelaySeconds = 5
    )

    try {
        Write-Output "Starting restart operation for Application Pool: $AppPoolName"
        
        # Pre-flight health check
        if (-not (Test-IISSystemHealth)) {
            Write-Warning "IIS system health issues detected, proceeding with caution..."
        }
        
        # Wait for stable state before operation
        $currentState = Wait-IISObjectStableState -ObjectName $AppPoolName -ObjectType "AppPool"
        Write-Output "Current Application Pool state: $currentState"

        if ($currentState -eq "Stopped") {
            Write-Warning "Application Pool '$AppPoolName' is stopped. Use Start-ApplicationPool instead."
            return
        }

        # Retry logic for restart operation
        for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
            try {
                Write-Output "Restart attempt $attempt of $MaxRetries for '$AppPoolName'"
                
                # Clean up any orphaned processes before restart
                Stop-OrphanedWorkerProcesses -AppPoolName $AppPoolName
                
                # Perform the restart
                Restart-WebAppPool -Name $AppPoolName -ErrorAction Stop
                
                # Wait and verify the restart
                Start-Sleep -Seconds 3
                $newState = Wait-IISObjectStableState -ObjectName $AppPoolName -ObjectType "AppPool" -TimeoutSeconds 30
                
                if ($newState -eq "Started") {
                    Write-Output "Application Pool '$AppPoolName' restarted successfully"
                    
                    # Additional health verification
                    Start-Sleep -Seconds 2
                    $verifyState = (Get-WebAppPoolState -Name $AppPoolName).Value
                    if ($verifyState -eq "Started") {
                        Write-Output "Restart verification passed for '$AppPoolName'"
                        return
                    }
                }
                
                throw "Application Pool did not reach 'Started' state. Current state: $newState"
            }
            catch {
                $errorMessage = $_.Exception.Message
                Write-Warning "Restart attempt $attempt failed: $errorMessage"
                
                if ($attempt -eq $MaxRetries) {
                    throw "Failed to restart Application Pool '$AppPoolName' after $MaxRetries attempts. Last error: $errorMessage"
                }
                
                $delay = $RetryDelaySeconds * $attempt
                Write-Output "Waiting $delay seconds before retry..."
                Start-Sleep -Seconds $delay
            }
        }
    }
    catch {
        $errorMessage = $_.Exception.Message
        Write-Error "Critical error during Application Pool restart for '$AppPoolName': $errorMessage"
        throw
    }
}

function Stop-ApplicationPool {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AppPoolName,
        [int]$TimeoutSeconds = 60,  # Increased from 30
        [int]$MaxRetries = 3,
        [int]$GracePeriodSeconds = 5
    )
    
    try {
        Write-Output "Stopping Application Pool: $AppPoolName"
        
        $currentState = (Get-WebAppPoolState $AppPoolName).Value
        Write-Output "Current state: $currentState"
        
        if ($currentState -eq "Stopped") {
            Write-Output "Application Pool '$AppPoolName' is already stopped"
            return
        }
        
        for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
            try {
                Write-Output "Stop attempt $attempt of $MaxRetries"
                
                # Force immediate shutdown on retry attempts
                if ($attempt -gt 1) {
                    Write-Warning "Force-stopping worker processes before retry"
                    Stop-OrphanedWorkerProcesses -AppPoolName $AppPoolName
                    Start-Sleep -Seconds 2
                }
                
                # Attempt to stop
                Stop-WebAppPool $AppPoolName -ErrorAction Stop
                
                # Wait for complete shutdown with timeout
                $timer = 0
                $pollInterval = 2  # Check every 2 seconds instead of 1
                do {
                    Start-Sleep -Seconds $pollInterval
                    $timer += $pollInterval
                    
                    try {
                        $state = (Get-WebAppPoolState $AppPoolName).Value
                        Write-Verbose "Waiting for stop... Current state: $state ($timer/$TimeoutSeconds)"
                    }
                    catch {
                        # App pool might be in transition, retry
                        Write-Verbose "State check failed, retrying..."
                        Start-Sleep -Seconds 1
                        continue
                    }
                    
                } while ($state -ne "Stopped" -and $timer -lt $TimeoutSeconds)
                
                if ($state -eq "Stopped") {
                    Write-Output "Successfully stopped Application Pool '$AppPoolName'"
                    
                    # Clean up any lingering worker processes
                    Start-Sleep -Seconds $GracePeriodSeconds
                    Stop-OrphanedWorkerProcesses -AppPoolName $AppPoolName -GracePeriodSeconds 2
                    return
                } 
                else {
                    throw "Application Pool did not stop within $TimeoutSeconds seconds. Current state: $state"
                }
            }
            catch {
                $errorMessage = $_.Exception.Message
                Write-Warning "Stop attempt $attempt failed: $errorMessage"
                
                if ($attempt -eq $MaxRetries) {
                    # Last resort: aggressive cleanup
                    Write-Warning "Performing emergency cleanup for '$AppPoolName'"
                    Stop-OrphanedWorkerProcesses -AppPoolName $AppPoolName
                    
                    # Final state check
                    Start-Sleep -Seconds 3
                    $finalState = (Get-WebAppPoolState $AppPoolName -ErrorAction SilentlyContinue).Value
                    if ($finalState -eq "Stopped") {
                        Write-Output "Application Pool stopped after emergency cleanup"
                        return
                    }
                    
                    throw "Failed to stop Application Pool '$AppPoolName' after $MaxRetries attempts"
                }
                
                Start-Sleep -Seconds 5  # Longer wait between retries
            }
        }
    }
    catch {
        $stopError = $_.Exception.Message
        Write-Error "Error in Stop-ApplicationPool for '$AppPoolName': $stopError"
        throw
    }
}

function Start-ApplicationPool {
    <#
    .SYNOPSIS
    Starts an IIS Application Pool with comprehensive retry logic and state verification
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$AppPoolName,
        [int]$MaxRetries = 5,
        [int]$RetryDelaySeconds = 3,
        [int]$StartupTimeoutSeconds = 30
    )
    
    try {
        Write-Output "Starting Application Pool: $AppPoolName"
        
        # Pre-flight system health check
        Test-IISSystemHealth | Out-Null
        
        # Wait for stable state
        $currentState = Wait-IISObjectStableState -ObjectName $AppPoolName -ObjectType "AppPool"
        Write-Output "Current Application Pool state: $currentState"
        
        if ($currentState -eq "Started") {
            Write-Output "Application Pool '$AppPoolName' is already started"
            return
        }
        
        # Clean up any orphaned processes first
        Stop-OrphanedWorkerProcesses -AppPoolName $AppPoolName
        
        # Retry logic with exponential backoff
        for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
            try {
                Write-Output "Start attempt $attempt of $MaxRetries for '$AppPoolName'"
                
                # Attempt to start
                Start-WebAppPool $AppPoolName -ErrorAction Stop
                
                # Verify startup with timeout
                $timer = 0
                $startupSuccessful = $false
                
                do {
                    Start-Sleep -Seconds 1
                    $timer++
                    $state = (Get-WebAppPoolState $AppPoolName).Value
                    Write-Verbose "Startup progress... Current state: $state ($timer/$StartupTimeoutSeconds)"
                    
                    if ($state -eq "Started") {
                        $startupSuccessful = $true
                        break
                    }
                } while ($timer -lt $StartupTimeoutSeconds)
                
                if ($startupSuccessful) {
                    Write-Output "Successfully started Application Pool '$AppPoolName'"
                    
                    # Additional verification after brief wait
                    Start-Sleep -Seconds 2
                    $verificationState = (Get-WebAppPoolState $AppPoolName).Value
                    if ($verificationState -eq "Started") {
                        Write-Output "Startup verification passed for '$AppPoolName'"
                        return
                    } else {
                        throw "Application Pool state changed unexpectedly to: $verificationState"
                    }
                } else {
                    throw "Application Pool did not start within $StartupTimeoutSeconds seconds. Final state: $state"
                }
            }
            catch {
                $errorMessage = $_.Exception.Message
                Write-Warning "Start attempt $attempt failed: $errorMessage"
                
                if ($attempt -eq $MaxRetries) {
                    throw "Failed to start Application Pool '$AppPoolName' after $MaxRetries attempts. Last error: $errorMessage"
                }
                
                # Exponential backoff: 3, 6, 12, 24, 48 seconds
                $delay = $RetryDelaySeconds * [Math]::Pow(2, $attempt - 1)
                Write-Output "Waiting $delay seconds before retry..."
                Start-Sleep -Seconds $delay
                
                # Clean up before retry
                Stop-OrphanedWorkerProcesses -AppPoolName $AppPoolName
            }
        }
    }
    catch {
        $startError = $_.Exception.Message
        Write-Error "Critical error in Start-ApplicationPool for '$AppPoolName': $startError"
        throw
    }
}

function Stop-WebSites {
    <#
    .SYNOPSIS
    Stops an IIS Website with proper error handling and state verification
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$WebSiteName,
        [int]$TimeoutSeconds = 30,
        [int]$MaxRetries = 3
    )
    
    try {
        Write-Output "Stopping Website: $WebSiteName"
        
        # Check current state
        $currentState = (Get-WebsiteState $WebSiteName).Value
        Write-Output "Current website state: $currentState"
        
        if ($currentState -eq "Stopped") {
            Write-Output "Website '$WebSiteName' is already stopped"
            return
        }
        
        for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
            try {
                Write-Output "Website stop attempt $attempt of $MaxRetries"
                
                Stop-Website $WebSiteName -ErrorAction Stop
                
                # Wait for complete stop
                $timer = 0
                do {
                    Start-Sleep -Seconds 1
                    $timer++
                    $state = (Get-WebsiteState $WebSiteName).Value
                    Write-Verbose "Stopping website... Current state: $state ($timer/$TimeoutSeconds)"
                } while ($state -ne "Stopped" -and $timer -lt $TimeoutSeconds)
                
                if ($state -eq "Stopped") {
                    Write-Output "Successfully stopped Website '$WebSiteName'"
                    return
                } else {
                    throw "Website did not stop within $TimeoutSeconds seconds. Current state: $state"
                }
            }
            catch {
                $errorMessage = $_.Exception.Message
                Write-Warning "Website stop attempt $attempt failed: $errorMessage"
                
                if ($attempt -eq $MaxRetries) {
                    throw "Failed to stop Website '$WebSiteName' after $MaxRetries attempts"
                }
                
                Start-Sleep -Seconds 3
            }
        }
    }
    catch {
        $websiteError = $_.Exception.Message
        Write-Error "Error in Stop-WebSites for '$WebSiteName': $websiteError"
        throw
    }
}

function Start-WebSites {
    <#
    .SYNOPSIS
    Starts an IIS Website with retry logic and proper state management
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$WebSiteName,
        [int]$MaxRetries = 3,
        [int]$RetryDelaySeconds = 5,
        [int]$StartupTimeoutSeconds = 30
    )
    
    try {
        Write-Output "Starting Website: $WebSiteName"
        
        # Wait for stable state
        $currentState = Wait-IISObjectStableState -ObjectName $WebSiteName -ObjectType "Website"
        Write-Output "Current website state: $currentState"
        
        if ($currentState -eq "Started") {
            Write-Output "Website '$WebSiteName' is already started"
            return
        }
        
        for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
            try {
                Write-Output "Website start attempt $attempt of $MaxRetries"
                
                Start-Website $WebSiteName -ErrorAction Stop
                
                # Verify startup
                $timer = 0
                $startupSuccessful = $false
                
                do {
                    Start-Sleep -Seconds 1
                    $timer++
                    $state = (Get-WebsiteState $WebSiteName).Value
                    Write-Verbose "Starting website... Current state: $state ($timer/$StartupTimeoutSeconds)"
                    
                    if ($state -eq "Started") {
                        $startupSuccessful = $true
                        break
                    }
                } while ($timer -lt $StartupTimeoutSeconds)
                
                if ($startupSuccessful) {
                    Write-Output "Successfully started Website '$WebSiteName'"
                    
                    # Verification after brief wait
                    Start-Sleep -Seconds 2
                    $verificationState = (Get-WebsiteState $WebSiteName).Value
                    if ($verificationState -eq "Started") {
                        Write-Output "Website startup verification passed for '$WebSiteName'"
                        return
                    }
                }
                
                throw "Website did not start properly within timeout period"
            }
            catch {
                $errorMessage = $_.Exception.Message
                Write-Warning "Website start attempt $attempt failed: $errorMessage"
                
                if ($attempt -eq $MaxRetries) {
                    throw "Failed to start Website '$WebSiteName' after $MaxRetries attempts"
                }
                
                $delay = $RetryDelaySeconds * $attempt
                Write-Output "Waiting $delay seconds before retry..."
                Start-Sleep -Seconds $delay
            }
        }
    }
    catch {
        $websiteStartError = $_.Exception.Message
        Write-Error "Critical error in Start-WebSites for '$WebSiteName': $websiteStartError"
        throw
    }
}

function replace_latest_ui {
        param (
            [string]$destPath,
            [string]$sourcePath,
            [string[]]$filesToCopy  # This should be folders/files to EXCLUDE from deletion
        )
    
        $hasErrors = $false
    
        # Validate input parameters
        if (-not (Test-Path $destPath)) {
            Write-Warning "Destination path does not exist: $destPath"
            $hasErrors = $true
        }
    
        if (-not (Test-Path $sourcePath)) {
            Write-Warning "Source path does not exist: $sourcePath"
            $hasErrors = $true
        }
    
        try {
            Write-Output "Clearing the website folder contents (excluding: $($filesToCopy -join ', '))..."
        
            # Get all items in the destination path
            $allItems = Get-ChildItem -Path $destPath -Force
        
            # Filter out the items to exclude (assets, reports, etc.)
            $itemsToRemove = $allItems | Where-Object { 
                $currentItem = $_.Name
                $shouldExclude = $false
            
                foreach ($excludeItem in $filesToCopy) {
                    # Handle both exact matches and wildcard patterns
                    if ($currentItem -eq $excludeItem -or $currentItem -like $excludeItem) {
                        $shouldExclude = $true
                        Write-Verbose "Excluding from deletion: $($_.FullName)"
                        break
                    }
                }
            
                return -not $shouldExclude
            }
        
            # Remove the filtered items (this cleans up old Angular hashed files)
            if ($itemsToRemove) {
                $removeCount = $itemsToRemove.Count
                Write-Host "Removing $removeCount items from website folder..."
            
                $itemsToRemove | ForEach-Object {
                    Write-Verbose "Removing: $($_.FullName)"
                    Remove-Item $_.FullName -Recurse -Force -ErrorAction Stop
                }
            
                Write-Host "Successfully removed $removeCount items (preserved: $($filesToCopy -join ', '))"
            } else {
                Write-Host "No items to remove - all items are in exclusion list"
            }
        
        } catch {
            $errorMessage = $_.Exception.Message
            Write-Warning "Error occurred while clearing website folder: $errorMessage"
            Write-Warning "Failed item: $($_.TargetObject)"
            $hasErrors = $true
        }
    
        try {
            Write-Output "Copying fresh Angular build from: $sourcePath to: $destPath..."
        
            # Get all items from source
            $sourceItems = Get-ChildItem -Path $sourcePath -Force
        
            # Filter source items to exclude the ones we want to preserve
            $sourceItemsToInclude = $sourceItems | Where-Object { 
                $currentItem = $_.Name
                $shouldExclude = $false
            
                foreach ($excludeItem in $filesToCopy) {
                    # Handle both exact matches and wildcard patterns
                    if ($currentItem -eq $excludeItem -or $currentItem -like $excludeItem) {
                        $shouldExclude = $true
                        Write-Verbose "Excluding from copy: $($_.FullName)"
                        break
                    }
                }
            
                return -not $shouldExclude
            }
        
            if ($sourceItemsToInclude) {
                $copyCount = $sourceItemsToInclude.Count
                Write-Host "Copying $copyCount items from source (excluding: $($filesToCopy -join ', '))..."
            
                $sourceItemsToInclude | ForEach-Object {
                    $destinationItem = Join-Path -Path $destPath -ChildPath $_.Name
                    Write-Verbose "Copying: $($_.Name) to destination"
                
                    if ($_.PSIsContainer) {
                        # For directories
                        Copy-Item -Path $_.FullName -Destination $destinationItem -Recurse -Force -ErrorAction Stop
                    } else {
                        # For files
                        Copy-Item -Path $_.FullName -Destination $destinationItem -Force -ErrorAction Stop
                    }
                }
            
                Write-Host "Successfully copied $copyCount items to: $destPath (preserved existing: $($filesToCopy -join ', '))"
            } else {
                Write-Warning "No items to copy - all items are in exclusion list"
            }
        
        } catch {
            $ErrorMessage = $_.Exception.Message
            Write-Warning "Error occurred while copying fresh build: $ErrorMessage"
            Write-Warning "Failed item: $($_.TargetObject)"
            Write-Warning "Please verify paths and try to revert from backup if needed"
            $hasErrors = $true
        }
    
        # Verification step
        try {
            Write-Output "Verifying deployment..."
        
            # Basic verification - check if key files exist
            $sourceFileCount = (Get-ChildItem -Path $sourcePath -Recurse -File).Count
            $destFileCount = (Get-ChildItem -Path $destPath -Recurse -File).Count
        
            Write-Host "Source files: $sourceFileCount"
            Write-Host "Destination files: $destFileCount (includes excluded items)"
        
            # Check if main Angular files exist
            $angularFiles = @("index.html", "main*.js", "polyfills*.js", "runtime*.js")
            $missingFiles = @()
        
            foreach ($pattern in $angularFiles) {
                $found = Get-ChildItem -Path $destPath -Name $pattern -ErrorAction SilentlyContinue
                if (-not $found) {
                    $missingFiles += $pattern
                }
            }
        
            if ($missingFiles.Count -eq 0) {
                Write-Host "[SUCCESS] Deployment verification successful - Angular files present" -ForegroundColor Green
            } else {
                Write-Warning "[FAILED] Deployment verification failed - Missing files: $($missingFiles -join ', ')"
                $hasErrors = $true
            }
        
            # Custom verification function if available
            if (Get-Command Test-FilesIdentical_folder -ErrorAction SilentlyContinue) {
                Write-Verbose "Running custom verification..."
                $customVerification = Test-FilesIdentical_folder -sourcePath $sourcePath -destPath $destPath -dirsToExclude $filesToCopy
                if (-not $customVerification) {
                    Write-Warning "Custom verification failed"
                    $hasErrors = $true
                }
            }
        
        } catch {
            Write-Warning "Error during verification: $($_.Exception.Message)"
            $hasErrors = $true
        }
    
        return $hasErrors
    }

function replace_latest_Service {
      param (
        [string]$destPath,
        [string]$sourcePath,
        [string[]]$filesToCopy
      )
      $hasErrors = $false
      try {
        Write-Output "clearing the webiste folder... "
        Remove-Item $destPath  -Exclude $filesToCopy  -Recurse  -Force
        Write-Host "removed the content in the website folder."
      }catch{
        $errorMessage = $_.Exception.Message
        Write-Warning "error occured while trying to delete in the website path: $_ please check the $destPath is  files are deleted. Error details : $errorMessage"
        $hasErrors = $true
      }
      try {
        Write-Output "copying the latest source to the website path: $destPath..... "
        Copy-Item $sourcePath\* -Exclude $filesToCopy $destPath -Recurse  -Force
        Write-Host "copied the latets source to: $destPath."
      }
      catch {
        $ErrorMessage = $_.Exception.Message
        Write-Warning "error occured while copying the latest to webiste path: $_. please verfy the path and try to revert from backup Error Details: $ErrorMessage "
        $hasErrors = $true
      }
      if (Test-FilesIdentical_files -sourcePath $destPath -destPath $sourcePath -filesToCopy $filesToCopy) {
        Write-Host "copy verified..." 
      }else {
        Write-Warning "verifiy failed for replace_latest "
        $hasErrors = $true

      }
      return $hasErrors
    }

  #   function Get-ChildItemExclude {
  #     param(
  #         [string]$Path,
  #         [string[]]$Exclude
  #     )
  #     Get-ChildItem -Path $Path -Directory | ForEach-Object {
  #         if ($_.Name -notin $Exclude) {
  #             $_
  #             Get-ChildItemExclude -Path $_.FullName -Exclude $Exclude
  #         }
  #     }
  # }
function Test-FilesIdentical_folder {
      param(
          $sourcePath,
          $destPath,
          $dirsToExclude
          
      )
      try {
          $sourceDirs = Get-ChildItem -Path $sourcePath -Exclude $dirsToExclude 
          foreach ($sourceDir in $sourceDirs) {
              $sourceFiles = Get-ChildItem -Path $sourceDir.FullName -File
              foreach ($sourceFile in $sourceFiles) {
                  $relativePath = $sourceFile.FullName.Substring($sourcePath.Length)
                  $destFile = Join-Path $destPath $relativePath
                  if (!(Test-Path $destFile)) {
                      Write-Error -Message "File $relativePath does not exist in the destination directory."
                      return $false
                  }
                  $sourceHash = Get-FileHash $sourceFile.FullName -Algorithm SHA256 | Select-Object -ExpandProperty Hash
                  $destHash = Get-FileHash $destFile -Algorithm SHA256 | Select-Object -ExpandProperty Hash
                  if ($sourceHash -ne $destHash) {
                      Write-Error -Message "File $relativePath is different in the destination directory." 
                      return $false
                  }
              }
          }
          Write-Host -Message "All files in the specified directory are identical." 
          return $true
      }
      catch {
          $filesError = $_.Exception.Message
          Write-Error "error in Test-FilesIdentical : $filesError "
      }
  }

function Test-FilesIdentical_files {
    param(
        $sourcePath,
        $destPath,
        $filesToCopy
    )
    try {
        $sourceFiles = Get-ChildItem -Path $sourcePath -Recurse -File -Exclude $filesToCopy
        foreach ($sourceFile in $sourceFiles) {
            $relativePath = $sourceFile.FullName.Substring($sourcePath.Length)
            $destFile = Join-Path $destPath $relativePath
            if (!(Test-Path $destFile)) {
                Write-Error -Message "File $relativePath does not exist in the destination directory."
                return $false
            }
            $sourceHash = Get-FileHash $sourceFile.FullName -Algorithm SHA256 | Select-Object -ExpandProperty Hash
            $destHash = Get-FileHash $destFile -Algorithm SHA256 | Select-Object -ExpandProperty Hash
            if ($sourceHash -ne $destHash) {
                Write-Error -Message "File $relativePath is different in the destination directory." 
                return $false
            }
        }
        Write-Host -Message "All files in the specified directory are identical." 
        return $true
    }
    catch {
        $filesError = $_.Exception.Message
        Write-Error "error in Test-FilesIdentical : $filesError "
    }
}
  

function Copy-Report {
  param (
    $sourcePath,
    $destPath

  )
  $hasErrors = $false
  try {
    
    if (!(Test-Path $sourcePath))
    {
           Write-Host "The Report $sourcePath does't exists please check the zip file exists or nor" -ForegroundColor Red
           $hasErrors = $true
           return $hasErrors  
    }
    
    if (!(Test-Path $destPath)) 
    {
        Write-Host "The report Path is not exists $destPath please check the path" -ForegroundColor Red
        $hasErrors = $true
        return $hasErrors        
    }
    Write-Host "Started to copy the report files to $destPath from $sourcePath"
    Copy-Item $sourcePath\* $destPath -Force
    Write-Host "Copyied the report files from $sourcePath to $destPath" -ForegroundColor Green
    
  }
  catch {
    $reportError = $_.Exception.Message
    Write-Error "error while copying the report file : $reportError"
    $hasErrors = $true
  }
  return $hasErrors
  
}

function functionsscript {
  param (
    $sourcePath,
    $scriptPath,
    $filesToExclude,
    $server,
    $database,
    $username,
    $pass
  )

  $scriptFullPath = Join-Path -Path $sourcePath -ChildPath $scriptPath
  $otherfiles = Get-ChildItem -Path $scriptFullPath -Filter *.sql | Where-Object { $filesToExclude -notcontains $_.Name }
  $hasErrors = $false

  foreach ($file in $otherfiles) {
    Write-Host "Executing $($file.Name)"
    try {
      $sqlcmdOutput = & sqlcmd -S $server -U $username -P $pass -b -d $database -I -i $file.FullName 2>&1 

      if ($LASTEXITCODE -eq 0) {
        Write-Host "$($file.Name) executed successfully`n"
      } else {
        Write-Host "`nError occurred while executing $($file.Name):" -ForegroundColor Red
        $errorMessage = $sqlcmdOutput | Out-String
        Write-Host $errorMessage -ForegroundColor Red
        $hasErrors = $true
      }
    } catch {
      Write-Host "`nError executing $($file.Name): $_" -ForegroundColor Red
      $hasErrors = $true
    }
  }
  
  return $hasErrors
}

function TableScript {
  param (
    $sourcePath,
    $scriptPath,
    $filesToExclude,
    $server,
    $database,
    $username,
    $pass
  )

  $scriptFullPath = Join-Path -Path $sourcePath -ChildPath $scriptPath
  $otherfiles = Get-ChildItem -Path $scriptFullPath -Filter *.sql | Where-Object { $filesToExclude -notcontains $_.Name }
  $hasErrors = $false

  foreach ($file in $otherfiles) {
    Write-Host "Executing $($file.Name)"
    try {
      $sqlcmdOutput = & sqlcmd -S $server -U $username -P $pass -b -d $database -I -i $file.FullName 2>&1 

      if ($LASTEXITCODE -eq 0) {
        Write-Host "$($file.Name) executed successfully`n"
      } else {
        Write-Host "Error occurred while executing $($file.Name):" -ForegroundColor Red
        $errorMessage = $sqlcmdOutput | Out-String
        Write-Host $errorMessage -ForegroundColor Red
        $hasErrors = $true
      }
    } catch {
      Write-Host "Error executing $($file.Name): $_" -ForegroundColor Red
      $hasErrors = $true
    }
  }
  
  return $hasErrors
}

function Procedurescript {
  param (
    $sourcePath,
    $scriptPath,
    $filesToExclude,
    $server,
    $database,
    $username,
    $pass,
    [switch]$ExecuteMainFolderFirst # Optional: Execute main folder files before subdirectories
  )
  
  $scriptFullPath = Join-Path -Path $sourcePath -ChildPath $scriptPath
  
  if (-not (Test-Path $scriptFullPath)) {
    Write-Host "Path does not exist: $scriptFullPath" -ForegroundColor Red
    return $true
  }
  
  $hasErrors = $false
  $allFiles = @()
  
  if ($ExecuteMainFolderFirst) {
    # First get files from main directory only
    $mainDirFiles = Get-ChildItem -Path $scriptFullPath -Filter *.sql | Where-Object { $filesToExclude -notcontains $_.Name }
    $allFiles += $mainDirFiles
    
    # Then get files from subdirectories
    $subDirFiles = Get-ChildItem -Path $scriptFullPath -Filter *.sql -Recurse | Where-Object { 
      $filesToExclude -notcontains $_.Name -and $_.Directory.FullName -ne $scriptFullPath 
    }
    $allFiles += $subDirFiles
  } else {
    # Get all files recursively (default behavior)
    $allFiles = Get-ChildItem -Path $scriptFullPath -Filter *.sql -Recurse | Where-Object { $filesToExclude -notcontains $_.Name }
  }
  
  if ($allFiles.Count -eq 0) {
    Write-Host "No SQL files found in $scriptFullPath or its subdirectories" -ForegroundColor Yellow
    return $false
  }
  
  Write-Host "Found $($allFiles.Count) SQL files to execute" -ForegroundColor Green
  
  $successCount = 0
  $errorCount = 0
  
  foreach ($file in $allFiles) {
    $relativePath = $file.FullName.Replace($scriptFullPath, "").TrimStart('\')
    Write-Host "Executing: $relativePath" -ForegroundColor Cyan
    
    try {
      $sqlcmdOutput = & sqlcmd -S $server -U $username -P $pass -b -d $database -I -i $file.FullName 2>&1 
      
      if ($LASTEXITCODE -eq 0) {
        Write-Host " $($file.Name) executed successfully" -ForegroundColor Green
        $successCount++
      } else {
        Write-Host " Error occurred while executing $($file.Name):" -ForegroundColor Red
        $errorMessage = $sqlcmdOutput | Out-String
        Write-Host $errorMessage -ForegroundColor Red
        $hasErrors = $true
        $errorCount++
      }
    } catch {
      Write-Host " Exception executing $($file.Name): $_" -ForegroundColor Red
      $hasErrors = $true
      $errorCount++
    }
    
    Write-Host ""
  }
  
  Write-Host "Execution Summary:" -ForegroundColor Yellow
  Write-Host "  - Successful: $successCount files" -ForegroundColor Green  
  Write-Host "  - Failed: $errorCount files" -ForegroundColor Red
  Write-Host "  - Total: $($allFiles.Count) files" -ForegroundColor Cyan
  
  return $hasErrors
}

function Basedatascript {
  param (
    $sourcePath,
    $scriptPath,
    $server,
    $database,
    $username,
    $pass,
    $env
  )
  
  $App_config = "02App_Configuration_$env.sql"
  $scriptFullPath = Join-Path -Path $sourcePath -ChildPath $scriptPath
  $hasErrors = $false
  
  if (Test-Path (Join-Path $scriptFullPath $App_config)) {
    Write-Host "Executing $App_config"
    try {
        $sqlcmdOutput = & sqlcmd -S $server -U $username -P $pass -d $database -i (Join-Path $scriptFullPath $App_config) -b 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "$App_config Executed Successfully`n"
        } else {
            Write-Host "`nError occurred while executing ${App_config}:" -ForegroundColor Red
            $errorMessage = $sqlcmdOutput | Out-String
            Write-Host $errorMessage -ForegroundColor Red
            $hasErrors = $true
        }
    } catch {
        Write-Host "Error: $_" -ForegroundColor Red
        $hasErrors = $true
    }
  } else {
    Write-Host "File not found: $App_config"
  }

  $otherfiles = Get-ChildItem -Path $scriptFullPath -Filter *.sql | Where-Object { $_.Name -notlike "02App_Configuration*.sql" }

  foreach ($file in $otherfiles) {
    Write-Host "Executing $($file.Name)"
    try {
      $sqlcmdOutput = & sqlcmd -S $server -U $username -P $pass -b -d $database -I -i $file.FullName 2>&1 

      if ($LASTEXITCODE -eq 0) {
        Write-Host "$($file.Name) executed successfully`n"
      } else {
        Write-Host "`nError occurred while executing $($file.Name):" -ForegroundColor Red
        $errorMessage = $sqlcmdOutput | Out-String
        Write-Host $errorMessage -ForegroundColor Red
        $hasErrors = $true
      }
    } catch {
      Write-Host "`nError executing $($file.Name): $_" -ForegroundColor Red
      $hasErrors = $true
    }
  }
  
  return $hasErrors
}

function Invoke-VersionScript {
    param (
        $sourcePath,
        $scriptPath,
        $server,
        $database,
        $username,
        $pass
    )
    $hasErrors = $false
    $totalSuccessCount = 0
    $totalErrorCount = 0
    $scriptFullPath = Join-Path -Path $sourcePath -ChildPath $scriptPath
    $versionFolder = Get-ChildItem -Path $scriptFullPath -Directory |
        Where-Object { $_.Name -match '^v\d+\.\d+\.\d+$' } |
        Sort-Object {
            $version = $_.Name -replace '^v', ''
            [version]$version
        }
    
    if ($versionFolder.Count -eq 0) {
        Write-Host "No version folder found in $scriptFullPath" -ForegroundColor Red
        return $true
    }
    Write-Host "Found version folder: $($versionFolder[-1].Name)" -ForegroundColor Green

    $latestFolder = $versionFolder[-1]
    $secondLatestFolder = if ($versionFolder.Count -gt 1) {
        $versionFolder[-2]
    }
    else {
        $null
    }
    $foldersToProcess = @()

    if ($secondLatestFolder){
        $foldersToProcess += $secondLatestFolder
        Write-Host "Safety folder (executing first): $($secondLatestFolder.Name)" -ForegroundColor Yellow
    }
    $foldersToProcess += $latestFolder
    Write-Host "Latest folder: $($latestFolder.Name)" -ForegroundColor Cyan
    foreach ($folder in $foldersToProcess){
        Write-Host " `n processing folder: $($folder.Name)" -ForegroundColor Magenta
        $sqlFiles = Get-ChildItem -Path $folder.FullName -Filter "*.sql" |
            Sort-Object Name
        if ($sqlFiles.Count -eq 0){
            Write-Host "No SQL files found in $($folder.FullName)" -ForegroundColor Yellow
            continue
        }

        Write-Host "Found $($sqlFiles.Count) SQL files to execute in $($folder.Name)" -ForegroundColor Green

        foreach ($file in $sqlFiles){
            Write-Host "Executing: $($file.Name)" -ForegroundColor Cyan
            try {
                $sqlcmdoutput = & sqlcmd -S $server -U $username -P $pass -b -d $database -I -i $file.FullName 2>&1

                if ($LASTEXITCODE -eq 0) {
                    Write-Host " $($file.Name) executed successfully" -ForegroundColor Green
                    $totalSuccessCount++
                }
                else {
                    Write-Host "Error executing $($file.Name):" -ForegroundColor Red
                    $errorMessage = $sqlcmdoutput | Out-String
                    Write-Host $errorMessage -ForegroundColor Red
                    $hasErrors = $true
                    $totalErrorCount++
                }
            } catch {
                Write-Host " Exception executing $($file.Name): $_" -ForegroundColor Red
                $hasErrors = $true
                $totalErrorCount++
            }
        }
    }
    Write-Host "`nExecution Summary:" -ForegroundColor Yellow
    Write-Host "  - Successful: $totalSuccessCount files" -ForegroundColor Green
    Write-Host "  - Failed: $totalErrorCount files" -ForegroundColor Red
    Write-Host "  - Total: $($totalSuccessCount + $totalErrorCount) files" -ForegroundColor Cyan
    return $hasErrors

}


function Get-InputValidation {
  param (
    [string]$prompt,
    [scriptblock]$validation

  )

  do {
    $valueinput = Read-Host $prompt
    if ( &$validation $valueinput){
      return $valueinput
    }
    else {
      Write-Warning "Invalid input. please try again"
    }
  } while ($true)
  
}

