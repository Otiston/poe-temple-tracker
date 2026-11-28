#requires -Version 5.1
<#
    Active le bouton Admin (reset / synchro) sur la page GitHub.

    Le script demande un jeton GitHub "fine-grained" limite a ce depot avec le droit
    "Actions : Read and write" (et "Contents : Read and write" pour le reset instantane, une
    fois le depot protege : voir le README), le chiffre avec le mot de passe admin de config.json
    (PBKDF2-SHA256 600 000 tours + AES-256-CBC + HMAC-SHA256) et l'ecrit dans docs/admin.json,
    puis publie ce fichier. Sur la page, le mot de passe dechiffre le jeton dans le navigateur
    du chef de guilde, qui fait alors le reset (directement sur la branche data, ou via la tache
    GitHub "reset") ou lance la tache "sync".

    Le fichier publie ne contient que du chiffre : sans le mot de passe, le jeton est illisible.
    Choisis un mot de passe long (12 caracteres ou plus) et ne le reutilise nulle part ailleurs.

    Usage (dans le dossier du projet) :  powershell -ExecutionPolicy Bypass -File tools\set-admin-token.ps1

    Ce fichier est volontairement en ASCII pur (Windows PowerShell 5.1).
#>
param(
    [string]$ConfigPath = '',
    [string]$Repo = 'Otiston/poe-temple-tracker',
    [string]$Workflow = 'tracker.yml',
    [string]$OutPath = '',
    [switch]$NoPush,
    # Test interne : chiffre un faux jeton avec un faux mot de passe, sans GitHub ni git.
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
if (-not $ConfigPath) { $ConfigPath = Join-Path $Root 'config.json' }
if (-not $OutPath) { $OutPath = Join-Path $Root 'docs\admin.json' }
$Utf8 = New-Object System.Text.UTF8Encoding($false)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Iterations = 600000

function New-RandomBytes([int]$Count) {
    $buf = New-Object byte[] $Count
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($buf) } finally { $rng.Dispose() }
    return , $buf
}

function Get-DerivedKeys([string]$Password, [byte[]]$Salt) {
    $kdf = [System.Security.Cryptography.Rfc2898DeriveBytes]::new($Utf8.GetBytes($Password), $Salt, $Iterations, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
    try { $bytes = $kdf.GetBytes(64) } finally { $kdf.Dispose() }
    return @{ enc = [byte[]]$bytes[0..31]; mac = [byte[]]$bytes[32..63] }
}

function Get-Mac([byte[]]$Key, [byte[]]$Iv, [byte[]]$Data) {
    $hmac = [System.Security.Cryptography.HMACSHA256]::new($Key)
    try { return , $hmac.ComputeHash([byte[]]($Iv + $Data)) } finally { $hmac.Dispose() }
}

function Protect-Token([string]$Token, [string]$Password) {
    $salt = New-RandomBytes 16
    $iv = New-RandomBytes 16
    $keys = Get-DerivedKeys $Password $salt
    $aes = [System.Security.Cryptography.Aes]::Create()
    try {
        $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
        $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
        $aes.Key = $keys.enc
        $aes.IV = $iv
        $plain = $Utf8.GetBytes($Token)
        $enc = $aes.CreateEncryptor()
        try { $cipher = $enc.TransformFinalBlock($plain, 0, $plain.Length) } finally { $enc.Dispose() }
    } finally { $aes.Dispose() }
    $mac = Get-Mac $keys.mac $iv $cipher
    return [ordered]@{
        v        = 1
        repo     = $Repo
        workflow = $Workflow
        ref      = 'main'
        kdf      = 'PBKDF2-SHA256'
        iter     = $Iterations
        salt     = [Convert]::ToBase64String($salt)
        iv       = [Convert]::ToBase64String($iv)
        data     = [Convert]::ToBase64String($cipher)
        mac      = [Convert]::ToBase64String($mac)
    }
}

# Relit le fichier produit pour s'assurer que le mot de passe le dechiffre bien.
function Test-Roundtrip($Blob, [string]$Password, [string]$Token) {
    $salt = [Convert]::FromBase64String($Blob.salt)
    $iv = [Convert]::FromBase64String($Blob.iv)
    $cipher = [Convert]::FromBase64String($Blob.data)
    $keys = Get-DerivedKeys $Password $salt
    $mac = Get-Mac $keys.mac $iv $cipher
    if ([Convert]::ToBase64String($mac) -ne $Blob.mac) { return $false }
    $aes = [System.Security.Cryptography.Aes]::Create()
    try {
        $aes.Key = $keys.enc
        $aes.IV = $iv
        $dec = $aes.CreateDecryptor()
        try { $plain = $dec.TransformFinalBlock($cipher, 0, $cipher.Length) } finally { $dec.Dispose() }
    } finally { $aes.Dispose() }
    return ($Utf8.GetString($plain) -ceq $Token)
}

function Invoke-GitHub([string]$Method, [string]$Path, [string]$Token, $Body) {
    $headers = @{
        Authorization          = "Bearer $Token"
        Accept                 = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
        'User-Agent'           = 'poe-temple-tracker'
    }
    $params = @{ Method = $Method; Uri = "https://api.github.com/$Path"; Headers = $headers; UseBasicParsing = $true }
    if ($Body) { $params.Body = (ConvertTo-Json -InputObject $Body -Compress); $params.ContentType = 'application/json' }
    return Invoke-WebRequest @params
}

# ------------------------------------------------------------------ test interne
if ($SelfTest) {
    $token = 'github_pat_SELFTEST_' + ([Convert]::ToBase64String((New-RandomBytes 12)) -replace '[^A-Za-z0-9]', 'x')
    $password = 'mot-de-passe-de-test'
    $blob = Protect-Token $token $password
    [IO.File]::WriteAllText($OutPath, (ConvertTo-Json -InputObject $blob), $Utf8)
    Write-Host "SelfTest : jeton=$token roundtrip=$(Test-Roundtrip $blob $password $token) -> $OutPath"
    exit 0
}

# ------------------------------------------------------------------ mot de passe admin
$cfg = [IO.File]::ReadAllText($ConfigPath, $Utf8) | ConvertFrom-Json
$password = [string]$cfg.adminPassword
if ([string]::IsNullOrWhiteSpace($password) -or $password -eq 'change-moi') {
    Write-Host 'Choisis d''abord un mot de passe admin dans config.json (champ "adminPassword").' -ForegroundColor Yellow
    exit 1
}
if ($password.Length -lt 12) {
    Write-Host "Attention : ton mot de passe admin fait moins de 12 caracteres. Comme la version chiffree est publique, un mot de passe plus long est plus sur." -ForegroundColor Yellow
}

# ------------------------------------------------------------------ jeton GitHub
Write-Host ''
Write-Host "Colle ton jeton GitHub (github_pat_...) puis Entree. Il ne s'affiche pas a l'ecran :"
$secure = Read-Host -AsSecureString
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
try { $token = ([Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)).Trim() } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
if ($token -notmatch '^(github_pat_|ghp_)[A-Za-z0-9_]+$') {
    Write-Host 'Ce ne ressemble pas a un jeton GitHub (il doit commencer par github_pat_).' -ForegroundColor Red
    exit 1
}

# Verification : le jeton doit pouvoir lancer la tache. On lance une simple synchro (sans effet).
Write-Host 'Verification du jeton (lancement d''une synchro sur GitHub)...'
try {
    $r = Invoke-GitHub 'POST' "repos/$Repo/actions/workflows/$Workflow/dispatches" $token @{ ref = 'main'; inputs = @{ action = 'sync' } }
} catch {
    $status = $null
    try { $status = [int]$_.Exception.Response.StatusCode } catch { }
    Write-Host "GitHub refuse ce jeton (HTTP $status). Verifie : depot $Repo selectionne, permission 'Actions : Read and write'." -ForegroundColor Red
    exit 1
}
Write-Host 'Jeton OK.' -ForegroundColor Green

# Reset instantane : il faut pouvoir ecrire la branche data. Test sans effet visible : un
# "blob" Git que rien ne reference (GitHub le supprime tout seul).
try {
    $null = Invoke-GitHub 'POST' "repos/$Repo/git/blobs" $token @{ content = 'test'; encoding = 'utf-8' }
    Write-Host 'Reset instantane : actif (permission Contents).' -ForegroundColor Green
} catch {
    Write-Host "Reset instantane : pas actif (pas de permission 'Contents : Read and write'). Le reset passera par la tache GitHub (1 a 2 min)." -ForegroundColor Yellow
}

# ------------------------------------------------------------------ chiffrement
Write-Host 'Chiffrement avec ton mot de passe admin (quelques secondes)...'
$blob = Protect-Token $token $password
if (-not (Test-Roundtrip $blob $password $token)) { Write-Host 'Echec de la verification du chiffrement.' -ForegroundColor Red; exit 1 }
[IO.File]::WriteAllText($OutPath, (ConvertTo-Json -InputObject $blob), $Utf8)
$token = $null
$password = $null
Write-Host "Ecrit : $OutPath"

if ($NoPush) { exit 0 }
Push-Location $Root
try {
    git add -- docs/admin.json
    git commit -q -m 'Bouton admin : jeton de reset chiffre' -- docs/admin.json
    git push -q
    Write-Host ''
    Write-Host 'Publie. Dans 1 a 2 minutes, le bouton Admin apparait sur https://otiston.github.io/poe-temple-tracker/' -ForegroundColor Green
} finally { Pop-Location }
