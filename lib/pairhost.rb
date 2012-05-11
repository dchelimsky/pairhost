require "pairhost/version"
require 'fog'
require 'thor'
require 'yaml'
require 'fileutils'

module Pairhost
  def self.config_file
    @config_file ||= File.expand_path('~/.pairhost/config.yml')
  end

  def self.config
    @config ||= begin
      unless File.exists?(config_file)
        abort "pairhost: No config found. First run 'pairhost init'."
      end
      YAML.load_file(config_file)
    end
  end

  def self.instance_id
    return @instance_id unless @instance_id.nil?

    file = File.expand_path('~/.pairhost/instance')
    @instance_id = File.read(file).chomp if File.exists?(file)
    return @instance_id
  end

  def self.connection
    return @connection if @connection

    Fog.credentials = Fog.credentials.merge(
      :private_key_path => config['private_key_path'],
    )

    @connection = Fog::Compute.new(
      :provider              => config['provider'],
      :aws_secret_access_key => config['aws_secret_access_key'],
      :aws_access_key_id     => config['aws_access_key_id'],
    )
  end

  def self.create(name)
    server_options = {
      "tags" => {"Name" => name,
                 "Created-By-Pairhost-Gem" => VERSION},
      "image_id" => config['ami_id'],
      "flavor_id" => config['flavor_id'],
      "key_name" => config['key_name'],
    }

    server = connection.servers.create(server_options)
    server.wait_for { ready? }

    @instance_id = server.id
    write_instance_id(@instance_id)

    server
  end

  def self.write_instance_id(instance_id)
    File.open(File.expand_path('~/.pairhost/instance'), "w") do |f|
      f.write(instance_id)
    end
  end

  def self.start(server)
    server.start
    server.wait_for { ready? }
  end

  def self.stop(server)
    server.stop
    server.wait_for { state == "stopped" }
  end

  def self.fetch!
    server = fetch
    abort "pairhost: No instance found. Please create or attach to one." if server.nil?
  end

  def self.fetch
    config
    connection.servers.get(instance_id) if instance_id
  end

  class CLI < Thor
    include Thor::Actions

    desc "verify", "Verify the config is in place"
    def verify
      Pairhost.config
    end

    desc "init", "Setup your ~/.pairhost directory with default config"
    def init
      if File.exists?(Pairhost.config_file)
        STDERR.puts "pairhost: Already initialized."
      else
        FileUtils.mkdir_p File.dirname(Pairhost.config_file)
        FileUtils.cp(File.dirname(__FILE__) + '/../config.example.yml', Pairhost.config_file)
      end
    end

    desc "create", "Provision a new pairhost; all future commands affect this pairhost"
    def create
      invoke :verify
      initials = `git config user.initials`.chomp.split("/").map(&:upcase).join(" ")
      default_name = "something1 #{initials}"
      name = ask_with_default("What to name your pairhost? [#{default_name}]", default_name)
      puts "Name will be: #{name}"
      puts "Provisioning..."
      server = Pairhost.create(name)
      puts "provisioned!"
      invoke :status
    end

    map "start" => :resume

    desc "resume", "Start a stopped pairhost"
    def resume
      invoke :verify
      server = Pairhost.fetch!
      puts "Starting..."
      Pairhost.start(server.reload)
      puts "started!"

      invoke :status
    end

    desc "up", "Create a new pairhost or start your stopped pairhost"
    def up
      invoke :verify
      server = Pairhost.fetch

      if server
        invoke :resume
      else
        invoke :create
      end
    end

    desc "status", "Print the status of your pairhost"
    def status
      invoke :verify
      server = Pairhost.fetch!
      puts "#{server.id}: #{server.tags['Name']}"
      puts "State: #{server.state}"
      puts server.dns_name if server.dns_name
    end

    desc "ssh", "SSH to your pairhost"
    def ssh
      invoke :verify
      server = Pairhost.fetch!
      exec "ssh -A -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=QUIET pair@#{server.dns_name}"
    end

    map "halt" => :stop
    map "shutdown" => :stop
    map "suspend" => :stop

    desc "stop", "Stop your pairhost"
    def stop
      invoke :verify
      server = Pairhost.fetch!
      puts "Shutting down..."
      Pairhost.stop(server)
      puts "shutdown!"
    end

    map "terminate" => :destroy

    desc "destroy", "Terminate your pairhost"
    def destroy
      invoke :verify
      server = Pairhost.fetch!
      confirm = ask("Type 'yes' to confirm deleting '#{server.tags['Name']}'.\n>")

      return unless confirm == "yes"

      puts "Destroying..."
      server.destroy
      server.wait_for { state == "terminated" }
      puts "destroyed!"
    end

    desc "provision", "Freshen the Chef recipes"
    def provision
      invoke :verify
      # TODO implement
      puts "Coming soon..."
    end

    desc "attach INSTANCE", "All future commands affect the pairhost with the given EC2 instance ID"
    def attach(instance_id)
      invoke :verify, []
      Pairhost.write_instance_id(instance_id)
      invoke :status, []
    end

    desc "detach", "Forget the currently-attached pairhost"
    def detach
      invoke :verify
      # TODO implement
      puts "Coming soon..."
    end

    private

    def ask_with_default(question, default)
      answer = ask(question)
      answer = answer.strip.empty? ? default : answer
      answer
    end
  end
end
