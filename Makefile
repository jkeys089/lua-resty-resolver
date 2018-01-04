PREFIX ?=          /opt/openresty
LUA_LIB_DIR ?=     $(PREFIX)/lualib
INSTALL ?= install
DNS_SERVER_IP ?= 8.8.8.8

.PHONY: all test install

all: ;

install: all
	$(INSTALL) -d $(LUA_LIB_DIR)/resolver
	$(INSTALL) lib/resolver/*.lua $(LUA_LIB_DIR)/resolver

test: install
	PATH=$(PREFIX)/nginx/sbin:$$PATH LUA_PATH="$(LUA_PATH);$(PREFIX)/lualib/?.lua;$(PREFIX)/nginx/lualib/?.lua;" DNS_SERVER_IP=$(DNS_SERVER_IP) prove -I../test-nginx/lib -r t

