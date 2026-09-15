@echo off
setlocal EnableExtensions EnableDelayedExpansion
chcp 936 >nul 2>&1
title DLUT 校园网一键修复

rem ===========================================================================
rem  DLUT 校园网认证故障 一键修复 / 诊断          v2026-09-15
rem
rem  适用：大连理工大学（开放网络 + 网页 Portal 认证）
rem    凌水校区 DLUT-LingShui  —— 已实测
rem    盘锦校区 DLUT-panjin    —— 常量未实测，脚本会自动识别并切换
rem    开发区校区、eduroam、DLUT-1X 等 802.1X / 需密码的网络 —— 不适用，见下方说明
rem
rem  用法：
rem    双击运行       -> 弹出菜单，可选「只诊断」或「一键修复」
rem    -diag          -> 只诊断，不修改任何配置（无需管理员）
rem    -fix           -> 直接修复，不弹菜单（需要管理员，会自动提权）
rem    -y             -> 跳过交互确认
rem    -nopause       -> 结束后不停留，直接退出
rem    -panjin        -> 强制按盘锦校区常量处理
rem    -lingshui      -> 强制按凌水校区常量处理
rem
rem  它修什么（2026-09-14 实测定位的两个根因）：
rem    1) 无线配置文件损坏：netsh 报「指定的网络无法用于连接」，Windows 退化
rem       成「不使用配置文件连接」，MAC 与 IP 绑定关系异常，DHCP 被持续 NACK
rem    2) hosts 把认证域名硬编码到失效 IP：202.118.66.117（真实为 .137），
rem       认证页因此永远打不开
rem
rem  它修不了什么（本机配置之外的故障，脚本只能诊断并给出该找谁）：
rem    * 账号欠费 / 流量用尽 / 账号被锁
rem    * 账号侧 MAC 绑定错乱（需到 tulip 自助服务把设备全部下线）
rem    * 楼宇交换机 DHCP 池耗尽、校园网整体故障
rem    * 网卡驱动异常、无线网卡硬件故障
rem    * 802.1X（WPA2-企业）或需要密码的 SSID —— 本脚本生成的是开放式配置
rem
rem  备份：脚本同目录 backup\（hosts.bak、WLAN-无线名.xml、无线名-clean.xml）
rem  回滚：运行结束时屏幕下方会打印回滚命令
rem ===========================================================================

rem ---- 默认常量：凌水校区（2026-09-14 实测确认） ----
set "SSID=DLUT-LingShui"
set "PORTAL=auth.dlut.edu.cn"
set "PORTALIP=202.118.66.137"
set "TULIP=tulip.dlut.edu.cn"
set "CAMPUSGW=10.5.0.1"
set "HOTLINE=84707007"
set "CAMPUS=凌水校区"
set "CAMPUSNOTE="

set "HOSTS=%SystemRoot%\System32\drivers\etc\hosts"
set "BAKDIR=%~dp0backup"
set "FORCE_PRESET="

rem hosts 里要清掉的：有效行 + 指向 auth 域名
rem 用 \sauth\. 而不是 auth\.，避免误伤 oauth.xxx 这类无关记录
set "HPAT=^\s*[0-9].*\sauth\."

rem ---- 参数解析 ----
set "DIAG=0"
set "MODE="
set "ASSUME_YES=0"
set "NOPAUSE=0"
:parse
if "%~1"=="" goto :parsed
if /i "%~1"=="-diag"    set "MODE=DIAG"
if /i "%~1"=="/diag"    set "MODE=DIAG"
if /i "%~1"=="--diag"   set "MODE=DIAG"
if /i "%~1"=="-fix"     set "MODE=FIX"
if /i "%~1"=="/fix"     set "MODE=FIX"
if /i "%~1"=="-y"       set "ASSUME_YES=1"
if /i "%~1"=="/y"       set "ASSUME_YES=1"
if /i "%~1"=="-nopause" set "NOPAUSE=1"
if /i "%~1"=="-panjin"   set "FORCE_PRESET=PANJIN"
if /i "%~1"=="-lingshui" set "FORCE_PRESET=LINGSHUI"
shift
goto :parse
:parsed

rem ---- 没带模式参数（双击的场景）就给个菜单，学生不用记参数 ----
rem 用 choice 而不是 set /p：set /p 在没有可用输入时会让批处理一直挂着等输入，
rem choice 带 /T 超时兜底，最多等 15 秒就自动按「只诊断」继续，绝不会卡死。
if "%MODE%"=="" call :askmode
if "%MODE%"=="DIAG" set "DIAG=1"

rem ---- 校区预设：默认按扫到的 SSID 自动判断，也可用 -panjin / -lingshui 强制 ----
set "PRESET="
if "%FORCE_PRESET%"=="PANJIN"   set "PRESET=PANJIN"
if "%FORCE_PRESET%"=="LINGSHUI" set "PRESET=LINGSHUI"
if not "%PRESET%"=="" goto :preset_apply
for /f "usebackq delims=" %%P in (`powershell -NoProfile -Command "$n=@(netsh wlan show networks mode=bssid | Select-String '^\s*SSID\s+\d+\s*:'); $x=@($n | ForEach-Object { ($_.Line -split ':',2)[1].Trim() }); if($x -contains 'DLUT-panjin'){'PANJIN'}elseif($x -contains 'DLUT-LingShui'){'LINGSHUI'}else{'DEFAULT'}" 2^>nul`) do set "PRESET=%%P"
:preset_apply
if "%PRESET%"=="PANJIN" call :preset_panjin
if "%PRESET%"=="" set "PRESET=DEFAULT"

rem SSID 的 ASCII 十六进制；优先动态重算，失败才用这个凌水校区的硬编码值
set "SSIDHEX=444C55542D4C696E6753687569"
for /f "usebackq delims=" %%H in (`powershell -NoProfile -Command "[BitConverter]::ToString([Text.Encoding]::ASCII.GetBytes($env:SSID)).Replace('-','')" 2^>nul`) do set "SSIDHEX=%%H"

rem ---- 提权（只诊断模式不需要管理员） ----
if "%DIAG%"=="1" goto :admin_ok
net session >nul 2>&1
if errorlevel 1 goto :elevate
goto :admin_ok

:elevate
echo.
echo [INFO] 修复需要管理员权限，正在请求提权，请在弹窗中点击「是」。
set "REL=-fix"
if /i "%FORCE_PRESET%"=="PANJIN"   set "REL=%REL% -panjin"
if /i "%FORCE_PRESET%"=="LINGSHUI" set "REL=%REL% -lingshui"
if "%ASSUME_YES%"=="1" set "REL=%REL% -y"
powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs -ArgumentList '%REL%'"
exit /b

:admin_ok
echo.
echo ============================================================
echo   DLUT 校园网认证故障 一键修复   v2026-09-15
if "%DIAG%"=="1" echo   模式：只诊断，不修改任何配置
if "%DIAG%"=="0" echo   模式：修复（重建无线配置 + 清理 hosts，全部自动备份）
echo   适用校区    : %CAMPUS%  （预设 %PRESET%，可用 -panjin / -lingshui 强制切换）
echo   校园网 SSID : %SSID%
echo   认证页      : http://%PORTAL%
if not "%CAMPUSNOTE%"=="" echo   [注意] %CAMPUSNOTE%
echo ============================================================

call :head "1/8  无线网卡与当前网络"

for /f "usebackq delims=" %%I in (`powershell -NoProfile -Command "(Get-NetAdapter -Physical | Where-Object { $_.PhysicalMediaType -eq 'Native 802.11' } | Select-Object -First 1).Name" 2^>nul`) do set "WLANIF=%%I"
if "%WLANIF%"=="" set "WLANIF=WLAN"
set "ISWLAN=0"
powershell -NoProfile -Command "if((Get-NetAdapter -Name $env:WLANIF -ErrorAction SilentlyContinue).PhysicalMediaType -eq 'Native 802.11'){exit 7}; exit 0"
if errorlevel 7 set "ISWLAN=1"
for /f "usebackq delims=" %%M in (`powershell -NoProfile -Command "(Get-NetAdapter -Name $env:WLANIF -ErrorAction SilentlyContinue).MacAddress" 2^>nul`) do set "WLANMAC=%%M"
for /f "usebackq delims=" %%S in (`powershell -NoProfile -Command "$s=(netsh wlan show interfaces) | Where-Object { $_ -match '^\s*SSID\s*:' } | Select-Object -First 1; if($s){($s -split ':',2)[1].Trim()}else{'NONE'}" 2^>nul`) do set "CURSSID=%%S"
if "%CURSSID%"=="" set "CURSSID=NONE"
call :wlanip

echo   无线接口     : %WLANIF%
echo   网卡物理地址 : %WLANMAC%
echo   当前所连SSID : %CURSSID%
echo   WLAN IPv4    : %WLANIP%
echo   提示：校园网按 MAC 绑定账号，网卡务必保持 MAC 随机化关闭。
if "%CURSSID%"=="%SSID%" echo   [OK] 当前已连在校园网上
if not "%CURSSID%"=="%SSID%" echo   [INFO] 当前不在校园网，若显示手机热点属正常
if "%PRESET%"=="LINGSHUI" echo   [OK] 使用凌水校区常量，SSID=%SSID%
if "%PRESET%"=="PANJIN"   echo   [OK] 使用盘锦校区常量，SSID=%SSID%
if "%PRESET%"=="DEFAULT"  echo   [INFO] 范围内没扫到校内 SSID，按凌水校区常量处理；在宿舍用手机热点时属正常

call :head "2/8  备份"
if "%DIAG%"=="1" echo   [跳过] -diag 模式不做任何写入
if "%DIAG%"=="0" call :dobackup

call :head "3/8  无线服务与配置文件状态"
set "SVCRUN=1"
sc query WlanSvc | findstr /i "RUNNING" >nul 2>&1 || set "SVCRUN=0"
if "%SVCRUN%"=="1" echo   [OK] WLAN AutoConfig 服务运行中
if "%SVCRUN%"=="0" echo   [WARN] WLAN AutoConfig 服务未运行
if "%DIAG%"=="0" if "%SVCRUN%"=="0" call :startsvc
set "PROF=0"
netsh wlan show profiles | findstr /i /c:"%SSID%" >nul 2>&1 && set "PROF=1"
if "%PROF%"=="1" echo   [OK] 已保存无线配置 %SSID%
if "%PROF%"=="1" powershell -NoProfile -Command "(netsh wlan show profile ('name='+$env:SSID)) | Select-String -Pattern '连接模式|Connection mode|随机化|randomization' | ForEach-Object { '   ' + $_.Line.Trim() }"
if "%PROF%"=="0" echo   [WARN] 没有找到 %SSID% 的无线配置

call :head "4/8  hosts 检查，认证域名是否被硬编码"
powershell -NoProfile -Command "$m=Select-String -LiteralPath $env:HOSTS -Pattern $env:HPAT -ErrorAction SilentlyContinue; if($m){ $m | ForEach-Object { '   [异常] ' + $_.Line } } else { '   [OK] 未发现认证域名被硬编码' }"
set "HFOUND=0"
powershell -NoProfile -Command "if(Select-String -LiteralPath $env:HOSTS -Pattern $env:HPAT -ErrorAction SilentlyContinue){exit 9}; exit 0"
if errorlevel 9 set "HFOUND=1"
if "%HFOUND%"=="0" echo   [INFO] hosts 无需改动
if "%HFOUND%"=="1" if "%DIAG%"=="1" echo   [WARN] 发现失效硬编码，-diag 模式不修改，去掉 -diag 重跑即可修复
if "%HFOUND%"=="1" if "%DIAG%"=="0" call :fixhosts
echo   hosts 里其它 dlut 相关记录，只报告不修改：
powershell -NoProfile -Command "$m=Select-String -LiteralPath $env:HOSTS -Pattern '^\s*[0-9].*dlut' -ErrorAction SilentlyContinue; if($m){ $m | ForEach-Object { '      ' + $_.Line } } else { '      无' }"

call :head "5/8  无线配置文件重建"
if "%DIAG%"=="1" echo   [跳过] -diag 模式不改配置
if "%DIAG%"=="0" call :rebuild

call :head "6/8  连接校园网并获取 IP"
if "%DIAG%"=="1" echo   [跳过] -diag 模式不切换网络
if "%DIAG%"=="0" call :connandip

call :head "7/8  认证链路检查"
call :linkcheck

call :head "8/8  打开认证页"
if "%DIAG%"=="1" echo   [跳过] -diag 模式不自动打开浏览器
if "%DIAG%"=="0" call :openportal

call :summary
if "%DIAG%"=="0" call :mayberestore
call :finish
goto :eof

rem ---------------------------------------------------------------------------
rem  子过程
rem ---------------------------------------------------------------------------

:wlanip
set "WLANIP=NONE"
for /f "usebackq delims=" %%A in (`powershell -NoProfile -Command "$a=Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceAlias -eq $env:WLANIF } | Select-Object -First 1; if($a){$a.IPAddress}else{'NONE'}" 2^>nul`) do set "WLANIP=%%A"
goto :eof

:wlanconnect
if "%ISWLAN%"=="1" goto :wc1
netsh wlan connect name="%SSID%"
goto :eof
:wc1
netsh wlan connect name="%SSID%" interface="%WLANIF%"
goto :eof

:wlanconnect_q
if "%ISWLAN%"=="1" goto :wcq1
netsh wlan connect name="%SSID%" >nul 2>&1
goto :eof
:wcq1
netsh wlan connect name="%SSID%" interface="%WLANIF%" >nul 2>&1
goto :eof

:askmode
echo.
echo ============================================================
echo   DLUT 校园网认证故障 一键修复   v2026-09-15
echo ============================================================
echo   [1] 只诊断    不改任何配置，不需要管理员，约 10 秒出结果
echo   [2] 一键修复  重建无线配置 + 清理 hosts，需要管理员权限
echo.
choice /C 12 /N /T 15 /D 1 /M "  按 1 只诊断 / 按 2 一键修复（15 秒不选则按只诊断处理）: "
set "MODE=DIAG"
if errorlevel 2 set "MODE=FIX"
echo.
goto :eof

:preset_panjin
set "SSID=DLUT-panjin"
set "PORTAL=auth.dlut.edu.cn"
set "PORTALIP=172.17.3.10"
set "TULIP=tulip.dlut.edu.cn"
set "CAMPUSGW="
set "HOTLINE=0427-2631978"
set "CAMPUS=盘锦校区"
set "CAMPUSNOTE=盘锦校区常量来自公开信息，未实测；若与实际不符请改脚本头部常量"
goto :eof

:dobackup
if not exist "%BAKDIR%" mkdir "%BAKDIR%" >nul 2>&1
if not exist "%BAKDIR%" set "BAKDIR=%TEMP%\dlut-net-backup"
if not exist "%BAKDIR%" mkdir "%BAKDIR%" >nul 2>&1
copy /y "%HOSTS%" "%BAKDIR%\hosts.bak" >nul 2>&1
if exist "%BAKDIR%\hosts.bak" echo   [OK] hosts → %BAKDIR%\hosts.bak
netsh wlan export profile name="%SSID%" folder="%BAKDIR%" >nul 2>&1
if exist "%BAKDIR%\WLAN-%SSID%.xml" echo   [OK] 无线配置 → %BAKDIR%\WLAN-%SSID%.xml
echo   备份目录 : %BAKDIR%
goto :eof

:startsvc
echo   [INFO] 正在启动 WLAN AutoConfig 服务...
net start WlanSvc
call :sleep 3
goto :eof

:fixhosts
net session >nul 2>&1
if errorlevel 1 echo   [WARN] 当前不是管理员，跳过 hosts 修改，请以管理员身份重跑
if errorlevel 1 goto :eof
echo   [INFO] 把失效的硬编码注释掉，不删除，便于回滚...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$p=$env:HOSTS; $d=(Get-Date -Format yyyy-MM-dd); $o=@(); $n=0; foreach($l in (Get-Content -LiteralPath $p)){ if($l -match '^\s*[0-9]' -and $l -match 'auth\.'){ $o+=('# disabled '+$d+' stale hardcoded portal IP: '+$l); $n++ } else { $o+=$l } }; if($n -gt 0){ Set-Content -LiteralPath $p -Value $o -Encoding Default; '   [OK] 已注释 ' + $n + ' 条失效记录' } else { '   [INFO] 无需改动' }"
ipconfig /flushdns >nul 2>&1
echo   [INFO] 已刷新 DNS 缓存
goto :eof

:rebuild
net session >nul 2>&1
if errorlevel 1 echo   [WARN] 当前不是管理员，跳过配置重建，请以管理员身份重跑
if errorlevel 1 goto :eof
set "XMLOUT=%BAKDIR%\%SSID%-clean.xml"
if not exist "%BAKDIR%" set "XMLOUT=%TEMP%\%SSID%-clean.xml"
echo   [INFO] 生成干净配置：开放网络 / 手动连接 / MAC 随机化关闭
> "%XMLOUT%" echo ^<?xml version="1.0" encoding="UTF-8"?^>
>>"%XMLOUT%" echo ^<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1"^>
>>"%XMLOUT%" echo    ^<name^>%SSID%^</name^>
>>"%XMLOUT%" echo    ^<SSIDConfig^>
>>"%XMLOUT%" echo        ^<SSID^>
>>"%XMLOUT%" echo            ^<hex^>%SSIDHEX%^</hex^>
>>"%XMLOUT%" echo            ^<name^>%SSID%^</name^>
>>"%XMLOUT%" echo        ^</SSID^>
>>"%XMLOUT%" echo        ^<nonBroadcast^>false^</nonBroadcast^>
>>"%XMLOUT%" echo    ^</SSIDConfig^>
>>"%XMLOUT%" echo    ^<connectionType^>ESS^</connectionType^>
>>"%XMLOUT%" echo    ^<connectionMode^>manual^</connectionMode^>
>>"%XMLOUT%" echo    ^<autoSwitch^>false^</autoSwitch^>
>>"%XMLOUT%" echo    ^<MSM^>
>>"%XMLOUT%" echo        ^<security^>
>>"%XMLOUT%" echo            ^<authEncryption^>
>>"%XMLOUT%" echo                ^<authentication^>open^</authentication^>
>>"%XMLOUT%" echo                ^<encryption^>none^</encryption^>
>>"%XMLOUT%" echo                ^<useOneX^>false^</useOneX^>
>>"%XMLOUT%" echo            ^</authEncryption^>
>>"%XMLOUT%" echo        ^</security^>
>>"%XMLOUT%" echo    ^</MSM^>
>>"%XMLOUT%" echo    ^<MacRandomization xmlns="http://www.microsoft.com/networking/WLAN/profile/v3"^>
>>"%XMLOUT%" echo        ^<enableRandomization^>false^</enableRandomization^>
>>"%XMLOUT%" echo    ^</MacRandomization^>
>>"%XMLOUT%" echo ^</WLANProfile^>

set "XMLOK=0"
if exist "%XMLOUT%" set "XMLOK=1"
findstr /c:"<enableRandomization>false</enableRandomization>" "%XMLOUT%" >nul 2>&1 || set "XMLOK=0"
if "%XMLOK%"=="0" echo   [FAIL] 配置生成不完整，已跳过重建，原配置未改动
if "%XMLOK%"=="1" echo   [OK] 已生成 %XMLOUT%
if "%XMLOK%"=="1" netsh wlan delete profile name="%SSID%" >nul 2>&1
if "%XMLOK%"=="1" netsh wlan add profile filename="%XMLOUT%" user=all
set "PROF2=0"
netsh wlan show profiles | findstr /i /c:"%SSID%" >nul 2>&1 && set "PROF2=1"
if "%PROF2%"=="1" echo   [OK] 配置文件重建成功
if "%PROF2%"=="1" goto :eof
echo   [FAIL] 重建失败，正在用备份自动回滚...
if exist "%BAKDIR%\WLAN-%SSID%.xml" netsh wlan add profile filename="%BAKDIR%\WLAN-%SSID%.xml" user=all
echo   [INFO] 若仍失败请手动导入：netsh wlan add profile filename="%BAKDIR%\WLAN-%SSID%.xml" user=all
goto :eof

:connandip
if "%CURSSID%"=="%SSID%" goto :ci_already
if "%CURSSID%"=="NONE" goto :ci_connect
echo   [INFO] 即将从 %CURSSID% 切到 %SSID%，若那是手机热点会被断开
if "%ASSUME_YES%"=="0" set /p "ANS=继续切换？Y/N : "
if "%ASSUME_YES%"=="0" if /i not "%ANS%"=="Y" goto :ci_abort
:ci_connect
echo   [INFO] 正在连接 %SSID% ...
call :wlanconnect
call :sleep 13
:ci_already
call :wlanip
echo   连接后 WLAN IPv4 : %WLANIP%
set "PFX=%WLANIP:~0,8%"
if "%PFX%"=="169.254." goto :ci_apipa
if "%WLANIP%"=="NONE" goto :ci_apipa
set "PFX=%WLANIP:~0,3%"
if "%PFX%"=="10." goto :ci_ok
if "%PFX%"=="172." goto :ci_ok
echo   [INFO] 拿到的地址不在常见校园网段，请人工确认
goto :ci_done
:ci_ok
echo   [OK] 已拿到校园网地址，DHCP 正常
goto :ci_done
:ci_apipa
echo   [FAIL] 没拿到有效地址，当前 %WLANIP%
if "%ISWLAN%"=="1" goto :ci_renew
echo   [WARN] 未能确认无线接口名，跳过 release，避免影响其它网卡
netsh wlan disconnect >nul 2>&1
call :sleep 3
call :wlanconnect_q
call :sleep 12
goto :ci_recheck
:ci_renew
echo   [INFO] 只对 %WLANIF% 强制续租...
ipconfig /release "%WLANIF%" >nul 2>&1
call :sleep 3
ipconfig /renew "%WLANIF%" >nul 2>&1
call :sleep 9
ipconfig /flushdns >nul 2>&1
:ci_recheck
call :wlanip
echo   续租后 WLAN IPv4 : %WLANIP%
set "PFX=%WLANIP:~0,8%"
if "%PFX%"=="169.254." echo   [FAIL] 仍未拿到地址，请按第 8 步提示到自助服务下线全部设备后重试
if "%WLANIP%"=="NONE" echo   [FAIL] 仍未拿到地址，请按第 8 步提示到自助服务下线全部设备后重试
if not "%PFX%"=="169.254." if not "%WLANIP%"=="NONE" echo   [OK] 续租成功
goto :ci_done
:ci_abort
echo   [INFO] 已取消切换网络
:ci_done
goto :eof

:linkcheck
set "GWRES=0"
if "%CAMPUSGW%"=="" goto :lc_no_gw
ping -n 2 -w 1500 %CAMPUSGW% | findstr /i "TTL" >nul 2>&1 && set "GWRES=1"
:lc_no_gw
if "%CAMPUSGW%"=="" echo   [INFO] 该校区网关地址未知，跳过网关检查
if not "%CAMPUSGW%"=="" if "%GWRES%"=="1" echo   [OK] 校园网关 %CAMPUSGW% 可达
if not "%CAMPUSGW%"=="" if "%GWRES%"=="0" echo   [WARN] 校园网关 %CAMPUSGW% 不可达
set "PRES=0"
ping -n 2 -w 1500 %PORTALIP% | findstr /i "TTL" >nul 2>&1 && set "PRES=1"
if "%PRES%"=="1" echo   [OK] 认证服务器 %PORTALIP% 可达
if "%PRES%"=="0" echo   [WARN] 认证服务器 %PORTALIP% 不可达
echo   认证域名解析 %PORTAL% ：
powershell -NoProfile -Command "try{ $r=@(Resolve-DnsName $env:PORTAL -Type A -ErrorAction Stop | Where-Object { $_.IPAddress } | ForEach-Object { $_.IPAddress } | Sort-Object -Unique); if($r.Count -gt 0){ $r | ForEach-Object { '      ' + $env:PORTAL + '  →  ' + $_ } } else { '      [WARN] 无 A 记录，未连校园网时属正常' } } catch { '      [WARN] 解析失败：' + $_.Exception.Message }"
echo   认证页 HTTP ：
rem 注意：必须关掉自动重定向。Portal 会把请求重定向到一个不可达地址，追下去会卡死。
rem 不追重定向时，未认证的校园网会立刻返回 302，这本身就是「认证页劫持生效」的铁证。
powershell -NoProfile -Command "$r=[System.Net.HttpWebRequest]::Create('http://'+$env:PORTAL); $r.Timeout=5000; $r.AllowAutoRedirect=$false; $r.UserAgent='dlut-net-fix'; try{ $rr=$r.GetResponse(); '      [OK] 认证页 HTTP ' + [int]$rr.StatusCode; $rr.Close() } catch [System.Net.WebException] { if($_.Exception.Response){ '      [OK] 认证页 HTTP ' + [int]$_.Exception.Response.StatusCode + '，Portal 重定向正常，链路已通' } else { '      [INFO] 认证页无响应：' + $_.Exception.Message + '，已登录认证后不响应属正常' } }"
echo   说明：未登录认证时 IPv4 公网 ping 不通属正常，不是故障。
goto :eof

:openportal
start "" "http://%PORTAL%"
echo   已打开认证页，请用学号 + 密码登录并选择线路。
goto :eof

:summary
echo.
echo ------------------------------ 小结 ------------------------------
echo   本脚本只修本机配置（无线配置损坏 + hosts 失效硬编码）；账号欠费、账号侧
echo   MAC 绑定、楼宇交换机故障等不在范围内，请按下面第 1、4 条处理。
if "%DIAG%"=="1" echo   本次为 -diag 诊断模式，未修改任何配置，也没有生成备份
if "%DIAG%"=="0" echo   备份目录 : %BAKDIR%
if "%DIAG%"=="0" echo   回滚 hosts :
if "%DIAG%"=="0" echo     copy /y "%BAKDIR%\hosts.bak" "%HOSTS%"
if "%DIAG%"=="0" echo   回滚无线配置 :
if "%DIAG%"=="0" echo     netsh wlan add profile filename="%BAKDIR%\WLAN-%SSID%.xml" user=all
echo   仍然不通时 :
echo     1) 打开 http://%TULIP% → 自助服务 → 认证上网服务 → 在线信息 → 全部设备强制下线，再重新认证
echo     2) 确认套餐流量是否用完、账号是否欠费
echo     3) 关掉下载器 / BT / 多开浏览器，排除短端口耗尽
echo     4) 联系网信中心 %HOTLINE%，或 i大工 App → 网络自助 报修
echo ------------------------------------------------------------------
goto :eof

:mayberestore
if "%CURSSID%"=="%SSID%" goto :eof
if "%CURSSID%"=="NONE" goto :eof
if "%ASSUME_YES%"=="1" goto :eof
echo.
set /p "ANS2=是否切回原来的网络 %CURSSID% ？Y/N : "
if /i "%ANS2%"=="Y" netsh wlan connect name="%CURSSID%"
goto :eof

:head
echo.
echo === %~1 ===
goto :eof

:sleep
ping -n %~1 127.0.0.1 >nul 2>&1
goto :eof

:finish
if "%NOPAUSE%"=="1" goto :fin_done
echo.
echo 按任意键退出...
pause >nul
:fin_done
exit /b
