local u,t,c="https://raw.githubusercontent.com/mah0isto1-max/Signalka/main/startup.lua",os.startTimer(5);local function f(m)print(m);sleep(1);os.reboot()end;if not http then f("HTTP disabled")end;http.request(u)
while true do local e,a,b=os.pullEvent();if e=="http_success"and a==u then c=b.readAll();b.close();break elseif e=="http_failure"and a==u then f("Download failed")elseif e=="timer"and a==t then f("Timeout")end end
local n,r=load(c,"github","t",_ENV);if not n then f("Code error: "..(r or ""))end;n()
