Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Must run before ANY WinForms Control is created on this thread - .NET
# throws "Thread exception mode cannot be changed once any Controls are
# created" if called later. This was previously placed right before
# ShowDialog() at the very end of the script (after every control in the
# whole app had already been created), so it silently failed on every single
# launch all session - the "global safety net" documented elsewhere in this
# file was never actually active. Moved here, and EnableVisualStyles has the
# same "must run first" requirement so it comes along with it.
[System.Windows.Forms.Application]::EnableVisualStyles()
try {
    [System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
} catch {}
[System.Windows.Forms.Application]::add_ThreadException({
    param($src, $e)
    try { Hide-Loading } catch {}
    try { Set-Status "Something went wrong: $($e.Exception.Message)" } catch {}
})

$llmfit = Join-Path $env:USERPROFILE "scoop\shims\llmfit.exe"
if (-not (Test-Path $llmfit)) {
    [System.Windows.Forms.MessageBox]::Show("Could not find llmfit.exe at:`n$llmfit`n`nPlease reinstall it with: scoop install llmfit", "LLM Fit GUI", "OK", "Error") | Out-Null
    exit
}

# Optional download targets - the app still works fully without these, the
# corresponding download options are just disabled if not found.
$lmStudioExe = Join-Path $env:USERPROFILE ".lmstudio\bin\lms.exe"
$hasLmStudio = Test-Path $lmStudioExe
$ollamaCmd = Get-Command ollama.exe -ErrorAction SilentlyContinue
$hasOllama = $null -ne $ollamaCmd
$ollamaExe = if ($hasOllama) { $ollamaCmd.Source } else { $null }

# ---------- Hugging Face token ----------
# An anonymous connection to huggingface.co gets a lower, shared rate limit;
# a free HF account token raises that limit and can improve download
# speed/stability (the app already saw real HF download timeouts this
# session). This is the SAME file path huggingface_hub's Python library and
# Rust's hf-hub crate (what llmfit itself is built on) both already read by
# convention, so saving here benefits llmfit's own downloads too, not just
# this app's own Hugging Face API calls - and any token already saved there
# by another HF tool on this machine is picked up automatically.
function Get-HfTokenPath { return (Join-Path $env:USERPROFILE ".cache\huggingface\token") }

function Get-SavedHfToken {
    $path = Get-HfTokenPath
    if (Test-Path $path) {
        try { return (Get-Content $path -Raw -ErrorAction Stop).Trim() } catch { return $null }
    }
    return $null
}

function Set-HfToken([string]$token) {
    $path = Get-HfTokenPath
    $dir = Split-Path $path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Set-Content -Path $path -Value $token -NoNewline
    $env:HF_TOKEN = $token
    $script:hfToken = $token
}

function Clear-HfToken {
    $path = Get-HfTokenPath
    if (Test-Path $path) { Remove-Item $path -Force -ErrorAction SilentlyContinue }
    $env:HF_TOKEN = $null
    $script:hfToken = $null
}

# Setting $env:HF_TOKEN here means every child process this script launches
# (llmfit.exe, lms.exe) inherits it automatically - Start-Process passes the
# current environment down to children by default.
$script:hfToken = Get-SavedHfToken
if ($script:hfToken) { $env:HF_TOKEN = $script:hfToken }

function C([int]$r, [int]$g, [int]$b) { [System.Drawing.Color]::FromArgb($r, $g, $b) }

$themes = @{
    Light = @{
        FormBg        = C 243 244 246
        PanelBg       = C 255 255 255
        HeaderBg      = C 30 41 59
        HeaderTitle   = C 255 255 255
        HeaderSub     = C 148 163 184
        Border        = C 214 217 223
        Accent        = C 37 99 235
        AccentHover   = C 29 78 216
        AccentText    = C 255 255 255
        NeutralBtn    = C 229 231 235
        NeutralHover  = C 209 213 219
        NeutralTxt    = C 31 41 55
        StatusTxt     = C 107 114 128
        Label         = C 75 85 99
        Hint          = C 176 176 176
        RowAlt        = C 248 249 251
        Selection     = C 219 234 254
        SelectionTxt  = C 30 58 138
        InputBg       = C 255 255 255
        InputTxt      = C 17 24 39
        GridTxt       = C 31 41 55
        FitPerfect    = C 21 128 61
        FitGood       = C 180 130 0
        FitOther      = C 120 53 15
    }
    Dark = @{
        FormBg        = C 17 24 39
        PanelBg       = C 30 41 59
        HeaderBg      = C 15 23 42
        HeaderTitle   = C 255 255 255
        HeaderSub     = C 148 163 184
        Border        = C 51 65 85
        Accent        = C 59 130 246
        AccentHover   = C 96 165 250
        AccentText    = C 255 255 255
        NeutralBtn    = C 51 65 85
        NeutralHover  = C 71 85 105
        NeutralTxt    = C 226 232 240
        StatusTxt     = C 148 163 184
        Label         = C 148 163 184
        Hint          = C 100 116 139
        RowAlt        = C 38 50 71
        Selection     = C 30 64 175
        SelectionTxt  = C 255 255 255
        InputBg       = C 51 65 85
        InputTxt      = C 241 245 249
        GridTxt       = C 226 232 240
        FitPerfect    = C 74 222 128
        FitGood       = C 250 204 21
        FitOther      = C 251 146 60
    }
}
$script:themeName = "Dark"
function Get-Theme { $themes[$script:themeName] }

$fontBase  = New-Object System.Drawing.Font("Segoe UI", 9.25)
$fontTitle = New-Object System.Drawing.Font("Segoe UI Semibold", 15)
$fontSub   = New-Object System.Drawing.Font("Segoe UI", 9)
$fontLbl   = New-Object System.Drawing.Font("Segoe UI", 8.25)
$fontBtn   = New-Object System.Drawing.Font("Segoe UI Semibold", 9)
$fontFit   = New-Object System.Drawing.Font("Segoe UI Semibold", 9)

$script:fieldLabels = New-Object System.Collections.Generic.List[object]
$script:themedButtons = New-Object System.Collections.Generic.List[object]

function Style-Button($btn, [bool]$primary) {
    $t = Get-Theme
    $btn.FlatStyle = "Flat"
    $btn.FlatAppearance.BorderSize = 0
    $btn.Font = $fontBtn
    $btn.Cursor = [System.Windows.Forms.Cursors]::Hand
    if ($primary) {
        $btn.BackColor = $t.Accent
        $btn.ForeColor = $t.AccentText
        $btn.FlatAppearance.MouseOverBackColor = $t.AccentHover
    } else {
        $btn.BackColor = $t.NeutralBtn
        $btn.ForeColor = $t.NeutralTxt
        $btn.FlatAppearance.MouseOverBackColor = $t.NeutralHover
    }
    if (-not ($script:themedButtons | Where-Object { $_.Btn -eq $btn })) {
        $script:themedButtons.Add([pscustomobject]@{ Btn = $btn; Primary = $primary })
    }
}

# ---------- Main Form ----------
$form = New-Object System.Windows.Forms.Form
$form.Text = "LLM Fit - Find AI Models for Your PC"
$form.Size = New-Object System.Drawing.Size(1220, 740)
$form.StartPosition = "CenterScreen"
$form.MinimumSize = New-Object System.Drawing.Size(960, 520)
$form.Font = $fontBase
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None

# ---------- Header ----------
$pnlHeader = New-Object System.Windows.Forms.Panel
$pnlHeader.Dock = "Top"
$pnlHeader.Height = 100
$form.Controls.Add($pnlHeader)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = "LLM Fit"
$lblTitle.Font = $fontTitle
$lblTitle.Location = New-Object System.Drawing.Point(18, 8)
$lblTitle.Size = New-Object System.Drawing.Size(300, 28)
$pnlHeader.Controls.Add($lblTitle)

$lblHardware = New-Object System.Windows.Forms.Label
$lblHardware.Location = New-Object System.Drawing.Point(20, 38)
$lblHardware.Size = New-Object System.Drawing.Size(1000, 22)
$lblHardware.Text = "Detecting your hardware..."
$lblHardware.Font = $fontSub
$pnlHeader.Controls.Add($lblHardware)

$fontCredits = New-Object System.Drawing.Font("Segoe UI", 7.5)

$lblCredits1 = New-Object System.Windows.Forms.Label
$lblCredits1.Location = New-Object System.Drawing.Point(20, 62)
$lblCredits1.Size = New-Object System.Drawing.Size(1000, 16)
$lblCredits1.Text = "Built by Claude (Anthropic) for Ryan (raiyyan729@gmail.com) - the first time Claude did me something useful."
$lblCredits1.Font = $fontCredits
$pnlHeader.Controls.Add($lblCredits1)

$lnkCredits2 = New-Object System.Windows.Forms.LinkLabel
$lnkCredits2.Location = New-Object System.Drawing.Point(20, 78)
$lnkCredits2.Size = New-Object System.Drawing.Size(1000, 16)
$creditsLinkText = "github.com/AlexsJones/llmfit"
$lnkCredits2.Text = "Model data powered by llmfit, created by AlexsJones - $creditsLinkText"
$lnkCredits2.Font = $fontCredits
$linkStart = $lnkCredits2.Text.IndexOf($creditsLinkText)
$lnkCredits2.LinkArea = New-Object System.Windows.Forms.LinkArea($linkStart, $creditsLinkText.Length)
$lnkCredits2.Add_LinkClicked({ Start-Process "https://github.com/AlexsJones/llmfit" })
$pnlHeader.Controls.Add($lnkCredits2)

$btnTheme = New-Object System.Windows.Forms.Button
$btnTheme.Text = "Light Mode"
$btnTheme.Location = New-Object System.Drawing.Point(1090, 17)
$btnTheme.Size = New-Object System.Drawing.Size(110, 32)
Style-Button $btnTheme $false
$pnlHeader.Controls.Add($btnTheme)

$btnHfToken = New-Object System.Windows.Forms.Button
$btnHfToken.Text = "HF Token..."
$btnHfToken.Location = New-Object System.Drawing.Point(1090, 55)
$btnHfToken.Size = New-Object System.Drawing.Size(110, 32)
Style-Button $btnHfToken $false
$pnlHeader.Controls.Add($btnHfToken)

# ---------- Filter panel ----------
$pnlFilters = New-Object System.Windows.Forms.Panel
$pnlFilters.Dock = "Top"
$pnlFilters.Height = 195
$form.Controls.Add($pnlFilters)

$pnlFiltersBorder = New-Object System.Windows.Forms.Panel
$pnlFiltersBorder.Dock = "Top"
$pnlFiltersBorder.Height = 1
$form.Controls.Add($pnlFiltersBorder)

function New-FieldLabel([string]$text, [int]$x, [int]$y = 12) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text
    $l.AutoSize = $true
    $l.Location = New-Object System.Drawing.Point($x, $y)
    $l.Font = $fontLbl
    $pnlFilters.Controls.Add($l)
    $script:fieldLabels.Add($l)
    return $l
}

function Add-ThemedComboDraw($cmb) {
    $cmb.DrawMode = "OwnerDrawFixed"
    $cmb.ItemHeight = 18
    $cmb.Add_DrawItem({
        param($src, $e)
        $t = Get-Theme
        $isSelected = ($e.State -band [System.Windows.Forms.DrawItemState]::Selected) -ne 0
        $bg = if ($isSelected) { $t.Selection } else { $t.InputBg }
        $fg = if ($isSelected) { $t.SelectionTxt } else { $t.InputTxt }
        $brush = New-Object System.Drawing.SolidBrush($bg)
        $e.Graphics.FillRectangle($brush, $e.Bounds)
        $brush.Dispose()
        if ($e.Index -ge 0) {
            $text = $src.Items[$e.Index].ToString()
            $textBrush = New-Object System.Drawing.SolidBrush($fg)
            $e.Graphics.DrawString($text, $e.Font, $textBrush, [float]($e.Bounds.X + 3), [float]($e.Bounds.Y + 1))
            $textBrush.Dispose()
        }
    })
}

New-FieldLabel "USE CASE" 20 | Out-Null
$cmbUseCase = New-Object System.Windows.Forms.ComboBox
$cmbUseCase.Location = New-Object System.Drawing.Point(20, 30)
$cmbUseCase.Size = New-Object System.Drawing.Size(140, 24)
$cmbUseCase.DropDownStyle = "DropDownList"
[void]$cmbUseCase.Items.AddRange(@("(any)", "general", "coding", "chat", "reasoning", "multimodal", "embedding"))
$cmbUseCase.SelectedIndex = 0
Add-ThemedComboDraw $cmbUseCase
$pnlFilters.Controls.Add($cmbUseCase)

New-FieldLabel "MINIMUM FIT" 175 | Out-Null
$cmbMinFit = New-Object System.Windows.Forms.ComboBox
$cmbMinFit.Location = New-Object System.Drawing.Point(175, 30)
$cmbMinFit.Size = New-Object System.Drawing.Size(110, 24)
$cmbMinFit.DropDownStyle = "DropDownList"
[void]$cmbMinFit.Items.AddRange(@("marginal", "good", "perfect"))
$cmbMinFit.SelectedIndex = 0
Add-ThemedComboDraw $cmbMinFit
$pnlFilters.Controls.Add($cmbMinFit)

New-FieldLabel "RUNTIME" 300 | Out-Null
$cmbRuntime = New-Object System.Windows.Forms.ComboBox
$cmbRuntime.Location = New-Object System.Drawing.Point(300, 30)
$cmbRuntime.Size = New-Object System.Drawing.Size(100, 24)
$cmbRuntime.DropDownStyle = "DropDownList"
[void]$cmbRuntime.Items.AddRange(@("any", "llamacpp", "mlx"))
$cmbRuntime.SelectedIndex = 0
Add-ThemedComboDraw $cmbRuntime
$pnlFilters.Controls.Add($cmbRuntime)

New-FieldLabel "RESULT CAP" 415 | Out-Null
$numLimit = New-Object System.Windows.Forms.NumericUpDown
$numLimit.Location = New-Object System.Drawing.Point(415, 30)
$numLimit.Size = New-Object System.Drawing.Size(65, 24)
$numLimit.Minimum = 5
$numLimit.Maximum = 10000
$numLimit.Increment = 50
$numLimit.Value = 20
$numLimit.Enabled = $false
$pnlFilters.Controls.Add($numLimit)

$chkShowAll = New-Object System.Windows.Forms.CheckBox
$chkShowAll.Text = "Show ALL matches"
$chkShowAll.Location = New-Object System.Drawing.Point(415, 58)
$chkShowAll.Size = New-Object System.Drawing.Size(140, 20)
$chkShowAll.Checked = $true
$chkShowAll.Add_CheckedChanged({ $numLimit.Enabled = -not $chkShowAll.Checked })
$pnlFilters.Controls.Add($chkShowAll)
$script:fieldLabels.Add($chkShowAll)

New-FieldLabel "SEARCH" 570 | Out-Null
$txtSearch = New-Object System.Windows.Forms.TextBox
$txtSearch.Location = New-Object System.Drawing.Point(570, 30)
$txtSearch.Size = New-Object System.Drawing.Size(190, 24)
$txtSearch.BorderStyle = "FixedSingle"
$pnlFilters.Controls.Add($txtSearch)

$lblSearchHint = New-Object System.Windows.Forms.Label
$lblSearchHint.Text = "matches name, use case or category - press Enter"
$lblSearchHint.Location = New-Object System.Drawing.Point(570, 58)
$lblSearchHint.Size = New-Object System.Drawing.Size(260, 16)
$lblSearchHint.Font = New-Object System.Drawing.Font("Segoe UI", 7.5)
$pnlFilters.Controls.Add($lblSearchHint)

$btnSearch = New-Object System.Windows.Forms.Button
$btnSearch.Text = "Search"
$btnSearch.Location = New-Object System.Drawing.Point(775, 29)
$btnSearch.Size = New-Object System.Drawing.Size(90, 27)
Style-Button $btnSearch $true
$pnlFilters.Controls.Add($btnSearch)

$btnRefreshHw = New-Object System.Windows.Forms.Button
$btnRefreshHw.Text = "Re-scan HW"
$btnRefreshHw.Location = New-Object System.Drawing.Point(875, 29)
$btnRefreshHw.Size = New-Object System.Drawing.Size(100, 27)
Style-Button $btnRefreshHw $false
$pnlFilters.Controls.Add($btnRefreshHw)

New-FieldLabel "SORT BY" 990 | Out-Null
$cmbSort = New-Object System.Windows.Forms.ComboBox
$cmbSort.Location = New-Object System.Drawing.Point(990, 30)
$cmbSort.Size = New-Object System.Drawing.Size(110, 24)
$cmbSort.DropDownStyle = "DropDownList"
[void]$cmbSort.Items.AddRange(@("Score", "Speed", "Fit", "Params", "Name", "Provider", "Category", "Context", "Size"))
$cmbSort.SelectedIndex = 0
Add-ThemedComboDraw $cmbSort
$pnlFilters.Controls.Add($cmbSort)

$chkSortDesc = New-Object System.Windows.Forms.CheckBox
$chkSortDesc.Text = "Descending"
$chkSortDesc.Location = New-Object System.Drawing.Point(990, 58)
$chkSortDesc.Size = New-Object System.Drawing.Size(100, 20)
$chkSortDesc.Checked = $true
$pnlFilters.Controls.Add($chkSortDesc)
$script:fieldLabels.Add($chkSortDesc)

# ---------- Advanced search row ----------
New-FieldLabel "CAPABILITY" 20 95 | Out-Null
$chkCapVision = New-Object System.Windows.Forms.CheckBox
$chkCapVision.Text = "Vision"
$chkCapVision.Location = New-Object System.Drawing.Point(20, 113)
$chkCapVision.Size = New-Object System.Drawing.Size(65, 20)
$pnlFilters.Controls.Add($chkCapVision)
$script:fieldLabels.Add($chkCapVision)

$chkCapTool = New-Object System.Windows.Forms.CheckBox
$chkCapTool.Text = "Tool Use"
$chkCapTool.Location = New-Object System.Drawing.Point(85, 113)
$chkCapTool.Size = New-Object System.Drawing.Size(80, 20)
$pnlFilters.Controls.Add($chkCapTool)
$script:fieldLabels.Add($chkCapTool)

$chkCapAudio = New-Object System.Windows.Forms.CheckBox
$chkCapAudio.Text = "Audio"
$chkCapAudio.Location = New-Object System.Drawing.Point(165, 113)
$chkCapAudio.Size = New-Object System.Drawing.Size(60, 20)
$pnlFilters.Controls.Add($chkCapAudio)
$script:fieldLabels.Add($chkCapAudio)

$chkCapTts = New-Object System.Windows.Forms.CheckBox
$chkCapTts.Text = "TTS"
$chkCapTts.Location = New-Object System.Drawing.Point(225, 113)
$chkCapTts.Size = New-Object System.Drawing.Size(55, 20)
$pnlFilters.Controls.Add($chkCapTts)
$script:fieldLabels.Add($chkCapTts)

New-FieldLabel "LICENSE (comma-separated)" 300 95 | Out-Null
$txtLicense = New-Object System.Windows.Forms.TextBox
$txtLicense.Location = New-Object System.Drawing.Point(300, 113)
$txtLicense.Size = New-Object System.Drawing.Size(170, 24)
$txtLicense.BorderStyle = "FixedSingle"
$pnlFilters.Controls.Add($txtLicense)

New-FieldLabel "FORCE RUNTIME" 485 95 | Out-Null
$cmbForceRuntime = New-Object System.Windows.Forms.ComboBox
$cmbForceRuntime.Location = New-Object System.Drawing.Point(485, 113)
$cmbForceRuntime.Size = New-Object System.Drawing.Size(100, 24)
$cmbForceRuntime.DropDownStyle = "DropDownList"
[void]$cmbForceRuntime.Items.AddRange(@("(none)", "mlx", "llamacpp"))
$cmbForceRuntime.SelectedIndex = 0
Add-ThemedComboDraw $cmbForceRuntime
$pnlFilters.Controls.Add($cmbForceRuntime)

New-FieldLabel "MIN PARAMS (B)" 600 95 | Out-Null
$numMinParams = New-Object System.Windows.Forms.NumericUpDown
$numMinParams.Location = New-Object System.Drawing.Point(600, 113)
$numMinParams.Size = New-Object System.Drawing.Size(60, 24)
$numMinParams.Minimum = 0
$numMinParams.Maximum = 2000
$numMinParams.Value = 0
$pnlFilters.Controls.Add($numMinParams)

New-FieldLabel "MAX PARAMS (B)" 715 95 | Out-Null
$numMaxParams = New-Object System.Windows.Forms.NumericUpDown
$numMaxParams.Location = New-Object System.Drawing.Point(715, 113)
$numMaxParams.Size = New-Object System.Drawing.Size(60, 24)
$numMaxParams.Minimum = 0
$numMaxParams.Maximum = 2000
$numMaxParams.Value = 2000
$pnlFilters.Controls.Add($numMaxParams)

$btnApplyAdvanced = New-Object System.Windows.Forms.Button
$btnApplyAdvanced.Text = "Apply Advanced"
$btnApplyAdvanced.Location = New-Object System.Drawing.Point(790, 112)
$btnApplyAdvanced.Size = New-Object System.Drawing.Size(120, 27)
Style-Button $btnApplyAdvanced $false
$pnlFilters.Controls.Add($btnApplyAdvanced)

$btnClearAdvanced = New-Object System.Windows.Forms.Button
$btnClearAdvanced.Text = "Clear Advanced"
$btnClearAdvanced.Location = New-Object System.Drawing.Point(915, 112)
$btnClearAdvanced.Size = New-Object System.Drawing.Size(120, 27)
Style-Button $btnClearAdvanced $false
$pnlFilters.Controls.Add($btnClearAdvanced)

# ---------- Score weighting row ----------
# llmfit's own "Score" column treats quality/speed/fit/context as fixed,
# opaque weights baked into the binary. These four boxes let the user pick
# their own weights instead; the grid's Score column and Score sort are
# always the resulting custom blend, recomputed instantly client-side from
# each model's score_components (no llmfit re-scan needed).
New-FieldLabel "SCORE WEIGHTS (%) - QUALITY / SPEED / FIT / CONTEXT" 20 140 | Out-Null

$numWeightQuality = New-Object System.Windows.Forms.NumericUpDown
$numWeightQuality.Location = New-Object System.Drawing.Point(20, 158)
$numWeightQuality.Size = New-Object System.Drawing.Size(55, 24)
$numWeightQuality.Minimum = 0
$numWeightQuality.Maximum = 100
$numWeightQuality.Value = 40
$pnlFilters.Controls.Add($numWeightQuality)

$numWeightSpeed = New-Object System.Windows.Forms.NumericUpDown
$numWeightSpeed.Location = New-Object System.Drawing.Point(85, 158)
$numWeightSpeed.Size = New-Object System.Drawing.Size(55, 24)
$numWeightSpeed.Minimum = 0
$numWeightSpeed.Maximum = 100
$numWeightSpeed.Value = 30
$pnlFilters.Controls.Add($numWeightSpeed)

$numWeightFit = New-Object System.Windows.Forms.NumericUpDown
$numWeightFit.Location = New-Object System.Drawing.Point(150, 158)
$numWeightFit.Size = New-Object System.Drawing.Size(55, 24)
$numWeightFit.Minimum = 0
$numWeightFit.Maximum = 100
$numWeightFit.Value = 20
$pnlFilters.Controls.Add($numWeightFit)

$numWeightContext = New-Object System.Windows.Forms.NumericUpDown
$numWeightContext.Location = New-Object System.Drawing.Point(215, 158)
$numWeightContext.Size = New-Object System.Drawing.Size(55, 24)
$numWeightContext.Minimum = 0
$numWeightContext.Maximum = 100
$numWeightContext.Value = 10
$pnlFilters.Controls.Add($numWeightContext)

$lblWeightHint = New-Object System.Windows.Forms.Label
$lblWeightHint.Text = "weights don't need to add to 100 - they're auto-normalized"
$lblWeightHint.Location = New-Object System.Drawing.Point(280, 162)
$lblWeightHint.Size = New-Object System.Drawing.Size(280, 16)
$lblWeightHint.Font = New-Object System.Drawing.Font("Segoe UI", 7.5)
$pnlFilters.Controls.Add($lblWeightHint)
$script:fieldLabels.Add($lblWeightHint)

$btnResetWeights = New-Object System.Windows.Forms.Button
$btnResetWeights.Text = "Reset Weights"
$btnResetWeights.Location = New-Object System.Drawing.Point(570, 156)
$btnResetWeights.Size = New-Object System.Drawing.Size(120, 27)
Style-Button $btnResetWeights $false
$pnlFilters.Controls.Add($btnResetWeights)

# ---------- Results grid ----------
# NOTE: WinForms has a real, reproducible bug in this environment where a
# panel/header row squashes to zero height whenever it sits INSIDE a
# Dock="Fill" wrapper alongside a Dock="Fill" DataGridView - regardless of
# z-order, BringToFront, or any DataGridView header property. Confirmed via
# isolated repro. Workaround: the custom header bar lives as a plain
# top-level sibling of the grid wrapper (same pattern as the header/filter
# bars above, which have rendered correctly in every test) instead of being
# nested with the grid.
$pnlColHeader = New-Object System.Windows.Forms.Panel
$pnlColHeader.Dock = "Top"
$pnlColHeader.Height = 32
$pnlColHeader.Padding = New-Object System.Windows.Forms.Padding(16, 0, 16, 0)
$form.Controls.Add($pnlColHeader)

$pnlGridWrap = New-Object System.Windows.Forms.Panel
$pnlGridWrap.Dock = "Fill"
$pnlGridWrap.Padding = New-Object System.Windows.Forms.Padding(16, 8, 16, 0)
$form.Controls.Add($pnlGridWrap)

$grid = New-Object System.Windows.Forms.DataGridView
$grid.Dock = "Fill"
$grid.BorderStyle = "None"
$grid.CellBorderStyle = "SingleHorizontal"
$grid.ReadOnly = $true
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.AllowUserToResizeRows = $false
$grid.RowHeadersVisible = $false
$grid.ColumnHeadersVisible = $false
$grid.SelectionMode = "FullRowSelect"
$grid.MultiSelect = $false
$grid.AutoSizeColumnsMode = "Fill"
$grid.RowTemplate.Height = 27
$grid.DefaultCellStyle.Padding = New-Object System.Windows.Forms.Padding(4, 0, 4, 0)

$columnDefs = @(
    @{Name="Model";     Width=260; Label="Model";    Sort="Name"},
    @{Name="Provider";  Width=100; Label="Provider";  Sort="Provider"},
    @{Name="Params";    Width=70;  Label="Params";    Sort="Params"},
    @{Name="Fit";       Width=70;  Label="Fit";       Sort="Fit"},
    @{Name="tok/s";     Width=60;  Label="tok/s";     Sort="Speed"},
    @{Name="Score";     Width=55;  Label="Score";     Sort="Score"},
    @{Name="Quant";     Width=80;  Label="Quant";     Sort=$null},
    @{Name="Runtime";   Width=75;  Label="Runtime";   Sort=$null},
    @{Name="Category";  Width=90;  Label="Category";  Sort="Category"},
    @{Name="SizeGB";    Width=60;  Label="SizeGB";    Sort="Size"},
    @{Name="Context";   Width=90;  Label="Context";   Sort="Context"}
)

$script:headerLabels = @{}

# Which column is currently being cycled by repeated header clicks, and
# which of its 3 phases it's on (0=Ascending, 1=None/reset, 2=Descending) -
# tracked separately from $cmbSort/$chkSortDesc so "None" can mean "no
# header is highlighted" even though the combo box still needs to sit on
# SOME real value (defaults back to the original launch default,
# Score/Descending) underneath it. Clicking a DIFFERENT header always
# restarts that column's own cycle at Ascending. This doubles as the "reset
# sorting" the user asked for - clicking the active header 3 times returns
# to the default with no extra button needed.
$script:sortCycleField = $null
$script:sortCyclePhase = 0
$script:suppressCycleClear = $false

function Set-SortColumn([string]$field) {
    if (-not $field) { return }
    if ($script:sortCycleField -eq $field) {
        $script:sortCyclePhase = ($script:sortCyclePhase + 1) % 3
    } else {
        $script:sortCycleField = $field
        $script:sortCyclePhase = 0
    }
    # Set-SortColumn drives $cmbSort/$chkSortDesc itself, which raises their
    # own change events same as a direct user click would - this flag tells
    # those handlers "this change came from the cycle logic, don't clear
    # what you just set."
    $script:suppressCycleClear = $true
    switch ($script:sortCyclePhase) {
        0 { $cmbSort.SelectedItem = $field; $chkSortDesc.Checked = $false }
        1 { $cmbSort.SelectedItem = "Score"; $chkSortDesc.Checked = $true }
        2 { $cmbSort.SelectedItem = $field; $chkSortDesc.Checked = $true }
    }
    $script:suppressCycleClear = $false
    # Clicking the "Score" column specifically can leave both $cmbSort and
    # $chkSortDesc holding the exact same values between two different
    # phases (its "None" default IS Score/Descending, same as its own
    # Descending phase) - WinForms only raises a change event when a value
    # actually differs, so that transition would silently not re-render if
    # this relied only on those events. Calling it directly here guarantees
    # every phase change is reflected regardless.
    Render-Grid
}

# Any DIRECT use of the Sort By dropdown or Descending checkbox (as opposed
# to a header click) is its own deliberate choice, not part of a header's
# ascend/none/descend cycle - drop the cycle tracking so the header
# indicator correctly shows an arrow on whatever they just picked instead
# of silently treating it as still "mid-cycle" on a different column.
function Clear-SortCycle {
    if ($script:suppressCycleClear) { return }
    $script:sortCycleField = $null
    $script:sortCyclePhase = 0
}

foreach ($col in $columnDefs) {
    $c = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $c.Name = $col.Name
    $c.HeaderText = $col.Label
    $c.FillWeight = $col.Width
    [void]$grid.Columns.Add($c)

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $col.Label
    $lbl.TextAlign = "MiddleLeft"
    $lbl.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 9)
    $lbl.Tag = $col.Sort
    if ($col.Sort) {
        $lbl.Cursor = [System.Windows.Forms.Cursors]::Hand
        $lbl.Add_Click({ param($s, $e) Set-SortColumn $s.Tag })
    }
    $pnlColHeader.Controls.Add($lbl)
    $script:headerLabels[$col.Name] = $lbl
}
$pnlGridWrap.Controls.Add($grid)

function Sync-HeaderLabels {
    try {
        # pnlColHeader is a separate top-level panel from pnlGridWrap, so we
        # manually match its own left padding to keep columns lined up with
        # the grid below (non-Dock children don't auto-respect Padding).
        $x = [int]$pnlColHeader.Padding.Left - 2
        foreach ($col in $grid.Columns) {
            $lbl = $script:headerLabels[$col.Name]
            if ($lbl) {
                $lbl.Location = New-Object System.Drawing.Point ([int]$x), 0
                $lbl.Size = New-Object System.Drawing.Size ([int]$col.Width), ([int]$pnlColHeader.Height)
            }
            $x += $col.Width
        }
    } catch {
        # layout hiccup - not worth crashing over
    }
}
$grid.Add_Resize({ Sync-HeaderLabels })
$grid.Add_ColumnWidthChanged({ Sync-HeaderLabels })

# Clicking a column header or changing Sort By used to have no visible
# effect on the header row itself - the only feedback was the row order
# changing, which isn't obvious at a glance. This marks the active sort
# column with an arrow and an accent color so it's clear at a glance which
# column and direction the list is currently sorted by.
function Update-SortIndicators {
    # Only an arrow marks the active column - no color/bold change, so a
    # header cycled to "None" (phase 1) looks completely plain again with
    # nothing left highlighted, matching the reset the user asked for.
    $isNone = (-not $script:sortCycleField) -or ($script:sortCyclePhase -eq 1)
    $activeField = if ($isNone) { $null } else { $cmbSort.SelectedItem }
    # Built from raw Unicode code points rather than typing the up/down
    # triangle characters directly into this file - this .ps1 has no UTF-8
    # BOM, and
    # "powershell.exe -File" silently falls back to the system's ANSI
    # codepage for a BOM-less script file, which mangled those two
    # characters into garbage on load (confirmed live: a real user saw them
    # rendered as literal "a-"). Building the character from its code point
    # at runtime sidesteps the file's own encoding entirely.
    $upArrow = [string][char]0x25B2
    $downArrow = [string][char]0x25BC
    $arrow = if ($chkSortDesc.Checked) { " $downArrow" } else { " $upArrow" }
    foreach ($col in $columnDefs) {
        $lbl = $script:headerLabels[$col.Name]
        if (-not $lbl) { continue }
        if ($col.Sort -and $col.Sort -eq $activeField) {
            $lbl.Text = "$($col.Label)$arrow"
        } else {
            $lbl.Text = $col.Label
        }
    }
}

# Hover overlay: shows Provider / Score / Speed for the row under the cursor
$grid.ShowCellToolTips = $true
$grid.Add_CellToolTipTextNeeded({
    param($src, $e)
    if ($e.RowIndex -ge 0) {
        $row = $grid.Rows[$e.RowIndex]
        $e.ToolTipText = "Provider: $($row.Cells['Provider'].Value)   |   Score: $($row.Cells['Score'].Value)   |   Speed: $($row.Cells['tok/s'].Value) tok/s"
    }
})

# Enable double-buffering (protected property) to stop flicker/blanking on scroll
$dgvDbProp = [System.Windows.Forms.DataGridView].GetProperty("DoubleBuffered", [System.Reflection.BindingFlags]::Instance -bor [System.Reflection.BindingFlags]::NonPublic)
$dgvDbProp.SetValue($grid, $true, $null)

# Same fix for the column header panel - without it, clicking a header to
# sort visibly flickers/glitches for an instant (the label's old text gets
# erased and the new one drawn in a separate, unbuffered paint pass) right
# as Render-Grid repopulates the (potentially thousands-of-rows) grid
# underneath it. A real user reported exactly this after the arrow
# indicator was added.
$panelDbProp = [System.Windows.Forms.Panel].GetProperty("DoubleBuffered", [System.Reflection.BindingFlags]::Instance -bor [System.Reflection.BindingFlags]::NonPublic)
$panelDbProp.SetValue($pnlColHeader, $true, $null)

$grid.Add_CellFormatting({
    param($src, $e)
    if ($grid.Columns[$e.ColumnIndex].Name -eq "Fit" -and $e.Value) {
        $t = Get-Theme
        switch ($e.Value.ToString()) {
            "Perfect" { $e.CellStyle.ForeColor = $t.FitPerfect; $e.CellStyle.Font = $fontFit }
            "Good"    { $e.CellStyle.ForeColor = $t.FitGood; $e.CellStyle.Font = $fontFit }
            default   { $e.CellStyle.ForeColor = $t.FitOther }
        }
    }
})

# ---------- Footer ----------
$pnlFooterBorder = New-Object System.Windows.Forms.Panel
$pnlFooterBorder.Dock = "Bottom"
$pnlFooterBorder.Height = 1
$form.Controls.Add($pnlFooterBorder)

$pnlFooter = New-Object System.Windows.Forms.Panel
$pnlFooter.Dock = "Bottom"
$pnlFooter.Height = 58
$form.Controls.Add($pnlFooter)

$btnDetails = New-Object System.Windows.Forms.Button
$btnDetails.Text = "View Full Details"
$btnDetails.Location = New-Object System.Drawing.Point(16, 13)
$btnDetails.Size = New-Object System.Drawing.Size(150, 32)
Style-Button $btnDetails $false
$pnlFooter.Controls.Add($btnDetails)

$btnTui = New-Object System.Windows.Forms.Button
$btnTui.Text = "Open Interactive Browser (TUI)"
$btnTui.Location = New-Object System.Drawing.Point(176, 13)
$btnTui.Size = New-Object System.Drawing.Size(220, 32)
Style-Button $btnTui $false
$pnlFooter.Controls.Add($btnTui)

$btnDownload = New-Object System.Windows.Forms.Button
$btnDownload.Text = "Download Model..."
$btnDownload.Location = New-Object System.Drawing.Point(406, 13)
$btnDownload.Size = New-Object System.Drawing.Size(150, 32)
Style-Button $btnDownload $true
$pnlFooter.Controls.Add($btnDownload)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Location = New-Object System.Drawing.Point(566, 20)
$lblStatus.Size = New-Object System.Drawing.Size(600, 20)
$lblStatus.Anchor = "Bottom,Left,Right"
$lblStatus.Text = "Ready."
$pnlFooter.Controls.Add($lblStatus)

# ---------- Loading overlay ----------
$pnlLoading = New-Object System.Windows.Forms.Panel
$pnlLoading.Dock = "Fill"
$pnlLoading.Visible = $false
$form.Controls.Add($pnlLoading)

$lblLoading = New-Object System.Windows.Forms.Label
$lblLoading.AutoSize = $true
$lblLoading.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 11)
$lblLoading.Text = "Working..."
$pnlLoading.Controls.Add($lblLoading)

$prgLoading = New-Object System.Windows.Forms.ProgressBar
$prgLoading.Style = "Marquee"
$prgLoading.MarqueeAnimationSpeed = 25
$prgLoading.Size = New-Object System.Drawing.Size(320, 18)
$pnlLoading.Controls.Add($prgLoading)

function Position-LoadingControls {
    try {
        [int]$panelW = $pnlLoading.Width
        [int]$panelH = $pnlLoading.Height
        [int]$barW = $prgLoading.Width
        [int]$lblW = $lblLoading.Width

        [int]$barX = ($panelW - $barW) / 2
        [int]$barY = $panelH / 2
        [int]$lblX = ($panelW - $lblW) / 2
        [int]$lblY = $barY - 30

        $prgLoading.Location = New-Object -TypeName System.Drawing.Point -ArgumentList $barX, $barY
        $lblLoading.Location = New-Object -TypeName System.Drawing.Point -ArgumentList $lblX, $lblY
    } catch {
        # Never let a layout hiccup take down the whole app.
    }
}

$pnlLoading.Add_Resize({ Position-LoadingControls })

function Show-Loading([string]$msg) {
    $lblLoading.Text = $msg
    $pnlLoading.Visible = $true
    $pnlLoading.BringToFront()
    Position-LoadingControls
    [System.Windows.Forms.Application]::DoEvents()
}

function Hide-Loading {
    $pnlLoading.Visible = $false
}

# Runs any external command without freezing the window. Output is captured
# via temp files rather than a redirected pipe so a large response can't
# deadlock the wait loop. Returns @{ ExitCode; Output } (stdout+stderr combined).
# Pass -OnProgress to get the partial stdout+stderr text polled every ~150ms
# while the process runs (used to drive a live progress bar / tailed output).
# Strips ANSI escape/cursor codes and collapses a live terminal progress
# display (which redraws the same line over and over via carriage returns)
# down to just its most recent line, so it's readable in a plain textbox
# instead of showing raw control-character garbage.
function Get-LastCleanLine([string]$text) {
    if (-not $text) { return "" }
    $esc = [char]27
    $clean = $text -replace "$esc\[[^a-zA-Z]*[a-zA-Z]", ""
    $lines = ($clean -split "[`r`n]+") | Where-Object { $_.Trim() -ne "" }
    if ($lines.Count -eq 0) { return "" }
    return $lines[-1].Trim()
}

# Reads only the last $maxBytes of a file (default 8KB) instead of the whole
# thing. A live \r-redrawing progress display (like "lms get") appends many
# redraws per second to the redirected output file, which on a multi-gigabyte
# download grows into tens of megabytes over several minutes - re-reading
# the ENTIRE file from disk every ~150ms made each poll tick progressively
# slower (confirmed via an isolated test: 34ms at 18KB growing to 444ms at
# 1.3MB, and continuing to climb from there), which starved DoEvents() of
# any chance to run and made Cancel and even the dialog's own titlebar
# Close button appear completely unresponsive during a real download.
# Only the tail is ever needed here anyway - only the most recent line matters.
function Get-FileTail([string]$path, [long]$maxBytes = 8192) {
    try {
        $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            if ($fs.Length -gt $maxBytes) { $fs.Seek(-$maxBytes, [System.IO.SeekOrigin]::End) | Out-Null }
            $reader = New-Object System.IO.StreamReader($fs)
            return $reader.ReadToEnd()
        } finally { $fs.Dispose() }
    } catch { return "" }
}

function Invoke-ExternalCommand([string]$exePath, [string[]]$argsList, [string]$loadingMessage, [scriptblock]$onProgress = $null) {
    Show-Loading $loadingMessage
    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        $proc = Start-Process -FilePath $exePath -ArgumentList $argsList -NoNewWindow -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        $global:currentProc = $proc
        # Touching .Handle right after Start-Process forces .NET to retain a
        # process handle with the access rights needed to read ExitCode later.
        # Without this, ExitCode reads back null even on a real, successful
        # run (confirmed via a live test download in this session, and
        # reproduced with a bare cmd.exe test - it's a Start-Process -PassThru
        # quirk, not anything specific to what we're launching here). That
        # silently broke every caller's "did it succeed" check.
        [void]$proc.Handle
        $lastProgressUpdate = [DateTime]::MinValue
        while (-not $proc.HasExited -and -not $global:downloadCancelled) {
            if ($onProgress -and ([DateTime]::Now - $lastProgressUpdate).TotalMilliseconds -ge 300) {
                try {
                    $partialOut = Get-FileTail $outFile
                    $partialErr = Get-FileTail $errFile
                    $partial = @($partialOut, $partialErr) | Where-Object { $_ } | Out-String
                    if ($partial) { & $onProgress $partial }
                    $lastProgressUpdate = [DateTime]::Now
                } catch {}
            }
            # Pumps messages (Cancel clicks, the window's own Close button)
            # far more often than the old plain Start-Sleep did, since
            # WaitForExit(50) returns the instant the process exits instead
            # of always waiting out the full interval.
            [System.Windows.Forms.Application]::DoEvents()
            $proc.WaitForExit(50) | Out-Null
        }
        if ($global:downloadCancelled -and -not $proc.HasExited) {
            try { & taskkill.exe /T /F /PID $proc.Id 2>&1 | Out-Null } catch {}
            try { $proc.Kill() } catch {}
            $proc.WaitForExit(2000) | Out-Null
        }
        # HasExited can flip true slightly before .NET has actually synced the
        # real exit code internally - without this, .ExitCode reads back as
        # null even on a real, successful run (confirmed via a live test
        # download in this session), so every caller's "did it succeed" check
        # silently never fires. But this MUST be bounded: an unbounded
        # WaitForExit() pumps no messages at all (unlike the DoEvents loop
        # above), so if the process is slower to fully exit than expected
        # here, the entire dialog freezes solid - Cancel and even the
        # window's own titlebar Close button stop responding completely.
        # Confirmed live: a real "lms load" call left the whole download
        # dialog unresponsive this way, with the app sitting at 0% CPU
        # (genuinely blocked, not spinning) until forcibly killed. A few
        # seconds is more than enough for the sync this is actually waiting
        # on; if it's not done by then, proceed anyway rather than hang.
        $proc.WaitForExit(5000) | Out-Null
        $stdout = Get-Content $outFile -Raw -ErrorAction SilentlyContinue
        $stderr = Get-Content $errFile -Raw -ErrorAction SilentlyContinue
        $combined = @($stdout, $stderr) | Where-Object { $_ } | Out-String
        return @{ ExitCode = $proc.ExitCode; Output = $combined; StdOut = $stdout; StdErr = $stderr }
    } finally {
        $global:currentProc = $null
        Remove-Item $outFile, $errFile -Force -ErrorAction SilentlyContinue
        Hide-Loading
    }
}

# Downloads over the network (lms get / ollama pull / llmfit download) can
# fail with a transient timeout that a plain retry fixes - confirmed live in
# this session, where the same "lms get" command failed twice with
# "Timed-out. Please try to resume" (the suggested resume didn't actually
# resume - it restarted from 0%) and then succeeded outright on a third try.
# This retries automatically up to $maxAttempts times, but only for failures
# that look transient - a permanent failure (model genuinely doesn't exist,
# no permission) is reported immediately instead of wasting the user's time
# retrying something that can't succeed.
function Invoke-ExternalCommandWithRetry([string]$exePath, [string[]]$argsList, [string]$baseMessage, [scriptblock]$onProgress = $null, [int]$maxAttempts = 3) {
    $permanentPatterns = @("does not exist", "permission", "not found", "no model found")
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        $msg = if ($attempt -eq 1) { $baseMessage } else { "$baseMessage (retry $attempt of $maxAttempts - previous attempt hit a transient error)" }
        $result = Invoke-ExternalCommand $exePath $argsList $msg $onProgress
        if ($result.ExitCode -eq 0) { return $result }
        if ($global:downloadCancelled) { return $result }

        $lastLine = Get-LastCleanLine $result.Output
        $isPermanent = $false
        foreach ($p in $permanentPatterns) {
            if ($lastLine -match [regex]::Escape($p)) { $isPermanent = $true; break }
        }
        if ($isPermanent -or $attempt -eq $maxAttempts) { return $result }
    }
    return $result
}

# Runs an llmfit command without freezing the window; returns raw stdout only
# (stderr is deliberately dropped here so JSON-consuming callers don't break
# if llmfit ever writes a warning to stderr alongside valid JSON on stdout).
function Invoke-Llmfit([string[]]$argsList, [string]$loadingMessage) {
    return (Invoke-ExternalCommand $llmfit $argsList $loadingMessage).StdOut
}

# "lms load <model>" only loads the model into memory - it does NOT start
# LM Studio's local REST API server, which is a completely separate step
# ("lms server start"). Without that server actually running, "llmfit
# bench --provider auto" (and anything else trying to talk to LM Studio)
# fails with "No inference provider found. Start Ollama, vLLM, MLX, or
# llama-server first." - confirmed live: a real user downloaded and loaded
# a model successfully through this app, then hit exactly that error on
# Benchmark, and "lms server status" on this machine confirmed the server
# genuinely wasn't running. The app never started it at any point. Calling
# this before anything that needs to actually talk to a loaded model closes
# that gap.
function Ensure-LmStudioServerRunning {
    $status = Invoke-ExternalCommand $lmStudioExe @("server", "status") "Checking if LM Studio's local server is running..."
    if ($status.Output -match "(?i)not running") {
        Invoke-ExternalCommand $lmStudioExe @("server", "start") "Starting LM Studio's local server..." | Out-Null
    }
}

# "lms get <repo>" downloads a file but doesn't hand back the short local
# identifier "lms load" needs - it only prints that identifier in some cases
# (e.g. "already downloaded"), not after a fresh download. Confirmed via a
# real download in this session that "lms ls --json" is the reliable way to
# get it back afterward: each entry's "path" contains the repo/quant we just
# downloaded, and its "modelKey" is what "lms load" actually accepts (a bare
# repo id or the full HF URL do NOT work as a load target - verified live).
function Get-LmStudioModelKey([string]$ggufRepo, [string]$quant) {
    $result = Invoke-ExternalCommand $lmStudioExe @("ls", "--json") "Looking up the downloaded model..."
    if ($result.ExitCode -ne 0 -or -not $result.StdOut) { return $null }
    try {
        $models = $result.StdOut | ConvertFrom-Json
    } catch {
        return $null
    }
    $repoName = ($ggufRepo -split "/")[-1]
    $hit = $models | Where-Object {
        $_.path -and $_.path -like "*$repoName*" -and $_.path -like "*$quant*"
    } | Select-Object -First 1
    if (-not $hit) {
        $hit = $models | Where-Object { $_.path -and $_.path -like "*$repoName*" } | Select-Object -First 1
    }
    if ($hit) { return $hit.modelKey }
    return $null
}

# llmfit's own gguf_sources list is frequently incomplete - it's a snapshot
# of what llmfit's own database has recorded, not a live check. Plenty of
# models it labels with no GGUF sources actually have one or more community
# GGUF conversions on Hugging Face (e.g. quantized by bartowski, unsloth,
# mradermacher, etc. under a different repo than the model's own page). This
# does a live Hugging Face search as a fallback when llmfit found nothing, so
# "no GGUF found" only happens when there genuinely isn't one, not just when
# llmfit's own records are stale. Runs in a background job (not the UI
# thread) so a slow/offline network doesn't freeze the window; results are
# cached per model name so repeat dialog opens don't repeat the network call.
if (-not $script:ggufFallbackCache) { $script:ggufFallbackCache = @{} }

# Strips known "this is just a format/quant variant" trailing tokens
# (repeatedly, since they can stack, e.g. "...-i1-GGUF") then normalizes to
# bare alphanumerics, so "Llama-3.2-3B-Instruct" and "Llama_3.2_3B_Instruct"
# compare equal regardless of separators/casing. Anything left over (like
# "-Coder-" or "-medical-finetuned-") is a real content difference, not a
# format difference, and will correctly fail to match.
function Get-GgufNameKey([string]$s) {
    $prev = $null
    while ($prev -ne $s) {
        $prev = $s
        $s = $s -replace '-(?i:GGUF|i1|IMat|imatrix|static|BF16|F16|F32|Q\d[\w]*)$', ''
    }
    return ($s -replace '[^a-zA-Z0-9]', '').ToLowerInvariant()
}

function Search-HuggingFaceGguf([string]$modelName, [string]$loadingMessage) {
    if ($script:ggufFallbackCache.ContainsKey($modelName)) {
        return $script:ggufFallbackCache[$modelName]
    }

    $baseName = ($modelName -split "/")[-1]
    # Strip common vLLM-style quant suffixes so the search still matches the
    # underlying base model when only a non-GGUF variant is what llmfit knew about.
    $searchTerm = $baseName -replace '-(AWQ|GPTQ[-\w]*|W4A16[-\w]*|AutoRound[-\w]*|bnb-[-\w]*|int4[-\w]*|4bit[-\w]*)$', ''
    if (-not $searchTerm) { $searchTerm = $baseName }
    $targetKey = Get-GgufNameKey $searchTerm

    Show-Loading $loadingMessage
    $job = Start-Job -ScriptBlock {
        param($term, $token)
        try {
            $headers = @{}
            if ($token) { $headers["Authorization"] = "Bearer $token" }
            $uri = "https://huggingface.co/api/models?search=$([Uri]::EscapeDataString($term))&filter=gguf&limit=15"
            Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec 15
        } catch {
            $null
        }
    } -ArgumentList $searchTerm, $script:hfToken

    try {
        $waited = 0
        while ($job.State -eq "Running" -and $waited -lt 20000) {
            Start-Sleep -Milliseconds 150
            $waited += 150
            [System.Windows.Forms.Application]::DoEvents()
        }
        $results = Receive-Job $job -ErrorAction SilentlyContinue
    } finally {
        Remove-Job $job -Force -ErrorAction SilentlyContinue
        Hide-Loading
    }

    $found = $null
    if ($results) {
        # Only accept a candidate that is the SAME model in a GGUF format/quant
        # (matched after stripping format/quant-only suffixes) - not just a
        # similarly-named different fine-tune or variant. HF's search is fuzzy
        # enough that a trusted quantizer's repo for a nearby-but-different
        # model can otherwise outrank the actual match.
        $matches = $results | Where-Object { (Get-GgufNameKey (($_.id -split "/")[-1])) -eq $targetKey }
        if ($matches) {
            # Among genuine matches, prefer well-known, trustworthy quantizer accounts.
            $preferred = @("bartowski", "unsloth", "lmstudio-community", "mradermacher", "QuantFactory", "hugging-quants", "TheBloke")
            foreach ($pref in $preferred) {
                $hit = $matches | Where-Object { $_.id -like "$pref/*" } | Select-Object -First 1
                if ($hit) { $found = $hit.id; break }
            }
            if (-not $found) { $found = $matches[0].id }
        }
    }

    $script:ggufFallbackCache[$modelName] = $found
    return $found
}

# Search-HuggingFaceGguf only finds GGUF versions hosted under a DIFFERENT
# repo (a community quantizer's mirror), via a fuzzy text search that misses
# repos not tagged with HF's "gguf" library tag or whose name doesn't survive
# the quant-suffix stripping (e.g. "-NVFP4"). But plenty of models ship their
# OWN .gguf files directly in the model's own repo - confirmed via a real
# case where "hf download <repo>" pulled real .gguf files straight from a
# repo llmfit had no gguf_sources for and the fuzzy search also missed. This
# checks the model's own repo's actual file listing directly - the same
# lookup as "hf download" itself does - before ever falling back to search.
if (-not $script:ownRepoGgufCache) { $script:ownRepoGgufCache = @{} }

function Test-OwnRepoHasGguf([string]$repo) {
    if ($script:ownRepoGgufCache.ContainsKey($repo)) {
        return $script:ownRepoGgufCache[$repo]
    }
    $job = Start-Job -ScriptBlock {
        param($r, $token)
        try {
            $headers = @{}
            if ($token) { $headers["Authorization"] = "Bearer $token" }
            Invoke-RestMethod -Uri "https://huggingface.co/api/models/$r" -Headers $headers -TimeoutSec 15
        } catch {
            $null
        }
    } -ArgumentList $repo, $script:hfToken

    try {
        $waited = 0
        while ($job.State -eq "Running" -and $waited -lt 15000) {
            Start-Sleep -Milliseconds 150
            $waited += 150
            [System.Windows.Forms.Application]::DoEvents()
        }
        $info = Receive-Job $job -ErrorAction SilentlyContinue
    } finally {
        Remove-Job $job -Force -ErrorAction SilentlyContinue
    }

    $hasGguf = $false
    if ($info -and $info.siblings) {
        $hasGguf = [bool]($info.siblings | Where-Object { $_.rfilename -like "*.gguf" } | Select-Object -First 1)
    }
    $script:ownRepoGgufCache[$repo] = $hasGguf
    return $hasGguf
}

# llmfit's "best_quant" describes the quant for the MODEL'S OWN listing,
# which can be a completely different format than the GGUF repo we're
# actually about to download from (e.g. the model's own entry is "AWQ-4bit"
# - a vLLM-only format - while the GGUF mirror we found only has files named
# Q4_K_M, Q8_0, etc). Confirmed live: a user got "Cannot find variant
# AWQ-4bit" running "lms get" with exactly that mismatch. This checks the
# actual GGUF repo's real file list and only trusts best_quant if a
# matching file genuinely exists there, otherwise substitutes a sensible
# quant that IS actually present.
if (-not $script:quantResolveCache) { $script:quantResolveCache = @{} }

function Resolve-GgufQuant([string]$ggufRepo, [string]$preferredQuant) {
    $cacheKey = "$ggufRepo|$preferredQuant"
    if ($script:quantResolveCache.ContainsKey($cacheKey)) {
        return $script:quantResolveCache[$cacheKey]
    }

    Show-Loading "Checking which quantizations $ggufRepo actually has..."
    $job = Start-Job -ScriptBlock {
        param($repo, $token)
        try {
            $headers = @{}
            if ($token) { $headers["Authorization"] = "Bearer $token" }
            # "?blobs=true" is what gets a real per-file byte size back in
            # each sibling entry - without it, siblings only list filenames.
            Invoke-RestMethod -Uri "https://huggingface.co/api/models/$repo`?blobs=true" -Headers $headers -TimeoutSec 15
        } catch {
            $null
        }
    } -ArgumentList $ggufRepo, $script:hfToken

    try {
        $waited = 0
        while ($job.State -eq "Running" -and $waited -lt 15000) {
            Start-Sleep -Milliseconds 150
            $waited += 150
            [System.Windows.Forms.Application]::DoEvents()
        }
        $info = Receive-Job $job -ErrorAction SilentlyContinue
    } finally {
        Remove-Job $job -Force -ErrorAction SilentlyContinue
        Hide-Loading
    }

    $resolved = $preferredQuant
    $files = $null
    if ($info) { $files = $info.siblings | Where-Object { $_.rfilename -like "*.gguf" } }

    if ($files) {
        # Quantizer repos don't agree on a delimiter: bartowski-style names
        # end in "-Q4_K_M.gguf" (hyphen), but mradermacher-style names end
        # in ".Q4_K_M.gguf" (dot) - e.g. "ATLAS-OLMo-3-7B-Think-v4.IQ4_XS.gguf".
        # Blindly splitting on "-" and taking the last segment gave
        # "v4.IQ4_XS" for that file instead of "IQ4_XS", which "lms get"
        # then rejected outright ("Cannot find variant v4.IQ4_XS") -
        # confirmed via a real user report. Matching a known quant-name
        # pattern right before either delimiter works for both styles.
        $tagged = $files | ForEach-Object {
            $base = $_.rfilename -replace '\.gguf$', ''
            $quant = if ($base -match '(?i)[-.]((?:I?Q\d[\w]*|B?F16|F32))(?:-\d+-of-\d+)?$') { $Matches[1] } else { $null }
            [pscustomobject]@{ Quant = $quant; Size = $_.size }
        } | Where-Object { $_.Quant }
        $available = $tagged.Quant | Select-Object -Unique
        $ciMatch = $available | Where-Object { $_ -ieq $preferredQuant } | Select-Object -First 1
        if ($ciMatch) {
            $resolved = $ciMatch
        } else {
            $priority = @("Q4_K_M", "Q4_K_S", "Q5_K_M", "Q8_0", "Q4_0", "Q3_K_M", "Q6_K", "Q2_K")
            $picked = $null
            foreach ($p in $priority) {
                $hit = $available | Where-Object { $_ -ieq $p } | Select-Object -First 1
                if ($hit) { $picked = $hit; break }
            }
            $resolved = if ($picked) { $picked } elseif ($available.Count -gt 0) { $available[0] } else { $preferredQuant }
        }
    }

    # llmfit's disk_size_gb describes $m.name at $m.best_quant - once this
    # function has substituted a DIFFERENT repo and/or quant (which is most
    # downloads, since gguf_sources is often stale/missing), that number
    # describes a file nobody is about to download. Confirmed via a real
    # report: the list showed "0.02 GB" for a model that was actually a
    # 14 GB download once the real GGUF quant was resolved. Sums every
    # matching file's real size in case it's a multi-part shard
    # ("-00001-of-00002.gguf" etc), so multi-file quants total correctly.
    $sizeBytes = $null
    if ($tagged) {
        $matchingFiles = $tagged | Where-Object { $_.Quant -ieq $resolved -and $_.Size }
        if ($matchingFiles) { $sizeBytes = ($matchingFiles | Measure-Object -Property Size -Sum).Sum }
    }

    $resolvedResult = @{ Quant = $resolved; SizeBytes = $sizeBytes }
    $script:quantResolveCache[$cacheKey] = $resolvedResult
    return $resolvedResult
}

# make sure panels stack in the right order
$pnlHeader.BringToFront()
$pnlFiltersBorder.BringToFront()
$pnlFilters.BringToFront()
$pnlColHeader.BringToFront()
# pnlGridWrap must come last (frontmost) - otherwise pnlColHeader silently
# paints over the top sliver of the grid's first row, making it look like
# the first result is hidden under the column headers.
$pnlGridWrap.BringToFront()

# ---------- Theming ----------
function Apply-Theme {
    $t = Get-Theme
    $form.BackColor = $t.FormBg
    $pnlHeader.BackColor = $t.HeaderBg
    $lblTitle.ForeColor = $t.HeaderTitle
    $lblHardware.ForeColor = $t.HeaderSub
    $lblCredits1.ForeColor = $t.HeaderSub
    $lnkCredits2.ForeColor = $t.HeaderSub
    $lnkCredits2.LinkColor = $t.HeaderSub
    $lnkCredits2.VisitedLinkColor = $t.HeaderSub
    $lnkCredits2.ActiveLinkColor = $t.Accent
    $lnkCredits2.BackColor = $t.HeaderBg
    $pnlFilters.BackColor = $t.PanelBg
    $pnlFiltersBorder.BackColor = $t.Border
    $pnlGridWrap.BackColor = $t.FormBg
    $pnlFooter.BackColor = $t.PanelBg
    $pnlFooterBorder.BackColor = $t.Border
    $lblStatus.ForeColor = $t.StatusTxt
    $lblSearchHint.ForeColor = $t.Hint

    foreach ($l in $script:fieldLabels) { $l.ForeColor = $t.Label }

    foreach ($cmb in @($cmbUseCase, $cmbMinFit, $cmbRuntime, $cmbSort, $cmbForceRuntime)) {
        $cmb.BackColor = $t.InputBg
        $cmb.ForeColor = $t.InputTxt
        $cmb.Invalidate()
    }
    foreach ($n in @($numLimit, $numMinParams, $numMaxParams, $numWeightQuality, $numWeightSpeed, $numWeightFit, $numWeightContext)) {
        $n.BackColor = $t.InputBg
        $n.ForeColor = $t.InputTxt
    }
    foreach ($tb in @($txtSearch, $txtLicense)) {
        $tb.BackColor = $t.InputBg
        $tb.ForeColor = $t.InputTxt
    }
    $lblWeightHint.ForeColor = $t.Hint

    foreach ($item in $script:themedButtons) { Style-Button $item.Btn $item.Primary }

    $grid.BackgroundColor = $t.PanelBg
    $grid.GridColor = $t.Border
    $pnlColHeader.BackColor = $t.HeaderBg
    foreach ($lbl in $script:headerLabels.Values) { $lbl.ForeColor = $t.HeaderTitle }
    Update-SortIndicators
    $grid.DefaultCellStyle.BackColor = $t.PanelBg
    $grid.DefaultCellStyle.ForeColor = $t.GridTxt
    $grid.DefaultCellStyle.SelectionBackColor = $t.Selection
    $grid.DefaultCellStyle.SelectionForeColor = $t.SelectionTxt
    $grid.AlternatingRowsDefaultCellStyle.BackColor = $t.RowAlt
    $grid.AlternatingRowsDefaultCellStyle.ForeColor = $t.GridTxt
    $grid.Invalidate()

    $pnlLoading.BackColor = $t.FormBg
    $lblLoading.ForeColor = $t.Label

    # Property assignment alone doesn't reliably repaint every panel in this
    # app (likely due to the AutoScaleMode=None + custom double-buffering
    # combination) - force a full recursive repaint so the new colors show.
    $form.Invalidate($true)
    $form.Refresh()
}

$btnTheme.Add_Click({
    if ($script:themeName -eq "Light") { $script:themeName = "Dark"; $btnTheme.Text = "Light Mode" }
    else { $script:themeName = "Light"; $btnTheme.Text = "Dark Mode" }
    Apply-Theme
    # DataGridView doesn't retroactively restyle already-added rows when
    # DefaultCellStyle changes - repopulate so every row picks up the new theme.
    if ($script:lastModels) { Render-Grid }
})

$btnHfToken.Add_Click({ Show-HfTokenDialog })

Apply-Theme

# ---------- Helpers ----------
function Set-Status([string]$text) {
    $lblStatus.Text = $text
    [System.Windows.Forms.Application]::DoEvents()
}

function Update-HardwareLabel($sys) {
    if ($null -eq $sys) { return }
    $gpuTxt = if ($sys.has_gpu) { "$($sys.gpu_name) ($($sys.gpu_vram_gb) GB VRAM)" } else { "none detected" }
    $lblHardware.Text = "$($sys.cpu_name)   -   RAM: $([math]::Round($sys.total_ram_gb,1)) GB total, $([math]::Round($sys.available_ram_gb,1)) GB free   -   GPU: $gpuTxt   -   Backend: $($sys.backend)"
}

function Get-FitRank([string]$lvl) {
    switch ($lvl) { "Perfect" { 2 }; "Good" { 1 }; default { 0 } }
}

# Reads the four weight boxes and normalizes them to fractions that sum to 1,
# so the user's own weighting still lands on a 0-100 scale like the source
# components (score_components.quality/speed/fit/context are each 0-100).
function Get-ScoreWeights {
    $q = [double]$numWeightQuality.Value
    $s = [double]$numWeightSpeed.Value
    $f = [double]$numWeightFit.Value
    $c = [double]$numWeightContext.Value
    $total = $q + $s + $f + $c
    if ($total -le 0) { return @{ Q = 0.25; S = 0.25; F = 0.25; C = 0.25 } }
    return @{ Q = $q / $total; S = $s / $total; F = $f / $total; C = $c / $total }
}

# Recomputes a "custom_score" property on every cached model from its
# score_components using the user's own weights, replacing llmfit's own
# fixed-weight "score" everywhere the grid shows/sorts by Score. Pure
# client-side math on already-fetched data - does not touch llmfit.
function Update-CustomScores {
    if (-not $script:rawModels) { return }
    $w = Get-ScoreWeights
    foreach ($m in $script:rawModels) {
        $sc = $m.score_components
        $custom = if ($sc) {
            ($sc.quality * $w.Q) + ($sc.speed * $w.S) + ($sc.fit * $w.F) + ($sc.context * $w.C)
        } else {
            $m.score
        }
        $m | Add-Member -NotePropertyName custom_score -NotePropertyValue ([math]::Round($custom, 1)) -Force
    }
}

# Sorts $script:lastModels per the Sort By / Descending controls and redraws
# the grid. Does NOT touch llmfit - safe to call on every sort-control change.
function Render-Grid {
    Update-SortIndicators
    $models = $script:lastModels
    if (-not $models -or $models.Count -eq 0) {
        $grid.Rows.Clear()
        Set-Status "No models matched. Try loosening the filters."
        return
    }

    $desc = $chkSortDesc.Checked
    $models = switch ($cmbSort.SelectedItem) {
        "Score"   { if ($desc) { $models | Sort-Object -Property custom_score -Descending } else { $models | Sort-Object -Property custom_score } }
        "Speed"   { if ($desc) { $models | Sort-Object -Property estimated_tps -Descending } else { $models | Sort-Object -Property estimated_tps } }
        "Fit"     { if ($desc) { $models | Sort-Object -Property { Get-FitRank $_.fit_level } -Descending } else { $models | Sort-Object -Property { Get-FitRank $_.fit_level } } }
        "Params"  { if ($desc) { $models | Sort-Object -Property params_b -Descending } else { $models | Sort-Object -Property params_b } }
        "Name"    { if ($desc) { $models | Sort-Object -Property name -Descending } else { $models | Sort-Object -Property name } }
        "Provider" { if ($desc) { $models | Sort-Object -Property provider -Descending } else { $models | Sort-Object -Property provider } }
        "Category" { if ($desc) { $models | Sort-Object -Property category -Descending } else { $models | Sort-Object -Property category } }
        "Context" { if ($desc) { $models | Sort-Object -Property effective_context_length -Descending } else { $models | Sort-Object -Property effective_context_length } }
        "Size"    { if ($desc) { $models | Sort-Object -Property disk_size_gb -Descending } else { $models | Sort-Object -Property disk_size_gb } }
        default   { $models }
    }

    # SuspendLayout has to wrap the Clear() too, not just the re-Add loop -
    # otherwise the grid visibly flashes empty between the two (Clear()
    # paints immediately, then the Add loop repopulates in a separate
    # pass), which reads as a brief glitch right as a header gets clicked.
    $grid.SuspendLayout()
    $grid.Rows.Clear()
    foreach ($m in $models) {
        [void]$grid.Rows.Add(
            $m.name,
            $m.provider,
            $m.parameter_count,
            $m.fit_level,
            [math]::Round($m.estimated_tps,1),
            $m.custom_score,
            $m.best_quant,
            $m.runtime,
            $m.category,
            $m.disk_size_gb,
            $m.effective_context_length
        )
    }
    $grid.ResumeLayout()
    # The grid can keep a stale partial vertical scroll offset from before the
    # rows were cleared/re-added, which renders row 0 half-cut-off under the
    # column header on the next redraw. Force it back to a clean top scroll.
    if ($grid.Rows.Count -gt 0) { $grid.FirstDisplayedScrollingRowIndex = 0 }
    Set-Status "Found $($models.Count) model(s). Double-click a row (or click 'View Full Details') to see more."
}

# Applies the search-text and param-range filters to the already-fetched
# $script:rawModels (no llmfit call - instant, works on cached data). This is
# what typing in Search and hitting Enter runs; it does NOT re-scan hardware.
function Apply-Filters {
    $models = $script:rawModels
    if (-not $models) { return }

    $filter = $txtSearch.Text.Trim()
    if ($filter) {
        $models = $models | Where-Object { $_.name -like "*$filter*" -or $_.use_case -like "*$filter*" -or $_.category -like "*$filter*" }
    }

    $minP = [double]$numMinParams.Value
    $maxP = [double]$numMaxParams.Value
    if ($minP -gt 0 -or $maxP -lt 2000) {
        $models = $models | Where-Object { $_.params_b -ge $minP -and $_.params_b -le $maxP }
    }

    $script:lastModels = $models
    Render-Grid
}

# Re-scans via llmfit (hardware/use-case/capability/license filters all live
# here since they're real CLI flags), caches the raw result, then applies the
# client-side filters on top. This is the "real work" path - use it only when
# something that needs llmfit's own analysis has changed.
function Run-Recommend {
    $grid.Rows.Clear()

    $effectiveLimit = if ($chkShowAll.Checked) { 20000 } else { [int]$numLimit.Value }
    $args = @("recommend", "-n", [string]$effectiveLimit, "--json")
    if ($cmbUseCase.SelectedItem -ne "(any)") { $args += @("--use-case", $cmbUseCase.SelectedItem) }
    if ($cmbMinFit.SelectedItem) { $args += @("--min-fit", $cmbMinFit.SelectedItem) }
    if ($cmbRuntime.SelectedItem -ne "any") { $args += @("--runtime", $cmbRuntime.SelectedItem) }

    if ($cmbForceRuntime.SelectedItem -ne "(none)") { $args += @("--force-runtime", $cmbForceRuntime.SelectedItem) }
    $caps = @()
    if ($chkCapVision.Checked) { $caps += "vision" }
    if ($chkCapTool.Checked) { $caps += "tool_use" }
    if ($chkCapAudio.Checked) { $caps += "audio" }
    if ($chkCapTts.Checked) { $caps += "tts" }
    if ($caps.Count -gt 0) { $args += @("--capability", ($caps -join ",")) }
    $license = $txtLicense.Text.Trim()
    if ($license) { $args += @("--license", $license) }

    try {
        $raw = Invoke-Llmfit $args "Scanning models for your hardware..."
        $json = $raw | ConvertFrom-Json
    } catch {
        "$(Get-Date -Format o)`r`n$($_ | Out-String)`r`n$($_.ScriptStackTrace)`r`n---" | Out-File "$env:USERPROFILE\llmfit-gui\debug.log" -Append
        Set-Status "Error running llmfit: $_"
        return
    }

    Update-HardwareLabel $json.system
    $script:rawModels = $json.models
    Update-CustomScores
    Apply-Filters
}

function Show-Details {
    if ($grid.SelectedRows.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Select a model in the list first.", "LLM Fit GUI") | Out-Null
        return
    }
    $name = $grid.SelectedRows[0].Cells["Model"].Value
    try {
        $info = Invoke-Llmfit @("info", "$name") "Loading details for $name..."
    } catch {
        $info = "Error: $_"
    }

    $t = Get-Theme
    $detailForm = New-Object System.Windows.Forms.Form
    $detailForm.Text = "Details - $name"
    $detailForm.Size = New-Object System.Drawing.Size(750, 600)
    $detailForm.StartPosition = "CenterParent"
    $detailForm.BackColor = $t.FormBg

    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Multiline = $true
    $txt.ReadOnly = $true
    $txt.ScrollBars = "Vertical"
    $txt.Dock = "Fill"
    $txt.BorderStyle = "None"
    $txt.BackColor = $t.PanelBg
    $txt.ForeColor = $t.GridTxt
    $txt.Font = New-Object System.Drawing.Font("Consolas", 9.5)
    $txt.Text = (($info -split "`r`n|`n") -join "`r`n")
    # Windows auto-selects a TextBox's entire contents when it receives
    # keyboard focus (e.g. via Tab) - undesirable for a read-only info box.
    $txt.Add_Enter({ $txt.SelectionLength = 0 })
    $detailForm.Controls.Add($txt)

    $detailForm.ShowDialog($form) | Out-Null
}

function Open-Tui {
    Start-Process "powershell.exe" -ArgumentList "-NoExit", "-Command", "& '$llmfit'"
}

function Show-HfTokenDialog {
    $t = Get-Theme
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Hugging Face Token"
    $dlg.Size = New-Object System.Drawing.Size(520, 300)
    $dlg.StartPosition = "CenterParent"
    $dlg.BackColor = $t.FormBg
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false

    $lblExplain = New-Object System.Windows.Forms.Label
    $lblExplain.Location = New-Object System.Drawing.Point(16, 14)
    $lblExplain.Size = New-Object System.Drawing.Size(480, 60)
    $lblExplain.ForeColor = $t.Label
    $lblExplain.Font = $fontSub
    $lblExplain.Text = "Downloads and searches go to Hugging Face anonymously by default, which shares a lower rate limit with everyone else. Adding your own free token can raise that limit and improve download speed/stability - it's not required, just optional."
    $dlg.Controls.Add($lblExplain)

    $lnkGetToken = New-Object System.Windows.Forms.LinkLabel
    $lnkGetToken.Location = New-Object System.Drawing.Point(16, 78)
    $lnkGetToken.Size = New-Object System.Drawing.Size(300, 18)
    $lnkGetToken.Text = "Get a free token: huggingface.co/settings/tokens"
    $lnkGetToken.Font = $fontSub
    $tokenLinkText = "huggingface.co/settings/tokens"
    $linkIdx = $lnkGetToken.Text.IndexOf($tokenLinkText)
    $lnkGetToken.LinkArea = New-Object System.Windows.Forms.LinkArea($linkIdx, $tokenLinkText.Length)
    $lnkGetToken.LinkColor = $t.Accent
    $lnkGetToken.ForeColor = $t.Label
    $lnkGetToken.Add_LinkClicked({ Start-Process "https://huggingface.co/settings/tokens" })
    $dlg.Controls.Add($lnkGetToken)

    $lblField = New-Object System.Windows.Forms.Label
    $lblField.Text = "Token:"
    $lblField.AutoSize = $true
    $lblField.Location = New-Object System.Drawing.Point(16, 112)
    $lblField.ForeColor = $t.Label
    $lblField.Font = $fontSub
    $dlg.Controls.Add($lblField)

    $txtToken = New-Object System.Windows.Forms.TextBox
    $txtToken.Location = New-Object System.Drawing.Point(16, 130)
    $txtToken.Size = New-Object System.Drawing.Size(480, 24)
    $txtToken.BorderStyle = "FixedSingle"
    $txtToken.BackColor = $t.InputBg
    $txtToken.ForeColor = $t.InputTxt
    $txtToken.PasswordChar = '*'
    $txtToken.Text = $script:hfToken
    $txtToken.Add_Enter({ $txtToken.SelectionLength = 0 })
    $dlg.Controls.Add($txtToken)

    $lblStatus2 = New-Object System.Windows.Forms.Label
    $lblStatus2.Location = New-Object System.Drawing.Point(16, 160)
    $lblStatus2.Size = New-Object System.Drawing.Size(480, 18)
    $lblStatus2.ForeColor = $t.Hint
    $lblStatus2.Font = New-Object System.Drawing.Font("Segoe UI", 7.5)
    $lblStatus2.Text = if ($script:hfToken) { "A token is currently saved and active." } else { "No token saved - using anonymous access." }
    $dlg.Controls.Add($lblStatus2)

    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text = "Save"
    $btnSave.Location = New-Object System.Drawing.Point(16, 200)
    $btnSave.Size = New-Object System.Drawing.Size(110, 30)
    Style-Button $btnSave $true
    $dlg.Controls.Add($btnSave)

    $btnClear = New-Object System.Windows.Forms.Button
    $btnClear.Text = "Clear"
    $btnClear.Location = New-Object System.Drawing.Point(136, 200)
    $btnClear.Size = New-Object System.Drawing.Size(110, 30)
    Style-Button $btnClear $false
    $dlg.Controls.Add($btnClear)

    $btnSave.Add_Click({
        $val = $txtToken.Text.Trim()
        if ($val) {
            Set-HfToken $val
            $lblStatus2.Text = "Saved - token is now active for searches and downloads."
        } else {
            $lblStatus2.Text = "Enter a token first, or use Clear to remove a saved one."
        }
    }.GetNewClosure())

    $btnClear.Add_Click({
        Clear-HfToken
        $txtToken.Text = ""
        $lblStatus2.Text = "Token cleared - back to anonymous access."
    }.GetNewClosure())

    $dlg.ShowDialog($form) | Out-Null
}

function Get-SelectedModelObject {
    if ($grid.SelectedRows.Count -eq 0) { return $null }
    $name = $grid.SelectedRows[0].Cells["Model"].Value
    return ($script:lastModels | Where-Object { $_.name -eq $name } | Select-Object -First 1)
}

function Show-Download {
    $m = Get-SelectedModelObject
    if (-not $m) {
        [System.Windows.Forms.MessageBox]::Show("Select a model in the list first.", "LLM Fit GUI") | Out-Null
        return
    }

    $t = Get-Theme
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Download - $($m.name)"
    $dlg.Size = New-Object System.Drawing.Size(640, 596)
    $dlg.StartPosition = "CenterParent"
    $dlg.BackColor = $t.FormBg
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false

    # "runtime: llama.cpp" is just llmfit's guess at the best backend for this
    # model - it does NOT guarantee a GGUF file actually exists anywhere. The
    # reliable signal is gguf_sources: the specific repo(s) llmfit confirmed
    # actually host a GGUF conversion (often a different repo than the model's
    # own, e.g. a community quantizer's mirror). Use that repo name for
    # downloads, and only enable GGUF-dependent buttons when one exists.
    $hasConfirmedGguf = ($m.gguf_sources -and $m.gguf_sources.Count -gt 0)
    $ggufRepo = if ($hasConfirmedGguf) { $m.gguf_sources[0].repo } else { $m.name }
    $isGguf = $hasConfirmedGguf
    $ggufIsFallback = $false

    if (-not $hasConfirmedGguf) {
        Show-Loading "Checking if $($m.name) hosts its own GGUF files..."
        $ownRepoHasGguf = $false
        try { $ownRepoHasGguf = Test-OwnRepoHasGguf $m.name } finally { Hide-Loading }
        if ($ownRepoHasGguf) {
            $ggufRepo = $m.name
            $isGguf = $true
        } else {
            $fallbackRepo = Search-HuggingFaceGguf $m.name "Searching Hugging Face for a GGUF version of $($m.name)..."
            if ($fallbackRepo) {
                $ggufRepo = $fallbackRepo
                $isGguf = $true
                $ggufIsFallback = $true
            }
        }
    }
    # "lms get org/repo" only resolves models in LM Studio's own catalog - for
    # anything else (which is most of what we find, whether from llmfit's
    # gguf_sources or the Hugging Face fallback above) it needs the full HF
    # URL instead, confirmed working via a real test download in this session.
    $ggufUrl = "https://huggingface.co/$ggufRepo"

    # llmfit's best_quant is computed for $m.name's OWN listing, which may be
    # a non-GGUF format (AWQ/GPTQ/etc) even when a real GGUF mirror exists
    # elsewhere - resolve it against the GGUF repo's actual files so we never
    # hand "lms get"/"llmfit download" a quant name that doesn't exist there.
    $resolvedQuant = $m.best_quant
    $resolvedSizeBytes = $null
    if ($isGguf) {
        $resolveResult = Resolve-GgufQuant $ggufRepo $m.best_quant
        $resolvedQuant = $resolveResult.Quant
        $resolvedSizeBytes = $resolveResult.SizeBytes
    }
    $quantNote = if ($resolvedQuant -ne $m.best_quant) { " (llmfit suggested $($m.best_quant), but that's not a real file in this GGUF repo - using $resolvedQuant instead)" } else { "" }

    # llmfit's own disk_size_gb describes $m.name at $m.best_quant, which is
    # frequently NOT what actually gets downloaded (see $quantNote above) -
    # confirmed via a real report of a model listed at 0.02 GB that was
    # actually a 14 GB download once resolved to its real GGUF quant. Prefer
    # the real byte size of the file(s) we just confirmed exist; only fall
    # back to llmfit's estimate when that lookup didn't return one.
    $sizeTxt = if ($resolvedSizeBytes) {
        "$([math]::Round($resolvedSizeBytes / 1GB, 2)) GB (actual size of $resolvedQuant)"
    } elseif ($m.disk_size_gb) {
        "$($m.disk_size_gb) GB (llmfit's estimate - could be for a different quant, see above)"
    } else {
        "unknown"
    }

    $lblInfo = New-Object System.Windows.Forms.Label
    $lblInfo.Location = New-Object System.Drawing.Point(16, 14)
    # 100px clipped the bottom lines once a 5th line (download size) was
    # added - confirmed by measuring the actual rendered text: these lines
    # are long enough to word-wrap within 600px width and need ~113px just
    # for typical text, more for a long repo/model name. A real user
    # reported this exact symptom ("everything doesn't have details") -
    # the Format and Ollama name lines were being silently cut off.
    $lblInfo.Size = New-Object System.Drawing.Size(600, 130)
    $lblInfo.ForeColor = $t.Label
    $lblInfo.Font = $fontSub
    $ollamaTxt = if ($m.ollama_name) { $m.ollama_name } else { "not available for this model" }
    $formatTxt = if ($hasConfirmedGguf) {
        "GGUF confirmed at $ggufRepo (used for LM Studio / direct download)"
    } elseif ($ggufIsFallback) {
        "Not in llmfit's own data, but found on Hugging Face: $ggufRepo (used for LM Studio / direct download)"
    } else {
        "No GGUF file found (checked llmfit's data and Hugging Face) - LM Studio and Direct Download can't load it"
    }
    $lblInfo.Text = "Model: $($m.name)`nQuantization to download: $resolvedQuant$quantNote`nDownload size: $sizeTxt`nFormat: $formatTxt`nOllama name: $ollamaTxt"
    $dlg.Controls.Add($lblInfo)

    $btnW = 180
    $btnLmStudio = New-Object System.Windows.Forms.Button
    $btnLmStudio.Text = "Get && Load in LM Studio"
    $btnLmStudio.Location = New-Object System.Drawing.Point(16, 152)
    $btnLmStudio.Size = New-Object System.Drawing.Size($btnW, 32)
    Style-Button $btnLmStudio $true
    $btnLmStudio.Enabled = ($hasLmStudio -and $isGguf)
    if (-not $hasLmStudio) { $btnLmStudio.Text = "LM Studio not found" }
    elseif (-not $isGguf) { $btnLmStudio.Text = "No GGUF version" }
    $dlg.Controls.Add($btnLmStudio)

    $btnOllama = New-Object System.Windows.Forms.Button
    $btnOllama.Text = "Pull via Ollama"
    $btnOllama.Location = New-Object System.Drawing.Point(206, 152)
    $btnOllama.Size = New-Object System.Drawing.Size($btnW, 32)
    Style-Button $btnOllama $true
    $btnOllama.Enabled = ($hasOllama -and $m.ollama_name)
    if (-not $hasOllama) { $btnOllama.Text = "Ollama not installed" }
    elseif (-not $m.ollama_name) { $btnOllama.Text = "Not on Ollama" }
    $dlg.Controls.Add($btnOllama)

    $btnDirect = New-Object System.Windows.Forms.Button
    $btnDirect.Text = "Download to Device"
    $btnDirect.Location = New-Object System.Drawing.Point(396, 152)
    $btnDirect.Size = New-Object System.Drawing.Size($btnW, 32)
    Style-Button $btnDirect $true
    $btnDirect.Enabled = $isGguf
    if (-not $isGguf) { $btnDirect.Text = "No GGUF version" }
    $dlg.Controls.Add($btnDirect)

    # LM Studio auto-picks a model's FULL max context length when loading if
    # not told otherwise - confirmed live in this session, that alone made a
    # 1B model's real speed ~49x slower than estimated (131072-token context
    # nearly filled a 2GB GPU's VRAM with cache, leaving almost nothing for
    # actual computation). Defaulting this to something reasonable instead of
    # the model's max is what fixes that.
    $lblContext = New-Object System.Windows.Forms.Label
    $lblContext.Text = "Context length to load with (tokens):"
    $lblContext.AutoSize = $true
    $lblContext.Location = New-Object System.Drawing.Point(16, 194)
    $lblContext.ForeColor = $t.Label
    $lblContext.Font = $fontSub
    $dlg.Controls.Add($lblContext)

    $numContextLength = New-Object System.Windows.Forms.NumericUpDown
    $numContextLength.Location = New-Object System.Drawing.Point(232, 190)
    $numContextLength.Size = New-Object System.Drawing.Size(80, 24)
    $numContextLength.Minimum = 512
    $maxCtx = if ($m.effective_context_length -gt 0) { $m.effective_context_length } else { 32768 }
    $numContextLength.Maximum = $maxCtx
    $numContextLength.Increment = 512
    $numContextLength.Value = [Math]::Min(4096, $maxCtx)
    $numContextLength.BackColor = $t.InputBg
    $numContextLength.ForeColor = $t.InputTxt
    $dlg.Controls.Add($numContextLength)

    $lblContextHint = New-Object System.Windows.Forms.Label
    $lblContextHint.Text = "smaller = more speed headroom on limited VRAM (model max: $maxCtx)"
    $lblContextHint.AutoSize = $true
    $lblContextHint.Location = New-Object System.Drawing.Point(320, 194)
    $lblContextHint.ForeColor = $t.Hint
    $lblContextHint.Font = New-Object System.Drawing.Font("Segoe UI", 7.5)
    $dlg.Controls.Add($lblContextHint)

    # llmfit's "estimated_tps" is a theoretical number - confirmed live in this
    # session that it can be off by 10x+ on real, imperfect hardware. llmfit
    # itself ships a "bench" command that measures actual live speed against
    # a running model, which is the real, honest comparison - this button
    # runs that directly (needs the model already loaded above) and shows
    # estimated vs. actual side by side instead of trusting the number blind.
    $btnBenchmark = New-Object System.Windows.Forms.Button
    $btnBenchmark.Text = "Benchmark vs Estimate"
    $btnBenchmark.Location = New-Object System.Drawing.Point(16, 220)
    $btnBenchmark.Size = New-Object System.Drawing.Size(180, 27)
    Style-Button $btnBenchmark $false
    $dlg.Controls.Add($btnBenchmark)

    $lblBenchHint = New-Object System.Windows.Forms.Label
    $lblBenchHint.Text = "Load the model above first, then run this for the real measured speed (llmfit bench, 3 runs)."
    $lblBenchHint.AutoSize = $true
    $lblBenchHint.Location = New-Object System.Drawing.Point(206, 228)
    $lblBenchHint.ForeColor = $t.Hint
    $lblBenchHint.Font = New-Object System.Drawing.Font("Segoe UI", 7.5)
    $dlg.Controls.Add($lblBenchHint)

    $prgDownload = New-Object System.Windows.Forms.ProgressBar
    $prgDownload.Location = New-Object System.Drawing.Point(16, 260)
    $prgDownload.Size = New-Object System.Drawing.Size(350, 18)
    $prgDownload.Style = "Continuous"
    $prgDownload.Minimum = 0
    $prgDownload.Maximum = 100
    $prgDownload.Value = 0
    $dlg.Controls.Add($prgDownload)

    # Wide enough for the longest status text ("Ready to chat") - it used to
    # be 50px, which clipped that text over the Cancel button next to it.
    $lblPct = New-Object System.Windows.Forms.Label
    $lblPct.Location = New-Object System.Drawing.Point(372, 260)
    $lblPct.Size = New-Object System.Drawing.Size(110, 18)
    $lblPct.ForeColor = $t.Label
    $lblPct.Text = ""
    $dlg.Controls.Add($lblPct)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"
    $btnCancel.Location = New-Object System.Drawing.Point(486, 256)
    $btnCancel.Size = New-Object System.Drawing.Size(90, 26)
    $btnCancel.Enabled = $false
    Style-Button $btnCancel $false
    $dlg.Controls.Add($btnCancel)
    $btnCancel.Add_Click({
        # The actual kill (whole process tree, via taskkill /T) happens
        # inside Invoke-ExternalCommand's own wait loop as soon as it next
        # notices this flag - within 50ms, not waiting on this handler to
        # race it. Duplicating the kill here isn't needed and used to
        # unconditionally disable the button even when $global:currentProc
        # was $null (e.g. the brief gap between the download and load
        # steps), which permanently and silently disabled Cancel for the
        # rest of the dialog's life with no way to tell why it stopped
        # responding.
        $global:downloadCancelled = $true
        $lblPct.Text = "Cancelling..."
    }.GetNewClosure())

    $lblHint = New-Object System.Windows.Forms.Label
    $lblHint.Location = New-Object System.Drawing.Point(16, 284)
    $lblHint.Size = New-Object System.Drawing.Size(600, 16)
    $lblHint.ForeColor = $t.Hint
    $lblHint.Font = New-Object System.Drawing.Font("Segoe UI", 7.5)
    $lblHint.Text = "Downloads can take a while for large models. LM Studio also auto-retries a failed download a couple of times before giving up."
    $dlg.Controls.Add($lblHint)

    $txtOut = New-Object System.Windows.Forms.TextBox
    $txtOut.Multiline = $true
    $txtOut.ReadOnly = $true
    $txtOut.ScrollBars = "Vertical"
    $txtOut.Location = New-Object System.Drawing.Point(16, 304)
    $txtOut.Size = New-Object System.Drawing.Size(590, 216)
    $txtOut.Anchor = "Top,Bottom,Left,Right"
    $txtOut.BorderStyle = "FixedSingle"
    $txtOut.BackColor = $t.PanelBg
    $txtOut.ForeColor = $t.GridTxt
    $txtOut.Font = New-Object System.Drawing.Font("Consolas", 9)
    $txtOut.Text = "Pick a download target above."
    $txtOut.Add_Enter({ $txtOut.SelectionLength = 0 })
    $dlg.Controls.Add($txtOut)

    # Parses the last "NN%" found in the command's live output and drives the
    # progress bar with it; falls back to a slow crawl if no % is reported yet
    # (some tools only print a spinner while resolving, before real progress starts).
    #
    # Two things this has to work around in lms's raw output:
    #  - It's a live terminal progress bar (ANSI cursor/escape codes, \r-redraws,
    #    spinner glyphs), so showing the raw captured text verbatim is unreadable
    #    garbage - Get-LastCleanLine strips the escape codes and keeps only the
    #    most recent redrawn line.
    #  - Percentages print with a decimal, e.g. "96.68%". A naive "(\d{1,3})%"
    #    regex matches the LAST 1-3 digits before the "%", which for "96.68%" is
    #    "68", not "96" - that bug was caught by an actual test download in this
    #    session (the bar jumped around at random instead of climbing steadily).
    #    "(\d{1,3})(?:\.\d+)?%" correctly captures the whole-number part instead.
    $updateProgress = {
        param($text)
        # The dialog can already be closing (Cancel/titlebar X sets the
        # cancelled flag, which the wait loop only notices on its next
        # tick) while a queued progress update for THIS still-running
        # process is in flight - writing to disposed controls at that point
        # throws instead of just being a no-op.
        if ($dlg.IsDisposed) { return }
        $txtOut.Text = Get-LastCleanLine $text
        $txtOut.SelectionStart = $txtOut.Text.Length
        $txtOut.ScrollToCaret()
        $matches = [regex]::Matches($text, '(\d{1,3})(?:\.\d+)?%')
        if ($matches.Count -gt 0) {
            $pct = [int]$matches[$matches.Count - 1].Groups[1].Value
            if ($pct -gt 100) { $pct = 100 }
            $prgDownload.Value = $pct
            $lblPct.Text = "$pct%"
        }
    }.GetNewClosure()

    $btnLmStudio.Add_Click({
        $prgDownload.Value = 0; $lblPct.Text = ""; $btnCancel.Enabled = $true; $global:downloadCancelled = $false
        $getArgs = @("get", "$ggufUrl@$resolvedQuant", "--gguf", "-y")
        $result = Invoke-ExternalCommandWithRetry $lmStudioExe $getArgs "Downloading via LM Studio..." $updateProgress
        # A killed process can still exit 0 depending on how it was
        # terminated, so ExitCode alone isn't a reliable "did Cancel happen"
        # signal - without checking the flag itself, a cancelled download
        # could silently fall through into loading the model anyway.
        if ($global:downloadCancelled) {
            $btnCancel.Enabled = $false
            $lblPct.Text = "Cancelled"
            $txtOut.Text = "lms get $ggufUrl@$resolvedQuant --gguf -y`r`n`r`n$(Get-LastCleanLine $result.Output)"
            return
        }
        if ($result.ExitCode -ne 0) {
            $btnCancel.Enabled = $false
            $txtOut.Text = "lms get $ggufUrl@$resolvedQuant --gguf -y`r`n`r`n$(Get-LastCleanLine $result.Output)"
            return
        }

        # Downloading alone isn't "ready to chat" - LM Studio still needs the
        # model loaded, and if we don't specify a context length it defaults
        # to the model's max, which on limited VRAM can crater real speed far
        # below what it should be (confirmed live: ~49x slower on a 2GB GPU
        # with a 131072-token default vs. a 4096-token load). Load it
        # ourselves with the context length chosen above instead.
        $ctxLen = [int]$numContextLength.Value
        $modelKey = Get-LmStudioModelKey $ggufRepo $resolvedQuant
        if ($global:downloadCancelled) {
            $btnCancel.Enabled = $false
            $lblPct.Text = "Cancelled"
            return
        }
        if (-not $modelKey) {
            $btnCancel.Enabled = $false
            $prgDownload.Value = 100; $lblPct.Text = "Downloaded"
            $txtOut.Text = "lms get $ggufUrl@$resolvedQuant --gguf -y`r`n`r`n$(Get-LastCleanLine $result.Output)`r`n`r`n(Downloaded, but couldn't find it in 'lms ls' to auto-load it - open it from LM Studio directly.)"
            return
        }
        $loadArgs = @("load", $modelKey, "--context-length", "$ctxLen", "--gpu", "max", "-y")
        $loadResult = Invoke-ExternalCommandWithRetry $lmStudioExe $loadArgs "Loading in LM Studio (context: $ctxLen tokens)..." $updateProgress
        $btnCancel.Enabled = $false
        if ($global:downloadCancelled) {
            $lblPct.Text = "Cancelled"
            return
        }
        if ($loadResult.ExitCode -eq 0) {
            $prgDownload.Value = 100; $lblPct.Text = "Ready to chat"
            # Loading a model does NOT start LM Studio's local API server -
            # that's a separate step, and without it "Benchmark vs Estimate"
            # (or chatting via any API-based tool) fails outright even
            # though the model loaded successfully. Confirmed via a real
            # user hitting exactly that after a successful download+load.
            Ensure-LmStudioServerRunning
        }
        $txtOut.Text = "lms get $ggufUrl@$resolvedQuant --gguf -y`r`n" +
            "lms load $modelKey --context-length $ctxLen --gpu max -y`r`n`r`n" +
            "$(Get-LastCleanLine $loadResult.Output)"
    }.GetNewClosure())

    $btnOllama.Add_Click({
        $prgDownload.Value = 0; $lblPct.Text = ""; $btnCancel.Enabled = $true; $global:downloadCancelled = $false
        $result = Invoke-ExternalCommandWithRetry $ollamaExe @("pull", $m.ollama_name) "Pulling via Ollama..." $updateProgress
        $btnCancel.Enabled = $false
        if ($result.ExitCode -eq 0) { $prgDownload.Value = 100; $lblPct.Text = "Done" }
        $txtOut.Text = "ollama pull $($m.ollama_name)`r`n`r`n$(Get-LastCleanLine $result.Output)"
    }.GetNewClosure())

    $btnDirect.Add_Click({
        $prgDownload.Value = 0; $lblPct.Text = ""; $btnCancel.Enabled = $true; $global:downloadCancelled = $false
        $result = Invoke-ExternalCommandWithRetry $llmfit @("download", $ggufRepo, "--quant", $resolvedQuant) "Downloading to device..." $updateProgress
        $btnCancel.Enabled = $false
        if ($result.ExitCode -eq 0) { $prgDownload.Value = 100; $lblPct.Text = "Done" }
        $txtOut.Text = "llmfit download $ggufRepo --quant $resolvedQuant`r`n`r`n$(Get-LastCleanLine $result.Output)"
    }.GetNewClosure())

    $btnBenchmark.Add_Click({
        $modelKey = Get-LmStudioModelKey $ggufRepo $resolvedQuant
        if (-not $modelKey) {
            $txtOut.Text = "Couldn't find this model loaded in LM Studio yet - click 'Get && Load in LM Studio' above first."
            return
        }
        # A model can be loaded (via this app in an earlier session, or
        # directly through LM Studio's own UI) without its local API server
        # having ever been started - "llmfit bench --provider auto" then
        # fails outright even though the model is genuinely loaded and
        # ready. Cheap to check every time; a no-op if it's already running.
        Ensure-LmStudioServerRunning
        $benchResult = Invoke-ExternalCommand $llmfit @("bench", $modelKey, "--provider", "auto", "--runs", "3", "--json") "Benchmarking $modelKey (3 runs)..."
        if ($benchResult.ExitCode -ne 0 -or -not $benchResult.StdOut) {
            $txtOut.Text = "Benchmark failed:`r`n`r`n$(Get-LastCleanLine $benchResult.Output)"
            return
        }
        try {
            $bench = $benchResult.StdOut | ConvertFrom-Json
            $actual = [math]::Round($bench.result.summary.avg_tps, 1)
            $estimated = [math]::Round([double]$m.estimated_tps, 1)
            $ratio = if ($actual -gt 0) { [math]::Round($estimated / $actual, 1) } else { 0 }
            $verdict = if ($ratio -le 1.3) { "Matches the estimate closely." }
                       elseif ($ratio -le 3) { "Noticeably slower than estimated, but in the same ballpark." }
                       else { "Estimate does NOT match real-world speed on this hardware - actual is ${ratio}x slower." }
            $txtOut.Text = "llmfit's estimate for this model: $estimated tok/s`r`n" +
                "Actual measured speed (llmfit bench, $($bench.result.summary.num_runs) runs): $actual tok/s (range: $([math]::Round($bench.result.summary.min_tps,1)) - $([math]::Round($bench.result.summary.max_tps,1)))`r`n`r`n" +
                "$verdict"
        } catch {
            $txtOut.Text = "Benchmark ran but the result couldn't be parsed:`r`n`r`n$(Get-LastCleanLine $benchResult.Output)"
        }
    }.GetNewClosure())

    # Closing the dialog directly (titlebar X, Alt+F4) while a download/load
    # is running used to leave that process running orphaned in the
    # background with no way to get back to it, since only the Cancel
    # button stopped it. This makes Close behave like Cancel.
    $dlg.Add_FormClosing({
        $global:downloadCancelled = $true
    }.GetNewClosure())

    $dlg.ShowDialog($form) | Out-Null
}

# ---------- Wire up events ----------
$btnSearch.Add_Click({ Run-Recommend })
$btnApplyAdvanced.Add_Click({ Run-Recommend })
$numMinParams.Add_ValueChanged({ Apply-Filters })
$numMaxParams.Add_ValueChanged({ Apply-Filters })
$btnClearAdvanced.Add_Click({
    $chkCapVision.Checked = $false
    $chkCapTool.Checked = $false
    $chkCapAudio.Checked = $false
    $chkCapTts.Checked = $false
    $txtLicense.Text = ""
    $cmbForceRuntime.SelectedIndex = 0
    $numMinParams.Value = 0
    $numMaxParams.Value = 2000
    Run-Recommend
})
$cmbSort.Add_SelectedIndexChanged({ Clear-SortCycle; Render-Grid })
$chkSortDesc.Add_CheckedChanged({ Clear-SortCycle; Render-Grid })
$numWeightQuality.Add_ValueChanged({ Update-CustomScores; Render-Grid })
$numWeightSpeed.Add_ValueChanged({ Update-CustomScores; Render-Grid })
$numWeightFit.Add_ValueChanged({ Update-CustomScores; Render-Grid })
$numWeightContext.Add_ValueChanged({ Update-CustomScores; Render-Grid })
$btnResetWeights.Add_Click({
    $numWeightQuality.Value = 40
    $numWeightSpeed.Value = 30
    $numWeightFit.Value = 20
    $numWeightContext.Value = 10
    Update-CustomScores
    Render-Grid
})
$txtSearch.Add_TextChanged({ Apply-Filters })
$txtSearch.Add_KeyDown({ if ($_.KeyCode -eq "Enter") { Apply-Filters } })
$grid.Add_CellDoubleClick({ if ($_.RowIndex -ge 0) { Show-Details } })
$btnDetails.Add_Click({ Show-Details })
$btnDownload.Add_Click({ Show-Download })
$btnTui.Add_Click({ Open-Tui })
$btnRefreshHw.Add_Click({
    try {
        $raw = Invoke-Llmfit @("recommend", "-n", "1", "--json") "Re-scanning hardware..."
        $json = $raw | ConvertFrom-Json
        Update-HardwareLabel $json.system
        Set-Status "Hardware re-scanned."
    } catch {
        Set-Status "Error: $_"
    }
})

# ---------- Initial load ----------
$form.Add_Shown({ $chkSortDesc.Checked = $true; Sync-HeaderLabels; Run-Recommend })
[void]$form.ShowDialog()
