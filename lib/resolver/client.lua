local ngx = require "ngx"
local setmetatable = setmetatable


local _M = { _VERSION = '1.0-1' }

local mt = { __index = _M }


-- reverse sort (i.e. descending order)
local function revsort(a, b)
    return a > b
end


-- sync from master
local function sync(worker)
    local hosts = {}
    local domain = worker._domain
    local domain_len = worker._domain_len
    local address_start = worker._address_start
    local cache = ngx.shared[worker._shared_key]
    local next_sync = 2147483647

    cache:flush_expired()

    for i, k in pairs(cache:get_keys(0)) do
        if k:sub(1, domain_len) == domain then
            local exp, err = cache:get(k)
            if exp then
                if exp < next_sync then
                    next_sync = exp
                end                
                hosts[#hosts+1] = {
                    address = k:sub(address_start),
                    exp = exp
                }
            end
        end
    end

    if #hosts > 0 then
        if next_sync >= 1 then 
            next_sync = next_sync - 1
        end
        worker._hosts = hosts
        worker._next_sync = next_sync + math.random() -- try not to have all workers attempting to sync at the exact same moment
    end
end


function _M.new(class, shared_dict_key, domain)
    if not shared_dict_key or not ngx.shared[shared_dict_key] then
        return nil, "missing shared_dict_key"
    end

    local domain = (domain or ""):match("^%s*(.*%S)")
    if not domain then
        return nil, "missing domain"
    end

    local self = setmetatable({
        _shared_key    = shared_dict_key,
        _domain        = domain,
        _domain_pref   = domain .. "_",
        _domain_len    = domain:len(),
        _address_start = domain:len() + 2,
        _hosts         = {},
        _next_idx      = 1,
        _next_sync     = 0
    }, mt)

    return self, nil
end


function _M.get(self, exp_fallback_ok)
    local hosts = self._hosts
    local tot = #hosts
    local now = ngx.now()

    -- re-sync only if necessary
    if tot < 1 or now > self._next_sync then
        sync(self)
        hosts = self._hosts
        tot = #hosts
    end
    
    if tot < 1 then
        return nil, "no hosts available"
    end

    local fallback_idx, host, address, err
    local idx = self._next_idx
    local exp_idxs = {}
    local cnt = 0
    
    while not host and cnt < tot do
        if idx > tot then
            idx = 1
        end

        local cur_host = hosts[idx]

        if cur_host.exp > now then
            host = cur_host
        else                        
            if not fallback_idx or cur_host.exp > hosts[fallback_idx].exp then
                fallback_idx = idx
            end
                
            exp_idxs[#exp_idxs+1] = idx

            idx = idx + 1
            cnt = cnt + 1
        end
    end

    if host then
        address = host.address
        self._next_idx = idx + 1
    elseif exp_fallback_ok then
        address = hosts[fallback_idx].address
    else
        err = "all hosts expired"
    end

    -- remove expired hosts leaving just one fallback
    if #exp_idxs > 1 then
        table.sort(exp_idxs, revsort)
        for i, eidx in ipairs(exp_idxs) do
            if eidx ~= fallback_idx then
                table.remove(hosts, eidx)
            end
        end
    end

    return address, err
end


return _M
