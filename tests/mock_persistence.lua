-- Test-only serializer for synthetic nested settings; matches Mudlet's nil-on-success API.
local function encode(value)
  if type(value)=='table' then
    local parts={}
    for k,v in pairs(value) do parts[#parts+1]='['..encode(k)..']='..encode(v)..',' end
    return '{'..table.concat(parts)..'}'
  elseif type(value)=='string' then return string.format('%q',value)
  else return tostring(value) end
end
function table.save(path,value)
  local f,reason=io.open(path,'w');if not f then return nil,reason end
  f:write('return '..encode(value));f:close()
end
function table.load(path,target)
  local saved=dofile(path)
  for k,v in pairs(saved) do target[k]=v end
end
