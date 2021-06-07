package = "lua-resty-resolver"
version = "0.05-1"
source = {
   url = "git://github.com/jkeys089/lua-resty-resolver",
}
description = {
   summary = "Caching DNS resolver for ngx_lua and LuaJIT",
   detailed = [[
      A pure lua DNS resolver that supports:

      Caching DNS lookups according to upstream TTL values
      Caching DNS lookups directly from the master (i.e. don't replicate DNS queries per worker thread)
      Support for DNS-based round-robin load balancing (e.g. multiple A records for a single domain)
      Low cache contention via local worker cache (i.e. workers sync from the master using a randomized delay to avoid contention)
      Optional stale results to smooth over DNS availability issues
      Configurable min / max TTL values
      Sensible security (e.g. don't allow potentially harmful results such as 127.0.0.1)
   ]],
   homepage = "https://github.com/jkeys089/lua-resty-resolver",
   license = "MIT"
}
dependencies = {
   "lua-resty-dns >= 0.21-1"
}
build = {
   type = "builtin",
   modules = {
      ["resolver.client"] = "lib/resolver/client.lua",
      ["resolver.master"] = "lib/resolver/master.lua"
   }
}
