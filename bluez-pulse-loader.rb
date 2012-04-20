#!/usr/bin/env ruby
require 'dbus'

#$DEBUG = true

module DBus
  class PulseBus < Connection
    include Singleton

    def initialize
      super("unix:path=/var/run/pulse/dbus-socket")
      if connect == nil
        $stderr.puts("Pulseaudio DBUS connection failed")
        exit false
      end
    end
  end
end

pa_bus = DBus::PulseBus.instance
pa_bus.instance_exec do
  class PulseProxy
      def AddMatch(mrs)
      end
  end

  def proxy
    if @proxy == nil
      @proxy = PulseProxy.new
    end
    @proxy
  end
end

pa_service = pa_bus.service("org.PulseAudio.Core1")
pa_core_obj = pa_service.object("/org/pulseaudio/core1")
pa_core_obj.default_iface = "org.PulseAudio.Core1"
pa_core_obj.introspect
pa_core = pa_core_obj["org.PulseAudio.Core1"]
pa_core.instance_exec do
  def on_signal(bus, name, &block)
    puts "on_signal(#{bus}, #{name}, #{block})" if $BT_DEBUG
    mr = DBus::MatchRule.new.from_signal(self, name)
    if block.nil?
      StopListeningForSignal("#{self.name}.#{name}", [])
      bus.remove_match(mr)
    else
      bus.add_match(mr) { |msg| block.call(*msg.params) }
      ListenForSignal("#{self.name}.#{name}", [])
    end
  end
end

$pa_modules = {}

pa_core["Sources"].each do |source|
  pa_source_obj = pa_service.object(source)
  pa_source_obj.introspect
  pa_source = pa_source_obj["org.PulseAudio.Core1.Device"]
  next unless pa_source["Driver"] == "module-bluetooth-device.c"
  pa_core["Modules"].each do |mod|
    pa_module_obj = pa_service.object(mod)
    pa_module_obj.introspect
    pa_module = pa_module_obj["org.PulseAudio.Core1.Module"]
    next unless pa_module["Name"] == "module-loopback"
    args = pa_module["Arguments"]
    next unless args.has_key? "source"
    name = pa_source["Name"]
    next unless args["source"] == name
    $pa_modules[source] = mod
  end
  puts "Found existing bluetooth source #{pa_source["Name"]}"
end

$pa_sink = pa_service.object(pa_core["Sinks"].first)
$pa_sink.introspect
$pa_sink = $pa_sink["org.PulseAudio.Core1.Device"]["Name"]
puts "Using audio sink #{$pa_sink}"

pa_core_obj.on_signal("NewSource") do |source|
  puts "NewSource(#{source})" if $BT_DEBUG
  pa_source_obj = pa_service.object(source)
  pa_source_obj.introspect
  pa_source = pa_source_obj["org.PulseAudio.Core1.Device"]
  next unless pa_source["Driver"] == "module-bluetooth-device.c"
  name = pa_source["Name"]
  print "Registering new audio source #{name}... "
  mod = pa_core.LoadModule("module-loopback", {
    "source" => name,
    "sink" => $pa_sink
  }).first
  $pa_modules[source] = mod
  puts "OK"
end

pa_core_obj.on_signal("SourceRemoved") do |source|
  puts "SourceRemoved(#{source})" if $BT_DEBUG
  next unless $pa_modules.has_key?(source)
  pa_module_obj = pa_service.object($pa_modules[source])
  pa_module_obj.introspect
  pa_module = pa_module_obj["org.PulseAudio.Core1.Module"]
  print "Unregistering audio source #{pa_module["Arguments"]["source"]}... "
  pa_module.Unload()
  $pa_modules.delete(source)
  puts "OK"
end

class Agent < DBus::Object
  dbus_interface "org.bluez.Agent" do
    dbus_method :Release do
      puts "Release()" if $BT_DEBUG
      exit false
    end

    dbus_method :RequestPinCode, "in device:o, out ret:s" do |device|
      puts "RequestPinCode(#{device})" if $BT_DEBUG
      ["0000"]
    end

    dbus_method :RequestPasskey, "in device:o, out ret:u" do |device|
      puts "RequestPasskey(#{device})" if $BT_DEBUG
      #[0]
      raise DBus.error("org.bluez.Error.Rejected")
    end

    dbus_method :DisplayPasskey, "in device:o, in passkey:u, in entered:y" do |device, passkey, entered|
      puts "DisplayPasskey(#{device}, #{passkey}, #{entered})" if $BT_DEBUG
      raise DBus.error("org.bluez.Error.Rejected")
    end

    dbus_method :RequestConfirmation, "in device:o, in passkey:u" do |device, passkey|
      puts "RequestConfirmation(#{device}, #{passkey})" if $BT_DEBUG
      raise DBus.error("org.bluez.Error.Rejected")
    end

    dbus_method :Authorize, "in device:o, in uuid:s" do |device, uuid|
      puts "Authorize(#{device}, #{uuid})" if $BT_DEBUG
    end

    dbus_method :ConfirmModeChange, "in mode:s" do |mode|
      puts "ConfirmModeChange(#{mode})" if $BT_DEBUG
      raise DBus.error("org.bluez.Error.Rejected")
    end

    dbus_method :Cancel do
      puts "Cancel()" if $BT_DEBUG
      raise DBus.error("org.bluez.Error.Rejected")
    end
  end
end

bus = DBus.system_bus
bt_service = bus.service("org.bluez")

bt_manager = bt_service.object("/")
bt_manager.introspect
bt_adapter = bt_service.object(bt_manager["org.bluez.Manager"].DefaultAdapter.first)
bt_adapter.introspect
bt_adapter.default_iface = "org.bluez.Adapter"

agent_path = "/com/eatnumber1/bluez/Agent"
bus.request_service("com.eatnumber1.bluez.Agent").export(Agent.new(agent_path))
bt_adapter.RegisterAgent(agent_path, "NoInputNoOutput")

shutdown = proc do
  puts "Shutting down" if $BT_DEBUG
  begin
    bt_adapter.UnregisterAgent(agent_path)
  rescue SystemExit
    exit true
  end
end
Signal.trap "INT", &shutdown
Signal.trap "TERM", &shutdown

bt_adapter.SetProperty("Name", "CSH User Center")

main_loop = DBus::Main.new
main_loop << bus
main_loop << pa_bus

puts "Entering main loop" if $BT_DEBUG
main_loop.run

# vim:ft=ruby et ts=2 sw=2 sts=2
