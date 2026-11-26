#requires -Version 5.1
<#
    Temple Tracker
    Compte les "Chronicle of Atzoatl" deposes dans le coffre de guilde Path of Exile,
    a partir de l'historique du coffre (reserve au chef de guilde), et sert une page web
    avec le classement. Seul l'admin (mot de passe dans config.json) peut remettre a zero.

    Lancement : double-clic sur start.bat
    (ou : powershell -NoProfile -ExecutionPolicy Bypass -File server.ps1)

    Ce fichier est volontairement en ASCII pur : Windows PowerShell 5.1 lit les scripts
    sans BOM en ANSI, les accents seraient corrompus.
#>
param(
    [string]$ConfigPath = '',
    [string]$StatePath = '',
    [switch]$NoBrowser,
    # Mode GitHub Actions : un seul passage (lecture + reset eventuel), ecrit data.json et s'arrete.
    [switch]$Once,
    [switch]$Reset,
    [string]$PublicPath = ''
)

$ErrorActionPreference = 'Stop'
if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 'config.json' }
if (-not $StatePath) { $StatePath = Join-Path $PSScriptRoot 'data\state.json' }

Add-Type -AssemblyName System.Net.Http
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
# Windows PowerShell 5.1 serialise certains tableaux en {"value":[...],"Count":n} sans ca.
try { Remove-TypeData -TypeName System.Array -ErrorAction SilentlyContinue } catch { }

$Utf8 = New-Object System.Text.UTF8Encoding($false)
$IndexPath = Join-Path $PSScriptRoot 'docs\index.html'
$DataDir = Split-Path -Parent $StatePath
$RawDumpPath = Join-Path $DataDir 'last-response.json'
$CookieName = 'tt_admin'

$ConfigDefaults = [ordered]@{
    guildId          = 0
    poesessid        = ''
    adminPassword    = ''
    port             = 8080
    pollMinutes      = 2
    itemName         = 'Chronicle of Atzoatl'
    templeRunners    = @()
    initialMembers   = @()
    firstSessionStart = ''
    githubRepo       = ''
    githubBranch     = 'data'
    maxBackfillPages = 20
    userAgent        = 'poe-temple-tracker/1.0 (guild stash contribution tracker)'
    apiUrl           = ''
}

$script:LastGoodConfig = $null
$script:NextPollAt = [int64]0
$script:LoginFailures = 0
$script:LastLoginFailure = [int64]0
$script:LoginLockedUntil = [int64]0
$script:Http = $null
$script:GhPath = $null
$script:Pub = @{ target = ''; branchReady = $false; shaKnown = $false; sha = $null; signature = ''; lastPushAt = [int64]0; error = $null }

# ---------------------------------------------------------------- utilitaires

function Get-UnixNow { return [int64][DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }

function Write-Log([string]$Message) {
    Write-Host ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message)
}

function New-RandomHex([int]$Bytes) {
    $buf = New-Object byte[] $Bytes
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($buf) } finally { $rng.Dispose() }
    return -join ($buf | ForEach-Object { $_.ToString('x2') })
}

function Get-Prop($Object, [string]$Name, $Default) {
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return $Default }
    return $p.Value
}

# ---------------------------------------------------------------- configuration

function Read-Config {
    if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Fichier de configuration introuvable : $ConfigPath" }
    $cfg = [IO.File]::ReadAllText($ConfigPath, $Utf8) | ConvertFrom-Json
    foreach ($key in $ConfigDefaults.Keys) {
        $p = $cfg.PSObject.Properties[$key]
        if ($null -eq $p -or $null -eq $p.Value -or ([string]$p.Value) -eq '') {
            $cfg | Add-Member -NotePropertyName $key -NotePropertyValue $ConfigDefaults[$key] -Force
        }
    }
    # Sur GitHub Actions, le POESESSID vient d'un secret (variable d'environnement), pas du fichier.
    if ($env:POESESSID) { $cfg.poesessid = ([string]$env:POESESSID).Trim() }
    $script:LastGoodConfig = $cfg
    return $cfg
}

# Relit config.json a chaque appel (on peut changer le POESESSID sans redemarrer).
# Si le fichier est casse pendant l'execution, on garde la derniere version valide.
function Get-Config {
    try { return Read-Config } catch {
        if ($script:LastGoodConfig) { return $script:LastGoodConfig }
        throw
    }
}

# ---------------------------------------------------------------- etat persistant

function Import-State {
    $s = $null
    if (Test-Path -LiteralPath $StatePath) {
        $s = [IO.File]::ReadAllText($StatePath, $Utf8) | ConvertFrom-Json
    }
    $entries = New-Object System.Collections.ArrayList
    $archives = New-Object System.Collections.ArrayList
    $members = New-Object System.Collections.ArrayList
    foreach ($e in @(Get-Prop $s 'entries' @())) { if ($null -ne $e) { [void]$entries.Add($e) } }
    foreach ($a in @(Get-Prop $s 'archives' @())) { if ($null -ne $a) { [void]$archives.Add($a) } }
    foreach ($m in @(Get-Prop $s 'members' @())) { if ($m) { [void]$members.Add([string]$m) } }

    $salt = [string](Get-Prop $s 'salt' '')
    if (-not $salt) { $salt = New-RandomHex 32 }

    return [pscustomobject]@{
        version      = 1
        sessionStart = [int64](Get-Prop $s 'sessionStart' 0)
        resets       = [int](Get-Prop $s 'resets' 0)
        cursorTime   = [int64](Get-Prop $s 'cursorTime' 0)
        lastPoll     = [int64](Get-Prop $s 'lastPoll' 0)
        lastSuccess  = [int64](Get-Prop $s 'lastSuccess' 0)
        lastError    = (Get-Prop $s 'lastError' $null)
        salt         = $salt
        members      = $members
        entries      = $entries
        archives     = $archives
    }
}

# ---------------------------------------------------------------- participants et runners

function Get-BaseName([string]$Account) {
    $i = $Account.LastIndexOf('#')
    if ($i -gt 0) { return $Account.Substring(0, $i) }
    return $Account
}

# Les "runners" (ex. le chef de guilde) retirent les temples pour les lancer :
# leurs retraits ne leur coutent pas de point. "Otiston" couvre Otiston#1234 ;
# avec un # dans config.json, le compte doit correspondre exactement.
function Test-Runner([string]$Account, $Cfg) {
    $base = Get-BaseName $Account
    foreach ($r in @($Cfg.templeRunners)) {
        $r = ([string]$r).Trim()
        if (-not $r) { continue }
        if ($r.Contains('#')) { if ($Account -ieq $r) { return $true } }
        elseif ($base -ieq $r) { return $true }
    }
    return $false
}

function Test-Counted([string]$Account, [string]$Action, $Cfg) {
    if ($Action -eq 'added') { return $true }
    if ($Action -eq 'removed') { return (-not (Test-Runner $Account $Cfg)) }
    return $false
}

# Une fois dans la liste, un joueur y reste pour toujours (meme apres un reset).
function Add-Participant([string]$Account) {
    if ($MemberSet.Add($Account)) { [void]$State.members.Add($Account) }
}

function Save-State {
    if (-not (Test-Path -LiteralPath $DataDir)) { [void](New-Item -ItemType Directory -Path $DataDir) }
    $json = ConvertTo-Json -InputObject $State -Depth 8
    $tmp = "$StatePath.tmp"
    [IO.File]::WriteAllText($tmp, $json, $Utf8)
    Move-Item -LiteralPath $tmp -Destination $StatePath -Force
}

function Set-PollError([string]$Code, [string]$Detail) {
    $State.lastError = [pscustomobject]@{ code = $Code; detail = $Detail; time = (Get-UnixNow) }
    Write-Log "Synchro en echec [$Code] $Detail"
}

# ---------------------------------------------------------------- API pathofexile.com

function Get-HttpClient {
    if (-not $script:Http) {
        $handler = New-Object System.Net.Http.HttpClientHandler
        $handler.UseCookies = $false
        $handler.AutomaticDecompression = [System.Net.DecompressionMethods]'GZip, Deflate'
        $script:Http = [System.Net.Http.HttpClient]::new($handler)
        $script:Http.Timeout = [TimeSpan]::FromSeconds(30)
    }
    return $script:Http
}

function Invoke-PoeGet([string]$Url, $Cfg) {
    $client = Get-HttpClient
    $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $Url)
    [void]$req.Headers.TryAddWithoutValidation('Cookie', 'POESESSID=' + ([string]$Cfg.poesessid).Trim())
    [void]$req.Headers.TryAddWithoutValidation('User-Agent', [string]$Cfg.userAgent)
    [void]$req.Headers.TryAddWithoutValidation('Accept', 'application/json')
    try {
        $resp = $client.SendAsync($req).GetAwaiter().GetResult()
    } catch {
        $ex = $_.Exception
        while ($ex.InnerException) { $ex = $ex.InnerException }
        return @{ ok = $false; code = 'network'; detail = $ex.Message; retryAfter = 0 }
    } finally {
        $req.Dispose()
    }
    try {
        $status = [int]$resp.StatusCode
        $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if ($status -eq 200) {
            try { $json = $body | ConvertFrom-Json } catch {
                return @{ ok = $false; code = 'bad_json'; detail = 'Reponse non JSON'; retryAfter = 0 }
            }
            return @{ ok = $true; json = $json; body = $body }
        }
        $retry = 0
        if ($resp.Headers.RetryAfter -and $resp.Headers.RetryAfter.Delta) {
            $retry = [int]$resp.Headers.RetryAfter.Delta.Value.TotalSeconds
        }
        $code = 'http'
        if ($body -match 'cf-chl|challenge-platform|Just a moment') { $code = 'cloudflare' }
        elseif ($status -eq 401) { $code = 'unauthorized' }
        elseif ($status -eq 403) { $code = 'forbidden' }
        elseif ($status -eq 404) { $code = 'not_found' }
        elseif ($status -eq 429) { $code = 'rate_limited' }
        return @{ ok = $false; code = $code; detail = "HTTP $status"; retryAfter = $retry }
    } finally {
        $resp.Dispose()
    }
}

function Get-AccountName($Entry) {
    $acc = $Entry.account
    if ($null -eq $acc) { return '?' }
    if ($acc -is [string]) { return $acc }
    $name = Get-Prop $acc 'name' ''
    if ($name) { return [string]$name }
    return '?'
}

# Recupere les nouvelles entrees de l'historique (les plus recentes d'abord) et garde
# uniquement les mouvements de temples. On s'arrete des qu'on retombe sur des entrees
# deja vues (cursorTime) ou anterieures au debut de la session.
function Invoke-Poll {
    $cfg = $null
    try { $cfg = Read-Config } catch { Set-PollError 'config' $_.Exception.Message; Save-State; return }

    $now = Get-UnixNow
    $State.lastPoll = $now
    $script:NextPollAt = $now + [int64]([double]$cfg.pollMinutes * 60)

    if ([string]::IsNullOrWhiteSpace([string]$cfg.poesessid)) {
        Set-PollError 'no_sessid' 'POESESSID vide dans config.json'
        Save-State
        return
    }

    $base = [string]$cfg.apiUrl
    if (-not $base) { $base = "https://www.pathofexile.com/api/guild/$($cfg.guildId)/stash/history" }
    $cursor = [int64]$State.cursorTime
    $stopTime = [Math]::Max($cursor, [int64]$State.sessionStart)
    $maxPages = 50
    if ($cursor -eq 0) { $maxPages = [int]$cfg.maxBackfillPages }
    $itemPattern = [regex]::Escape([string]$cfg.itemName)

    $newest = $cursor
    $pages = 0
    $found = 0
    $fromId = $null
    $from = $null

    while ($pages -lt $maxPages) {
        $url = $base
        if ($fromId) {
            $sep = '?'
            if ($url.Contains('?')) { $sep = '&' }
            $url = "$url${sep}fromid=$([uri]::EscapeDataString([string]$fromId))&from=$from"
        }

        $r = Invoke-PoeGet -Url $url -Cfg $cfg
        if (-not $r.ok) {
            if ($r.retryAfter -gt 0) { $script:NextPollAt = (Get-UnixNow) + [Math]::Max([int64]$r.retryAfter, [int64]60) }
            Set-PollError $r.code $r.detail
            Save-State
            return
        }
        $pages++
        if ($pages -eq 1) { try { [IO.File]::WriteAllText($RawDumpPath, $r.body, $Utf8) } catch { } }

        $data = $r.json
        $apiError = Get-Prop $data 'error' $null
        if ($apiError) {
            Set-PollError 'api_error' ([string](Get-Prop $apiError 'message' ''))
            Save-State
            return
        }

        $entries = @(Get-Prop $data 'entries' @())
        $reachedKnown = $false
        foreach ($e in $entries) {
            if ($null -eq $e) { continue }
            $t = [int64](Get-Prop $e 'time' 0)
            if ($t -gt $newest) { $newest = $t }
            if ($t -lt $stopTime) { $reachedKnown = $true; continue }
            if ([string](Get-Prop $e 'item' '') -notmatch $itemPattern) { continue }

            $account = Get-AccountName $e
            $action = ([string](Get-Prop $e 'action' '')).ToLowerInvariant()
            $id = [string](Get-Prop $e 'id' '')
            if (-not $id) { $id = "$t|$account|$action|$(Get-Prop $e 'x' '')|$(Get-Prop $e 'y' '')" }
            if (-not $Seen.Add($id)) { continue }

            [void]$State.entries.Add([pscustomobject]@{
                    id      = $id
                    time    = $t
                    account = $account
                    action  = $action
                    league  = [string](Get-Prop $e 'league' '')
                    stash   = [string](Get-Prop $e 'stash' '')
                })
            if (Test-Counted $account $action $cfg) { Add-Participant $account }
            $found++
        }

        $truncated = [bool](Get-Prop $data 'truncated' $false)
        if ($reachedKnown -or $entries.Count -eq 0 -or -not $truncated) { break }
        $last = $entries[$entries.Count - 1]
        $fromId = Get-Prop $last 'id' $null
        $from = Get-Prop $last 'time' $null
        if (-not $fromId) { break }
        Start-Sleep -Milliseconds 1500
    }

    $State.cursorTime = $newest
    $State.lastSuccess = Get-UnixNow
    $State.lastError = $null
    Save-State
    if ($found -gt 0 -or $cursor -eq 0) {
        Write-Log "Synchro OK : $pages page(s) lue(s), $found nouveau(x) mouvement(s) de temple"
    }
}

# ---------------------------------------------------------------- classement

function New-ScoreRow([string]$Account, $Cfg) {
    return [pscustomobject]@{
        account   = $Account
        score     = 0
        added     = 0
        removed   = 0
        runs      = 0
        runner    = (Test-Runner $Account $Cfg)
        lastAdded = [int64]0
    }
}

# Score de session : +1 par temple depose, -1 par temple retire (sauf runners).
# Tous les participants connus apparaissent, meme a 0.
function Get-Summary($Cfg) {
    $start = [int64]$State.sessionStart
    $byAccount = @{}
    foreach ($m in $State.members) { $byAccount[[string]$m] = New-ScoreRow ([string]$m) $Cfg }

    $session = New-Object System.Collections.ArrayList
    foreach ($e in $State.entries) {
        if ([int64]$e.time -lt $start) { continue }
        $acc = [string]$e.account
        $row = $byAccount[$acc]
        if ($null -eq $row) { $row = New-ScoreRow $acc $Cfg; $byAccount[$acc] = $row }
        $delta = 0
        if ($e.action -eq 'added') {
            $row.added++
            $row.score++
            $delta = 1
            if ([int64]$e.time -gt $row.lastAdded) { $row.lastAdded = [int64]$e.time }
        } elseif ($e.action -eq 'removed') {
            if ($row.runner) { $row.runs++ } else { $row.removed++; $row.score--; $delta = -1 }
        } else {
            continue
        }
        [void]$session.Add([pscustomobject]@{
                id      = $e.id
                time    = [int64]$e.time
                account = $acc
                action  = $e.action
                stash   = $e.stash
                delta   = $delta
            })
    }

    $totalAdded = 0
    $totalRemoved = 0
    $totalRuns = 0
    foreach ($r in $byAccount.Values) { $totalAdded += $r.added; $totalRemoved += $r.removed; $totalRuns += $r.runs }

    # A egalite, celui qui a atteint son score le premier passe devant.
    $contributors = @($byAccount.Values | Where-Object { $MemberSet.Contains([string]$_.account) } | Sort-Object -Property `
        @{ Expression = { $_.score }; Descending = $true }, `
        @{ Expression = { if ($_.added -gt 0) { $_.lastAdded } else { [int64]::MaxValue } }; Descending = $false }, `
        @{ Expression = { $_.account }; Descending = $false })

    $recent = @($session | Sort-Object -Property @{ Expression = { $_.time }; Descending = $true } | Select-Object -First 25)

    return [pscustomobject]@{
        totalAdded   = $totalAdded
        totalRemoved = $totalRemoved
        totalRuns    = $totalRuns
        contributors = $contributors
        recent       = $recent
    }
}

function Get-Stats($Cfg, [bool]$IsAdmin) {
    $s = Get-Summary $Cfg
    $publish = $null
    if ($IsAdmin -and [string]$Cfg.githubRepo) {
        $publish = [pscustomobject]@{ url = (Get-PublicUrl $Cfg); lastPushAt = $script:Pub.lastPushAt; error = $script:Pub.error }
    }
    return [pscustomobject]@{
        publish      = $publish
        now          = (Get-UnixNow)
        sessionStart = $State.sessionStart
        lastPoll     = $State.lastPoll
        lastSuccess  = $State.lastSuccess
        lastError    = $State.lastError
        pollMinutes  = $Cfg.pollMinutes
        itemName     = $Cfg.itemName
        configured   = (-not [string]::IsNullOrWhiteSpace([string]$Cfg.poesessid))
        isAdmin      = $IsAdmin
        runners      = @(@($Cfg.templeRunners) | Where-Object { $_ } | ForEach-Object { [string]$_ })
        totalAdded   = $s.totalAdded
        totalRemoved = $s.totalRemoved
        totalRuns    = $s.totalRuns
        contributors = $s.contributors
        recent       = $s.recent
    }
}

# Archive le classement en cours dans state.json puis repart de zero.
function Reset-Session($Cfg) {
    $now = Get-UnixNow
    $s = Get-Summary $Cfg
    if ($s.contributors.Count -gt 0) {
        [void]$State.archives.Add([pscustomobject]@{
                start        = $State.sessionStart
                end          = $now
                totalAdded   = $s.totalAdded
                totalRuns    = $s.totalRuns
                contributors = $s.contributors
            })
    }
    # Tout ce qui est deja connu vient d'etre archive : la nouvelle session commence apres
    # le dernier mouvement connu (sinon un depot dans la meme seconde compterait deux fois).
    $start = $now
    foreach ($e in $State.entries) { if ([int64]$e.time -ge $start) { $start = [int64]$e.time + 1 } }
    $State.sessionStart = $start
    $State.resets = [int]$State.resets + 1
    $State.entries = New-Object System.Collections.ArrayList
    $Seen.Clear()
    Save-State
    Write-Log "Session reinitialisee ($($s.totalAdded) temple(s) archive(s))"
}

# ---------------------------------------------------------------- publication GitHub
# Le classement (sans aucun secret) est pousse dans data.json sur la branche "githubBranch"
# du depot "githubRepo", avec le compte deja connecte dans GitHub CLI (gh). La page publique
# (docs/index.html servie par GitHub Pages) lit ce fichier.

function Get-PublicUrl($Cfg) {
    $parts = ([string]$Cfg.githubRepo).Split('/')
    if ($parts.Count -ne 2 -or -not $parts[0] -or -not $parts[1]) { return '' }
    return "https://$($parts[0].ToLowerInvariant()).github.io/$($parts[1])/"
}

# $Body (JSON) passe par un fichier temporaire UTF-8 sans BOM : via stdin, .NET peut
# ajouter un BOM que l'API GitHub refuse ("Problems parsing JSON").
function Invoke-Gh([string[]]$GhArgs, [string]$Body) {
    $tmp = $null
    $allArgs = @($GhArgs)
    if ($Body) {
        $tmp = [IO.Path]::GetTempFileName()
        [IO.File]::WriteAllText($tmp, $Body, $Utf8)
        $allArgs += @('--input', $tmp)
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:GhPath
    $psi.Arguments = ($allArgs | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' }) -join ' '
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $Utf8
    $psi.StandardErrorEncoding = $Utf8
    $p = [System.Diagnostics.Process]::Start($psi)
    try {
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit(60000)) {
            try { $p.Kill() } catch { }
            return @{ ok = $false; out = ''; err = 'gh ne repond pas (timeout)'; json = $null }
        }
        $out = $outTask.Result
        $err = ([string]$errTask.Result).Trim()
        $json = $null
        if ($out) { try { $json = $out | ConvertFrom-Json } catch { } }
        return @{ ok = ($p.ExitCode -eq 0); out = $out; err = $err; json = $json }
    } finally {
        $p.Dispose()
        if ($tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

# Cree la branche de donnees (a partir de la branche par defaut) si elle n'existe pas.
function Initialize-PublishTarget($Cfg) {
    $repo = [string]$Cfg.githubRepo
    $branch = [string]$Cfg.githubBranch
    $target = "$repo@$branch"
    if ($script:Pub.target -ne $target) {
        $script:Pub.target = $target
        $script:Pub.branchReady = $false
        $script:Pub.shaKnown = $false
        $script:Pub.sha = $null
        $script:Pub.signature = ''
    }
    if ($script:Pub.branchReady) { return $true }

    $r = Invoke-Gh @('api', "repos/$repo/branches/$branch")
    if (-not $r.ok) {
        if ($r.err -notmatch 'HTTP 404') { $script:Pub.error = "branche $branch : $($r.err)"; return $false }
        $info = Invoke-Gh @('api', "repos/$repo")
        if (-not $info.ok) { $script:Pub.error = "depot $repo : $($info.err)"; return $false }
        $default = [string]$info.json.default_branch
        $ref = Invoke-Gh @('api', "repos/$repo/git/ref/heads/$default")
        if (-not $ref.ok) { $script:Pub.error = "branche $default : $($ref.err)"; return $false }
        $body = ConvertTo-Json -Compress -InputObject @{ ref = "refs/heads/$branch"; sha = [string]$ref.json.object.sha }
        $c = Invoke-Gh @('api', '--method', 'POST', "repos/$repo/git/refs") $body
        if (-not $c.ok) { $script:Pub.error = "creation de la branche $branch : $($c.err)"; return $false }
        Write-Log "Branche '$branch' creee sur $repo"
    }
    $script:Pub.branchReady = $true
    return $true
}

function Get-RemoteDataSha($Cfg) {
    $r = Invoke-Gh @('api', "repos/$($Cfg.githubRepo)/contents/data.json?ref=$($Cfg.githubBranch)")
    if ($r.ok) { return @{ ok = $true; sha = [string]$r.json.sha } }
    if ($r.err -match 'HTTP 404') { return @{ ok = $true; sha = $null } }
    return @{ ok = $false; err = $r.err }
}

# Publie seulement si le classement a change, ou toutes les 15 min pour montrer que le
# serveur tourne toujours. Un echec est retente au cycle suivant.
# Ce que voit la page publique : aucun secret, pas de detail d'erreur.
function Get-PublicView($Cfg) {
    $stats = Get-Stats -Cfg $Cfg -IsAdmin $false
    $errInfo = $null
    if ($State.lastError) { $errInfo = [pscustomobject]@{ code = [string](Get-Prop $State.lastError 'code' '') } }
    return [pscustomobject]@{
        sessionStart = $stats.sessionStart
        lastError    = $errInfo
        pollMinutes  = $stats.pollMinutes
        itemName     = $stats.itemName
        configured   = $stats.configured
        isAdmin      = $false
        runners      = $stats.runners
        totalAdded   = $stats.totalAdded
        totalRemoved = $stats.totalRemoved
        totalRuns    = $stats.totalRuns
        contributors = $stats.contributors
        recent       = $stats.recent
    }
}

function Get-Sha256Hex([string]$Text) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash($Utf8.GetBytes($Text)) } finally { $sha.Dispose() }
    return -join ($hash | ForEach-Object { $_.ToString('x2') })
}

function Publish-Data([switch]$Force) {
    $cfg = Get-Config
    if (-not [string]$cfg.githubRepo) { return }
    if (-not $script:GhPath) { $script:Pub.error = 'GitHub CLI (gh) introuvable'; return }

    $stats = Get-Stats -Cfg $cfg -IsAdmin $false
    $view = Get-PublicView $cfg
    $signature = ConvertTo-Json -InputObject $view -Depth 8 -Compress
    $now = Get-UnixNow
    if (-not $Force -and $signature -eq $script:Pub.signature -and ($now - $script:Pub.lastPushAt) -lt 900) { return }

    $view | Add-Member -NotePropertyName lastSuccess -NotePropertyValue $State.lastSuccess
    $view | Add-Member -NotePropertyName publishedAt -NotePropertyValue $now
    $content = [Convert]::ToBase64String($Utf8.GetBytes((ConvertTo-Json -InputObject $view -Depth 8 -Compress)))

    if (-not (Initialize-PublishTarget $cfg)) { Write-Log "Publication GitHub impossible : $($script:Pub.error)"; return }
    if (-not $script:Pub.shaKnown) {
        $s = Get-RemoteDataSha $cfg
        if (-not $s.ok) { $script:Pub.error = $s.err; Write-Log "Publication GitHub impossible : $($s.err)"; return }
        $script:Pub.sha = $s.sha
        $script:Pub.shaKnown = $true
    }

    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $body = @{ message = "Scores : $($stats.totalAdded) temple(s) depose(s)"; content = $content; branch = [string]$cfg.githubBranch }
        if ($script:Pub.sha) { $body.sha = $script:Pub.sha }
        $r = Invoke-Gh @('api', '--method', 'PUT', "repos/$($cfg.githubRepo)/contents/data.json") (ConvertTo-Json -InputObject $body -Compress)
        if ($r.ok) {
            $script:Pub.sha = [string]$r.json.content.sha
            $script:Pub.signature = $signature
            $script:Pub.lastPushAt = $now
            $script:Pub.error = $null
            return
        }
        # SHA perime (fichier modifie ailleurs) : on le relit et on reessaie une fois.
        if ($attempt -eq 2 -or $r.err -notmatch 'HTTP (409|422)') { break }
        $s = Get-RemoteDataSha $cfg
        if (-not $s.ok) { break }
        $script:Pub.sha = $s.sha
    }
    $script:Pub.error = $r.err
    Write-Log "Publication GitHub en echec : $($r.err)"
}

function Invoke-Sync {
    try { Invoke-Poll } catch { Write-Log "Erreur de synchro : $($_.Exception.Message)" }
    try { Publish-Data } catch { $script:Pub.error = $_.Exception.Message; Write-Log "Erreur de publication : $($_.Exception.Message)" }
}

# ---------------------------------------------------------------- serveur HTTP

function Get-AdminToken($Cfg) {
    $hmac = [System.Security.Cryptography.HMACSHA256]::new($Utf8.GetBytes([string]$State.salt))
    try { $hash = $hmac.ComputeHash($Utf8.GetBytes([string]$Cfg.adminPassword)) } finally { $hmac.Dispose() }
    return -join ($hash | ForEach-Object { $_.ToString('x2') })
}

function Test-Admin($Ctx, $Cfg) {
    $cookie = $Ctx.Request.Cookies[$CookieName]
    if ($null -eq $cookie -or -not $cookie.Value) { return $false }
    return ($cookie.Value -ceq (Get-AdminToken $Cfg))
}

function Send-Bytes($Ctx, [int]$Status, [string]$ContentType, [byte[]]$Bytes) {
    $res = $Ctx.Response
    $res.StatusCode = $Status
    $res.ContentType = $ContentType
    $res.AddHeader('Cache-Control', 'no-store')
    $res.AddHeader('X-Content-Type-Options', 'nosniff')
    $res.AddHeader('Referrer-Policy', 'no-referrer')
    $res.ContentLength64 = $Bytes.Length
    $res.OutputStream.Write($Bytes, 0, $Bytes.Length)
    $res.OutputStream.Close()
}

function Send-Json($Ctx, [int]$Status, $Object) {
    $json = ConvertTo-Json -InputObject $Object -Depth 8 -Compress
    $bytes = $Utf8.GetBytes($json)
    Send-Bytes $Ctx $Status 'application/json; charset=utf-8' $bytes
}

function Read-JsonBody($Ctx) {
    $req = $Ctx.Request
    if ($req.ContentLength64 -gt 8192) { return $null }
    $reader = New-Object System.IO.StreamReader($req.InputStream, $Utf8)
    try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
    if (-not $text) { return $null }
    try { return ($text | ConvertFrom-Json) } catch { return $null }
}

function Get-CookieSuffix($Ctx) {
    $proto = [string]$Ctx.Request.Headers['X-Forwarded-Proto']
    if ($Ctx.Request.IsSecureConnection -or $proto -eq 'https') { return '; Secure' }
    return ''
}

function Invoke-Login($Ctx, $Cfg) {
    $now = Get-UnixNow
    if ($script:LoginLockedUntil -gt $now) {
        Send-Json $Ctx 429 @{ error = 'locked'; retryIn = ($script:LoginLockedUntil - $now) }
        return
    }
    if ($now - $script:LastLoginFailure -gt 900) { $script:LoginFailures = 0 }

    $body = Read-JsonBody $Ctx
    $password = [string](Get-Prop $body 'password' '')
    if ($password -and ($password -ceq [string]$Cfg.adminPassword)) {
        $script:LoginFailures = 0
        $token = Get-AdminToken $Cfg
        $Ctx.Response.AppendHeader('Set-Cookie', "$CookieName=$token; Path=/; HttpOnly; SameSite=Strict; Max-Age=2592000$(Get-CookieSuffix $Ctx)")
        Write-Log 'Connexion admin'
        Send-Json $Ctx 200 @{ ok = $true }
        return
    }

    $script:LoginFailures++
    $script:LastLoginFailure = $now
    if ($script:LoginFailures -ge 8) {
        $script:LoginLockedUntil = $now + 600
        $script:LoginFailures = 0
        Write-Log 'Trop de mots de passe faux : connexion admin bloquee 10 min'
    }
    Send-Json $Ctx 401 @{ error = 'bad_password' }
}

function Invoke-Request($Ctx) {
    $req = $Ctx.Request
    $path = $req.Url.AbsolutePath
    $method = $req.HttpMethod
    $cfg = Get-Config

    if ($method -eq 'GET' -and ($path -eq '/' -or $path -eq '/index.html')) {
        $bytes = [IO.File]::ReadAllBytes($IndexPath)
        Send-Bytes $Ctx 200 'text/html; charset=utf-8' $bytes
        return
    }
    if ($method -eq 'GET' -and $path -eq '/api/stats') {
        Send-Json $Ctx 200 (Get-Stats -Cfg $cfg -IsAdmin (Test-Admin $Ctx $cfg))
        return
    }

    if ($method -eq 'POST' -and $path.StartsWith('/api/')) {
        # Les cookies sont SameSite=Strict ; on exige en plus du JSON (pas de formulaire cross-site).
        if (-not ([string]$req.ContentType).StartsWith('application/json')) {
            Send-Json $Ctx 415 @{ error = 'json_required' }
            return
        }
        if ($path -eq '/api/login') { Invoke-Login $Ctx $cfg; return }
        if ($path -eq '/api/logout') {
            $Ctx.Response.AppendHeader('Set-Cookie', "$CookieName=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0$(Get-CookieSuffix $Ctx)")
            Send-Json $Ctx 200 @{ ok = $true }
            return
        }

        if (-not (Test-Admin $Ctx $cfg)) { Send-Json $Ctx 403 @{ error = 'forbidden' }; return }

        if ($path -eq '/api/reset') {
            # On recupere les derniers depots avant d'archiver, sauf si GGG nous a mis en pause.
            $code = [string](Get-Prop $State.lastError 'code' '')
            if ($code -ne 'rate_limited') { try { Invoke-Poll } catch { Write-Log "Synchro avant reset impossible : $($_.Exception.Message)" } }
            Reset-Session $cfg
            try { Publish-Data -Force } catch { $script:Pub.error = $_.Exception.Message }
            Send-Json $Ctx 200 @{ ok = $true }
            return
        }
        if ($path -eq '/api/refresh') {
            if ((Get-UnixNow) - [int64]$State.lastPoll -ge 5) { Invoke-Sync }
            Send-Json $Ctx 200 @{ ok = ($null -eq $State.lastError); error = $State.lastError }
            return
        }
    }

    Send-Json $Ctx 404 @{ error = 'not_found' }
}

# ---------------------------------------------------------------- demarrage

try { $Host.UI.RawUI.WindowTitle = 'Temple Tracker' } catch { }

try {
    $startupConfig = Read-Config
} catch {
    Write-Host ''
    Write-Host "config.json invalide : $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
$pw = [string]$startupConfig.adminPassword
if (-not $Once -and ([string]::IsNullOrWhiteSpace($pw) -or $pw -eq 'change-moi')) {
    Write-Host ''
    Write-Host 'Choisis un mot de passe admin dans config.json (champ "adminPassword"), puis relance.' -ForegroundColor Yellow
    exit 1
}
if ([int64]$startupConfig.guildId -le 0 -and -not $startupConfig.apiUrl) {
    Write-Host ''
    Write-Host 'Renseigne "guildId" dans config.json, puis relance.' -ForegroundColor Yellow
    exit 1
}

$State = Import-State
$Seen = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($e in $State.entries) { [void]$Seen.Add([string]$e.id) }
# Tant qu'aucun reset n'a eu lieu, la premiere session commence a "firstSessionStart",
# ex. "2026-11-26T16:49:00+01:00" (avec le decalage horaire : GitHub Actions tourne en UTC).
# Sans decalage, c'est l'heure du PC. Vide = tout l'historique disponible.
$firstStart = $startupConfig.firstSessionStart
if ([int]$State.resets -eq 0 -and $firstStart) {
    $dto = [DateTimeOffset]::MinValue
    $parsed = $true
    if ($firstStart -is [DateTime]) { $dto = [DateTimeOffset]$firstStart }
    elseif (-not [DateTimeOffset]::TryParse([string]$firstStart, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeLocal, [ref]$dto)) {
        Write-Host "firstSessionStart illisible dans la config : '$firstStart' (format attendu : 2026-11-26T16:49:00+01:00)" -ForegroundColor Yellow
        $parsed = $false
    }
    if ($parsed) {
        $wanted = [int64]$dto.ToUnixTimeSeconds()
        if ($wanted -ne [int64]$State.sessionStart) {
            # Debut avance dans le passe : il faut relire l'historique plus ancien.
            if ($wanted -lt [int64]$State.sessionStart) { $State.cursorTime = [int64]0 }
            $State.sessionStart = $wanted
            Write-Log "Premiere session : on compte a partir du $($dto.ToLocalTime().ToString('dd/MM/yyyy HH:mm:ss'))"
        }
    }
}

$MemberSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($m in $State.members) { [void]$MemberSet.Add([string]$m) }
foreach ($m in @($startupConfig.initialMembers)) { if ($m) { Add-Participant ([string]$m).Trim() } }
foreach ($e in $State.entries) {
    if ([int64]$e.time -lt [int64]$State.sessionStart) { continue }
    if (Test-Counted ([string]$e.account) ([string]$e.action) $startupConfig) { Add-Participant ([string]$e.account) }
}
Save-State

if ($Once) {
    # Un passage : lecture de l'historique, reset si demande, puis data.json. Le fichier n'est
    # reecrit que si le classement a change (champ "rev"), lors d'un reset, ou toutes les
    # 15 min pour que la page sache que le suivi tourne toujours.

    # Diagnostic sans fuite : longueur, format et debut du SHA-256 du cookie (irreversible),
    # pour verifier que le secret GitHub est bien le meme que celui du PC.
    $sessid = ([string]$startupConfig.poesessid).Trim()
    $fmt = 'inattendu (32 caracteres 0-9a-f attendus)'
    if ($sessid -match '^[0-9a-f]{32}$') { $fmt = 'ok' }
    Write-Log "POESESSID : $($sessid.Length) caracteres, format $fmt, empreinte $((Get-Sha256Hex $sessid).Substring(0, 8))"
    Remove-Variable sessid

    try { Invoke-Poll } catch { Write-Log "Erreur de synchro : $($_.Exception.Message)" }
    if ($Reset) { Reset-Session $startupConfig }
    if (-not $PublicPath) { $PublicPath = Join-Path $DataDir 'data.json' }

    $view = Get-PublicView $startupConfig
    $rev = Get-Sha256Hex (ConvertTo-Json -InputObject $view -Depth 8 -Compress)
    $now = Get-UnixNow
    $prevRev = ''
    $prevAt = [int64]0
    if (Test-Path -LiteralPath $PublicPath) {
        try {
            $prev = [IO.File]::ReadAllText($PublicPath, $Utf8) | ConvertFrom-Json
            $prevRev = [string](Get-Prop $prev 'rev' '')
            $prevAt = [int64](Get-Prop $prev 'publishedAt' 0)
        } catch { }
    }
    if ($Reset -or $rev -ne $prevRev -or ($now - $prevAt) -ge 900) {
        $view | Add-Member -NotePropertyName lastSuccess -NotePropertyValue $State.lastSuccess
        $view | Add-Member -NotePropertyName publishedAt -NotePropertyValue $now
        $view | Add-Member -NotePropertyName rev -NotePropertyValue $rev
        [IO.File]::WriteAllText($PublicPath, (ConvertTo-Json -InputObject $view -Depth 8 -Compress), $Utf8)
        Write-Log "data.json mis a jour ($($view.totalAdded) temple(s) depose(s))"
    } else {
        Write-Log 'Classement inchange : rien a publier'
    }
    exit 0
}

$port = [int]$startupConfig.port
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://localhost:$port/")
try {
    $listener.Start()
} catch {
    Write-Host ''
    Write-Host "Impossible d'ouvrir le port $port : $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'Le port est peut-etre deja utilise (serveur deja lance ?). Change "port" dans config.json.'
    exit 1
}

$ghCmd = Get-Command gh -ErrorAction SilentlyContinue
if ($ghCmd) { $script:GhPath = $ghCmd.Source }

Write-Host ''
Write-Host "  Temple Tracker demarre : http://localhost:$port/" -ForegroundColor Green
if ([string]$startupConfig.githubRepo) {
    if ($script:GhPath) {
        Write-Host "  Page publique (GitHub) : $(Get-PublicUrl $startupConfig)" -ForegroundColor Green
    } else {
        Write-Host '  GitHub CLI (gh) introuvable : la page publique ne sera pas mise a jour.' -ForegroundColor Yellow
    }
}
Write-Host '  Ferme cette fenetre (ou Ctrl+C) pour l''arreter.'
Write-Host ''
if (-not $NoBrowser) { try { Start-Process "http://localhost:$port/" } catch { } }

Invoke-Sync

try {
    while ($listener.IsListening) {
        if ((Get-UnixNow) -ge $script:NextPollAt) { Invoke-Sync }
        $task = $listener.GetContextAsync()
        while (-not $task.AsyncWaitHandle.WaitOne(1000)) {
            if ((Get-UnixNow) -ge $script:NextPollAt) { Invoke-Sync }
        }
        $ctx = $task.GetAwaiter().GetResult()
        try {
            Invoke-Request $ctx
        } catch {
            Write-Log "Erreur sur $($ctx.Request.HttpMethod) $($ctx.Request.Url.AbsolutePath) : $($_.Exception.Message)"
            try { Send-Json $ctx 500 @{ error = 'server' } } catch { }
        }
    }
} finally {
    try { $listener.Stop(); $listener.Close() } catch { }
    try { Save-State } catch { }
}
