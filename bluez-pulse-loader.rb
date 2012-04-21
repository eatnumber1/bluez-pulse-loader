#!/usr/bin/env ruby
require 'dbus'
require 'logger'

$log = Logger.new STDOUT
$log.level = Logger::INFO
#$log.level = Logger::DEBUG

if $log.level > Logger::DEBUG
  $log.formatter = proc do |severity, datetime, progname, msg|
    "#{msg}\n"
  end
end

module DBus
  class PulseBus < Connection
    include Singleton

    def initialize
      super("unix:path=/var/run/pulse/dbus-socket")
      if connect == nil
        $log.fatal "Pulseaudio DBUS connection failed"
        exit false
      end
    end

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
end

class DBusProxy
  def initialize( opts )
    @interfaces = opts[:interfaces]
    @bus = opts[:bus]
    @object = opts[:service].object(opts[:path])
    @object.introspect
    @object.default_iface = opts[:interfaces].first
    @object.instance_exec do
      def on_signal(bus, name, &block)
        $log.debug{ "on_signal(#{bus}, #{name}, #{block})" }
        mr = DBus::MatchRule.new.from_signal(self, name)
        if block.nil?
          StopListeningForSignal("#{self.name}.#{name}")
          bus.remove_match(mr)
        else
          bus.add_match(mr) { |msg| block.call(*msg.params) }
          ListenForSignal("#{self.name}.#{name}", [])
        end
      end
    end
  end

  def method_missing(name, *args, &block)
    $log.debug{ "method_missing(#{name}, #{args}, #{block})" }
    @interfaces.each do |interface|
      begin
        # This will mask if the invoked method raises a NoMethodError, eh.
        ret = @object[interface].public_send(name, *args, &block)
        $log.debug{ "Method dispatched to #{interface}" }
        return ret
      rescue NoMethodError
      end
    end
    raise NoMethodError, "undefined method `#{name}' for the interfaces #{@interfaces} on #{@object}"
  end

  def on_signal(name, &block)
    @object.on_signal(@bus, name, &block)
  end
end

class DBusProxyFactory
  attr_accessor :bus, :service_name

  def initialize(opts = {})
    @bus = opts[:bus]
    @service_name = opts[:service_name]
  end

  def create(opts)
    DBusProxy.new({
      :service => @bus.service(@service_name),
      :bus => @bus
    }.merge(opts))
  end
end

class PulseProxyFactory < DBusProxyFactory
  COMMON_INTERFACES = [
    "org.freedesktop.DBus.Properties",
    "org.freedesktop.DBus.Introspectable"
  ]

  def initialize(opts = {})
    super({
      :bus => DBus::PulseBus.instance,
      :service_name => "org.PulseAudio.Core1"
    }.merge(opts))
  end

  def create_core(opts = {})
    create({
      :path => "/org/pulseaudio/core1",
      :interfaces => ["org.PulseAudio.Core1"] + COMMON_INTERFACES
    }.merge(opts))
  end

  def create_device(opts)
    create({
      :interfaces => ["org.PulseAudio.Core1.Device"] + COMMON_INTERFACES
    }.merge(opts))
  end

  def create_module(opts)
    create({
      :interfaces => ["org.PulseAudio.Core1.Module"] + COMMON_INTERFACES
    }.merge(opts))
  end
end

pa_factory = PulseProxyFactory.new
pa_core = pa_factory.create_core

$pa_modules = {}

pa_core["Sources"].each do |source|
  pa_source = pa_factory.create_device(:path => source)
  next unless pa_source["Driver"] == "module-bluetooth-device.c"
  pa_core["Modules"].each do |mod|
    pa_module = pa_factory.create_module(:path => mod)
    next unless pa_module["Name"] == "module-loopback"
    args = pa_module["Arguments"]
    next unless args.has_key? "source" && args["source"] == pa_source["Name"]
    $pa_modules[source] = mod
  end
  $log.info{ "Found existing bluetooth source #{pa_source["Name"]}" }
end

$pa_sink = pa_factory.create_device(:path => pa_core["Sinks"].first)["Name"]
$log.info{ "Using audio sink #{$pa_sink}" }

pa_core.on_signal("NewSource") do |source|
  $log.debug{ "NewSource(#{source})" }
  pa_source = pa_factory.create_device(:path => source)
  next unless pa_source["Driver"] == "module-bluetooth-device.c"
  name = pa_source["Name"]
  $log.info{ "Registering new audio source #{name}" }
  mod = pa_core.LoadModule("module-loopback", {
    "source" => name,
    "sink" => $pa_sink
  }).first
  $pa_modules[source] = mod
end

pa_core.on_signal("SourceRemoved") do |source|
  $log.debug{ "SourceRemoved(#{source})" }
  next unless $pa_modules.has_key?(source)
  pa_module = pa_factory.create_module(:path => $pa_modules[source])
  $log.info{ "Unregistering audio source #{pa_module["Arguments"]["source"]}" }
  pa_module.Unload()
  $pa_modules.delete(source)
end

class Agent < DBus::Object
  dbus_interface "org.bluez.Agent" do
    dbus_method :Release do
      $log.debug "Release()"
      exit false
    end

    dbus_method :RequestPinCode, "in device:o, out ret:s" do |device|
      $log.debug{ "RequestPinCode(#{device})" }
      ["0000"]
    end

    dbus_method :RequestPasskey, "in device:o, out ret:u" do |device|
      $log.debug{ "RequestPasskey(#{device})" }
      raise DBus.error("org.bluez.Error.Rejected")
    end

    dbus_method :DisplayPasskey, "in device:o, in passkey:u, in entered:y" do |device, passkey, entered|
      $log.debug{ "DisplayPasskey(#{device}, #{passkey}, #{entered})" }
      raise DBus.error("org.bluez.Error.Rejected")
    end

    dbus_method :RequestConfirmation, "in device:o, in passkey:u" do |device, passkey|
      $log.debug{ "RequestConfirmation(#{device}, #{passkey})" }
      raise DBus.error("org.bluez.Error.Rejected")
    end

    dbus_method :Authorize, "in device:o, in uuid:s" do |device, uuid|
      $log.debug{ "Authorize(#{device}, #{uuid})" }
    end

    dbus_method :ConfirmModeChange, "in mode:s" do |mode|
      $log.debug{ "ConfirmModeChange(#{mode})" }
      raise DBus.error("org.bluez.Error.Rejected")
    end

    dbus_method :Cancel do
      $log.debug "Cancel()"
      raise DBus.error("org.bluez.Error.Rejected")
    end
  end
end

bt_factory = DBusProxyFactory.new(
  :bus => DBus.system_bus,
  :service_name => "org.bluez"
)

bt_adapter = bt_factory.create(
  :path => bt_factory.create(
    :path => "/",
    :interfaces => ["org.bluez.Manager"]
  ).DefaultAdapter.first,
  :interfaces => ["org.bluez.Adapter"]
)

agent_path = "/com/eatnumber1/bluez/Agent"
$log.debug{ "Registering authentication agent at #{agent_path}" }
bt_factory.bus.request_service("com.eatnumber1.bluez.Agent").export(Agent.new(agent_path))
bt_adapter.RegisterAgent(agent_path, "NoInputNoOutput")

$log.debug "Registering shutdown handlers"
shutdown = proc do
  $log.debug "Shutting down"
  begin
    bt_adapter.UnregisterAgent(agent_path)
  rescue SystemExit
    exit true
  end
  $log.warn "Didn't get agent release message"
  exit false
end
Signal.trap "INT", &shutdown
Signal.trap "TERM", &shutdown

$log.debug 'Setting adapter name to "CSH User Center"'
bt_adapter.SetProperty("Name", "CSH User Center")

main_loop = DBus::Main.new
main_loop << bt_factory.bus
main_loop << pa_factory.bus

$log.debug "Entering main loop"
main_loop.run

# vim:ft=ruby et ts=2 sw=2 sts=2
