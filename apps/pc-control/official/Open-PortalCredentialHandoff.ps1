param()
$ErrorActionPreference = 'Stop'
# Manual handoff only: never find, fill or submit another program's login UI.
$workspace = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
. (Join-Path $workspace 'apps/holographic-control/ops/Holographic.Common.ps1')
$context = New-HoloAuthenticatedPortalContext
try {
    $saved = Import-Clixml -LiteralPath (Join-Path $workspace 'apps/holographic-control/.state/portal-credential.clixml')
    if ($saved.DeviceName -cne $context.Device.DeviceName -or
        $saved.SshFingerprint -cne $context.Device.HostFingerprint -or
        $saved.PublicKeySha256 -cne $context.PublicKeySha256) {
        throw 'Saved credential identity mismatch.'
    }
    $deviceAddress = $context.Device.Address
} finally { $context.Client.Dispose() }
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$form = [Windows.Forms.Form]::new()
$form.Text = '官方眼镜测试 · 手工登录'
$form.ClientSize = [Drawing.Size]::new(540,250)
$form.StartPosition = 'CenterScreen'
$form.TopMost = $true
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.Font = [Drawing.Font]::new('Microsoft YaHei UI',10)
$label = [Windows.Forms.Label]::new()
$label.Location = [Drawing.Point]::new(18,15)
$label.Size = [Drawing.Size]::new(504,70)
$label.Text = "目标：$($saved.DeviceName) / $deviceAddress`r`n在微软 Perception Simulation Control 登录框手工粘贴。`r`n这是已保存的门户账号，不是眼镜开机 PIN。"
$form.Controls.Add($label)
$account = [Windows.Forms.TextBox]::new()
$account.Location = [Drawing.Point]::new(18,92)
$account.Size = [Drawing.Size]::new(504,28)
$account.Text = $saved.Credential.UserName
$account.ReadOnly = $true
$form.Controls.Add($account)
$copyAccount = [Windows.Forms.Button]::new()
$copyAccount.Location = [Drawing.Point]::new(18,134)
$copyAccount.Size = [Drawing.Size]::new(150,36)
$copyAccount.Text = '1. 复制用户名'
$form.Controls.Add($copyAccount)
$copyPassword = [Windows.Forms.Button]::new()
$copyPassword.Location = [Drawing.Point]::new(182,134)
$copyPassword.Size = [Drawing.Size]::new(150,36)
$copyPassword.Text = '2. 复制密码'
$form.Controls.Add($copyPassword)
$close = [Windows.Forms.Button]::new()
$close.Location = [Drawing.Point]::new(346,134)
$close.Size = [Drawing.Size]::new(176,36)
$close.Text = '登录后关闭此窗口'
$form.Controls.Add($close)
$status = [Windows.Forms.Label]::new()
$status.Location = [Drawing.Point]::new(18,190)
$status.Size = [Drawing.Size]::new(504,45)
$status.Text = '密码不会显示、输出到终端或保存为明文；复制后 30 秒清除。'
$form.Controls.Add($status)
$script:handoffCopied = $null
$timer = [Windows.Forms.Timer]::new()
$timer.Interval = 30000
function Clear-HandoffClipboard {
    $timer.Stop()
    try {
        if ($null -ne $script:handoffCopied -and [Windows.Forms.Clipboard]::ContainsText() -and
            [Windows.Forms.Clipboard]::GetText() -ceq $script:handoffCopied) {
            [Windows.Forms.Clipboard]::Clear()
        }
    } finally { $script:handoffCopied = $null }
}
$copyAccount.Add_Click({
    Clear-HandoffClipboard
    [Windows.Forms.Clipboard]::SetText($saved.Credential.UserName)
    $status.Text = '用户名已复制。请手工粘贴到微软官方登录框的用户名栏。'
})
$copyPassword.Add_Click({
    Clear-HandoffClipboard
    $script:handoffCopied = $saved.Credential.GetNetworkCredential().Password
    [Windows.Forms.Clipboard]::SetText($script:handoffCopied)
    $timer.Start()
    $status.Text = '密码已复制，30 秒后清除。请手工粘贴密码并点击官方登录框的确定。'
})
$timer.Add_Tick({ Clear-HandoffClipboard; $status.Text = '本窗口复制的密码已从剪贴板清除。需要时可重新复制。' })
$close.Add_Click({ $form.Close() })
$form.Add_FormClosed({ Clear-HandoffClipboard; $timer.Dispose() })
try { [Windows.Forms.Application]::Run($form) } finally { $saved = $null; $form.Dispose() }
