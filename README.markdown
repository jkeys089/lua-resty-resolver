Name
====

lua-resty-resolver - Caching DNS resolver for ngx_lua and LuaJIT


Table of Contents
=================

* [Name](#name)
* [Status](#status)
* [Description](#description)
* [Motivation](#motivation)
* [Synopsis](#synopsis)
* [Master Methods](#master-methods)
    * [new](#master-new)
    * [init](#master-init)
    * [set](#master-set)
    * [client](#master-client)
* [Client Methods](#client-methods)
    * [new](#client-new)
    * [get](#client-get)
* [Prerequisites](#prerequisites)
* [Installation](#installation)
* [Copyright and License](#copyright-and-license)
* [See Also](#see-also)


Status
======

This library is still under active development and is considered production ready.


Description
===========

A pure lua DNS resolver that supports:

*   Caching DNS lookups according to upstream TTL values
*   Caching DNS lookups directly from the master (i.e. don't replicate DNS queries per worker thread)
*   Support for DNS-based round-robin load balancing (e.g. multiple A records for a single domain)
*   Low cache contention via local worker cache (i.e. workers sync from the master using a randomized delay to avoid contention)
*   Optional stale results to smooth over DNS availability issues
*   Configurable min / max TTL values
*   Sensible security (e.g. don't allow potentially harmful results such as `127.0.0.1`)


Motivation
==========

Q: Why would you want to use this library?

A: You want dynamic DNS resolution [like they have in Nginx Plus](http://nginx.org/en/docs/http/ngx_http_upstream_module.html#resolve)

As of nginx v1.9.x you'll need a commercial license to dynamically resolve upstream server names. The opensource version doesn't support this feature and will simply resolve each domain once and cache it forever (i.e. until nginx restart).
There are [workarounds](https://forum.nginx.org/read.php?2,248924,248924#msg-248924) but they are less than ideal (e.g. don't support [keepalive](http://nginx.org/en/docs/http/ngx_http_upstream_module.html#keepalive)).

This module allows us to use the standard, open source [OpenResty bundle](https://openresty.org) _and_ get the benefits of dynamic upstream name resolution without sacrificing features like keepalive.


Synopsis
========

```lua
    # nginx.conf:

    http {
        lua_package_path "/path/to/lua-resty-resolver/lib/?.lua;;";

        # global dns cache (may be shared for multiple domains but for best perf use separate zone per domain)
        lua_shared_dict dns_cache 1m;

        # create a global master which caches DNS answers according to upstream TTL
        init_by_lua_block {
            local err
            cdnjs_master, err = require("resolver.master"):new("dns_cache", "cdnjs.cloudflare.com", {"8.8.8.8"})
            if not cdnjs_master then
                error("failed to create cdnjs resolver master: " .. err)
            end
        }

        # create a per-worker client that periodically syncs from the master cache (again, according to TTL values)
        init_worker_by_lua_block {
            cdnjs_master:init() -- master `init` must be called from a worker since it uses `ngx.timer.at`, it is ok to call multiple times
            local err
            cdnjs_client, err = cdnjs_master:client()
            if not cdnjs_client then
                error("failed to create cdnjs resolver client: " .. err)
            end
        }

        # use per-worker client to lookup host address
        upstream cdnjs_backend {
            server 0.0.0.1;   # just an invalid address as a place holder

            balancer_by_lua_block {
                -- note: if `lua_code_cache` is `off` then you'll need to uncomment the next line
                -- local cdnjs_client = require("resolver.client"):new("dns_cache", "cdnjs.cloudflare.com")
                local address, err = cdnjs_client:get(true)
                if not address then
                    ngx.log(ngx.ERR, "failed to lookup address for cdnjs: ", err)
                    return ngx.exit(500)
                end

                local ok, err = require("ngx.balancer").set_current_peer(address, 80)
                if not ok then
                    ngx.log(ngx.ERR, "failed to set the current peer for cdnjs: ", err)
                    return ngx.exit(500)
                end
            }

            keepalive 10;     # connection pool MUST come after balancer_by_lua_block
        }

        server {
            location =/status {
                content_by_lua_block {
                    local address, err = cdnjs_client:get()
                    if address then
                        ngx.say("OK")
                    else
                        ngx.say(err)
                        ngx.exit(ngx.HTTP_SERVICE_UNAVAILABLE)
                    end
                }
            }

            location = /js {
                proxy_pass http://cdnjs_backend/
                proxy_pass_header Server;
                proxy_http_version 1.1;
                proxy_set_header Connection "";
                proxy_set_header Host cdnjs.cloudflare.com;
            }
        }
    }
```

[Back to TOC](#table-of-contents)


Master Methods
==============

To load the master library,

1. you need to specify this library's path in ngx_lua's [lua_package_path](https://github.com/openresty/lua-nginx-module#lua_package_path) directive. For example, `lua_package_path "/path/to/lua-resty-resolver/lib/?.lua;;";`.
2. you use `require` to load the library into a local Lua variable:

```lua
    local resolver_master = require "resolver.master"
```


master new
----------
`syntax: local master, err = resolver_master:new(shared_dict_key, domain, nameservers [, min_ttl, max_ttl, dns_timeout, blacklist])`

Creates a new master instance. Returns the instance and an error string.
If successful the error string will be `nil`.
If failed, the the instance will be `nil` and the error string will be populated.

The `shared_dict_key` argument specifies the [ngx.shared](https://github.com/openresty/lua-nginx-module#ngxshareddict) key to use for cached DNS values.
It is OK to use the same shared dict for multiple domains (i.e. masters are careful not to interfere with other masters resolving other domains).
However, for best performance it is recommended to use a different shared dict for each domain.

The `domain` argument specifies the fully qualified domain name to resolve.

The `nameservers` argument specifies the list of nameservers to query (see the `nameservers` param in of [resty.dns.resolver:new](https://github.com/openresty/lua-resty-dns#new).

The `min_ttl` argument specifies the minimum allowable time in seconds to cache the results of a DNS query.
The default value is `10`.

The `max_ttl` argument specifies the maximum allowable time in seconds to cache the results of a DNS query.
The default value is `3600` (1 hour).

The `dns_timeout` argument determines the maximum amount of time in seconds to wait for DNS results.
We also use this value to schedule future DNS queries (i.e. query a bit earlier than the TTL suggests to allow for potential lag up to the `dns_timeout` value when receiving the results).
**Note:** this is _NOT_ the total timeout for all nameservers. The total time is calculated as `dns_timeout * 5` since we use the default `retrans` value in [resty.dns.resolver:new](https://github.com/openresty/lua-resty-dns#new).
The default value is `2`.

The `blacklist` argument specifies table of banned IP addresses which are ignored if included in DNS server response.
The default value is `{"127.0.0.1"}`.

The master instance is thread safe and can be safely shared globally (typically declared as a global in a [init_by_lua_block](https://github.com/openresty/lua-nginx-module#init_by_lua_block)).

[Back to TOC](#table-of-contents)


master init
-----------
`syntax: local ok, err = master:init()`

Initializes a master instance and causes the master to populate the cache ASAP. Returns a success indicator and an error string.
If successful the success indicator will be truthy and the error string will be `nil`.
If failed, the success indicator will be falsy and the error string will be populated.

The `init` method **MUST** be called in a context that supports the use of [ngx.timer.at](https://github.com/openresty/lua-nginx-module#ngxtimerat) (e.g. the first usable entrypoint is [init_worker_by_lua_block](https://github.com/openresty/lua-nginx-module#init_worker_by_lua_block)).
This method is idempotent and can be safely called any number of times without any impact.

[Back to TOC](#table-of-contents)


master set
----------
`syntax: local next_query_delay = master:set(lookup_result [, exp_offset])`

Caches the DNS query results. Returns the amount of time in seconds to delay before querying again.

The `lookup_result` argument is a table containing successful query results (i.e. each entry is a table with IPv4 `address` and `ttl` seconds keys).

The `exp_offset` argument is the expiration offset to use with each record's TTL (useful for testing).
The default value is the current timestamp determined by [ngx.now](https://github.com/openresty/lua-nginx-module#ngxnow)

This method should not be used in normal operation and is only really useful for testing.

[Back to TOC](#table-of-contents)


master client
----------
`syntax: local client, err = master:client()`

Convenience method for creating a new client.
Exactly the same as calling [resolver_client:new](#client-new) with the same `shared_dict_key` and `domain` used by the master instance.

[Back to TOC](#table-of-contents)


Client Methods
==============

To load the client library,

1. you need to specify this library's path in ngx_lua's [lua_package_path](https://github.com/openresty/lua-nginx-module#lua_package_path) directive. For example, `lua_package_path "/path/to/lua-resty-resolver/lib/?.lua;;";`.
2. you use `require` to load the library into a local Lua variable:

```lua
    local resolver_client = require "resolver.client"
```

[Back to TOC](#table-of-contents)


client new
----------
`syntax: local client, err = resolver_client:new(shared_dict_key, domain)`

Creates a new client instance. Returns the instance and an error string.
If successful the error string will be `nil`.
If failed, the the instance will be `nil` and the error string will be populated.

The `shared_dict_key` argument specifies the [ngx.shared](https://github.com/openresty/lua-nginx-module#ngxshareddict) key to use for cached DNS values and should be the same value used when creating the master instance.

The `domain` argument specifies the fully qualified domain name to resolve and should be the same value used when creating the master instance.

Client instances are _NOT_ thread safe and should be shared only at the worker level (typically declared as a global in a [init_worker_by_lua_block](https://github.com/openresty/lua-nginx-module#init_worker_by_lua_block)).
**Note:** when [lua_code_cache](https://github.com/openresty/lua-nginx-module#lua_code_cache) is `off` (e.g. during development) it is not possible to use a global, per-worker client due to the new lua VM per-request model.

[Back to TOC](#table-of-contents)


client get
----------
`syntax: local address, err = client:get([exp_fallback_ok])`

Retrieve the next cached address using a simple round-robin algorithm to choose when multiple addresses are available. Returns an IPv4 address string and an error string.
If successful the error string will be `nil`.
If failed, the the address will be `nil` and the error string will be populated.

The `exp_fallback_ok` argument is a boolean which determines if it is OK to return a stale value (`true` when a stale value is allowable, `false` when it is NOT ok to return a stale value).
A stale value is one that has been cached longer than the TTL duration. If there is even one fresh record it will always be returned, even when `exp_fallback_ok` is `true`.
The default value is `false`.

Clients will automatically sync from the master cache as needed.
Under normal conditions there should never be a situation where the client has no fresh records. However, if the upstream nameserver becomes unavailable the local cache may expire while the master continues to retry.
The client will always retain at least one stale record so that it may continue to service requests until the upstream nameserver becomes available.
It may be preferable to return an error rather than use stale results which is why the `exp_fallback_ok` option defaults to `false`.

[Back to TOC](#table-of-contents)


Prerequisites
=============

* [LuaJIT](http://luajit.org) 2.0+
* [ngx_lua module](http://wiki.nginx.org/HttpLuaModule)
* [lua-resty-dns](https://github.com/openresty/lua-resty-dns)

These all come with the standard [OpenResty bundle](http://openresty.org).

[Back to TOC](#table-of-contents)


Installation
============

It is recommended to use the latest [OpenResty bundle](http://openresty.org) directly. You'll need to enable LuaJIT when building your ngx_openresty
bundle by passing the `--with-luajit` option to its `./configure` script.

Also, you'll need to configure the [lua_package_path](https://github.com/openresty/lua-nginx-module#lua_package_path) directive to
add the path of your lua-resty-resolver source tree to ngx_lua's Lua module search path, as in

```nginx
    # nginx.conf
    http {
        lua_package_path "/path/to/lua-resty-resolver/lib/?.lua;;";
        ...
    }
```

and then load the library in Lua:

```lua
    local resolver_master = require "resolver.master"
```

[Back to TOC](#table-of-contents)


Copyright and License
=====================

This module is licensed under the BSD license.

Copyright (C) 2012-2019, Thought Foundry Inc.

All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

* Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

* Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

[Back to TOC](#table-of-contents)


See Also
========
* the ngx_lua module: http://wiki.nginx.org/HttpLuaModule

[Back to TOC](#table-of-contents)

