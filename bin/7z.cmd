
rem script:		@rgadguard
rem version:	v1.10.0

title Working - 7z

cls
set passwd="ms_by_rgadguard"

set flist=list.txt
if defined cart (
	"%aria2%">nul -x1 -s1 -d"%dir_temp%" -o"list_7z.txt" "!server!/dl/%key%/%uuid%/list" --disable-ipv6
	set flist=list_7z.txt
)

for /f "tokens=1,2 delims=^|" %%b in ('type "%dir_temp%\!flist!"') do (
	call :7ze %%b "%%c"
)
exit /b

:7ze
echo Unpacking %1.7z to %~2
if exist "%cd%\tmp\%~1.7z" (
	"%x7z%">nul x "%cd%\tmp\%~1.7z" -o"%dir_temp%" -p"%passwd%"
	
	rem	set file=
	rem	if exist "%dir_temp%\%~2" set "file=%dir_temp%\%~2"
	rem	if exist "%dir_temp%\%~2.svf" set "file=%dir_temp%\%~2.svf"
	rem call :7zt "%file%"
)

exit /b

:7zt
echo Checking checksum - %~nx1...
for /f "tokens=1 delims=" %%a in ('certutil -hashfile "%file%" SHA1 ^| findstr ^[0-9a-f]$') do (
	set "sha1_7z=%%a"
	set "sha1_7z=!sha1_7z: =!"
	for /f "tokens=1 delims=" %%c in ('type "%file%.hash"') do (
		if /i "!sha1_7z!" EQU "%%c" (
			echo Successfully unpacked file...
			echo.
			del>nul /f /q "%file%.hash"
		) else (
			goto :7zrr
		)
	)
)
exit /b

:7zrr
cls
color 4f
echo.
call :tr r
echo.
echo.
echo            Errors were detected during unpacking...
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