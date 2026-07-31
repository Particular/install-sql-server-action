@{
    RootModule        = 'WslTools.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890'
    Author            = 'install-sql-server-action'
    CompanyName       = 'Particular Software'
    Copyright         = '(c) install-sql-server-action. All rights reserved.'
    Description       = 'WSL helper functions for the install-sql-server-action GitHub Action.'
    PowerShellVersion = '7.0'
    FunctionsToExport = @('Invoke-Wsl', 'ConvertTo-WslPath')
    FileList          = @('WslTools.psm1')
}
