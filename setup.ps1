Move-Item -Path "$HOME\.ssh\config" -Destination "$HOME\.ssh\config.bak" -Force
New-Item -ItemType SymbolicLink `
  -Path "$HOME\.ssh\config" `
  -Target ".\config"
