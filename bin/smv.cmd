
rem script:		@rgadguard
rem version:	v1.10.0

title Working - SmartVersion

cls
set "oldfl="

cd /d "%dir_temp%"
if defined cart (call :smv_cart) else (call :smv %count%)
cd /d "..\"
exit /b

:smv
if /i %1 GEQ 1 (
	for /f "tokens=2 delims=^|" %%a in ('find /V /N "" "%dir_temp%\list.txt" ^| find "[%1]"') do (
		if exist "%%a.svf" (
			"%smv%" x "%%a.svf" -br . 
			if /i "%ListSel%" EQU "S" (
				move>nul /y "!oldfl!" "..\!oldfl!"
			) else (
				if /i "%ListSel%" EQU "F" (
					del>nul /q /f "!oldfl!"
				)
			)
			echo.
			if defined cart del>nul /f /q "%%a.svf"
			if not exist "%%a" goto :smvrr
		)
		if exist "%%a.dvp" (
			"%dvp%" -o "%%a" "%%a.dvp"
			if /i "%ListSel%" EQU "S" (
				move>nul /y "!oldfl!" "..\!oldfl!"
			) else (
				if /i "%ListSel%" EQU "F" (
					del>nul /q /f "!oldfl!"
				)
			)
			echo.
			if defined cart del>nul /f /q "%%a.dvp"
			if not exist "%%a" goto :smvrr
		)
		set "oldfl=%%a"
	)
	set /a count-=1
	call :smv !count!
) else (
	if exist !oldfl! (
		echo Download checkinfo SHA1 - !oldfl!...
		"%aria2%">nul -x1 -s1 -d"%dir_temp%" -o"sha1.txt" "!server!/file/%uuid%/sha1" --disable-ipv6
		echo Checking checksum - !oldfl!...
		for /f "tokens=1 delims=" %%a in ('certutil -hashfile "!oldfl!" SHA1 ^| findstr ^[0-9a-f]$') do (
			set "sha1=%%a"
			set "sha1=!sha1: =!"
			for /f "tokens=1 delims=" %%c in ('type "%dir_temp%\sha1.txt"') do (
				if /i "!sha1!" EQU "%%c" (
					echo Successfully checksum file...
					if not defined cart move>nul /y "!oldfl!" "..\!oldfl!"
				) else (
					goto :smvrr
				)
			)
		)
		echo.
	)
)
exit /b

:smv_cart
set "ListSel=C"
for /f "tokens=1 delims=" %%a in ('type "%dir_temp%\list_cart.txt"') do set /a ccart+=1
FOR /L %%a IN (1,1,!ccart!) DO (
	for /f "tokens=2 delims=^|[]" %%b in ('find /V /N "" "%dir_temp%\list_cart.txt" ^| find "[%%a]"') do (
		if exist "..\tmp\%%b.7z" (
			"%aria2%">nul -x1 -s1 -d"%dir_temp%" -o"list.txt" "!server!/file/%%b/list" --disable-ipv6
			set "uuid=%%b"
			for /f "tokens=1 delims=" %%b in ('type "%dir_temp%\list.txt"') do set /a count+=1
			call :smv !count!
			erase /f /q "%dir_temp%\list.txt"
			erase /f /q "%dir_temp%\sha1.txt"
		)
	)
)
for /f "tokens=2 delims=^|" %%a in ('type "%dir_temp%\list_cart.txt"') do (
	move>nul "%%a" "..\%%a"
)
exit /b

:smvrr
cd /d "..\"
cls
color 4f
echo.
call :tr r
echo.
echo.
echo                  SVF file processing error...
echo.
echo.
call :tr r
echo.
echo.
rd>nul /s /q "%dir_temp%"
pause
exit

:tr
if "%1" EQU "r" echo ====================================================================================================
exit /b