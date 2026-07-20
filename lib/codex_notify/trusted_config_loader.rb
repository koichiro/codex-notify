# frozen_string_literal: true

require 'pathname'
require 'yaml'
require_relative 'config_diagnostics'
require_relative 'destination_name'

module CodexNotify
  class TrustedConfigLoader
    DEFAULT_RELATIVE_PATH = Pathname('codex-notify/config.yml')
    TOP_LEVEL_KEYS = %w[env_policy default_destination destinations].freeze
    DESTINATION_KEYS = %w[token channel].freeze
    ENV_POLICIES = %w[legacy restricted].freeze

    class Error < StandardError; end

    ConfigFile = Data.define(:kind, :path, :values)

    def initialize(environment: ENV, home: nil, stderr: $stderr)
      @environment = environment
      @home = home
      @stderr = stderr
    end

    def load(explicit_path: nil)
      files = []
      explicit = explicit_path && Pathname(explicit_path).expand_path
      files << load_file(explicit, kind: :config_explicit, required: true) if explicit

      default = default_path
      files << load_file(default, kind: :config, required: false) unless explicit == default
      files.compact
    end

    def default_path
      xdg_home = environment['XDG_CONFIG_HOME']
      if xdg_home && !xdg_home.empty?
        base = Pathname(xdg_home)
        raise Error, 'XDG_CONFIG_HOME must be an absolute path' unless base.absolute?

        return base.join(DEFAULT_RELATIVE_PATH)
      end

      home_path = home || environment['HOME']
      home_path = Dir.home if !home_path || home_path.empty?
      Pathname(home_path).expand_path.join('.config', DEFAULT_RELATIVE_PATH)
    rescue ArgumentError, SystemCallError => e
      raise Error, "could not resolve the home configuration directory: #{e.class}"
    end

    private

    attr_reader :environment, :home

    def load_file(path, kind:, required:)
      unless path.exist?
        raise Error, "config file does not exist: #{path}" if required

        return nil
      end
      raise Error, "config path is not a file: #{path}" unless path.file?

      ConfigDiagnostics.warn_if_file_insecure(path, label: 'config file', stderr: @stderr)
      document = YAML.safe_load_file(
        path.to_s,
        permitted_classes: [],
        permitted_symbols: [],
        aliases: false
      )
      ConfigFile.new(kind:, path:, values: validate(document))
    rescue Psych::Exception
      raise Error, "config file is not valid safe YAML: #{path}"
    rescue SystemCallError => e
      raise Error, "could not read config file #{path}: #{e.class}"
    end

    def validate(document)
      mapping = require_mapping(document, 'configuration')
      reject_unknown_keys(mapping, TOP_LEVEL_KEYS, 'configuration')

      values = {}
      apply_policy(mapping, values)
      apply_default_destination(mapping, values)
      apply_destinations(mapping, values)
      values.freeze
    end

    def apply_policy(mapping, values)
      return unless mapping.key?('env_policy')

      policy = require_string(mapping['env_policy'], 'env_policy').strip.downcase
      unless ENV_POLICIES.include?(policy)
        raise Error, "env_policy must be one of: #{ENV_POLICIES.join(', ')}"
      end

      values['CODEX_NOTIFY_ENV_POLICY'] = policy
    end

    def apply_default_destination(mapping, values)
      return unless mapping.key?('default_destination')

      destination = require_mapping(mapping['default_destination'], 'default_destination')
      reject_unknown_keys(destination, DESTINATION_KEYS, 'default_destination')
      raise Error, 'default_destination must define token or channel' if destination.empty?

      assign_string(destination, 'token', values, 'SLACK_BOT_TOKEN', context: 'default_destination')
      assign_string(destination, 'channel', values, 'SLACK_CHANNEL', context: 'default_destination')
    end

    def apply_destinations(mapping, values)
      return unless mapping.key?('destinations')

      destinations = require_mapping(mapping['destinations'], 'destinations')
      normalized_names = {}
      destinations.each do |raw_name, raw_destination|
        raise Error, 'destination names must be strings' unless raw_name.is_a?(String)

        name = DestinationName.normalize(raw_name)
        raise Error, "destination name is duplicated after normalization: #{name}" if normalized_names.key?(name)

        normalized_names[name] = true
        destination = require_mapping(raw_destination, "destination #{name}")
        reject_unknown_keys(destination, DESTINATION_KEYS, "destination #{name}")
        raise Error, "destination #{name} must define channel" unless destination.key?('channel')

        assign_string(destination, 'token', values, "SLACK_BOT_TOKEN__#{name}", context: "destination #{name}")
        assign_string(destination, 'channel', values, "SLACK_CHANNEL__#{name}", context: "destination #{name}")
      end
    rescue DestinationName::Error => e
      raise Error, e.message
    end

    def assign_string(mapping, key, values, output_key, context:)
      return unless mapping.key?(key)

      values[output_key] = require_string(mapping[key], "#{context}.#{key}")
    end

    def require_mapping(value, label)
      raise Error, "#{label} must be a mapping" unless value.is_a?(Hash)
      raise Error, "#{label} keys must be strings" unless value.keys.all? { |key| key.is_a?(String) }

      value
    end

    def require_string(value, label)
      raise Error, "#{label} must be a non-empty string" unless value.is_a?(String) && !value.strip.empty?

      value
    end

    def reject_unknown_keys(mapping, allowed, label)
      unknown = mapping.keys - allowed
      return if unknown.empty?

      raise Error, "#{label} contains unknown keys"
    end
  end
end
