#!/usr/bin/env ruby
require 'dbus'
require 'json'

json_filename = "devices.json"
json_data = nil
begin
  File.open(json_filename) do |file|
    file.flock(File::LOCK_SH)
    data = file.read
    if data == ""
      json_data = []
    else
      json_data = JSON.parse(data)
    end
  end
rescue Errno::ENOENT
  json_data = []
end

bus = DBus.system_bus
bt_service = bus.service("org.bluez")

# TODO: Save the authorized devices.

#$authorized_devices = []

class SoundMaster
  attr_reader :devices

  def initialize( bluez_service, pulse_service, devices )
    @bluez_service = bluez_service
    @pulse_service = pulse_service
    devices.each do |device|
      add_device device
    end
  end

  def add_device( device )
    puts "add_device(#{device})"
    @devices.push(device)
    audio(device) do |audio|
      address = audio["org.bluez.Device"].GetProperties.first["Address"]
      audio.on_signal("PropertyChanged") do |name, value|
        puts "PropertyChanged(#{name}, #{value})"
        next unless name == "State"
        next unless value == "connected" || value == "disconnected"
        case value
        when "connected"
          puts "\t-> #{address} connected"
        when "disconnected"
          puts "\t-> #{address} disconnected"
        end
      end
    end
  end

  def remove_device( device )
    puts "remove_device(#{device})"
    audio(device) do |audio|
      audio.on_signal("PropertyChanged")
    end
    @devices.delete(device)
  end

  private
  def audio( device, &block )
    audio = @bluez_service.object(device)
    audio.introspect
    audio.default_iface = "org.bluez.AudioSource"
    block.call(audio)
  end
end

class Agent < DBus::Object
  def initialize( path, soundMaster )
    @soundMaster = soundMaster
    super(path)
  end

  dbus_interface "org.bluez.Agent" do
    dbus_method :Release do
      puts "Release()"
      exit false
    end

    dbus_method :RequestPinCode, "in device:o, out ret:s" do |device|
      puts "RequestPinCode(#{device})"
      ["0000"]
    end

    dbus_method :RequestPasskey, "in device:o, out ret:u" do |device|
      puts "RequestPasskey(#{device})"
      #[0]
      raise DBus.error("org.bluez.Error.Rejected")
    end

    dbus_method :DisplayPasskey, "in device:o, in passkey:u, in entered:y" do |device, passkey, entered|
      puts "DisplayPasskey(#{device}, #{passkey}, #{entered})"
      raise DBus.error("org.bluez.Error.Rejected")
    end

    dbus_method :RequestConfirmation, "in device:o, in passkey:u" do |device, passkey|
      puts "RequestConfirmation(#{device}, #{passkey})"
      raise DBus.error("org.bluez.Error.Rejected")
    end

    dbus_method :Authorize, "in device:o, in uuid:s" do |device, uuid|
      puts "Authorize(#{device}, #{uuid})"
      #$authorized_devices += device
      @soundMaster.add_device(device)
    end

    dbus_method :ConfirmModeChange, "in mode:s" do |mode|
      puts "ConfirmModeChange(#{mode})"
      raise DBus.error("org.bluez.Error.Rejected")
    end

    dbus_method :Cancel do
      puts "Cancel()"
      raise DBus.error("org.bluez.Error.Rejected")
    end
  end
end

sm = SoundMaster.new(bt_service, nil, json_data)
agent_path = "/com/eatnumber1/bluez/Agent"
bus.request_service("com.eatnumber1.bluez.Agent").export(Agent.new(agent_path, sm))

bt_manager = bt_service.object("/")
bt_manager.introspect
bt_adapter = bt_service.object(bt_manager["org.bluez.Manager"].DefaultAdapter.first)
bt_adapter.introspect
bt_adapter.default_iface = "org.bluez.Adapter"
bt_adapter.RegisterAgent(agent_path, "NoInputNoOutput")

shutdown = proc do
  puts "Shutting down"
  File.open(json_filename, "w") do |file|
    file.flock(File::LOCK_EX)
    file.write(sm.devices.to_json)
  end
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

puts "Entering main loop"
main_loop.run

# vim:ft=ruby et ts=2 sw=2 sts=2
