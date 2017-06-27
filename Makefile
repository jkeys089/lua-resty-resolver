PREFIX ?=          /opt/openresty
LUA_LIB_DIR ?=     $(PREFIX)/lualib
INSTALL ?= install

.PHONY: all test install

all: ;

install: all
	$(INSTALL) -d $(LUA_LIB_DIR)/resolver
	$(INSTALL) lib/resolver/*.lua $(LUA_LIB_DIR)/resolver

test: install
	PATH=$(PREFIX)/nginx/sbin:$$PATH LUA_PATH="$(LUA_PATH);$(PREFIX)/lualib/?.lua;$(PREFIX)/nginx/lualib/?.lua;" prove -I../test-nginx/lib -r t

