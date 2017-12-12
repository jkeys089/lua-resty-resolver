use Test::Nginx::Socket 'no_plan';

workers(2);

run_tests();

__DATA__


=== TEST 1: catch shared dict init problems
--- config
    location /t {
        content_by_lua_block {
            local resolver_client = require "resolver.client"
            local ok, err = resolver_client:new(nil, "google.com")
            ngx.say(err)
            ok, err = resolver_client:new("bad_key", "google.com")
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


=== TEST 2: catch domain init problems
--- http_config
    lua_shared_dict test_res 1m;
--- config
    location /t {
        content_by_lua_block {
            local resolver_client = require "resolver.client"
            local ok, err = resolver_client:new("test_res", nil)
            ngx.say(err)
            ok, err = resolver_client:new("test_res", "")
            ngx.say(err)
            ok, err = resolver_client:new("test_res", "  ")
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


=== TEST 3: catch no hosts error
--- http_config
    lua_shared_dict test_res 1m;
--- config
    location /t {
        content_by_lua_block {
            local resolver_client = require "resolver.client"
            local goog_client = resolver_client:new("test_res", "google.com")
            local ok, err = goog_client:get()
            ngx.say(err)
        }
    }
--- request
    GET /t
--- response_body
no hosts available
--- no_error_log
[error]


=== TEST 4: catch expired hosts error
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
        }, 1)
    }
    init_worker_by_lua_block {
        local resolver_client = require "resolver.client"
        goog_client = resolver_client:new("test_res", "google.com")
    }
--- config
    location /t {
        content_by_lua_block {
            local address, err = goog_client:get()
            ngx.say(err)
        }
    }
--- request
    GET /t
--- response_body
all hosts expired
--- no_error_log
[error]


=== TEST 5: get an address
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
        })
    }
    init_worker_by_lua_block {
        local resolver_client = require "resolver.client"
        goog_client = resolver_client:new("test_res", "google.com")
    }
--- config
    location /t {
        content_by_lua_block {
            local address, err = goog_client:get()
            ngx.say(address)
        }
    }
--- request
    GET /t
--- response_body
17.0.0.1
--- no_error_log
[error]


=== TEST 6: get stale address
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
        }, 1)
    }
    init_worker_by_lua_block {
        local resolver_client = require "resolver.client"
        goog_client = resolver_client:new("test_res", "google.com")
    }
--- config
    location /t {
        content_by_lua_block {
            local address, err = goog_client:get(true)
            ngx.say(address)
        }
    }
--- request
    GET /t
--- response_body
17.0.0.1
--- no_error_log
[error]


=== TEST 7: get round-robin
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
                address = "17.0.0.2",
                ttl = 300
            },
            {
                address = "17.0.0.3",
                ttl = 300
            }
        })
    }
    init_worker_by_lua_block {
        local resolver_client = require "resolver.client"
        goog_client = resolver_client:new("test_res", "google.com")
    }
--- config
    location /t {
        content_by_lua_block {
            local address, err = goog_client:get()
            ngx.say(address)
            address, err = goog_client:get()
            ngx.say(address)
            address, err = goog_client:get()
            ngx.say(address)
            address, err = goog_client:get()
            ngx.say(address)
            address, err = goog_client:get()
            ngx.say(address)
            address, err = goog_client:get()
            ngx.say(address)
        }
    }
--- request
    GET /t
--- response_body
17.0.0.1
17.0.0.2
17.0.0.3
17.0.0.1
17.0.0.2
17.0.0.3
--- no_error_log
[error]


=== TEST 8: skip expired
--- main_config
    env DNS_SERVER_IP=8.8.8.8;
--- http_config
    lua_shared_dict test_res 1m;
    init_by_lua_block {
        local resolver_master = require "resolver.master"
        local goog_master = resolver_master:new("test_res", "google.com", {os.getenv("DNS_SERVER_IP")})
        local exp_offset = ngx.now() - 30
        goog_master:set({
            {
                address = "17.0.0.1",
                ttl = 10
            },
            {
                address = "17.0.0.2",
                ttl = 10
            },
            {
                address = "17.0.0.3",
                ttl = 300
            }
        }, exp_offset)
    }
    init_worker_by_lua_block {
        local resolver_client = require "resolver.client"
        goog_client = resolver_client:new("test_res", "google.com")
    }
--- config
    location /t {
        content_by_lua_block {
            local address, err = goog_client:get()
            ngx.say(address)
            address, err = goog_client:get(true)
            ngx.say(address)
        }
    }
--- request
    GET /t
--- response_body
17.0.0.3
17.0.0.3
--- no_error_log
[error]


=== TEST 9: select least expired
--- main_config
    env DNS_SERVER_IP=8.8.8.8;
--- http_config
    lua_shared_dict test_res 1m;
    init_by_lua_block {
        local resolver_master = require "resolver.master"
        local goog_master = resolver_master:new("test_res", "google.com", {os.getenv("DNS_SERVER_IP")})
        local exp_offset = ngx.now() - 30
        goog_master:set({
            {
                address = "17.0.0.1",
                ttl = 20
            },
            {
                address = "17.0.0.2",
                ttl = 25
            },
            {
                address = "17.0.0.3",
                ttl = 15
            }
        }, exp_offset)
    }
    init_worker_by_lua_block {
        local resolver_client = require "resolver.client"
        goog_client = resolver_client:new("test_res", "google.com")
    }
--- config
    location /t {
        content_by_lua_block {
            local address, err = goog_client:get(true)
            ngx.say(address)
            address, err = goog_client:get(true)
            ngx.say(address)
        }
    }
--- request
    GET /t
--- response_body
17.0.0.2
17.0.0.2
--- no_error_log
[error]


=== TEST 10: obey ttl for re-sync
--- main_config
    env DNS_SERVER_IP=8.8.8.8;
--- http_config
    lua_shared_dict test_res 1m;
    init_by_lua_block {
        local resolver_master = require "resolver.master"
        goog_master = resolver_master:new("test_res", "google.com", {os.getenv("DNS_SERVER_IP")}, 1)
        goog_master:set({
            {
                address = "17.0.0.1",
                ttl = 2
            }
        })
    }
    init_worker_by_lua_block {
        local resolver_client = require "resolver.client"
        goog_client = resolver_client:new("test_res", "google.com")
        ngx.timer.at(1, function()
            goog_master:set({
                {
                    address = "17.0.0.2",
                    ttl = 30
                }
            })
        end)
    }
--- config
    location /t {
        content_by_lua_block {
            local address, err = goog_client:get()
            ngx.say(address)
            ngx.sleep(1)
            address, err = goog_client:get()
            ngx.say(address)
            ngx.sleep(1)
            address, err = goog_client:get()
            ngx.say(address)
        }
    }
--- request
    GET /t
--- response_body
17.0.0.1
17.0.0.1
17.0.0.2
--- no_error_log
[error]
--- timeout: 3


=== TEST 11: don't wipe stale local entries on failed re-sync
--- main_config
    env DNS_SERVER_IP=8.8.8.8;
--- http_config
    lua_shared_dict test_res 1m;
    init_by_lua_block {
        local resolver_master = require "resolver.master"
        goog_master = resolver_master:new("test_res", "google.com", {os.getenv("DNS_SERVER_IP")}, 1)
        goog_master:set({
            {
                address = "17.0.0.1",
                ttl = 1
            }
        })
    }
    init_worker_by_lua_block {
        local resolver_client = require "resolver.client"
        goog_client = resolver_client:new("test_res", "google.com")
        ngx.timer.at(1, function()
            goog_master:set({
                {
                    address = "17.0.0.2",
                    ttl = 1
                }
            })
        end)
    }
--- config
    location /t {
        content_by_lua_block {
            local address, err = goog_client:get()
            ngx.say(address)
            ngx.sleep(2.5)
            address, err = goog_client:get()
            ngx.say(address)
            address, err = goog_client:get(true)
            ngx.say(address)
        }
    }
--- request
    GET /t
--- response_body
17.0.0.1
nil
17.0.0.1
--- no_error_log
[error]
--- timeout: 3


=== TEST 12: sync picks up changes
--- main_config
    env DNS_SERVER_IP=8.8.8.8;
--- http_config
    lua_shared_dict test_res 1m;
    init_by_lua_block {
        local resolver_master = require "resolver.master"
        goog_master = resolver_master:new("test_res", "google.com", {os.getenv("DNS_SERVER_IP")}, 1)
        goog_master:set({
            {
                address = "17.0.0.1",
                ttl = 1
            }
        })
    }
    init_worker_by_lua_block {
        local resolver_client = require "resolver.client"
        goog_client = resolver_client:new("test_res", "google.com")
        ngx.timer.at(1, function()
            goog_master:set({
                {
                    address = "17.0.0.2",
                    ttl = 1
                }
            })
        end)
    }
--- config
    location /t {
        content_by_lua_block {
            local address, err = goog_client:get()
            ngx.say(address)
            ngx.sleep(1)
            address, err = goog_client:get()
            ngx.say(address)
            ngx.sleep(1)
            address, err = goog_client:get()
            ngx.say(address)
            address, err = goog_client:get(true)
            ngx.say(address)
        }
    }
--- request
    GET /t
--- response_body
17.0.0.1
17.0.0.2
nil
17.0.0.2
--- no_error_log
[error]
--- timeout: 3


