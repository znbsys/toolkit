# Load necessary .NET assemblies for cursor control
Add-Type -AssemblyName System.Windows.Forms

Write-Host "Anti-Sleep Script Started (Mouse Version)..." -ForegroundColor Cyan
Write-Host "Mode: Random movement within 10-minute intervals." -ForegroundColor Gray
Write-Host "Press Ctrl+C or close this window to stop." -ForegroundColor Yellow

while($true) {
    # 1. Capture current mouse cursor position
    $pos = [System.Windows.Forms.Cursor]::Position

    # 2. Perform micro-movement: move 1 pixel offset and back instantly
    # This prevents system idle state without interfering with user tasks
    [System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point(($pos.X + 1), ($pos.Y + 1))
    Start-Sleep -Milliseconds 50
    [System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point($pos.X, $pos.Y)

    # 3. Generate random delay between 300 and 600 seconds (5 minutes)
    $waitTime = Get-Random -Minimum 300 -Maximum 601

    $currentTime = Get-Date -Format "HH:mm:ss"
    Write-Host "[$currentTime] Mouse activity simulated. Next execution in $waitTime seconds..." -ForegroundColor DarkGray

    # 4. Enter random sleep interval
    Start-Sleep -Seconds $waitTime
}