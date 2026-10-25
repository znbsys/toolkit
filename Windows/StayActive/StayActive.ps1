$shell = New-Object -ComObject WScript.Shell
Write-Host "The script has started and is keeping the desktop active..." -ForegroundColor Green
Write-Host "Press Ctrl+C or close the window to stop." -ForegroundColor Yellow

while($true) {
    $shell.SendKeys('{SCROLLLOCK}')
    Start-Sleep -Seconds 60
}