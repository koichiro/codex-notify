# frozen_string_literal: true

require_relative 'destination_name'

module CodexNotify
  class DestinationResolver
    class Error < StandardError; end

    Resolution = Struct.new(
      :destination,
      :token,
      :channel,
      :token_source,
      :channel_source,
      keyword_init: true
    )

    def initialize(selection_sources:, profile_sources:, default_sources:)
      @selection_sources = selection_sources
      @profile_sources = profile_sources
      @default_sources = default_sources
    end

    def resolve(destination:, token:, channel:)
      selected = destination || selection_sources.lookup('CODEX_NOTIFY_DESTINATION')&.value
      return resolve_default(token:, channel:) unless selected

      resolve_profile(DestinationName.normalize(selected), token:, channel:)
    rescue DestinationName::Error => e
      raise Error, e.message
    end

    private

    attr_reader :selection_sources, :profile_sources, :default_sources

    def resolve_profile(destination, token:, channel:)
      channel_key = "SLACK_CHANNEL__#{destination}"
      profile_channel = profile_sources.lookup(channel_key)
      raise Error, "destination #{destination} is not configured: missing #{channel_key}" unless profile_channel

      profile_token = profile_sources.lookup("SLACK_BOT_TOKEN__#{destination}") unless token
      default_token = profile_sources.lookup('SLACK_BOT_TOKEN') unless token || profile_token
      resolved_token = token || profile_token&.value || default_token&.value
      raise Error, "destination #{destination} has no Slack bot token" unless resolved_token

      Resolution.new(
        destination:,
        token: resolved_token,
        channel: channel || profile_channel.value,
        token_source: token ? nil : (profile_token || default_token)&.source,
        channel_source: channel ? nil : profile_channel.source
      )
    end

    def resolve_default(token:, channel:)
      token_result = default_sources.lookup('SLACK_BOT_TOKEN') unless token
      channel_result = default_sources.lookup('SLACK_CHANNEL') unless channel
      Resolution.new(
        destination: nil,
        token: token || token_result&.value,
        channel: channel || channel_result&.value,
        token_source: token_result&.source,
        channel_source: channel_result&.source
      )
    end
  end
end
