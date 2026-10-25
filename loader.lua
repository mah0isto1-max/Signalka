local u="https://raw.githubusercontent.com/mah0isto1-max/Signalka/main/startup.lua"
local res=http and http.get(u);if not res then print("Ошибка загрузки");sleep(3);os.reboot()end
local fn,err=load(res.readAll(),"github","t",_ENV);res.close();if not fn then print("Ошибка кода: "..(err or"?"));sleep(3);os.reboot()end;local ok,e=pcall(fn);if not ok then print("Ошибка запуска: "..tostring(e));sleep(3);os.reboot()end
