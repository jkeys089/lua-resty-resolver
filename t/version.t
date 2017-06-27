# vim:set ft= ts=4 sw=4 et:

use Test::Nginx::Socket 'no_plan';

run_tests();

__DATA__

=== TEST 1: master version
--- http_config
    lua_shared_dict ver 12k;
    init_by_lua_block {
        local resolver_master = require "resolver.master"
        ngx.shared.ver:set("version", resolver_master._VERSION)
    }
--- config
    location /t {
        content_by_lua_block {
            local ver, err = ngx.shared.ver:get("version")
            ngx.say("version" .. ver)
        }
    }
--- request
    GET /t
--- response_body_like chop
^version\d+\.\d+$



=== TEST 2: worker version
--- http_config
    upstream backend {
        server 0.0.0.1;   # just an invalid address as a place holder

        balancer_by_lua_block {
            local balancer = require "ngx.balancer"
            balancer.set_current_peer("127.0.0.1", 8080)
            local resolver_client = require "resolver.client"
            ngx.log(ngx.ERR, "version", resolver_client._VERSION)
        }
    }
    server {
        listen 8080;
        location = /fake {
            echo "OK";
        }
    }
--- config
    location /t {
        proxy_pass http://backend/fake;
    }
--- request
    GET /t
--- error_log eval
qr/version\d+\.\d+/