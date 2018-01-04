local ngx = require "ngx"
local client = require "resolver.client"
local resolver = require "resty.dns.resolver"
local setmetatable = setmetatable


local _M = { _VERSION = '0.02' }

local mt = { __index = _M }

local resolve, schedule

schedule = function(master, delay)
    local ok, err = ngx.timer.at(delay, function(premature, master) 
        if not premature then
            resolve(master)
        end
    end, master)

    if not ok then
       ngx.log(ngx.CRIT, "resolver master failed to create resolve timer for domain '", master._domain, "': ", err)
    end
end


resolve = function(master)
    local res, err = resolver:new({
        nameservers = master._nameservers,
        timeout = master._timeout * 1000
    })
    if not res then
        ngx.log(ngx.CRIT, "resolver master failed to create resty.dns.resolver for domain '", master._domain, "': ", err)
        return
    end

    local domain = master._domain
    local ns_cnt = #master._nameservers

    local answers, err

    while ns_cnt ~= 0 do
        answers, err = res:query(domain, master._qopts)
        if not answers then
            -- unable to even send the query, move along
            err = "resolver master failed to query DNS for domain '" .. domain .. "': " .. err
            ngx.log(ngx.DEBUG, err)
            ns_cnt = ns_cnt - 1
        else
            if answers.errcode then
                -- executed the query but got a bad result, move along
                err = "resolver master failed to resolve domain '" .. domain .. "': [" .. answers.errcode .. "] " .. answers.errstr
                ngx.log(ngx.DEBUG, err)
                ns_cnt = ns_cnt - 1
            else
                -- we got a usable result!
                err = nil
                ns_cnt = 0
            end
        end
    end

    if err then
        -- exhausted all nameservers and couldn't get a usable result
        ngx.log(ngx.ERR, err)
        schedule(master, master._min_ttl)
        return
    end

    -- DNS query was successful, store the result and schedule the next lookup
    schedule(master, master:set(answers))
end


function _M.new(class, shared_dict_key, domain, nameservers, min_ttl, max_ttl, dns_timeout, blacklist)
    if not shared_dict_key or not ngx.shared[shared_dict_key] then
        return nil, "missing shared_dict_key"
    end

    local domain = (domain or ""):match("^%s*(.*%S)")
    if not domain then
        return nil, "missing domain"
    end

    if not nameservers or #nameservers < 1 then
        return nil, "missing nameservers"
    end

    local minttl = min_ttl or 10
    if minttl <= 0 then
        return nil, "min_ttl must be a positive number"
    end

    local maxttl = max_ttl or 3600
    if maxttl < minttl then
        return nil, "max_ttl must >= min_ttl (" .. minttl .. ")"
    end

    local timeout = dns_timeout or 2
    if timeout <= 0 then
        return nil, "dns_timeout must be a positive number"
    end

    blacklist = blacklist or { "127.0.0.1" }
    if type(blacklist) ~= 'table' then
        return nil, "blacklist must be a table"
    end
    local blacklist_table = {}
    for _, l in ipairs(blacklist) do blacklist_table[l] = true end

    local self = setmetatable({
        _name        = "_master_[" .. domain .. "]_",
        _shared_key  = shared_dict_key,
        _domain      = domain,
        _domain_pref = domain .. "_",
        _qopts       = { qtype = resolver.TYPE_A },
        _min_ttl     = minttl,
        _max_ttl     = maxttl,
        _timeout     = timeout,
        _nameservers = nameservers,
        _blacklist   = blacklist_table
    }, mt)

    return self, nil
end


function _M.init(self)
    local added, err, forced = ngx.shared[self._shared_key]:add(self._name, "_master_")
    if added then
        return ngx.timer.at(0, function(premature, master)
            if not premature then
                resolve(master)
            end
        end, self)
    end
    return true, nil
end


function _M.client(self)
    return client:new(self._shared_key, self._domain)
end


function _M.set(self, lookup_result, exp_offset)
    local prefix = self._domain_pref
    local cache = ngx.shared[self._shared_key]
    local minttl = self._min_ttl
    local maxttl = self._max_ttl
    local blacklist = self._blacklist
    local timeout = self._timeout
    local next_res = maxttl
    local exp_offset = exp_offset or ngx.now()

    for i, ans in ipairs(lookup_result) do
        if not blacklist[ans.address] then
            local ttl = ans.ttl

            if ttl < minttl then
                ttl = minttl
            elseif ttl > maxttl then
                ttl = maxttl
            end

            -- let the smallest returned TTL determine when we'll query again
            if ttl < next_res then
                next_res = ttl
            end

            local exp = exp_offset + ttl

            cache:set(prefix .. ans.address, exp, ttl)
        end
    end

    if next_res > timeout then
        next_res = next_res - timeout
    end

    return next_res
end


return _M
