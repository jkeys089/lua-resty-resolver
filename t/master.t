use Test::Nginx::Socket 'no_plan';

workers(2);

run_tests();

__DATA__


=== TEST 1: manual hosts
--- main_config
    env DNS_SERVER_IP=8.8.8.8;
--- http_config
    lua_shared_dict test_res 1m;
    init_by_lua_block {
        local resolver_master = require "resolver.master"
        local goog_master = resolver_master:new("test_res", "google.com", {os.getenv("DNS_SERVER_IP")})
        goog_master:set({
            {
                address = "17.0.0.1",
                ttl = 300
            }
        }, 1482624000)
    }
--- config
    location /t {
        content_by_lua_block {
            local k = ngx.shared.test_res:get_keys()
            local v, err = ngx.shared.test_res:get(k[1])
            ngx.say(k[1])
            ngx.say(v)
        }
    }
--- request
    GET /t
--- response_body
google.com_17.0.0.1
1482624300
--- no_error_log
[error]


=== TEST 2: query hosts
--- main_config
    env DNS_SERVER_IP=8.8.8.8;
--- http_config
    lua_shared_dict test_res 1m;
    init_by_lua_block {
        local resolver_master = require "resolver.master"
        goog_master = resolver_master:new("test_res", "google.com", {os.getenv("DNS_SERVER_IP")}, 10, 30)
    }
    init_worker_by_lua_block {
        goog_master:init()
    }
--- config
    location /t {
        content_by_lua_block {
            ngx.sleep(2)
            local keys = ngx.shared.test_res:get_keys()
            for i, k in ipairs(keys) do
                local v, err = ngx.shared.test_res:get(k)
                if v ~= "_master_" then
                    ngx.say(k)
                    ngx.say(v)
                    break
                end
            end
        }
    }
--- request
    GET /t
--- response_body_like chop
^google.com_\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}.*\d+$
--- no_error_log
[error]


=== TEST 3: multiple inits single master
--- main_config
    env DNS_SERVER_IP=8.8.8.8;
--- http_config
    lua_shared_dict test_res 1m;
    init_by_lua_block {
        local resolver_master = require "resolver.master"
        goog_master = resolver_master:new("test_res", "google.com", {os.getenv("DNS_SERVER_IP")}, 10, 30)
    }
    init_worker_by_lua_block {
        for i = 1,10 do
            goog_master:init()
        end
    }
--- config
    location /t {
        content_by_lua_block {
            ngx.sleep(2)
            local keys = ngx.shared.test_res:get_keys()
            for i, k in ipairs(keys) do
                local v, err = ngx.shared.test_res:get(k)
                if v == "_master_" then
                    ngx.say(v)
                end
            end
        }
    }
--- request
    GET /t
--- response_body_like chop
^_master_$
--- no_error_log
[error]


=== TEST 4: multiple inits multiple masters
--- main_config
    env DNS_SERVER_IP=8.8.8.8;
--- http_config
    lua_shared_dict test_res 1m;
    init_by_lua_block {
        local resolver_master = require "resolver.master"
        goog_master_a = resolver_master:new("test_res", "google.com", {os.getenv("DNS_SERVER_IP")}, 10, 30)
        goog_master_b = resolver_master:new("test_res", "google.com", {os.getenv("DNS_SERVER_IP")}, 10, 30)
        goog_master_c = resolver_master:new("test_res", "google.com", {os.getenv("DNS_SERVER_IP")}, 10, 30)
    }
    init_worker_by_lua_block {
        for i = 1,10 do
            goog_master_a:init()
            goog_master_b:init()
            goog_master_c:init()
        end
    }
--- config
    location /t {
        content_by_lua_block {
            ngx.sleep(2)
            local keys = ngx.shared.test_res:get_keys()
            for i, k in ipairs(keys) do
                local v, err = ngx.shared.test_res:get(k)
                if v == "_master_" then
                    ngx.say(v)
                end
            end
        }
    }
--- request
    GET /t
--- response_body_like chop
^_master_$
--- no_error_log
[error]


=== TEST 5: filter banned ip's
--- main_config
    env DNS_SERVER_IP=8.8.8.8;
--- http_config
    lua_shared_dict test_res 1m;
    init_by_lua_block {
        local resolver_master = require "resolver.master"
        local goog_master = resolver_master:new("test_res", "google.com", {os.getenv("DNS_SERVER_IP")})
        goog_master:set({
            {
                address = "17.0.0.1",
                ttl = 300
            },
            {
                address = "127.0.0.1", -- banned
                ttl = 300
            },
        }, 1482624000)
    }
--- config
    location /t {
        content_by_lua_block {
            local keys = ngx.shared.test_res:get_keys()
            for i, k in ipairs(keys) do
                local v, err = ngx.shared.test_res:get(k)
                if v ~= "_master_" then
                    ngx.say(k)
                    ngx.say(v)
                end
            end
        }
    }
--- request
    GET /t
--- response_body
google.com_17.0.0.1
1482624300
--- no_error_log
[error]


=== TEST 6: catch shared dict init problems
--- main_config
    env DNS_SERVER_IP=8.8.8.8;
--- http_config
    lua_shared_dict test_res 1m;
--- config
    location /t {
        content_by_lua_block {
            local resolver_master = require "resolver.master"
            local goog_master, err = resolver_master:new(nil, "google.com", {os.getenv("DNS_SERVER_IP")})
            ngx.say(err)
            goog_master, err = resolver_master:new("bad_key", "google.com", {os.getenv("DNS_SERVER_IP")})
            ngx.say(err)
        }
    }
--- request
    GET /t
--- response_body
missing shared_dict_key
missing shared_dict_key
--- no_error_log
[error]


=== TEST 7: catch domain init problems
--- main_config
    env DNS_SERVER_IP=8.8.8.8;
--- http_config
    lua_shared_dict test_res 1m;
--- config
    location /t {
        content_by_lua_block {
            local resolver_master = require "resolver.master"
            local goog_master, err = resolver_master:new("test_res", nil, {os.getenv("DNS_SERVER_IP")})
            ngx.say(err)
            goog_master, err = resolver_master:new("test_res", "", {os.getenv("DNS_SERVER_IP")})
            ngx.say(err)
            goog_master, err = resolver_master:new("test_res", "  ", {os.getenv("DNS_SERVER_IP")})
            ngx.say(err)
        }
    }
--- request
    GET /t
--- response_body
missing domain
missing domain
missing domain
--- no_error_log
[error]


=== TEST 8: catch min / max ttl init problems
--- main_config
    env DNS_SERVER_IP=8.8.8.8;
--- http_config
    lua_shared_dict test_res 1m;
--- config
    location /t {
        content_by_lua_block {
            local resolver_master = require "resolver.master"
            local goog_master, err = resolver_master:new("test_res", "google.com", {os.getenv("DNS_SERVER_IP")}, 0, 30)
            ngx.say(err)
            goog_master, err = resolver_master:new("test_res", "google.com", {os.getenv("DNS_SERVER_IP")}, -1, 30)
            ngx.say(err)
            goog_master, err = resolver_master:new("test_res", "google.com", {os.getenv("DNS_SERVER_IP")}, 10, 9)
            ngx.say(err)
        }
    }
--- request
    GET /t
--- response_body
min_ttl must be a positive number
min_ttl must be a positive number
max_ttl must >= min_ttl (10)
--- no_error_log
[error]


=== TEST 9: catch dns_timeout init problems
--- main_config
    env DNS_SERVER_IP=8.8.8.8;
--- http_config
    lua_shared_dict test_res 1m;
--- config
    location /t {
        content_by_lua_block {
            local resolver_master = require "resolver.master"
            local goog_master, err = resolver_master:new("test_res", "google.com", {os.getenv("DNS_SERVER_IP")}, 10, 30, 0)
            ngx.say(err)
            goog_master, err = resolver_master:new("test_res", "google.com", {os.getenv("DNS_SERVER_IP")}, 10, 30, -1)
            ngx.say(err)
        }
    }
--- request
    GET /t
--- response_body
dns_timeout must be a positive number
dns_timeout must be a positive number
--- no_error_log
[error]


=== TEST 10: catch nameserver init problems
--- http_config
    lua_shared_dict test_res 1m;
--- config
    location /t {
        content_by_lua_block {
            local resolver_master = require "resolver.master"
            local goog_master, err = resolver_master:new("test_res", "google.com", nil, 10, 30)
            ngx.say(err)
            goog_master, err = resolver_master:new("test_res", "google.com", {}, 10, 30)
            ngx.say(err)
        }
    }
--- request
    GET /t
--- response_body
missing nameservers
missing nameservers
--- no_error_log
[error]


=== TEST 11: bogus nameserver alerts
--- http_config
    lua_shared_dict test_res 1m;
    init_by_lua_block {
        local resolver_master = require "resolver.master"
        goog_master = resolver_master:new("test_res", "google.com", {"127.0.0.1"}, 10, 30)
    }
    init_worker_by_lua_block {
        goog_master:init()
    }
--- config
    location /t {
        echo "OK";
    }
--- request
    GET /t
--- wait: 2
--- error_log
resolver master failed to query DNS for domain 'google.com'


=== TEST 12: bogus nameserver struct causes resolver init to alert
--- http_config
    lua_shared_dict test_res 1m;
    init_by_lua_block {
        local resolver_master = require "resolver.master"
        goog_master = resolver_master:new("test_res", "google.com", {{"boom", 0}}, 10, 30)
    }
    init_worker_by_lua_block {
        goog_master:init()
    }
--- config
    location /t {
        echo "OK";
    }
--- request
    GET /t
--- wait: 2
--- error_log
resolver master failed to create resty.dns.resolver for domain 'google.com'


=== TEST 13: backup nameserver
--- main_config
    env DNS_SERVER_IP=8.8.8.8;
--- http_config
    lua_shared_dict test_res 1m;
    init_by_lua_block {
        local resolver_master = require "resolver.master"
        goog_master = resolver_master:new("test_res", "google.com", {"127.0.0.1",os.getenv("DNS_SERVER_IP")}, 1, 1)
    }
    init_worker_by_lua_block {
        goog_master:init()
    }
--- config
    location /t {
        content_by_lua_block {
            ngx.sleep(10)
            local keys = ngx.shared.test_res:get_keys()
            for i, k in ipairs(keys) do
                local v, err = ngx.shared.test_res:get_stale(k)
                if v ~= "_master_" then
                    ngx.say(k)
                    ngx.say(v)
                    break
                end
            end
        }
    }
--- request
    GET /t
--- response_body_like chop
^google.com_\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}.*\d+$
--- error_log
resolver master failed to query DNS for domain 'google.com'
--- timeout: 11


=== TEST 14: bogus domain alerts
--- main_config
    env DNS_SERVER_IP=8.8.8.8;
--- http_config
    lua_shared_dict test_res 1m;
    init_by_lua_block {
        local resolver_master = require "resolver.master"
        goog_master = resolver_master:new("test_res", "iam.notreal.fake", {os.getenv("DNS_SERVER_IP")}, 10, 30)
    }
    init_worker_by_lua_block {
        goog_master:init()
    }
--- config
    location /t {
        echo "OK";
    }
--- request
    GET /t
--- wait: 2
--- error_log
resolver master failed to resolve domain 'iam.notreal.fake'


=== TEST 15: failed init
--- main_config
    env DNS_SERVER_IP=8.8.8.8;
--- http_config
    lua_max_pending_timers 1;
    lua_shared_dict test_res 1m;
    init_by_lua_block {
        local resolver_master = require "resolver.master"
        goog_master = resolver_master:new("test_res", "google.com", {os.getenv("DNS_SERVER_IP")}, 10, 30)
    }
    init_worker_by_lua_block {
        ngx.timer.at(30, function() return true end)
        local ok, err = goog_master:init()
        if not ok then
            ngx.log(ngx.ERR, err)
        end
    }
--- config
    location /t {
        echo "OK";
    }
--- request
    GET /t
--- error_log
too many pending timers


=== TEST 16: unable to schedule resolve alerts
--- main_config
    env DNS_SERVER_IP=8.8.8.8;
--- http_config
    lua_max_pending_timers 2;
    lua_shared_dict test_res 1m;
    init_by_lua_block {
        local resolver_master = require "resolver.master"
        goog_master = resolver_master:new("test_res", "google.com", {os.getenv("DNS_SERVER_IP")}, 2, 2)
    }
    init_worker_by_lua_block {
        ngx.timer.at(0, function()
            ngx.timer.at(0, function()
                ngx.timer.at(30, function() return true end)
                ngx.timer.at(30, function() return true end)
            end)
        end)
        goog_master:init()
    }
--- config
    location /t {
        echo "OK";
    }
--- request
    GET /t
--- wait: 3
--- error_log
resolver master failed to create resolve timer for domain 'google.com'


=== TEST 17: obey min / max ttl
--- main_config
    env DNS_SERVER_IP=8.8.8.8;
--- http_config
    lua_shared_dict test_res 1m;
    init_by_lua_block {
        local resolver_master = require "resolver.master"
        local goog_master = resolver_master:new("test_res", "google.com", {os.getenv("DNS_SERVER_IP")}, 10, 30)
        goog_master:set({
            {
                address = "17.0.0.1",
                ttl = 300
            },
            {
                address = "17.0.0.2",
                ttl = 20
            },
            {
                address = "17.0.0.3",
                ttl = 1
            }
        }, 1482624000)
    }
--- config
    location /t {
        content_by_lua_block {
            local keys = ngx.shared.test_res:get_keys()
            for i, k in ipairs(keys) do
                local v, err = ngx.shared.test_res:get(k)
                ngx.say(k .. "=" .. v)
            end
        }
    }
--- request
    GET /t
--- response_body
google.com_17.0.0.1=1482624030
google.com_17.0.0.2=1482624020
google.com_17.0.0.3=1482624010
--- no_error_log
[error]


=== TEST 18: next resolve time
--- main_config
    env DNS_SERVER_IP=8.8.8.8;
--- http_config
    lua_shared_dict test_res 1m;
    init_by_lua_block {
        local resolver_master = require "resolver.master"
        goog_master = resolver_master:new("test_res", "google.com", {os.getenv("DNS_SERVER_IP")}, 10, 30, 2)
    }
--- config
    location /t {
        content_by_lua_block {
            ngx.say(goog_master:set({{
                address = "17.0.0.1",
                ttl = 300
            }}))
            ngx.say(goog_master:set({{
                address = "17.0.0.1",
                ttl = 0
            }}))
            ngx.say(goog_master:set({
                {
                    address = "17.0.0.1",
                    ttl = 15
                },
                {
                    address = "17.0.0.2",
                    ttl = 25
                },
                {
                    address = "17.0.0.3",
                    ttl = 20
                }
            }, 1482624000))
        }
    }
--- request
    GET /t
--- response_body
28
8
13
--- no_error_log
[error]


=== TEST 19: filter banned 127.0.53.53 and 127.0.0.1 ip's
--- main_config
    env DNS_SERVER_IP=8.8.8.8;
--- http_config
    lua_shared_dict test_res 1m;
    init_by_lua_block {
        local resolver_master = require "resolver.master"
        local goog_master = resolver_master:new("test_res", "google.com", {os.getenv("DNS_SERVER_IP")}, nil, nil, nil, {"127.0.0.1", "127.0.53.53"})
        goog_master:set({
            {
                address = "17.0.0.1",
                ttl = 300
            },
            {
                address = "127.0.0.1", -- banned
                ttl = 300
            },
            {
                address = "127.0.53.53", -- banned
                ttl = 300
            },
        }, 1482624000)
    }
--- config
    location /t {
        content_by_lua_block {
            local keys = ngx.shared.test_res:get_keys()
            for i, k in ipairs(keys) do
                local v, err = ngx.shared.test_res:get(k)
                if v ~= "_master_" then
                    ngx.say(k)
                    ngx.say(v)
                end
            end
        }
    }
--- request
    GET /t
--- response_body
google.com_17.0.0.1
1482624300
--- no_error_log
[error]
