local core,profile,persistence=arg[1],arg[2],arg[3]
assert(core and profile and persistence)
dofile(persistence)
local sent,output,links,handlers={},{},{},{}
local separator=';;'
local failSend,sendCalls,nextHandler=nil,0,0
function getMudletHomeDir() return profile end
function getCommandSeparator() return separator end
function send(value)
  sendCalls=sendCalls+1
  if failSend=='throw' then error('fixture send error') end
  if failSend=='false' then return false end
  if failSend=='nil' then return nil,'fixture send error' end
  sent[#sent+1]=value
end
function echo(value) output[#output+1]=value end
function resetFormat() end
function setBold() end
function setUnderline() end
function setItalics() end
function setFgColor() end
function echoLink(label,fn,hint,format)
  assert(type(fn)=='function' and type(hint)=='string' and format==true)
  links[#links+1]={label=label,fn=fn};echo(label)
end
local draft
function printCmdLine(...)
  assert(select('#',...)==1,'must target main input, not a named input')
  draft=...;assert(type(draft)=='string')
end
function registerAnonymousEventHandler(name,fn)
  nextHandler=nextHandler+1;handlers[nextHandler]={name=name,fn=fn};return nextHandler
end
function killAnonymousEventHandler(id) handlers[id]=nil end
local function event(name,...)
  local callbacks={}
  for _,h in pairs(handlers) do if h.name==name then callbacks[#callbacks+1]=h.fn end end
  for _,fn in ipairs(callbacks) do fn(name,...) end
end
local function command(name,args) LotJComlink.dispatch(name,args or '') end
local function reset() sent={};output={};links={};sendCalls=0 end
local function text() return table.concat(output) end
local function contains(s) assert(text():find(s,1,true),text()) end
local function count(t) local n=0 for _ in pairs(t) do n=n+1 end return n end
local function complete(kind) LotJComlink[kind=='container' and 'mclOnContainerFinished' or 'mclOnComlinkFinished']() end
local function equal(t)
  assert(#sent==#t,'command count: '..#sent..' versus '..#t)
  for i,v in ipairs(t) do assert(sent[i]==v,tostring(i)..': '..sent[i]..' versus '..v) end
end
local function passed(label) print('PASS '..label) end

dofile(core)
assert(#sent==0 and count(handlers)==2)
command('mclstart');complete('comlink');complete('container');assert(#sent==0)
passed('empty install, empty queue and idle completions send nothing')
reset();command('mclhelp')
local expected={"mcladd ''",'mclremove ',"mclcontainer ''",'mclcontainer clear','mcliterations ',
 'mcllist','mclstart','mclstatus','mclstop','mclclear','mclhelp'}
assert(#links==#expected)
for i,link in ipairs(links) do link.fn();assert(draft==expected[i]) end
local lines=0 for line in text():gmatch('[^\n]+') do lines=lines+1;assert(#line<=76,line) end
assert(lines<=15 and #sent==0)
passed('all 11 links prefill exact commands; compact help sends nothing')
command('mcladd',"'sample one' 12345");command('mcladd','"sample \'two\'" 23456')
command('mclcontainer',"'sample case' case");command('mcliterations','3')
reset();command('mclstart')
for _=1,3 do complete('comlink');complete('comlink');complete('container') end
local batch={'makecomlink hold sample one','tune comlink 12345',"makecomlink hold sample 'two'",'tune comlink 23456',
 'makecontainer hold sample case','put comlink case','put comlink case'}
local full={} for _=1,3 do for _,s in ipairs(batch) do full[#full+1]=s end end
equal(full);contains('batch complete!');passed('three full tuned and packed batches in order')
reset();command('mclstart')
for _,cmd in ipairs({'mcladd','mclremove','mclcontainer','mcliterations','mclclear'}) do command(cmd,'fixture') end
local _,errors=text():gsub("can't change the batch",'');assert(errors==5)
complete('container');assert(#sent==1);command('mclstop');complete('comlink');assert(#sent==1)
passed('running edits, wrong-stage completion, and post-stop completion guarded')
reset();dofile(core);command('mcllist');contains("sample 'two'");contains('Iterations: 3')
command('mclstatus');contains('idle, nothing running.');assert(#sent==0 and count(handlers)==2)
passed('saved settings survive reload; idle and event handlers not duplicated')
command('mclcontainer','clear');command('mcliterations','2');command('mclremove','2');command('mcladd',"'untuned sample'")
reset();command('mclstart');for _=1,4 do complete('comlink') end
equal({'makecomlink hold sample one','tune comlink 12345','makecomlink hold untuned sample',
 'makecomlink hold sample one','tune comlink 12345','makecomlink hold untuned sample'})
passed('optional tuning and no-container batches')
command('mclclear');reset()
for _,args in ipairs({'unquoted',"'name' 12345 extra","'   '","'name' ''","'bad;quit'","'bad\nquit'"}) do command('mcladd',args) end
for _,args in ipairs({'0','-1','1.5','1e309'}) do command('mcliterations',args) end
command('mcllist');contains('no comlinks queued');contains('Iterations: 1');assert(#sent==0)
passed('invalid arguments, separators and nonfinite counts rejected')
command('mcladd',"'a <tag> &#abcdefsample' 12345");command('mclcontainer',"'a &#8a8f98case of samples'")
reset();command('mclstart');complete('comlink');complete('container')
equal({'makecomlink hold a <tag> &#abcdefsample','tune comlink 12345','makecontainer hold a &#8a8f98case of samples','put comlink case'})
contains('<tag>');passed('literal names and derived container keyword')
reset();command('mclstart');event('sysDisconnectionEvent');complete('comlink');assert(#sent==1)
event('sysUninstallPackage','unrelated');assert(LotJComlink)
event('sysUninstallPackage','LotJComlink');assert(not LotJComlink and count(handlers)==0)
passed('disconnect stops work; uninstall cleans only owned handlers')
dofile(core);command('mclclear');command('mcladd',"'sample' 12345")
for _,mode in ipairs({'false','nil','throw'}) do
 reset();failSend=mode;command('mclstart');complete('comlink');assert(#sent==0 and sendCalls==1)
 failSend=nil
end
reset();command('mclstart');failSend='nil';complete('comlink');assert(#sent==1 and sendCalls==2)
failSend=nil;complete('comlink');assert(sendCalls==2)
passed('transport failures stop without tuning or continuing')
command('mclclear');command('mcladd',"'sample@@other'");separator='@@'
reset();command('mclstart');assert(#sent==0);contains('batch stopped')
separator=';;';command('mclclear');command('mcladd',"'saved sample'")
local path=profile..'/LotJComlink-settings.lua'
local function bytes() local f=assert(io.open(path,'r'));local s=f:read('*a');f:close();return s end
local old=bytes();local save=table.save;table.save=function() return nil,'fixture failure' end
reset();command('mcladd',"'unsaved sample'");contains('could not save');assert(bytes()==old);table.save=save
local f=assert(io.open(path,'w'));f:write('invalid Lua !!!!');f:close()
reset();dofile(core);command('mcllist');contains('could not load');contains('no comlinks queued');assert(#sent==0)
passed('changed separator blocked at send; save failure preserves old data; corrupt settings load empty')
