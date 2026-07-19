# frozen_string_literal: true

require 'dotenv'
require 'fileutils'
require 'pathname'
require 'tempfile'
require 'yaml'
require_relative 'config_diagnostics'
require_relative 'destination_name'
require_relative 'trusted_config_loader'

module CodexNotify
  class ConfigMigrator
    PROFILE_KEYS = {
      'SLACK_BOT_TOKEN__' => 'token',
      'SLACK_CHANNEL__' => 'channel'
    }.freeze
    ENV_POLICIES = %w[legacy restricted].freeze

    class Error < StandardError; end

    def initialize(app_root:, environment: ENV, stdout: $stdout, stderr: $stderr)
      @app_root = Pathname(app_root).expand_path
      @environment = environment
      @stdout = stdout
      @stderr = stderr
    end

    def run(env_path:, env_explicit:, config_path: nil)
      source = source_path(env_path, explicit: env_explicit)
      target = target_path(config_path)
      validate_paths(source, target)

      ConfigDiagnostics.warn_if_env_file_insecure(source, stderr: @stderr)
      values = Dotenv.parse(source.to_s)
      document = build_document(values)
      write_config(target, YAML.dump(document))
      @stdout.puts("Created trusted config file #{target}.")
      @stdout.puts('Verify the destination settings, then remove migrated secrets from the legacy env file manually.')
      0
    rescue SystemCallError => e
      raise Error, "could not migrate configuration: #{e.class}"
    end

    private

    def source_path(path, explicit:)
      return Pathname(path).expand_path if explicit

      @app_root.join('.env')
    end

    def target_path(path)
      return Pathname(path).expand_path if path

      TrustedConfigLoader.new(environment: @environment, stderr: @stderr).default_path
    end

    def validate_paths(source, target)
      raise Error, "legacy env file does not exist: #{source}" unless source.exist?
      raise Error, "legacy env path is not a file: #{source}" unless source.file?
      raise Error, 'legacy env file and config output path must be different' if source == target
      raise Error, "config file already exists: #{target}" if target.exist?
    end

    def build_document(values)
      document = {}
      add_policy(document, values['CODEX_NOTIFY_ENV_POLICY'])
      add_default_destination(document, values)
      add_destinations(document, values)
      raise Error, 'legacy env file contains no trusted settings to migrate' if document.empty?

      document
    end

    def add_policy(document, raw_policy)
      return if empty?(raw_policy)

      policy = raw_policy.strip.downcase
      unless ENV_POLICIES.include?(policy)
        raise Error, "environment policy must be one of: #{ENV_POLICIES.join(', ')}"
      end

      document['env_policy'] = policy
    end

    def add_default_destination(document, values)
      destination = {}
      destination['token'] = values['SLACK_BOT_TOKEN'] unless empty?(values['SLACK_BOT_TOKEN'])
      destination['channel'] = values['SLACK_CHANNEL'] unless empty?(values['SLACK_CHANNEL'])
      document['default_destination'] = destination unless destination.empty?
    end

    def add_destinations(document, values)
      destinations = {}
      original_names = {}
      values.each do |key, value|
        next if empty?(value)

        prefix, field = PROFILE_KEYS.find { |candidate, _| key.start_with?(candidate) }
        next unless prefix

        raw_name = key.delete_prefix(prefix)
        name = DestinationName.normalize(raw_name)
        previous = original_names[name]
        if previous && previous != raw_name
          raise Error, "destination name is duplicated after normalization: #{name}"
        end

        original_names[name] = raw_name
        destinations[name] ||= {}
        destinations[name][field] = value
      end

      destinations.sort.each do |name, destination|
        raise Error, "destination #{name} must define channel" unless destination.key?('channel')
      end
      document['destinations'] = destinations.sort.to_h unless destinations.empty?
    rescue DestinationName::Error => e
      raise Error, e.message
    end

    def write_config(path, contents)
      FileUtils.mkdir_p(path.dirname, mode: 0o700)
      raise Error, "config file already exists: #{path}" if path.exist?

      Tempfile.create(['codex-notify-config', '.tmp'], path.dirname.to_s) do |file|
        file.chmod(0o600)
        file.write(contents)
        file.flush
        file.fsync
        File.link(file.path, path.to_s)
      rescue Errno::EEXIST
        raise Error, "config file already exists: #{path}"
      end
    end

    def empty?(value)
      !value || value.strip.empty?
    end
  end
end
