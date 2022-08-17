#! /usr/bin/env ruby
# frozen_string_literal: true

# find the library without external help
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "dbus"

def peer_address
  return "unix:path=/run/user/11018/pulse/dbus-socket"
  bus = DBus::SessionBus.instance
  svc = bus["org.PulseAudio1"]
  obj = svc["/org/pulseaudio/server_lookup1"]
  ifc = obj["org.PulseAudio.ServerLookup1"]
  ifc["Address"]
end

conn = DBus::Connection.new(peer_address)
no_svc = DBus::ProxyPeerService.new(conn)
obj = no_svc["/org/pulseaudio/core1"]
ifc = obj["org.PulseAudio.Core1"]
p ifc["Name"]
