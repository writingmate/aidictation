param(
    [Parameter(Mandatory = $true)]
    [string]$AppPath,
    [Parameter(Mandatory = $true)]
    [string]$ExpectedVersion,
    [string]$ReportDir = ""
)

$ErrorActionPreference = "Stop"

if (-not $ReportDir) {
    $ReportDir = Join-Path $env:RUNNER_TEMP "aidictation-windows-release-validation"
}
New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null

function Get-ThreePartVersion {
    param([Parameter(Mandatory = $true)] [string]$Version)

    $match = [regex]::Match($Version, '^\d+\.\d+\.\d+')
    if (-not $match.Success) {
        throw "Could not read a three-part product version from '$Version'."
    }
    return $match.Value
}

function Invoke-WebDriverJson {
    param(
        [Parameter(Mandatory = $true)] [string]$Uri,
        [string]$Method = "GET",
        [object]$Body = $null
    )

    $parameters = @{
        Uri = $Uri
        Method = $Method
        TimeoutSec = 15
    }
    if ($null -ne $Body) {
        $parameters.ContentType = "application/json"
        $parameters.Body = ($Body | ConvertTo-Json -Depth 8 -Compress)
    }
    return Invoke-RestMethod @parameters
}

function Get-WebDriverElement {
    param(
        [Parameter(Mandatory = $true)] [string]$SessionUrl,
        [Parameter(Mandatory = $true)] [string]$Selector
    )

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(20)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        try {
            $found = Invoke-WebDriverJson `
                -Uri "$SessionUrl/element" `
                -Method POST `
                -Body @{ using = "css selector"; value = $Selector }
            $id = $found.value.PSObject.Properties.Value | Select-Object -First 1
            if ($id) { return $id }
        } catch {
            Start-Sleep -Milliseconds 300
        }
    }
    throw "The public sign-in page did not expose $Selector."
}

function ConvertFrom-Fragment {
    param([Parameter(Mandatory = $true)] [string]$Fragment)

    $result = @{}
    foreach ($pair in $Fragment.TrimStart('#').Split('&')) {
        if (-not $pair) { continue }
        $parts = $pair.Split('=', 2)
        $name = [System.Net.WebUtility]::UrlDecode($parts[0])
        $value = if ($parts.Length -gt 1) {
            [System.Net.WebUtility]::UrlDecode($parts[1])
        } else {
            ""
        }
        $result[$name] = $value
    }
    return $result
}

function Start-PackagedValidation {
    param(
        [Parameter(Mandatory = $true)] [string]$Mode,
        [Parameter(Mandatory = $true)] [string]$ReportPath
    )

    if (Test-Path $ReportPath) {
        Remove-Item -Force $ReportPath
    }
    $process = Start-Process `
        -FilePath $AppPath `
        -ArgumentList @($Mode, $ReportPath) `
        -PassThru `
        -Wait
    if (-not (Test-Path $ReportPath)) {
        throw "The packaged app did not write its release-validation report."
    }
    $report = Get-Content -Raw $ReportPath | ConvertFrom-Json
    if ($process.ExitCode -ne 0 -or -not $report.success) {
        $reason = if ($report.error) { $report.error } else { "unknown validation failure" }
        throw "Packaged app release validation failed: $reason"
    }
    return $report
}

function Get-BrowserSessionTokens {
    param(
        [Parameter(Mandatory = $true)] [string]$Email,
        [Parameter(Mandatory = $true)] [string]$Password
    )

    $driverCommand = Get-Command chromedriver.exe -ErrorAction SilentlyContinue
    if (-not $driverCommand) {
        $driverCommand = Get-Command msedgedriver.exe -ErrorAction SilentlyContinue
    }
    if (-not $driverCommand) {
        throw "A supported WebDriver is required to verify the public browser sign-in flow."
    }

    $port = 9515
    $driverLog = Join-Path $ReportDir "webdriver.out.log"
    $driverErrorLog = Join-Path $ReportDir "webdriver.err.log"
    $driver = Start-Process `
        -FilePath $driverCommand.Source `
        -ArgumentList @("--port=$port") `
        -RedirectStandardOutput $driverLog `
        -RedirectStandardError $driverErrorLog `
        -PassThru
    $sessionUrl = $null

    try {
        $statusUrl = "http://127.0.0.1:$port/status"
        $readyDeadline = [DateTimeOffset]::UtcNow.AddSeconds(15)
        while ([DateTimeOffset]::UtcNow -lt $readyDeadline) {
            try {
                $status = Invoke-WebDriverJson -Uri $statusUrl
                if ($status.value.ready) { break }
            } catch {
                Start-Sleep -Milliseconds 300
            }
        }

        $browserName = if ($driverCommand.Name -like "msedge*") { "MicrosoftEdge" } else { "chrome" }
        $optionsName = if ($browserName -eq "MicrosoftEdge") { "ms:edgeOptions" } else { "goog:chromeOptions" }
        $alwaysMatch = @{ browserName = $browserName }
        $alwaysMatch[$optionsName] = @{
            args = @("--headless=new", "--disable-gpu", "--no-sandbox", "--window-size=1280,900")
        }
        $session = Invoke-WebDriverJson `
            -Uri "http://127.0.0.1:$port/session" `
            -Method POST `
            -Body @{ capabilities = @{ alwaysMatch = $alwaysMatch } }
        $sessionId = $session.value.sessionId
        if (-not $sessionId) { $sessionId = $session.sessionId }
        if (-not $sessionId) { throw "WebDriver did not create a browser session." }
        $sessionUrl = "http://127.0.0.1:$port/session/$sessionId"

        $callbackUrl = "https://aidictation.com/release-validation"
        $encodedCallback = [Uri]::EscapeDataString($callbackUrl)
        $authUrl = "https://aidictation.com/auth?redirect_to=$encodedCallback"
        Invoke-WebDriverJson -Uri "$sessionUrl/url" -Method POST -Body @{ url = $authUrl } | Out-Null

        $emailElement = Get-WebDriverElement -SessionUrl $sessionUrl -Selector "#email"
        $passwordElement = Get-WebDriverElement -SessionUrl $sessionUrl -Selector "#password"
        $submitElement = Get-WebDriverElement -SessionUrl $sessionUrl -Selector "button[type='submit']"
        Invoke-WebDriverJson `
            -Uri "$sessionUrl/element/$emailElement/value" `
            -Method POST `
            -Body @{ text = $Email } | Out-Null
        Invoke-WebDriverJson `
            -Uri "$sessionUrl/element/$passwordElement/value" `
            -Method POST `
            -Body @{ text = $Password } | Out-Null
        Invoke-WebDriverJson `
            -Uri "$sessionUrl/element/$submitElement/click" `
            -Method POST `
            -Body @{} | Out-Null

        $callback = $null
        $callbackDeadline = [DateTimeOffset]::UtcNow.AddSeconds(30)
        while ([DateTimeOffset]::UtcNow -lt $callbackDeadline) {
            $current = Invoke-WebDriverJson -Uri "$sessionUrl/url"
            if ($current.value -and $current.value.StartsWith("$callbackUrl#")) {
                $callback = [Uri]$current.value
                break
            }
            Start-Sleep -Milliseconds 500
        }
        if (-not $callback) {
            throw "The public browser sign-in did not return an app session."
        }

        $tokens = ConvertFrom-Fragment -Fragment $callback.Fragment
        if (-not $tokens.access_token -or -not $tokens.refresh_token) {
            throw "The public browser sign-in callback omitted session tokens."
        }
        return @{
            access_token = $tokens.access_token
            refresh_token = $tokens.refresh_token
        }
    } finally {
        if ($sessionUrl) {
            try { Invoke-WebDriverJson -Uri $sessionUrl -Method DELETE | Out-Null } catch { }
        }
        if ($driver -and -not $driver.HasExited) {
            Stop-Process -Id $driver.Id -Force
        }
        Remove-Item -Force -ErrorAction SilentlyContinue $driverLog, $driverErrorLog
    }
}

function ConvertTo-Base64Url {
    param([Parameter(Mandatory = $true)] [string]$Value)
    return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Value)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Start-LifetimeStub {
    param([Parameter(Mandatory = $true)] [int]$Port)

    return Start-Job -ScriptBlock {
        param($ListenPort)
        $listener = [System.Net.HttpListener]::new()
        $listener.Prefixes.Add("http://127.0.0.1:$ListenPort/")
        $listener.Start()
        try {
            for ($requestIndex = 0; $requestIndex -lt 2; $requestIndex++) {
                $context = $listener.GetContext()
                $path = $context.Request.Url.AbsolutePath
                if ($path -eq "/auth/v1/user") {
                    $json = '{"id":"11111111-1111-1111-1111-111111111111","email":"release-lifetime@example.test"}'
                } elseif ($path -eq "/rest/v1/profiles") {
                    $json = '[{"id":"22222222-2222-2222-2222-222222222222","user_id":"11111111-1111-1111-1111-111111111111","email":"release-lifetime@example.test","monthly_word_count":321,"subscription_status":"lifetime"}]'
                } else {
                    $context.Response.StatusCode = 404
                    $json = '{"error":"not found"}'
                }
                $bytes = [Text.Encoding]::UTF8.GetBytes($json)
                $context.Response.ContentType = "application/json"
                $context.Response.ContentLength64 = $bytes.Length
                $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                $context.Response.Close()
            }
        } finally {
            $listener.Stop()
            $listener.Close()
        }
    } -ArgumentList $Port
}

$app = Get-Item $AppPath
$productVersion = Get-ThreePartVersion -Version $app.VersionInfo.ProductVersion
if ($productVersion -ne $ExpectedVersion) {
    throw "Packaged app reports $productVersion; expected $ExpectedVersion."
}

$releaseSupabaseUrl = $env:SUPABASE_URL
$releaseSupabaseAnonKey = $env:SUPABASE_ANON_KEY
$releaseAuthWebUrl = $env:AUTH_WEB_URL
if ($releaseSupabaseUrl.TrimEnd('/') -ne "https://aidictation.com" -or
    $releaseAuthWebUrl.TrimEnd('/') -ne "https://aidictation.com/auth") {
    throw "Windows release endpoints must both use aidictation.com."
}

try {
    $env:SUPABASE_URL = $null
    $env:SUPABASE_ANON_KEY = $null
    $env:AUTH_WEB_URL = $null
    $configReportPath = Join-Path $ReportDir "packaged-config.json"
    $config = Start-PackagedValidation `
        -Mode "--validate-release-config" `
        -ReportPath $configReportPath
    if ($config.version -ne $ExpectedVersion -or
        $config.auth_web_url.TrimEnd('/') -ne "https://aidictation.com/auth" -or
        $config.profile_api_origin.TrimEnd('/') -ne "https://aidictation.com" -or
        -not $config.auth_backends_agree) {
        throw "The packaged app did not retain the release version and account-service configuration."
    }
} finally {
    $env:SUPABASE_URL = $releaseSupabaseUrl
    $env:SUPABASE_ANON_KEY = $releaseSupabaseAnonKey
    $env:AUTH_WEB_URL = $releaseAuthWebUrl
}

$testEmail = $env:AIDICTATION_RELEASE_TEST_EMAIL
$testPassword = $env:AIDICTATION_RELEASE_TEST_PASSWORD
if (-not $testEmail -or -not $testPassword) {
    throw "Authenticated browser release-test credentials are required."
}

$sessionTokens = Get-BrowserSessionTokens -Email $testEmail -Password $testPassword
try {
    $env:SUPABASE_URL = $null
    $env:SUPABASE_ANON_KEY = $null
    $env:AUTH_WEB_URL = $null
    $env:AIDICTATION_RELEASE_ACCESS_TOKEN = $sessionTokens.access_token
    $env:AIDICTATION_RELEASE_REFRESH_TOKEN = $sessionTokens.refresh_token
    $env:AIDICTATION_RELEASE_EXPECTED_TIER = ""
    $liveReportPath = Join-Path $ReportDir "live-account.json"
    $live = Start-PackagedValidation `
        -Mode "--validate-release-auth" `
        -ReportPath $liveReportPath
    if ($live.auth_host -ne "aidictation.com" -or
        $live.profile_api_host -ne "aidictation.com" -or
        -not $live.profile_record_loaded -or
        $live.tier -notin @("Free", "Pro", "Lifetime")) {
        throw "The packaged app did not load the live account, limits, and access tier."
    }
    if ($live.tier -eq "Free" -and $live.word_limit -ne 2000) {
        throw "The packaged app loaded the wrong free account limit."
    }
    if ($live.tier -in @("Pro", "Lifetime") -and $live.word_limit -ne [int]::MaxValue) {
        throw "The packaged app loaded a finite paid account limit."
    }
    $protocolCommand = (Get-Item `
        -Path "Registry::HKEY_CURRENT_USER\Software\Classes\aidictation\shell\open\command").GetValue("")
    if (-not $protocolCommand -or -not $protocolCommand.Contains((Get-Item $AppPath).FullName)) {
        throw "The packaged app did not register its browser callback to the installed executable."
    }
    Write-Host "Live packaged account validated: tier=$($live.tier), monthly_words=$($live.monthly_words), word_limit=$($live.word_limit)"
} finally {
    $env:AIDICTATION_RELEASE_ACCESS_TOKEN = $null
    $env:AIDICTATION_RELEASE_REFRESH_TOKEN = $null
    $env:AIDICTATION_RELEASE_EXPECTED_TIER = $null
    $env:SUPABASE_URL = $releaseSupabaseUrl
    $env:SUPABASE_ANON_KEY = $releaseSupabaseAnonKey
    $env:AUTH_WEB_URL = $releaseAuthWebUrl
}

$stubPort = 18765
$stubJob = Start-LifetimeStub -Port $stubPort
try {
    Start-Sleep -Milliseconds 800
    $header = ConvertTo-Base64Url -Value '{"alg":"none","typ":"JWT"}'
    $expiresAt = [DateTimeOffset]::UtcNow.AddHours(1).ToUnixTimeSeconds()
    $payload = ConvertTo-Base64Url -Value ("{\"exp\":$expiresAt}")
    $env:SUPABASE_URL = "http://127.0.0.1:$stubPort"
    $env:SUPABASE_ANON_KEY = "release-validation"
    $env:AUTH_WEB_URL = "http://127.0.0.1:$stubPort/auth"
    $env:AIDICTATION_RELEASE_ACCESS_TOKEN = "$header.$payload.release-validation"
    $env:AIDICTATION_RELEASE_REFRESH_TOKEN = "release-validation"
    $env:AIDICTATION_RELEASE_EXPECTED_TIER = "Lifetime"
    $lifetimeReportPath = Join-Path $ReportDir "lifetime-account.json"
    $lifetime = Start-PackagedValidation `
        -Mode "--validate-release-auth" `
        -ReportPath $lifetimeReportPath
    if ($lifetime.tier -ne "Lifetime" -or
        -not $lifetime.profile_record_loaded -or
        $lifetime.word_limit -ne [int]::MaxValue -or
        $lifetime.words_remaining -ne [int]::MaxValue -or
        $lifetime.has_reached_limit) {
        throw "The packaged app did not preserve lifetime access and unlimited limits."
    }
    Write-Host "Lifetime packaged account validated: tier=$($lifetime.tier), word_limit=unlimited"
} finally {
    $env:AIDICTATION_RELEASE_ACCESS_TOKEN = $null
    $env:AIDICTATION_RELEASE_REFRESH_TOKEN = $null
    $env:AIDICTATION_RELEASE_EXPECTED_TIER = $null
    $env:SUPABASE_URL = $releaseSupabaseUrl
    $env:SUPABASE_ANON_KEY = $releaseSupabaseAnonKey
    $env:AUTH_WEB_URL = $releaseAuthWebUrl
    if ($stubJob) {
        Stop-Job -Job $stubJob -ErrorAction SilentlyContinue
        Remove-Job -Job $stubJob -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "PASS: published-path browser sign-in, packaged profile/limits, and lifetime access validated"
