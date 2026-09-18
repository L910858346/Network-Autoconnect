#Requires -Version 5.1
<#
    Normalize-Encoding.ps1 —— 源码编码规范化（开发用，输出刻意只用英文）

    原因：Windows PowerShell 5.1 只有在文件带 UTF-8 BOM 时才会把中文按 UTF-8 解析；
          没有 BOM 会把中文当 GBK，直接乱码甚至语法报错。
          所以本脚本自身必须保持纯 ASCII，才能在任何编码环境下先跑起来。

    它做两件事：
      1. 所有 .ps1 / .psm1 统一成 “UTF-8 带 BOM”，其余文件统一成 “UTF-8 无 BOM”
      2. 对 .ps1 / .psm1 做一次语法检查

    用法：powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Normalize-Encoding.ps1
#>
[CmdletBinding()]
param([string]$Root = '')

if (-not $Root) { $Root = (Split-Path -Parent $PSScriptRoot) }

$keep = @('.ps1', '.psm1')
$count = 0
foreach ($f in (Get-ChildItem -LiteralPath $Root -Recurse -File)) {
    if ($f.FullName -like '*\logs\*') { continue }
    $c = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8
    if ($keep -contains $f.Extension.ToLower()) {
        [IO.File]::WriteAllText($f.FullName, $c, (New-Object Text.UTF8Encoding $true))
    } else {
        [IO.File]::WriteAllText($f.FullName, $c, (New-Object Text.UTF8Encoding $false))
    }
    $count++
}
Write-Output ("[encoding] normalized {0} files" -f $count)

$bad = 0
foreach ($f in (Get-ChildItem -LiteralPath $Root -Recurse -File | Where-Object { $keep -contains $_.Extension.ToLower() })) {
    $errors = $null
    $tokens = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        Write-Output ("[syntax] FAIL {0} -> {1} (line {2})" -f $f.Name, $errors[0].Message, $errors[0].Extent.StartLineNumber)
        $bad++
    }
}
if ($bad -eq 0) { Write-Output '[syntax] all ok' } else { exit 1 }
