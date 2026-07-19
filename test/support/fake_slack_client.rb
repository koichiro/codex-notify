# frozen_string_literal: true

module HookTestSupport
  class FakeSlackClient
    attr_reader :posts

    def initialize(root_ts: '1000.01', &handler)
      @root_ts = root_ts
      @handler = handler
      @posts = []
    end

    def post(text, thread_ts: nil)
      posts << [text, thread_ts]
      return @handler.call(text, thread_ts) if @handler

      { 'ok' => true, 'ts' => (thread_ts || @root_ts) }
    end
  end

  def hook_runner_factory(client:, store: nil)
    lambda do |**options|
      CodexNotify::HookRunner.new(**options, client:, store:)
    end
  end
end
